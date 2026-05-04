import AppKit
import ClaudeToolCore

@MainActor
final class CalibrationWindowController: NSWindowController, NSWindowDelegate {
    private let flow = CalibrationFlow()
    private let waveView: WaveformView
    private let bigCountLabel: NSTextField
    private let phaseLabel: NSTextField
    private let statusLabel: NSTextField
    private let detailLabel: NSTextField
    private let gestureListLabel: NSTextField
    private let progressBar: NSProgressIndicator
    private let actionButton: NSButton    // Start / I'm Done / Next Step / Save
    private let secondaryButton: NSButton // Re-do step / Skip
    private let cancelButton: NSButton
    private var redrawTimer: Timer?
    private var lastResult: CalibrationFlow.Result?

    init() {
        let frame = NSRect(x: 0, y: 0, width: 620, height: 430)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tango Calibration"
        window.center()
        window.isReleasedWhenClosed = false

        // Top: phase + status text
        let phaseLabel = NSTextField(labelWithString: "Ready to calibrate")
        phaseLabel.frame = NSRect(x: 16, y: 390, width: 588, height: 22)
        phaseLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        phaseLabel.autoresizingMask = [.width]

        let statusLabel = NSTextField(labelWithString: "Click Start. The calibrator will sample ambient noise then walk you through 3 steps: single-pat, double-pat, triple-pat.")
        statusLabel.frame = NSRect(x: 16, y: 350, width: 588, height: 36)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.autoresizingMask = [.width]

        let progressBar = NSProgressIndicator(frame: NSRect(x: 16, y: 332, width: 588, height: 12))
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.isIndeterminate = false
        progressBar.autoresizingMask = [.width]

        // Big indicator
        let bigCountLabel = NSTextField(labelWithString: "")
        bigCountLabel.frame = NSRect(x: 16, y: 250, width: 588, height: 70)
        bigCountLabel.font = .systemFont(ofSize: 40, weight: .bold)
        bigCountLabel.alignment = .center
        bigCountLabel.textColor = .systemBlue
        bigCountLabel.autoresizingMask = [.width]

        // Live waveform
        let waveView = WaveformView(frame: NSRect(x: 16, y: 110, width: 588, height: 130))
        waveView.autoresizingMask = [.width, .height]
        waveView.monitor = flow.liveMonitor

        // Gesture list (last few captured for current step)
        let gestureListLabel = NSTextField(labelWithString: "")
        gestureListLabel.frame = NSRect(x: 16, y: 78, width: 588, height: 24)
        gestureListLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        gestureListLabel.textColor = .labelColor
        gestureListLabel.lineBreakMode = .byTruncatingMiddle
        gestureListLabel.autoresizingMask = [.width]

        // Onset detail line
        let detailLabel = NSTextField(labelWithString: "")
        detailLabel.frame = NSRect(x: 16, y: 56, width: 588, height: 18)
        detailLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.autoresizingMask = [.width]

        // Buttons
        let actionButton = NSButton(title: "Start", target: nil, action: nil)
        actionButton.bezelStyle = .rounded
        actionButton.frame = NSRect(x: 510, y: 12, width: 94, height: 30)
        actionButton.keyEquivalent = "\r"
        actionButton.autoresizingMask = [.minXMargin]

        let secondaryButton = NSButton(title: "Re-do step", target: nil, action: nil)
        secondaryButton.bezelStyle = .rounded
        secondaryButton.frame = NSRect(x: 396, y: 12, width: 104, height: 30)
        secondaryButton.autoresizingMask = [.minXMargin]
        secondaryButton.isHidden = true

        let cancelButton = NSButton(title: "Close", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: 298, y: 12, width: 90, height: 30)
        cancelButton.autoresizingMask = [.minXMargin]

        self.waveView = waveView
        self.bigCountLabel = bigCountLabel
        self.phaseLabel = phaseLabel
        self.statusLabel = statusLabel
        self.detailLabel = detailLabel
        self.gestureListLabel = gestureListLabel
        self.progressBar = progressBar
        self.actionButton = actionButton
        self.secondaryButton = secondaryButton
        self.cancelButton = cancelButton
        super.init(window: window)

        actionButton.target = self
        actionButton.action = #selector(didPressAction)
        secondaryButton.target = self
        secondaryButton.action = #selector(didPressSecondary)
        cancelButton.target = self
        cancelButton.action = #selector(didPressClose)

        window.delegate = self
        window.contentView?.addSubview(phaseLabel)
        window.contentView?.addSubview(statusLabel)
        window.contentView?.addSubview(progressBar)
        window.contentView?.addSubview(bigCountLabel)
        window.contentView?.addSubview(waveView)
        window.contentView?.addSubview(gestureListLabel)
        window.contentView?.addSubview(detailLabel)
        window.contentView?.addSubview(actionButton)
        window.contentView?.addSubview(secondaryButton)
        window.contentView?.addSubview(cancelButton)

        flow.onPhase = { [weak self] phase in
            self?.render(phase: phase)
        }
        flow.onCandidate = { [weak self] event in
            self?.waveView.registerBeat()
            self?.detailLabel.stringValue = String(
                format: "onset: peak %.1f dB · rms %.1f dB · crest %.1f · flatness %.2f",
                event.peakDb, event.rmsDb, event.peakDb - event.rmsDb, event.spectralFlatness
            )
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        startRedrawTimer()
    }

    func windowWillClose(_ notification: Notification) {
        flow.cancel()
        stopRedrawTimer()
    }

    // MARK: - Actions

    @objc private func didPressAction() {
        switch flow.phase {
        case .idle, .cancelled, .failed:
            flow.begin()
        case .stepReady:
            flow.startStep()
        case .stepListening:
            flow.finishStep()
        case .stepReview:
            Task { @MainActor in await flow.nextStep() }
        case .completed:
            if let r = lastResult, r.passed {
                save(result: r)
                window?.close()
            } else {
                flow.begin()
            }
        case .ambientListening, .tuning:
            break  // these are auto-advanced
        }
    }

    @objc private func didPressSecondary() {
        switch flow.phase {
        case .stepReview:
            // Re-do this step: restart it
            flow.startStep()
        default:
            break
        }
    }

    @objc private func didPressClose() {
        flow.cancel()
        window?.close()
    }

    private func save(result: CalibrationFlow.Result) {
        do {
            _ = try ConfigStore.shared.update { cfg in
                cfg.detection.calibratedNoiseFloorDb = Double(result.ambientFloorDb)
                cfg.detection.sensitivityDb = Double(result.recommendedThresholdDb)
            }
        } catch {
            statusLabel.stringValue = "Save failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Rendering

    private func render(phase: CalibrationFlow.Phase) {
        if case .completed = phase, let r = flow.cachedResult {
            lastResult = r
            renderResult(r)
            return
        }

        // Reset secondary button visibility per phase
        secondaryButton.isHidden = true
        statusLabel.textColor = .secondaryLabelColor

        switch phase {
        case .idle:
            phaseLabel.stringValue = "Ready to calibrate"
            statusLabel.stringValue = "WHAT HAPPENS NEXT: Tango will (1) sample 3 seconds of ambient noise, then walk you through (2) single-pat training, (3) double-pat training, (4) triple-pat training. Click Start to begin."
            bigCountLabel.stringValue = ""
            gestureListLabel.stringValue = ""
            progressBar.doubleValue = 0
            actionButton.title = "Start"
            actionButton.isEnabled = true

        case .ambientListening(let remaining):
            phaseLabel.stringValue = String(format: "Step 0: ambient noise (%.1fs left)", remaining)
            statusLabel.stringValue = "🤫 STAY SILENT. Don't move, don't type. Tango is measuring your room's background noise level."
            bigCountLabel.stringValue = "🔇"
            bigCountLabel.textColor = .systemTeal
            progressBar.doubleValue = max(0, min(1, 1 - remaining / 3.0))
            actionButton.title = "…"
            actionButton.isEnabled = false

        case .stepReady(let label, let idx, let total):
            phaseLabel.stringValue = "Step \(idx) of \(total): \(stepName(label))"
            let labelWord = label == 1 ? "ONCE" : (label == 2 ? "TWICE" : "THREE TIMES")
            let plural = label == 1 ? "" : "s"
            statusLabel.stringValue = "WHAT TO DO NEXT:\n  1. Click the Start button (right). \n  2. Pat your case \(labelWord) (this counts as ONE \(label)-pat gesture). \n  3. Wait ~1 second. \n  4. Repeat 5 times total — five separate \(label)-pat gesture\(plural). \n  5. Click I'm Done when finished."
            bigCountLabel.stringValue = "Pat \(label)×"
            bigCountLabel.textColor = .systemOrange
            gestureListLabel.stringValue = "Tango will record each gesture as a labeled training example."
            progressBar.doubleValue = Double(idx - 1) / Double(total)
            actionButton.title = "Start"
            actionButton.isEnabled = true

        case .stepListening(let label, let idx, let total, let gestures):
            let labelWord = label == 1 ? "ONCE" : (label == 2 ? "TWICE" : "THREE TIMES")
            let correct = gestures.filter { $0 == label }.count
            phaseLabel.stringValue = "Step \(idx)/\(total): 🎙 LISTENING — pat \(label) time\(label == 1 ? "" : "s")"
            statusLabel.stringValue = "Pat your case \(labelWord), wait 1 second, repeat. Aim for 5 gestures total. ✓ means correctly counted, ✗ means miscounted (you can re-do this step). Click I'm Done when satisfied."
            bigCountLabel.stringValue = "🎙 \(gestures.count) captured (\(correct) correct)"
            bigCountLabel.textColor = correct == gestures.count && gestures.count >= 3 ? .systemGreen : .systemRed
            gestureListLabel.stringValue = gestures.isEmpty
                ? "Waiting for first pat…"
                : "Trials: " + (gestures.suffix(15).map { renderGesture($0, expected: label) }.joined(separator: "  "))
            progressBar.doubleValue = (Double(idx - 1) + min(1.0, Double(gestures.count) / 5.0)) / Double(total)
            actionButton.title = "I'm Done"
            actionButton.isEnabled = true

        case .stepReview(let label, let idx, let total, let gestures):
            let correct = gestures.filter { $0 == label }.count
            phaseLabel.stringValue = "Step \(idx)/\(total) review: \(correct)/\(gestures.count) correctly counted"
            let nextActionText = idx == total ? "Run Tuning to learn from your data" : "advance to step \(idx + 1)"
            statusLabel.stringValue = "Recorded \(gestures.count) \(label)-pat gesture\(gestures.count == 1 ? "" : "s"); \(correct) were counted correctly. These become labeled training examples. Click \(idx == total ? "Run Tuning" : "Next Step") to \(nextActionText), or Re-do step if the count was off."
            bigCountLabel.stringValue = correct == gestures.count && gestures.count > 0 ? "✓ \(correct)/\(gestures.count)" : "\(correct)/\(gestures.count)"
            bigCountLabel.textColor = (correct == gestures.count && gestures.count > 0) ? .systemGreen : .systemOrange
            gestureListLabel.stringValue = "Trials: " + (gestures.map { renderGesture($0, expected: label) }.joined(separator: "  "))
            progressBar.doubleValue = Double(idx) / Double(total)
            actionButton.title = idx == total ? "Run Tuning" : "Next Step"
            actionButton.isEnabled = true
            secondaryButton.isHidden = false

        case .tuning:
            phaseLabel.stringValue = "⚙︎ Learning your pat patterns…"
            statusLabel.stringValue = "Searching ~1000 detector parameter combinations against your captured trials. Picks the one that matches your labels best. (Should finish in 1–2 seconds.)"
            bigCountLabel.stringValue = "⚙︎ tuning"
            bigCountLabel.textColor = .systemPurple
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
            actionButton.title = "…"
            actionButton.isEnabled = false

        case .completed:
            // Handled above with renderResult.
            break

        case .cancelled:
            phaseLabel.stringValue = "Cancelled"
            statusLabel.stringValue = "Click Start to try again."
            actionButton.title = "Start"
            actionButton.isEnabled = true

        case .failed(let reason):
            phaseLabel.stringValue = "Failed"
            statusLabel.stringValue = reason
            statusLabel.textColor = .systemRed
            actionButton.title = "Retry"
            actionButton.isEnabled = true
        }
    }

    private func renderResult(_ r: CalibrationFlow.Result) {
        progressBar.isIndeterminate = false
        progressBar.doubleValue = 1
        let perLabel = r.perLabelAccuracy
        let line1 = String(
            format: "Accuracy: 1-pat %@ · 2-pat %@ · 3-pat %@   (overall %.0f%%)",
            accString(perLabel[1]), accString(perLabel[2]), accString(perLabel[3]),
            r.overallAccuracy * 100
        )
        let line2 = String(
            format: "Tuned: floor %.1f dB · threshold +%.1f · crest ≥ %.1f · flatness ≥ %.2f · echo-reject %.0f dB",
            r.ambientFloorDb,
            r.recommendedThresholdDb,
            r.recommendedCrestFactorDb,
            r.recommendedSpectralFlatnessMin,
            r.recommendedEchoRejectDb
        )
        statusLabel.stringValue = line1
        gestureListLabel.stringValue = line2
        detailLabel.stringValue = "Trials per label: " + r.trialsByLabel.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)-pat: \($0.value.count)" }.joined(separator: " · ")

        bigCountLabel.stringValue = r.passed ? "✓ Passed" : "Needs retry"
        bigCountLabel.textColor = r.passed ? .systemGreen : .systemOrange

        if r.passed {
            phaseLabel.stringValue = "Calibration complete"
            statusLabel.textColor = .systemGreen
            actionButton.title = "Save"
        } else {
            phaseLabel.stringValue = "Calibration not reliable enough"
            statusLabel.textColor = .systemOrange
            actionButton.title = "Retry"
        }
        actionButton.isEnabled = true
        secondaryButton.isHidden = true
    }

    // MARK: - Helpers

    private func stepName(_ label: Int) -> String {
        switch label {
        case 1: return "Single-Pat Training"
        case 2: return "Double-Pat Training"
        case 3: return "Triple-Pat Training"
        default: return "\(label)-pat training"
        }
    }

    private func renderGesture(_ count: Int, expected: Int) -> String {
        count == expected ? "✓\(count)" : "✗\(count)"
    }

    private func accString(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int((v * 100).rounded()))%"
    }

    private func startRedrawTimer() {
        stopRedrawTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.waveView.setNeedsRedrawSoon()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
    }

    private func stopRedrawTimer() {
        redrawTimer?.invalidate()
        redrawTimer = nil
    }
}
