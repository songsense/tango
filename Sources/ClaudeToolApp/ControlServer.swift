import Foundation
import Darwin
import ClaudeToolCore

public final class ControlServer: @unchecked Sendable {
    public let socketPath: String
    private let handler: ControlHandler
    private let acceptQueue = DispatchQueue(label: "tango.control.accept", qos: .userInitiated)
    private let lock = NSLock()
    private var serverFd: Int32 = -1
    private var running: Bool = false

    public init(socketPath: String, handler: ControlHandler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    public func start() throws {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            lock.unlock()
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        unlink(socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < pathLen else {
            close(fd)
            lock.unlock()
            throw NSError(domain: "Tango", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket path too long"])
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: pathLen) { dst in
                socketPath.withCString { src in
                    strncpy(dst, src, pathLen - 1)
                }
            }
        }

        let socketLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socketLen)
            }
        }
        guard bindRes == 0 else {
            let err = errno
            close(fd)
            lock.unlock()
            throw POSIXError(.init(rawValue: err) ?? .EIO)
        }

        guard listen(fd, 8) == 0 else {
            let err = errno
            close(fd)
            lock.unlock()
            throw POSIXError(.init(rawValue: err) ?? .EIO)
        }

        chmod(socketPath, 0o600)
        serverFd = fd
        running = true
        lock.unlock()

        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        let fd = serverFd
        serverFd = -1
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = serverFd
            let isRunning = running
            lock.unlock()
            guard isRunning, fd >= 0 else { break }

            let clientFd = accept(fd, nil, nil)
            if clientFd < 0 {
                if errno == EINTR { continue }
                if errno == EBADF || errno == EINVAL { break }
                continue
            }
            let handler = self.handler
            Task.detached(priority: .userInitiated) {
                await Self.handleConnection(fd: clientFd, handler: handler)
            }
        }
    }

    private static func handleConnection(fd: Int32, handler: ControlHandler) async {
        defer { close(fd) }

        guard let requestData = readUntilNewline(fd: fd) else {
            writeError(fd: fd, message: "empty request")
            return
        }

        let decoder = JSONDecoder()
        guard let request = try? decoder.decode(AskRequest.self, from: requestData) else {
            writeError(fd: fd, message: "invalid JSON")
            return
        }

        guard request.op == "ask" else {
            writeError(fd: fd, message: "unsupported op: \(request.op)")
            return
        }

        let reply = await handler.handle(request)
        writeReply(fd: fd, reply: reply)
    }

    private static func readUntilNewline(fd: Int32, maxBytes: Int = 65_536) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while buffer.count < maxBytes {
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { break }
            for i in 0..<n {
                if chunk[i] == 0x0A {
                    buffer.append(chunk, count: i)
                    return buffer
                }
            }
            buffer.append(chunk, count: n)
        }
        return buffer.isEmpty ? nil : buffer
    }

    private static func writeReply(fd: Int32, reply: AskReply) {
        let encoder = JSONEncoder()
        guard var data = try? encoder.encode(reply) else { return }
        data.append(0x0A)
        writeAll(fd: fd, data: data)
    }

    private static func writeError(fd: Int32, message: String) {
        let payload: [String: String] = ["error": message]
        guard var data = try? JSONEncoder().encode(payload) else { return }
        data.append(0x0A)
        writeAll(fd: fd, data: data)
    }

    private static func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var written = 0
            while written < buf.count {
                let n = Darwin.write(fd, base + written, buf.count - written)
                if n <= 0 { return }
                written += n
            }
        }
    }
}
