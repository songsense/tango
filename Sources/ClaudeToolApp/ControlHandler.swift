import Foundation
import ClaudeToolCore

public actor ControlHandler {
    private let detector: PatDetector
    private let notificationManager: NotificationManager
    private let configStore: ConfigStore

    public init(detector: PatDetector, notificationManager: NotificationManager, configStore: ConfigStore) {
        self.detector = detector
        self.notificationManager = notificationManager
        self.configStore = configStore
    }

    public func handle(_ req: AskRequest) async -> AskReply {
        let config = (try? configStore.load()) ?? AppConfig()

        // Notification structure: title is the action verb, subtitle is the
        // tool category, body is the actual command/prompt the user must read.
        let title: String
        let subtitle: String?
        let body: String
        let truncate: (String) -> String = { s in s.count > 240 ? String(s.prefix(240)) + "…" : s }

        if let tool = req.context?.toolName {
            title = "Claude wants permission"
            subtitle = "Tool: \(tool)"
            if let cmd = req.context?.command, config.notifications.includeCommandInBody {
                body = truncate(cmd)
            } else {
                body = truncate(req.prompt)
            }
        } else {
            // Notification-style ask (Claude attention request, not tool gate).
            title = "Claude needs your attention"
            subtitle = nil
            body = truncate(req.prompt)
        }

        let nm = notificationManager
        let detectorOptions = PatDetector.Options(
            thresholdDb: Float(config.detection.sensitivityDb),
            initialNoiseFloorDb: Float(config.detection.calibratedNoiseFloorDb ?? -30)
        )

        // Start the detector BEFORE posting the notification so warmup
        // (~600ms) overlaps with notification rendering. Otherwise the user's
        // first tap lands during the warmup window and gets silently dropped.
        let patResolver = ContinuationResolver()
        let detectorAvailable: Bool
        do {
            try detector.start(options: detectorOptions) { count in
                patResolver.resolve(count)
            }
            detectorAvailable = true
        } catch {
            detectorAvailable = false
        }

        try? await nm.post(title: title, subtitle: subtitle, body: body,
                           soundEnabled: config.notifications.soundEnabled)

        enum Outcome: Sendable {
            case button(Gesture?)
            case pats(Int)
            case timeout
        }

        let outcome: Outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask { [nm] in
                let g = await nm.awaitButton()
                return .button(g)
            }
            group.addTask {
                if detectorAvailable {
                    if let count = await patResolver.wait() {
                        return .pats(count)
                    }
                }
                // Mic unavailable — suspend so button/timeout decide the
                // outcome instead of racing back as cancelled.
                try? await Task.sleep(nanoseconds: UInt64.max)
                return .timeout
            }
            group.addTask {
                let nanos = UInt64(max(req.timeout, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }

        // Cleanup whichever side did not win.
        detector.stop()
        await nm.cancel()

        switch outcome {
        case .button(let g):
            if let g {
                return AskReply(response: gestureToResponse(g), via: .button)
            } else {
                return AskReply(response: .cancelled, via: .cancelled)
            }
        case .pats(let count):
            if let g = config.gestures.gesture(forPatCount: count) {
                return AskReply(response: gestureToResponse(g), via: .pat, pats: count)
            } else {
                return AskReply(response: .cancelled, via: .cancelled, pats: count)
            }
        case .timeout:
            return AskReply(response: .timeout, via: .timeout)
        }
    }

}

/// Bridges a callback-based result (the detector's `onPats` closure) into
/// async/await. `resolve()` may run before or after `wait()`; either order
/// works because the value buffers until someone is listening.
private final class ContinuationResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Int?, Never>?
    private var pendingValue: Int??

    func wait() async -> Int? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Int?, Never>) in
                lock.lock()
                if let pendingValue {
                    lock.unlock()
                    c.resume(returning: pendingValue)
                    return
                }
                self.cont = c
                lock.unlock()
            }
        } onCancel: {
            // Without this, a cancelled task hangs on the continuation forever,
            // blocking withTaskGroup from returning and the daemon from
            // writing a reply — observed as "invalid daemon response: ".
            resolve(nil)
        }
    }

    func resolve(_ value: Int?) {
        lock.lock()
        if let c = cont {
            cont = nil
            lock.unlock()
            c.resume(returning: value)
        } else if pendingValue == nil {
            pendingValue = .some(value)
            lock.unlock()
        } else {
            lock.unlock()
        }
    }
}

func gestureToResponse(_ g: Gesture) -> AskResponse {
    switch g {
    case .yes: return .yes
    case .yesAlways: return .yesAlways
    case .no: return .no
    }
}
