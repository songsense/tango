import Foundation
@preconcurrency import UserNotifications
import ClaudeToolCore

@MainActor
public final class NotificationManager: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    public static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()
    private static let categoryId = "tango.ask"

    private var currentRequestId: String?
    private var continuation: CheckedContinuation<Gesture?, Never>?

    /// Fired on the main actor when a prompt becomes pending (true) or resolves
    /// (false). Lets the AppDelegate update the menu-bar icon, bounce the dock,
    /// or otherwise grab the user's attention while we're waiting for a tap.
    public var onPendingChange: ((Bool) -> Void)?

    public override init() {
        super.init()
        center.delegate = self
        registerCategory()
    }

    public func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    public var authorizationStatus: UNAuthorizationStatus {
        get async { await center.notificationSettings().authorizationStatus }
    }

    private func registerCategory() {
        let yes = UNNotificationAction(identifier: "yes", title: "Yes", options: [.foreground])
        let yesAlways = UNNotificationAction(identifier: "yes-always", title: "Yes, always", options: [.foreground])
        let no = UNNotificationAction(identifier: "no", title: "No", options: [.destructive])
        let cat = UNNotificationCategory(
            identifier: Self.categoryId,
            actions: [yes, yesAlways, no],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([cat])
    }

    /// Post the notification. Throws if delivery fails. Pairs with `awaitButton()`.
    /// `subtitle` is shown below the title in the system banner (e.g. tool name).
    public func post(title: String, subtitle: String? = nil, body: String, soundEnabled: Bool) async throws {
        // Verify authorization first — silently failing is the worst UX.
        let settings = await center.notificationSettings()
        if settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional {
            let granted = await requestAuthorization()
            if !granted {
                throw NSError(domain: "Tango", code: 100,
                              userInfo: [NSLocalizedDescriptionKey: "Notifications not authorized — System Settings → Notifications → Tango"])
            }
        }

        // Cancel any in-flight notification first.
        cancelLocked(reason: .superseded)

        let id = UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        content.categoryIdentifier = Self.categoryId
        if soundEnabled { content.sound = .default }
        // Time-sensitive interruption breaks through Focus modes (Do Not Disturb)
        // when the user has allowed it for Tango. Falls back to .active otherwise.
        if #available(macOS 12.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        // Group all Tango notifications together so the user can review history.
        content.threadIdentifier = "tango.ask"
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        currentRequestId = id
        try await center.add(req)
        onPendingChange?(true)
    }

    /// Suspend until the user taps an action button. Returns nil if cancelled
    /// or dismissed without an action.
    public func awaitButton() async -> Gesture? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Gesture?, Never>) in
                if let prev = continuation {
                    continuation = nil
                    prev.resume(returning: nil)
                }
                continuation = cont
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let cont = self.continuation {
                    self.continuation = nil
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Dismiss the current notification and resolve `awaitButton()` with nil.
    public func cancel() {
        cancelLocked(reason: .external)
    }

    private enum CancelReason {
        case external
        case superseded
    }

    private func cancelLocked(reason: CancelReason) {
        let wasPending = currentRequestId != nil || continuation != nil
        if let id = currentRequestId {
            center.removeDeliveredNotifications(withIdentifiers: [id])
            center.removePendingNotificationRequests(withIdentifiers: [id])
            currentRequestId = nil
        }
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: nil)
        }
        // Only fire the resolved signal for genuine cancellations, not when
        // we're being superseded by a fresh post() that's about to fire its
        // own onPendingChange(true) callback.
        if wasPending && reason == .external {
            onPendingChange?(false)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // .banner = always show; .list = persist in Notification Center;
        // .sound = audible alert. We exclude .badge (no app icon badging).
        handler([.banner, .sound, .list])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler handler: @escaping () -> Void
    ) {
        let gesture: Gesture?
        switch response.actionIdentifier {
        case "yes": gesture = .yes
        case "yes-always": gesture = .yesAlways
        case "no": gesture = .no
        default: gesture = nil
        }
        Task { @MainActor in
            self.deliverResponse(gesture)
            handler()
        }
    }

    private func deliverResponse(_ gesture: Gesture?) {
        currentRequestId = nil
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: gesture)
        }
        onPendingChange?(false)
    }
}
