import Foundation

public struct AppConfig: Codable, Sendable {
    public var detection: DetectionConfig
    public var gestures: GestureConfig
    public var hooks: HooksConfig
    public var notifications: NotificationsConfig

    public init(
        detection: DetectionConfig = .init(),
        gestures: GestureConfig = .init(),
        hooks: HooksConfig = .init(),
        notifications: NotificationsConfig = .init()
    ) {
        self.detection = detection
        self.gestures = gestures
        self.hooks = hooks
        self.notifications = notifications
    }
}

public struct DetectionConfig: Codable, Sendable {
    public var timeoutSeconds: Double
    public var inputDevice: String          // "default" or a CoreAudio device UID
    public var inputDeviceName: String?     // last-seen friendly name (just for UI/debug)
    public var sensitivityDb: Double
    public var calibratedNoiseFloorDb: Double?
    public var calibratedPatPeakDb: Double?

    public init(
        timeoutSeconds: Double = 30,
        inputDevice: String = "default",
        inputDeviceName: String? = nil,
        sensitivityDb: Double = 8.0,
        calibratedNoiseFloorDb: Double? = nil,
        calibratedPatPeakDb: Double? = nil
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.inputDevice = inputDevice
        self.inputDeviceName = inputDeviceName
        self.sensitivityDb = sensitivityDb
        self.calibratedNoiseFloorDb = calibratedNoiseFloorDb
        self.calibratedPatPeakDb = calibratedPatPeakDb
    }
}

public struct GestureConfig: Codable, Sendable {
    public var onePat: Gesture
    public var twoPat: Gesture
    public var threePat: Gesture

    public init(onePat: Gesture = .yes, twoPat: Gesture = .yesAlways, threePat: Gesture = .no) {
        self.onePat = onePat
        self.twoPat = twoPat
        self.threePat = threePat
    }

    public func gesture(forPatCount count: Int) -> Gesture? {
        switch count {
        case 1: return onePat
        case 2: return twoPat
        case 3: return threePat
        default: return nil
        }
    }
}

public struct HooksConfig: Codable, Sendable {
    public var preToolUse: PreToolUseConfig

    public init(preToolUse: PreToolUseConfig = .init()) {
        self.preToolUse = preToolUse
    }
}

public struct PreToolUseConfig: Codable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case all
        case whitelist
    }
    public var mode: Mode
    public var whitelist: [String]

    public init(mode: Mode = .all, whitelist: [String] = []) {
        self.mode = mode
        self.whitelist = whitelist
    }
}

public struct NotificationsConfig: Codable, Sendable {
    public var includeCommandInBody: Bool
    public var soundEnabled: Bool

    public init(includeCommandInBody: Bool = true, soundEnabled: Bool = true) {
        self.includeCommandInBody = includeCommandInBody
        self.soundEnabled = soundEnabled
    }
}

public final class ConfigStore: @unchecked Sendable {
    public static let shared = ConfigStore()

    public let configURL: URL
    private let lock = NSLock()
    private var cached: AppConfig?

    public init(configURL: URL? = nil) {
        if let configURL {
            self.configURL = configURL
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.configURL = home
                .appendingPathComponent(".config/tango/config.json")
        }
    }

    public func load() throws -> AppConfig {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let config: AppConfig
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            config = try decoder.decode(AppConfig.self, from: data)
        } else {
            config = AppConfig()
        }
        cached = config
        return config
    }

    public func save(_ config: AppConfig) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: .atomic)
        cached = config
    }

    public func update(_ mutate: (inout AppConfig) -> Void) throws -> AppConfig {
        var current = try load()
        mutate(&current)
        try save(current)
        return current
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }
}
