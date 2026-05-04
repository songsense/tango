import Foundation

public enum Gesture: String, Codable, Sendable, CaseIterable {
    case yes
    case yesAlways = "yes-always"
    case no
}

public enum AskResponse: String, Codable, Sendable {
    case yes
    case yesAlways = "yes-always"
    case no
    case timeout
    case cancelled
}

public enum ResponseSource: String, Codable, Sendable {
    case pat
    case button
    case timeout
    case cancelled
}

public struct AskRequest: Codable, Sendable {
    public let op: String
    public let prompt: String
    public let timeout: TimeInterval
    public let context: AskContext?

    public init(prompt: String, timeout: TimeInterval, context: AskContext? = nil) {
        self.op = "ask"
        self.prompt = prompt
        self.timeout = timeout
        self.context = context
    }
}

public struct AskContext: Codable, Sendable {
    public let toolName: String?
    public let command: String?

    public init(toolName: String? = nil, command: String? = nil) {
        self.toolName = toolName
        self.command = command
    }
}

public struct AskReply: Codable, Sendable {
    public let response: AskResponse
    public let via: ResponseSource
    public let pats: Int?

    public init(response: AskResponse, via: ResponseSource, pats: Int? = nil) {
        self.response = response
        self.via = via
        self.pats = pats
    }
}

public enum SocketPaths {
    public static var controlSocket: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Tango/control.sock")
    }

    public static var supportDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Tango", isDirectory: true)
    }
}
