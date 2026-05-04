import AppKit
import ClaudeToolCore

@MainActor
final class MonitorWindowController: NSWindowController, NSWindowDelegate {
    private let monitor = AudioMonitor()
    private let waveView: WaveformView
    private let statusLabel: NSTextField
    private let patLabel: NSTextField
    private let diagLabel: NSTextField
    private var redrawTimer: Timer?
    private var clearStatusWorkItem: DispatchWorkItem?
    private var lastRmsDb: Float = -80
    private var lastPeakDb: Float = -80
    private var onsetCount: Int = 0
    private var clusterCount: Int = 0

    init() {
        let frame = NSRect(x: 0, y: 0, width: 560, height: 260)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tango Monitor"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 200)

        let waveView = WaveformView(frame: NSRect(x: 0, y: 70, width: frame.width, height: frame.height - 70))
        waveView.autoresizingMask = [.width, .height]

        let statusLabel = NSTextField(labelWithString: "Idle")
        statusLabel.frame = NSRect(x: 12, y: 46, width: frame.width - 24, height: 18)
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor

        let diagLabel = NSTextField(labelWithString: "—")
        diagLabel.frame = NSRect(x: 12, y: 26, width: frame.width - 24, height: 18)
        diagLabel.autoresizingMask = [.width, .maxYMargin]
        diagLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagLabel.textColor = .systemTeal

        let patLabel = NSTextField(labelWithString: "Last cluster: —")
        patLabel.frame = NSRect(x: 12, y: 6, width: frame.width - 24, height: 18)
        patLabel.autoresizingMask = [.width, .maxYMargin]
        patLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        patLabel.textColor = .tertiaryLabelColor

        self.waveView = waveView
        self.statusLabel = statusLabel
        self.patLabel = patLabel
        self.diagLabel = diagLabel
        super.init(window: window)

        window.delegate = self
        window.contentView?.addSubview(waveView)
        window.contentView?.addSubview(statusLabel)
        window.contentView?.addSubview(diagLabel)
        window.contentView?.addSubview(patLabel)
        waveView.monitor = monitor

        monitor.onUpdate = { [weak self] in
            _ = self  // redraw is timer-driven
        }
        monitor.onSample = { [weak self] rms, peak in
            self?.lastRmsDb = rms
            self?.lastPeakDb = peak
        }
        monitor.onOnset = { [weak self] event in
            self?.handleOnset(event: event)
        }
        monitor.onPat = { [weak self] count in
            self?.handlePatCluster(count: count)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        do {
            try monitor.start()
            statusLabel.stringValue = "Listening on \(monitor.currentDeviceName) — clap or finger-tap the desk"
            statusLabel.textColor = .systemGreen
        } catch {
            statusLabel.stringValue = "Mic error: \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
        }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)

        startRedrawTimer()
    }

    func windowWillClose(_ notification: Notification) {
        stopRedrawTimer()
        monitor.stop()
        statusLabel.stringValue = "Idle"
    }

    private func startRedrawTimer() {
        stopRedrawTimer()
        // 30 Hz redraws — smooth without burning CPU.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.waveView.setNeedsRedrawSoon()
                let floor = self.monitor.currentNoiseFloorDb
                let aboveFloor = self.lastRmsDb - floor
                let crest = self.lastPeakDb - self.lastRmsDb
                let rejCent = self.monitor.rejectedCentroidCount
                let rejPeak = self.monitor.rejectedPeakCount
                let voiceSup = self.monitor.voiceSuppressedClusters
                let voiceObs = self.monitor.lastVoiceObservation
                let voiceActive = voiceObs.age < 2.5
                let voiceTag = voiceActive
                    ? String(format: "voice:%@ %.0f%% (%.1fs ago)", voiceObs.label.isEmpty ? "—" : voiceObs.label, voiceObs.confidence * 100, voiceObs.age)
                    : "voice:idle"
                self.waveView.voiceActive = voiceActive
                self.diagLabel.stringValue = String(
                    format: "floor %.1f · peak %.1f · onsets:%d clusters:%d · rej(quiet:%d, voice:%d) · %@",
                    floor, self.lastPeakDb,
                    self.onsetCount, self.clusterCount, rejPeak, voiceSup,
                    voiceTag
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
    }

    private func stopRedrawTimer() {
        redrawTimer?.invalidate()
        redrawTimer = nil
    }

    private func handleOnset(event: OnsetEvent) {
        onsetCount += 1
        waveView.registerBeat()
        statusLabel.stringValue = String(format: "Beat #%d (peak %.1f dB · flatness %.2f)", onsetCount, event.peakDb, event.spectralFlatness)
        statusLabel.textColor = .systemOrange
        scheduleStatusReset(after: 1.0, idleColor: .systemGreen, idleText: "Listening — pat your case to see beats")
    }

    private func handlePatCluster(count: Int) {
        clusterCount += 1
        let label: String
        switch count {
        case 1: label = "1 pat → yes"
        case 2: label = "2 pats → yes-always"
        case 3: label = "3 pats → no"
        default: label = "\(count) pats → unmapped"
        }
        patLabel.stringValue = "Cluster #\(clusterCount): \(label)"
        patLabel.textColor = count <= 3 ? .systemTeal : .systemPink
    }

    private func scheduleStatusReset(after seconds: TimeInterval, idleColor: NSColor, idleText: String) {
        clearStatusWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.statusLabel.stringValue = idleText
            self.statusLabel.textColor = idleColor
        }
        clearStatusWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }
}
