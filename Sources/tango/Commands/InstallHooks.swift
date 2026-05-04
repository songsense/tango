import ArgumentParser
import Foundation
import ClaudeToolCore

struct InstallHooks: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-hooks",
        abstract: "Add Tango hook entries to ~/.claude/settings.json."
    )

    @Option(name: .long, help: "Settings file to edit. Defaults to ~/.claude/settings.json.")
    var settings: String?

    @Flag(name: .long, help: "Print the change but don't write it.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Install only the Notification hook (skip PreToolUse).")
    var notificationOnly: Bool = false

    func run() throws {
        let path = settings ?? defaultSettingsPath()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        var settingsObj: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            settingsObj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }

        var hooks = (settingsObj["hooks"] as? [String: Any]) ?? [:]

        let notificationEntry: [String: Any] = [
            "hooks": [
                ["type": "command", "command": "\(tangoCommandPath()) hook notification"]
            ]
        ]
        var notificationArr = (hooks["Notification"] as? [[String: Any]]) ?? []
        notificationArr.removeAll(where: { entry in
            isTangoEntry(entry, command: "tango hook notification") ||
                isTangoEntry(entry, command: "claudetool hook notification")
        })
        notificationArr.append(notificationEntry)
        hooks["Notification"] = notificationArr

        if !notificationOnly {
            let preToolUseEntry: [String: Any] = [
                "hooks": [
                    ["type": "command", "command": "\(tangoCommandPath()) hook pretooluse"]
                ]
            ]
            var preArr = (hooks["PreToolUse"] as? [[String: Any]]) ?? []
            preArr.removeAll(where: { entry in
                isTangoEntry(entry, command: "tango hook pretooluse") ||
                    isTangoEntry(entry, command: "claudetool hook pretooluse")
            })
            preArr.append(preToolUseEntry)
            hooks["PreToolUse"] = preArr
        }

        settingsObj["hooks"] = hooks

        let data = try JSONSerialization.data(withJSONObject: settingsObj, options: [.prettyPrinted, .sortedKeys])
        let str = String(data: data, encoding: .utf8) ?? "{}"

        if dryRun {
            print("Would write to \(url.path):")
            print(str)
            return
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        print("Installed hooks to \(url.path)")
    }

    private func defaultSettingsPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/settings.json").path
    }

    /// Returns the absolute path of the currently running tango binary so
    /// hooks work without any PATH manipulation.
    private func tangoCommandPath() -> String {
        // Use Bundle's main executable path — works for any CLI launched via
        // its absolute path, no Darwin-specific calls needed.
        if let url = Bundle.main.executableURL {
            return url.path
        }
        // Fallback: ProcessInfo.arguments.first (may be just the basename).
        let exePath = ProcessInfo.processInfo.arguments.first ?? "tango"
        if exePath.hasPrefix("/") { return exePath }
        let cwd = FileManager.default.currentDirectoryPath
        return ((cwd as NSString).appendingPathComponent(exePath) as NSString).standardizingPath
    }

    private func isTangoEntry(_ entry: [String: Any], command: String) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains(where: { ($0["command"] as? String) == command })
    }
}
