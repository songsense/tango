import ArgumentParser
import Foundation
import ClaudeToolCore

struct Daemon: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Manage the Tango background daemon (the menu-bar app).",
        subcommands: [Status.self, Start.self, Stop.self]
    )
}

extension Daemon {
    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "Check whether the daemon socket is reachable.")
        func run() throws {
            let path = SocketPaths.controlSocket.path
            if FileManager.default.fileExists(atPath: path) {
                print("daemon socket: \(path) (present)")
            } else {
                print("daemon socket: \(path) (missing — daemon not running?)")
                throw ExitCode(1)
            }
        }
    }

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "start", abstract: "Launch the menu-bar daemon (.app).")
        func run() throws {
            let candidates = [
                "/Applications/Tango.app",
                "\(NSHomeDirectory())/Applications/Tango.app",
                "/opt/homebrew/Caskroom/tango/latest/Tango.app"
            ]
            guard let appPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                FileHandle.standardError.write(Data("Tango.app not found in /Applications, ~/Applications, or Homebrew Cask path.\n".utf8))
                throw ExitCode(1)
            }
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-a", appPath]
            try task.run()
            task.waitUntilExit()
            print("Launched \(appPath)")
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "stop", abstract: "Quit the menu-bar daemon.")
        func run() throws {
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", "tell application \"Tango\" to quit"]
            try task.run()
            task.waitUntilExit()
        }
    }
}
