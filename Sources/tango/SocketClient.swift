import Foundation
import Darwin
import ClaudeToolCore

enum SocketClientError: Error, CustomStringConvertible {
    case connectFailed(Int32)
    case writeFailed(Int32)
    case readFailed(Int32)
    case daemonNotRunning(String)
    case invalidResponse(String)

    var description: String {
        switch self {
        case .connectFailed(let e):
            return "connect failed: \(String(cString: strerror(e)))"
        case .writeFailed(let e):
            return "write failed: \(String(cString: strerror(e)))"
        case .readFailed(let e):
            return "read failed: \(String(cString: strerror(e)))"
        case .daemonNotRunning(let path):
            return "Tango daemon not reachable at \(path). Is Tango.app running?"
        case .invalidResponse(let s):
            return "invalid daemon response: \(s)"
        }
    }
}

struct SocketClient {
    let socketPath: String

    init(socketPath: String = SocketPaths.controlSocket.path) {
        self.socketPath = socketPath
    }

    func ask(_ request: AskRequest) throws -> AskReply {
        let fd = try connect()
        defer { close(fd) }

        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        try writeAll(fd: fd, data: data)
        // Half-close write side so server can detect end-of-request if it ever does;
        // our server protocol uses newline so this is just a courtesy.
        shutdown(fd, SHUT_WR)

        let respData = try readAll(fd: fd)
        let decoder = JSONDecoder()
        if let reply = try? decoder.decode(AskReply.self, from: respData) {
            return reply
        }
        if let errEnv = try? decoder.decode([String: String].self, from: respData),
           let msg = errEnv["error"] {
            throw SocketClientError.invalidResponse(msg)
        }
        let preview = String(data: respData, encoding: .utf8) ?? "<binary>"
        throw SocketClientError.invalidResponse(preview)
    }

    private func connect() throws -> Int32 {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw SocketClientError.daemonNotRunning(socketPath)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketClientError.connectFailed(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLen = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: pathLen) { dst in
                socketPath.withCString { src in
                    strncpy(dst, src, pathLen - 1)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, len)
            }
        }
        if res != 0 {
            let err = errno
            close(fd)
            if err == ENOENT || err == ECONNREFUSED {
                throw SocketClientError.daemonNotRunning(socketPath)
            }
            throw SocketClientError.connectFailed(err)
        }
        return fd
    }

    private func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var written = 0
            while written < buf.count {
                let n = Darwin.write(fd, base + written, buf.count - written)
                if n <= 0 { throw SocketClientError.writeFailed(errno) }
                written += n
            }
        }
    }

    private func readAll(fd: Int32) throws -> Data {
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketClientError.readFailed(errno)
            }
            out.append(chunk, count: n)
        }
        if let nlIdx = out.firstIndex(of: 0x0A) {
            return out.prefix(upTo: nlIdx)
        }
        return out
    }
}
