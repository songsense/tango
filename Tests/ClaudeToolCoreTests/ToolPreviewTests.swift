import XCTest
@testable import ClaudeToolCore

final class ToolPreviewTests: XCTestCase {

    // MARK: - Bash

    func testBashShowsRawCommand() {
        let body = ToolPreview.text(toolName: "Bash", fields: ["command": "git status"])
        XCTAssertEqual(body, "git status")
    }

    func testBashWithoutCommandReturnsNil() {
        let body = ToolPreview.text(toolName: "Bash", fields: [:])
        XCTAssertNil(body)
    }

    // MARK: - Read / Write / Edit

    func testReadShowsShortenedPath() {
        let body = ToolPreview.text(toolName: "Read", fields: ["file_path": "/Users/foo/bar/baz/file.swift"])
        XCTAssertEqual(body, "Read …/baz/file.swift")
    }

    func testWriteUsesWriteVerb() {
        let body = ToolPreview.text(toolName: "Write", fields: ["file_path": "/tmp/x.txt"])
        XCTAssertEqual(body, "Write /tmp/x.txt")
    }

    func testEditAndMultiEditBothShowEditVerb() {
        let edit = ToolPreview.text(toolName: "Edit", fields: ["file_path": "/tmp/a.swift"])
        let multi = ToolPreview.text(toolName: "MultiEdit", fields: ["file_path": "/tmp/a.swift"])
        XCTAssertEqual(edit, "Edit /tmp/a.swift")
        XCTAssertEqual(multi, "Edit /tmp/a.swift")
    }

    // MARK: - Web

    func testWebFetchShowsHost() {
        let body = ToolPreview.text(toolName: "WebFetch", fields: ["url": "https://example.com/path?q=1"])
        XCTAssertEqual(body, "Fetch example.com")
    }

    func testWebFetchInvalidURLFallsBack() {
        let body = ToolPreview.text(toolName: "WebFetch", fields: ["url": "not a url"])
        XCTAssertEqual(body, "Fetch URL")
    }

    func testWebSearchQuotesQuery() {
        let body = ToolPreview.text(toolName: "WebSearch", fields: ["query": "swift concurrency"])
        XCTAssertEqual(body, "Search: \"swift concurrency\"")
    }

    // MARK: - Grep / Glob

    func testGrepWithPath() {
        let body = ToolPreview.text(toolName: "Grep", fields: ["pattern": "TODO", "path": "/repo/src"])
        XCTAssertEqual(body, "Search \"TODO\" in /repo/src")
    }

    func testGrepWithoutPath() {
        let body = ToolPreview.text(toolName: "Grep", fields: ["pattern": "TODO"])
        XCTAssertEqual(body, "Search \"TODO\"")
    }

    func testGlob() {
        let body = ToolPreview.text(toolName: "Glob", fields: ["pattern": "**/*.swift"])
        XCTAssertEqual(body, "Find **/*.swift")
    }

    // MARK: - Plan-mode tools (the audit gap)

    func testEnterPlanModeWithPlanShowsFirstLine() {
        let plan = "## Refactor auth module\n\n- step 1\n- step 2"
        let body = ToolPreview.text(toolName: "EnterPlanMode", fields: ["plan": plan])
        XCTAssertEqual(body, "Plan: Refactor auth module")
    }

    func testEnterPlanModeWithoutPlanFallsBackToVerb() {
        let body = ToolPreview.text(toolName: "EnterPlanMode", fields: [:])
        XCTAssertEqual(body, "Switch to plan mode")
    }

    func testExitPlanModeWithPlanShowsApproveAndFirstLine() {
        let plan = "# Implementation plan\nDo X then Y"
        let body = ToolPreview.text(toolName: "ExitPlanMode", fields: ["plan": plan])
        XCTAssertEqual(body, "Approve plan: Implementation plan")
    }

    func testExitPlanModeWithoutPlanFallsBack() {
        let body = ToolPreview.text(toolName: "ExitPlanMode", fields: [:])
        XCTAssertEqual(body, "Approve plan and start executing")
    }

    func testFirstLineSkipsLeadingBlankLines() {
        XCTAssertEqual(ToolPreview.firstLine("\n\n## Header\nbody"), "Header")
    }

    func testFirstLineStripsMarkdownHeaderHashes() {
        XCTAssertEqual(ToolPreview.firstLine("### Heading three"), "Heading three")
    }

    // MARK: - Agent / TodoWrite

    func testAgentWithDescription() {
        let body = ToolPreview.text(toolName: "Agent", fields: ["description": "code review"])
        XCTAssertEqual(body, "Launch agent: code review")
    }

    func testAgentWithoutDescription() {
        let body = ToolPreview.text(toolName: "Agent", fields: [:])
        XCTAssertEqual(body, "Launch sub-agent")
    }

    func testTodoWrite() {
        let body = ToolPreview.text(toolName: "TodoWrite", fields: [:])
        XCTAssertEqual(body, "Update task list")
    }

    // MARK: - Unknown tool fallback

    func testUnknownToolWithCommand() {
        let body = ToolPreview.text(toolName: "FrobulateThing", fields: ["command": "frob it"])
        XCTAssertEqual(body, "frob it")
    }

    func testUnknownToolWithFilePath() {
        let body = ToolPreview.text(toolName: "FrobulateThing", fields: ["file_path": "/x"])
        XCTAssertEqual(body, "/x")
    }

    func testUnknownToolWithUrl() {
        let body = ToolPreview.text(toolName: "FrobulateThing", fields: ["url": "https://x"])
        XCTAssertEqual(body, "https://x")
    }

    func testUnknownToolWithNothingReturnsNil() {
        let body = ToolPreview.text(toolName: "FrobulateThing", fields: [:])
        XCTAssertNil(body)
    }

    // MARK: - shortPath

    func testShortPathShortensLongPaths() {
        XCTAssertEqual(ToolPreview.shortPath("/a/b/c/d/e/f.txt"), "…/e/f.txt")
    }

    func testShortPathLeavesShortPathsAlone() {
        XCTAssertEqual(ToolPreview.shortPath("/a/b.txt"), "/a/b.txt")
    }

    // MARK: - Self-command detection (prevents tap-eating)

    func testIsTangoSelfCommandMatchesBare() {
        XCTAssertTrue(ToolPreview.isTangoSelfCommand("tango ask --prompt foo"))
    }

    func testIsTangoSelfCommandMatchesAbsolutePath() {
        XCTAssertTrue(ToolPreview.isTangoSelfCommand("/usr/local/bin/tango hook pretooluse"))
    }

    func testIsTangoSelfCommandMatchesRepoBuildPath() {
        let cmd = "/Users/iris/Projects/ClaudeTool/.build/arm64-apple-macosx/release/tango ask"
        XCTAssertTrue(ToolPreview.isTangoSelfCommand(cmd))
    }

    func testIsTangoSelfCommandRejectsTangoSubstringInPath() {
        // A path that *contains* "tango" but is not the tango binary must not match.
        XCTAssertFalse(ToolPreview.isTangoSelfCommand("git status # tango release notes"))
        XCTAssertFalse(ToolPreview.isTangoSelfCommand("brew install tangoesque"))
    }

    func testIsTangoSelfCommandRejectsUnrelated() {
        XCTAssertFalse(ToolPreview.isTangoSelfCommand("git status"))
        XCTAssertFalse(ToolPreview.isTangoSelfCommand("ls /tmp"))
    }
}
