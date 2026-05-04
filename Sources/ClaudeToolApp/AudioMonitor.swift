import Foundation
import AVFoundation
import ClaudeToolCore

/// Live mic monitor used by the visualization window. Independent of PatDetector
/// — has its own AVAudioEngine instance.
final class AudioMonitor: @unchecked Sendable {
    static let ringSize = 240   // ~6s at ~25ms hop

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var analyzer: OnsetAnalyzer?
    private var clusterer: PatClusterer?
    private var voiceGate: VoiceGate?
    private(set) var voiceSuppressedClusters: Int = 0
    private var isRunning = false

    // Visualization state — written from audio thread under lock, snapshotted on main.
    private var ring: [Float] = Array(repeating: -80, count: AudioMonitor.ringSize)
    private var writePos: Int = 0
    private var floorDb: Float = -50
    private var lastSampleRate: Double = 0

    var onUpdate: (@MainActor () -> Void)?
    var onOnset: (@MainActor (OnsetEvent) -> Void)?
    var onPat: (@MainActor (Int) -> Void)?
    var onSample: (@MainActor (_ rmsDb: Float, _ peakDb: Float) -> Void)?

    func start(
        thresholdDb: Float = 5,
        crestFactorMinDb: Float = 4,
        spectralFlatnessMin: Float = 0.0,
        maxCentroidHz: Float = 8000,
        minPeakDb: Float = -38,
        initialFloorDb: Float = -40,
        refractorySeconds: TimeInterval = 0.25,
        gapSeconds: TimeInterval = 0.7,
        minInterPatGap: TimeInterval = 0.12,
        maxClusterDuration: TimeInterval = 2.0,
        echoRejectDb: Float = 10
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        // Apply the selected input device BEFORE asking the input node for its
        // format — AVAudioEngine binds to the active device at this point.
        applyConfiguredInputDevice()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw NSError(domain: "AudioMonitor", code: 1) }
        lastSampleRate = format.sampleRate

