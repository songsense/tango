import Foundation

/// Generates a human-readable, scan-in-2-seconds notification body for any
/// Claude Code tool invocation.
///
/// The hook command extracts string fields from the JSON `tool_input` into a
/// flat `[String: String]` dict and passes it here. Returning `nil` lets the
/// caller fall back to its own truncation of `req.prompt`.
public enum ToolPreview {
    public static func text(toolName: String, fields: [String: String]) -> String? {
        switch toolName {
        case "Bash":
            return fields["command"]
        case "Read":
            return fields["file_path"].map { "Read \(shortPath($0))" }
        case "Write":
            return fields["file_path"].map { "Write \(shortPath($0))" }
        case "Edit", "MultiEdit":
            return fields["file_path"].map { "Edit \(shortPath($0))" }
        case "WebFetch":
            if let url = fields["url"] {
                return (URL(string: url)?.host).map { "Fetch \($0)" } ?? "Fetch URL"
            }
        case "WebSearch":
            return fields["query"].map { "Search: \"\($0)\"" }
        case "Grep":
            if let pattern = fields["pattern"] {
                let loc = fields["path"].map { " in \(shortPath($0))" } ?? ""
                return "Search \"\(pattern)\"\(loc)"
            }
        case "Glob":
            return fields["pattern"].map { "Find \($0)" }
        case "EnterPlanMode":
            // EnterPlanMode in Claude Code carries a `plan` field with the
            // proposed plan text. Show its first non-empty line so the user
            // knows what they're approving.
            if let plan = fields["plan"], !plan.isEmpty {
                return "Plan: \(firstLine(plan))"
            }
            return "Switch to plan mode"
        case "ExitPlanMode":
            // ExitPlanMode is the critical "I'm about to start executing this
            // plan, OK?" gate. The full plan markdown is in `plan` — surface
            // its first line so the tap is informed, not blind.
            if let plan = fields["plan"], !plan.isEmpty {
                return "Approve plan: \(firstLine(plan))"
            }
            return "Approve plan and start executing"
        case "Agent":
            return fields["description"].map { "Launch agent: \($0)" } ?? "Launch sub-agent"
        case "TodoWrite":
            return "Update task list"
        default:
            break
        }
        // Generic fallback for unknown tools.
        if let cmd = fields["command"] { return cmd }
        if let path = fields["file_path"] { return path }
        if let url = fields["url"] { return url }
        return nil
    }

    /// Last two path components, with `~` substitution for the home directory.
    public static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let rel = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count > 3 {
            return "…/" + parts.suffix(2).joined(separator: "/")
        }
        return rel
    }

    /// First non-empty line of a markdown plan, with markdown headers stripped.
    public static func firstLine(_ text: String) -> String {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Strip "# ", "## ", "### " prefixes so headers read naturally.
            let stripped = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return String(stripped)
        }
        return text
    }

    /// Match bare `tango` or any absolute path ending in `/tango`.
    public static func isTangoSelfCommand(_ cmd: String) -> Bool {
        let exe = cmd.split(separator: " ").first.map(String.init) ?? cmd
        return exe == "tango" || exe.hasSuffix("/tango")
    }
}
