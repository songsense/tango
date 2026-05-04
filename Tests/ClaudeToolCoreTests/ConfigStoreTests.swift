import XCTest
@testable import ClaudeToolCore

final class ConfigStoreTests: XCTestCase {
    func testDefaultsRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudetool-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = ConfigStore(configURL: tmp)

        let loaded = try store.load()
        XCTAssertEqual(loaded.detection.timeoutSeconds, 30)
        XCTAssertEqual(loaded.gestures.onePat, .yes)
        XCTAssertEqual(loaded.gestures.twoPat, .yesAlways)
        XCTAssertEqual(loaded.gestures.threePat, .no)
        XCTAssertEqual(loaded.hooks.preToolUse.mode, .all)
    }

    func testMutateAndPersist() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudetool-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = ConfigStore(configURL: tmp)

        _ = try store.update { cfg in
            cfg.detection.timeoutSeconds = 60
            cfg.hooks.preToolUse.mode = .whitelist
            cfg.hooks.preToolUse.whitelist = ["Read", "Glob"]
        }

        // Force re-read
        store.reset()
        let reloaded = try store.load()
        XCTAssertEqual(reloaded.detection.timeoutSeconds, 60)
        XCTAssertEqual(reloaded.hooks.preToolUse.mode, .whitelist)
        XCTAssertEqual(reloaded.hooks.preToolUse.whitelist, ["Read", "Glob"])
    }

    func testGestureMapping() {
        let cfg = GestureConfig()
        XCTAssertEqual(cfg.gesture(forPatCount: 1), .yes)
        XCTAssertEqual(cfg.gesture(forPatCount: 2), .yesAlways)
        XCTAssertEqual(cfg.gesture(forPatCount: 3), .no)
        XCTAssertNil(cfg.gesture(forPatCount: 4))
        XCTAssertNil(cfg.gesture(forPatCount: 0))
    }
}
