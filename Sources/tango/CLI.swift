import ArgumentParser
import Foundation
import ClaudeToolCore

@main
struct TangoCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tango",
        abstract: "Tap-and-Go: pat-to-respond bridge between Claude Code hooks and your aluminum case.",
        subcommands: [
            Ask.self,
            Hook.self,
            InstallHooks.self,
            Calibrate.self,
            Config.self,
            Daemon.self
        ]
    )
}
