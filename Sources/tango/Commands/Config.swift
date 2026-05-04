import ArgumentParser
import Foundation
import ClaudeToolCore

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read or modify the Tango config.",
        subcommands: [Show.self, Path.self, Edit.self, Reset.self, Set.self]
    )
}

extension Config {
    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Print the current config as JSON.")
        func run() throws {
            let cfg = try ConfigStore.shared.load()
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.keyEncodingStrategy = .convertToSnakeCase
            let data = try enc.encode(cfg)
            print(String(data: data, encoding: .utf8) ?? "{}")
        }
    }

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "path", abstract: "Print the config file path.")
        func run() throws {
            print(ConfigStore.shared.configURL.path)
        }
    }

    struct Edit: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "edit", abstract: "Open the config in $EDITOR (or TextEdit).")
        func run() throws {
            let path = ConfigStore.shared.configURL.path
            let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "open"
            let task = Process()
            if editor == "open" {
                task.launchPath = "/usr/bin/open"
                task.arguments = [path]
            } else {
                task.launchPath = "/bin/sh"
                task.arguments = ["-c", "\(editor) \(path.replacingOccurrences(of: " ", with: "\\ "))"]
            }
            try task.run()
            task.waitUntilExit()
        }
    }

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "reset", abstract: "Overwrite config with defaults.")
        func run() throws {
            try ConfigStore.shared.save(AppConfig())
            print("Wrote defaults to \(ConfigStore.shared.configURL.path)")
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set", abstract: "Set a config value. Supported keys: timeout, sensitivity, pretooluse_mode.")

        @Argument(help: "Key to set: timeout | sensitivity | pretooluse_mode")
        var key: String

        @Argument(help: "Value to assign.")
        var value: String

        func run() throws {
            let updated = try ConfigStore.shared.update { cfg in
                switch key {
                case "timeout":
                    if let v = Double(value) { cfg.detection.timeoutSeconds = v }
                case "sensitivity":
                    if let v = Double(value) { cfg.detection.sensitivityDb = v }
                case "pretooluse_mode":
                    if let mode = PreToolUseConfig.Mode(rawValue: value) {
                        cfg.hooks.preToolUse.mode = mode
                    }
                default:
                    break
                }
            }
            _ = updated
            print("OK")
        }
    }
}