        let analyzer = OnsetAnalyzer(
            sampleRate: format.sampleRate,
            thresholdDb: thresholdDb,
            crestFactorMinDb: crestFactorMinDb,
            spectralFlatnessMin: spectralFlatnessMin,
            maxCentroidHz: maxCentroidHz,
            minPeakDb: minPeakDb,
            initialNoiseFloorDb: initialFloorDb,
            refractorySeconds: refractorySeconds
        )
        let onPat = self.onPat
        let voiceGate: VoiceGate? = (try? VoiceGate(format: format))
        self.voiceGate = voiceGate
        self.voiceSuppressedClusters = 0
        let clusterer = PatClusterer(
            gapSeconds: gapSeconds,
            minInterPatGap: minInterPatGap,
            maxClusterDuration: maxClusterDuration,
            echoRejectDb: echoRejectDb
        ) { [weak self] count in
            // VoiceGate: suppress clusters that overlap with detected speech.
            if let gate = self?.voiceGate, gate.isVoiceActive(within: 2.5) {
                self?.lock.lock()
                self?.voiceSuppressedClusters += 1
                self?.lock.unlock()
                return
            }
            if let onPat {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { onPat(count) }
                }
            }
        }
        self.analyzer = analyzer
        self.clusterer = clusterer

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        try engine.start()
        isRunning = true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        analyzer = nil
        clusterer = nil
        voiceGate = nil
        isRunning = false
    }

    /// Returns the most recent VoiceGate observation, for diagnostics UI.
    var lastVoiceObservation: (label: String, confidence: Double, age: TimeInterval) {
        voiceGate?.lastObservation ?? ("", 0, .greatestFiniteMagnitude)
    }

    /// Adjust the analyzer's onset threshold while running. Useful for
    /// calibration phases (silent → sensitive → tuned).
    func setThreshold(_ db: Float, crestFactorMinDb: Float? = nil, spectralFlatnessMin: Float? = nil) {
        lock.lock()
        defer { lock.unlock() }
        analyzer?.thresholdDb = db
        if let crestFactorMinDb { analyzer?.crestFactorMinDb = crestFactorMinDb }
        if let spectralFlatnessMin { analyzer?.spectralFlatnessMin = spectralFlatnessMin }
    }

    /// Adjust the clusterer's echo-rejection level while running.
    func setEchoReject(_ db: Float) {
        lock.lock()
        defer { lock.unlock() }
        clusterer?.echoRejectDb = db
    }

    /// Reset the noise-floor and refractory state. Use between calibration phases.
    func resetAnalyzer(noiseFloorDb: Float? = nil) {
        lock.lock()
        defer { lock.unlock() }
        analyzer?.reset(noiseFloorDb: noiseFloorDb)
        clusterer?.reset()
    }

    var running: Bool {
        lock.lock(); defer { lock.unlock() }
        return isRunning
    }

    var currentNoiseFloorDb: Float {
        lock.lock(); defer { lock.unlock() }
        return analyzer?.noiseFloorDb ?? floorDb
    }

    var rejectedCentroidCount: Int {
        lock.lock(); defer { lock.unlock() }
        return analyzer?.rejectedCentroidCount ?? 0
    }

    var rejectedPeakCount: Int {
        lock.lock(); defer { lock.unlock() }
        return analyzer?.rejectedPeakCount ?? 0
    }

    /// Returns the friendly name of the currently bound input device.
    var currentDeviceName: String {
        guard let id = AudioDevices.currentInputDevice(on: engine), id != 0 else {
            return "default (none bound)"
        }
        return AudioDevices.name(forDeviceID: id) ?? "device \(id)"
    }

    private func applyConfiguredInputDevice() {
        let cfg = (try? ConfigStore.shared.load()) ?? AppConfig()
        let pref = cfg.detection.inputDevice
        if pref == "default" || pref.isEmpty { return }
        if let dev = AudioDevices.device(forUID: pref) {
            _ = AudioDevices.setInputDevice(dev.id, on: engine)
        }
    }

    /// Returns the current ring contents in oldest-to-newest order plus the
    /// noise-floor estimate.
    func snapshot() -> (samples: [Float], floorDb: Float) {
        lock.lock(); defer { lock.unlock() }
        let n = ring.count
        var ordered = [Float](repeating: -80, count: n)
        for i in 0..<n {
            ordered[i] = ring[(writePos + i) % n]
        }
        return (ordered, floorDb)
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        lock.lock()
        let analyzer = self.analyzer
        let clusterer = self.clusterer
        let voiceGate = self.voiceGate
        lock.unlock()
        // Feed the same buffer to the voice classifier in parallel.
        voiceGate?.feed(buffer: buffer)
        guard let analyzer, let clusterer else { return }
        guard let ch = buffer.floatChannelData else { return }

        // Voice-active short-circuit: don't run the analyzer at all while voice
        // is detected. This prevents onset markers, cluster builds, and any
        // observable activity during speech.
        if let voiceGate, voiceGate.isVoiceActive(within: 2.5) {
            // Still update RMS history for the waveform display, but skip
            // onset detection and clusterer.
            let count = Int(buffer.frameLength)
            let samples = ch[0]
            var sumSq: Float = 0
            for i in 0..<count { sumSq += samples[i] * samples[i] }
            let rms = (sumSq / Float(count)).squareRoot()
            let rmsDb = 20 * log10(max(rms, 1e-7))
            let floor = analyzer.noiseFloorDb
            lock.lock()
            ring[writePos] = rmsDb
            writePos = (writePos + 1) % ring.count
            floorDb = floor
            lock.unlock()
            // Also flush any pending cluster so a brief voice burst doesn't
            // leave half-built clusters that emit later.
            clusterer.reset()
            // Drive the per-frame UI tick (waveform redraw + diag line update).
            if let onUpdate {
                DispatchQueue.main.async { MainActor.assumeIsolated { onUpdate() } }
            }
            return
        }
        let count = Int(buffer.frameLength)
        let samples = ch[0]

        var sumSq: Float = 0
        var peak: Float = 0
        for i in 0..<count {
            let v = samples[i]
            sumSq += v * v
            let a = abs(v)
            if a > peak { peak = a }
        }
        let rms = (sumSq / Float(count)).squareRoot()
        let rmsDb = 20 * log10(max(rms, 1e-7))
        let peakDb = 20 * log10(max(peak, 1e-7))

        let onset = analyzer.process(samples: samples, count: count)
        if let onset { clusterer.register(onset) }
        clusterer.tick(currentTime: analyzer.elapsedTime)

        let floor = analyzer.noiseFloorDb
        lock.lock()
        ring[writePos] = rmsDb
        writePos = (writePos + 1) % ring.count
        floorDb = floor
        lock.unlock()

        if let onSample {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onSample(rmsDb, peakDb) }
            }
        }
        if let onUpdate {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onUpdate() }
            }
        }
        if let onset, let onOnset {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onOnset(onset) }
            }
        }
    }
}
