import ArgumentParser
import Foundation
import ClaudeToolCore

struct Hook: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Wire a Claude Code hook event to the daemon.",
        subcommands: [PreToolUse.self, Notification.self]
    )
}

struct HookInputPreToolUse: Decodable {
    let session_id: String?
    let tool_name: String?
    let tool_input: [String: AnyJSON]?
}

struct HookInputNotification: Decodable {
    let session_id: String?
    let message: String?
}

enum AnyJSON: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case object([String: AnyJSON])
    case array([AnyJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([String: AnyJSON].self) { self = .object(v); return }
        if let v = try? c.decode([AnyJSON].self) { self = .array(v); return }
        self = .null
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

extension Hook {
    struct PreToolUse: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pretooluse",
            abstract: "Reads a Claude PreToolUse JSON payload from stdin and emits a permission decision to stdout."
        )

        @Option(name: .long, help: "Override the configured timeout (seconds).")
        var timeout: Double?

        func run() throws {
            let stdin = FileHandle.standardInput.readDataToEndOfFile()
            let input = (try? JSONDecoder().decode(HookInputPreToolUse.self, from: stdin)) ?? HookInputPreToolUse(session_id: nil, tool_name: nil, tool_input: nil)
            let toolName = input.tool_name ?? "tool"
            let commandPreview = previewCommand(toolName: toolName, input: input.tool_input)

            // Explicitly allow tango's own commands so Claude Code doesn't
            // fall back to its built-in permission dialog, which would block
            // the tap that was meant for the tango ask notification.
            if let cmd = input.tool_input?["command"]?.stringValue,
               isTangoCommand(cmd) {
                emitAllow(reason: "tango: self")
                return
            }

            let config = (try? ConfigStore.shared.load()) ?? AppConfig()
            let mode = config.hooks.preToolUse.mode
            if mode == .whitelist {
                let key = commandPreview.map { "\(toolName):\($0)" } ?? toolName
                let allowed = config.hooks.preToolUse.whitelist.contains(where: { key.hasPrefix($0) || toolName == $0 })
                if !allowed {
                    // Fall through: don't intercept; let Claude do its normal permission flow.
                    print("{}")
                    return
                }
            }

            let req = AskRequest(
                prompt: "Allow \(toolName)?",
                timeout: timeout ?? config.detection.timeoutSeconds,
                context: AskContext(toolName: toolName, command: commandPreview)
            )
            let reply: AskReply
            do {
                reply = try SocketClient().ask(req)
            } catch {
                FileHandle.standardError.write(Data("tango: \(error)\n".utf8))
                print("{}")
                return
            }
            emitDecision(reply: reply)
        }

        private func previewCommand(toolName: String, input: [String: AnyJSON]?) -> String? {
            switch toolName {
            case "Bash":
                return input?["command"]?.stringValue
            case "Read":
                return input?["file_path"]?.stringValue.map { "Read \(shortPath($0))" }
            case "Write":
                return input?["file_path"]?.stringValue.map { "Write \(shortPath($0))" }
            case "Edit", "MultiEdit":
                return input?["file_path"]?.stringValue.map { "Edit \(shortPath($0))" }
            case "WebFetch":
                if let url = input?["url"]?.stringValue {
                    return (URL(string: url)?.host).map { "Fetch \($0)" } ?? "Fetch URL"
                }
            case "WebSearch":
                return input?["query"]?.stringValue.map { "Search: \"\($0)\"" }
            case "Grep":
                if let pattern = input?["pattern"]?.stringValue {
                    let loc = input?["path"]?.stringValue.map { " in \(shortPath($0))" } ?? ""
                    return "Search \"\(pattern)\"\(loc)"
                }
            case "Glob":
                return input?["pattern"]?.stringValue.map { "Find \($0)" }
            case "EnterPlanMode":
                return "Switch to plan mode — review before I start acting"
            case "ExitPlanMode":
                return "Commit plan and begin execution"
            case "Agent":
                return input?["description"]?.stringValue.map { "Launch agent: \($0)" } ?? "Launch sub-agent"
            case "TodoWrite":
                return "Update task list"
            default:
                break
            }
            // Generic fallback: pick the first recognisable string field.
            guard let input else { return nil }
            if let cmd = input["command"]?.stringValue { return cmd }
            if let path = input["file_path"]?.stringValue { return path }
            if let url = input["url"]?.stringValue { return url }
            return nil
        }

        private func isTangoCommand(_ cmd: String) -> Bool {
            // Match bare "tango …" or any absolute path ending in "/tango …"
            let exe = cmd.split(separator: " ").first.map(String.init) ?? cmd
            return exe == "tango" || exe.hasSuffix("/tango")
        }

        private func shortPath(_ path: String) -> String {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let rel = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
            // Show last 2 components to keep it scannable.
            let parts = rel.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count > 3 {
                return "…/" + parts.suffix(2).joined(separator: "/")
            }
            return rel
        }

        private func emitAllow(reason: String) {
            let payload: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "permissionDecisionReason": reason
                ]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            } else {
                print("{}")
            }
        }

        private func emitDecision(reply: AskReply) {
            let decision: String
            switch reply.response {
            case .yes, .yesAlways: decision = "allow"
            case .no: decision = "deny"
            case .timeout, .cancelled:
                print("{}")
                return
            }
            let payload: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": decision,
                    "permissionDecisionReason": "tango: \(reply.via.rawValue)"
                ]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            } else {
                print("{}")
            }
        }
    }

    struct Notification: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "notification",
            abstract: "Reads a Claude Notification JSON payload from stdin and waits for a pat acknowledgement."
        )

        @Option(name: .long, help: "Override the configured timeout (seconds).")
        var timeout: Double?

        func run() throws {
            let stdin = FileHandle.standardInput.readDataToEndOfFile()
            let input = (try? JSONDecoder().decode(HookInputNotification.self, from: stdin)) ?? HookInputNotification(session_id: nil, message: nil)
            let message = input.message ?? "Claude needs your attention"

            let config = (try? ConfigStore.shared.load()) ?? AppConfig()
            let req = AskRequest(
                prompt: message,
                timeout: timeout ?? config.detection.timeoutSeconds,
                context: nil
            )
            do {
                _ = try SocketClient().ask(req)
            } catch {
                FileHandle.standardError.write(Data("tango: \(error)\n".utf8))
            }
            // Notification hook does not require a structured reply.
            print("{}")
        }
    }
}
