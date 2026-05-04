import AppKit
import ClaudeToolCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenuStatusItem: NSMenuItem?
    private var detector: PatDetector?
    private var server: ControlServer?
    private var handler: ControlHandler?
    private var monitorController: MonitorWindowController?
    private var calibrationController: CalibrationWindowController?
    private var micMenu: NSMenu?
    private var idleStatusText: String = "Idle"
    private var attentionToken: Int?
    private var feedbackResetWorkItem: DispatchWorkItem?
    private var isPending: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        // Ensure config file exists so users can edit it.
        let config = (try? ConfigStore.shared.load()) ?? AppConfig()
        try? ConfigStore.shared.save(config)

        Task { @MainActor in
            await self.bootstrapBackend()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        detector?.stop()
    }

    // MARK: - Setup

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: "Tango") {
                button.image = image
            } else {
                button.title = "TG"
            }
        }
        let menu = NSMenu()
        menu.addItem(menuLabel("Tango"))
        menu.addItem(.separator())
        let status = menuLabel("Idle")
        menu.addItem(status)
        statusMenuStatusItem = status
        menu.addItem(.separator())
        menu.addItem(menuItem("Show Monitor", action: #selector(showMonitor), key: "m"))
        menu.addItem(menuItem("Calibrate…", action: #selector(showCalibration), key: "k"))
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micSubmenu = NSMenu(title: "Microphone")
        micSubmenu.delegate = self
        micItem.submenu = micSubmenu
        self.micMenu = micSubmenu
        menu.addItem(micItem)
        menu.addItem(menuItem("Open Config", action: #selector(openConfig), key: ","))
        menu.addItem(menuItem("Reveal Socket", action: #selector(revealSocket), key: ""))
        menu.addItem(menuItem("Reload Config", action: #selector(reloadConfig), key: "r"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Tango", action: #selector(quit), key: "q"))
        item.menu = menu
        statusItem = item
    }

    private func bootstrapBackend() async {
        // Start the socket server first so the CLI is reachable even before
        // microphone/notification permission decisions complete.
        do {
            try FileManager.default.createDirectory(at: SocketPaths.supportDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("Tango: failed to create support directory: \(error)")
        }
        let detector = PatDetector()
        let handler = ControlHandler(
            detector: detector,
            notificationManager: NotificationManager.shared,
            configStore: ConfigStore.shared
        )
        let server = ControlServer(socketPath: SocketPaths.controlSocket.path, handler: handler)
        do {
            try server.start()
            self.detector = detector
            self.handler = handler
            self.server = server
            idleStatusText = "Listening on socket"
            statusMenuStatusItem?.title = idleStatusText
        } catch {
            NSLog("Tango: ControlServer failed to start: \(error)")
            idleStatusText = "Error: \(error.localizedDescription)"
            statusMenuStatusItem?.title = idleStatusText
        }

        // Wire pending-state UI: when a prompt is awaiting your tap, the
        // menu-bar icon flips to a high-contrast alert symbol and the dock
        // gets a critical attention request. Both reset on resolve.
        NotificationManager.shared.onPendingChange = { [weak self] pending in
            self?.updatePendingState(pending)
        }

        // Flash the menu-bar icon on every accepted onset so the user gets
        // instant "your tap landed" feedback before the cluster fires.
        detector.onAnyOnset = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pulseIconFeedback()
            }
        }

        // Request permissions in the background; if denied, pat detection and
        // notifications will silently fail-fast on the next ask request.
        Task.detached(priority: .background) {
            let micGranted = await PatDetector.requestMicrophonePermission()
            let notifGranted = await NotificationManager.shared.requestAuthorization()
            if !micGranted {
                NSLog("Tango: microphone permission denied — pat detection disabled")
            }
            if !notifGranted {
                NSLog("Tango: notification permission denied — visual alerts disabled")
            }
        }
    }

    // MARK: - Pending-state UI

    private func updatePendingState(_ pending: Bool) {
        isPending = pending
        guard let button = statusItem?.button else { return }
        if pending {
            // Red bell-with-badge is universally read as "needs your attention".
            // Falls back to text if the symbol isn't available on this OS.
            if let img = NSImage(systemSymbolName: "bell.badge.fill",
                                 accessibilityDescription: "Tango — waiting for tap") {
                if #available(macOS 11.0, *) {
                    button.image = img.withSymbolConfiguration(
                        NSImage.SymbolConfiguration(paletteColors: [.systemRed])
                    )
                } else {
                    button.image = img
                }
            } else {
                button.title = "TG!"
            }
            statusMenuStatusItem?.title = "Waiting for your tap…"
            // .criticalRequest keeps the dock icon (if any) bouncing until the
            // app activates. For a menu-bar-only app this is mostly a no-op,
            // but harmless and useful if LSUIElement is ever flipped off.
            attentionToken = NSApp.requestUserAttention(.criticalRequest)
        } else {
            if let img = NSImage(systemSymbolName: "hand.tap",
                                 accessibilityDescription: "Tango") {
                button.image = img
            } else {
                button.title = "TG"
            }
            statusMenuStatusItem?.title = idleStatusText
            if let token = attentionToken {
                NSApp.cancelUserAttentionRequest(token)
                attentionToken = nil
            }
        }
    }

    /// Briefly flip the menu-bar icon to a "tap landed" symbol, then revert
    /// to whatever state the AppDelegate is currently in (pending/idle).
    /// Called on every detected onset, so a 3-pat cluster pulses 3 times.
    private func pulseIconFeedback() {
        guard let button = statusItem?.button else { return }
        if let img = NSImage(systemSymbolName: "checkmark.circle.fill",
                             accessibilityDescription: "Tango — tap detected") {
            if #available(macOS 11.0, *) {
                button.image = img.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
                )
            } else {
                button.image = img
            }
        } else {
            button.title = "✓"
        }
        feedbackResetWorkItem?.cancel()
        let revert = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Restore the icon that matches our current state. Calling
            // updatePendingState with the unchanged value re-renders the icon.
            self.updatePendingState(self.isPending)
        }
        feedbackResetWorkItem = revert
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: revert)
    }

    // MARK: - Menu actions

    @objc private func showMonitor() {
        if monitorController == nil {
            monitorController = MonitorWindowController()
        }
        monitorController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showCalibration() {
        // Always start a fresh calibration window so prior state doesn't leak.
        calibrationController = CalibrationWindowController()
        calibrationController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openConfig() {
        let url = ConfigStore.shared.configURL
        NSWorkspace.shared.open(url)
    }

    @objc private func revealSocket() {
        NSWorkspace.shared.activateFileViewerSelecting([SocketPaths.supportDirectory])
    }

    @objc private func reloadConfig() {
        ConfigStore.shared.reset()
        _ = try? ConfigStore.shared.load()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Mic submenu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === micMenu else { return }
        menu.removeAllItems()
        let cfg = (try? ConfigStore.shared.load()) ?? AppConfig()
        let selectedUID = cfg.detection.inputDevice
        let devices = AudioDevices.listInputDevices()

        let defaultItem = NSMenuItem(title: "System default", action: #selector(selectMicDefault), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.state = (selectedUID == "default" || selectedUID.isEmpty) ? .on : .off
        menu.addItem(defaultItem)
        menu.addItem(.separator())

        for dev in devices {
            let title = dev.isDefault ? "\(dev.name) (system default)" : dev.name
            let item = NSMenuItem(title: title, action: #selector(selectMic(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dev.uid
            item.state = (selectedUID == dev.uid) ? .on : .off
            menu.addItem(item)
        }
        if devices.isEmpty {
            let none = NSMenuItem(title: "(no input devices found)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
    }

    @objc private func selectMicDefault() {
        _ = try? ConfigStore.shared.update { cfg in
            cfg.detection.inputDevice = "default"
            cfg.detection.inputDeviceName = nil
        }
        statusMenuStatusItem?.title = "Mic: system default (restart Monitor to apply)"
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        let dev = AudioDevices.device(forUID: uid)
        _ = try? ConfigStore.shared.update { cfg in
            cfg.detection.inputDevice = uid
            cfg.detection.inputDeviceName = dev?.name
        }
        statusMenuStatusItem?.title = "Mic: \(dev?.name ?? uid) (restart Monitor to apply)"
    }

    // MARK: - Helpers

    private func menuLabel(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func menuItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}
