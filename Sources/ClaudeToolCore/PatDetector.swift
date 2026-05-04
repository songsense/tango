import Foundation
import AVFoundation

public final class PatDetector: @unchecked Sendable {
    public enum DetectorError: Error {
        case microphonePermissionDenied
        case audioEngineFailed(Error)
        case noInputDevice
    }

    public struct Options: Sendable {
        public var thresholdDb: Float
        public var crestFactorMinDb: Float
        public var spectralFlatnessMin: Float
        public var maxCentroidHz: Float
        public var minPeakDb: Float
        public var initialNoiseFloorDb: Float
        public var gapSeconds: TimeInterval
        public var minInterPatGap: TimeInterval
        public var maxClusterDuration: TimeInterval
        public var refractorySeconds: TimeInterval
        public var echoRejectDb: Float
        public var bufferSize: AVAudioFrameCount

        public init(
            thresholdDb: Float = 5.0,
            crestFactorMinDb: Float = 4.0,
            spectralFlatnessMin: Float = 0.0,
            maxCentroidHz: Float = 8000,
            minPeakDb: Float = -38,
            initialNoiseFloorDb: Float = -40,
            gapSeconds: TimeInterval = 0.7,
            minInterPatGap: TimeInterval = 0.12,
            maxClusterDuration: TimeInterval = 2.0,
            refractorySeconds: TimeInterval = 0.25,
            echoRejectDb: Float = 10.0,
            bufferSize: AVAudioFrameCount = 1024
        ) {
            self.thresholdDb = thresholdDb
            self.crestFactorMinDb = crestFactorMinDb
            self.spectralFlatnessMin = spectralFlatnessMin
            self.maxCentroidHz = maxCentroidHz
            self.minPeakDb = minPeakDb
            self.initialNoiseFloorDb = initialNoiseFloorDb
            self.gapSeconds = gapSeconds
            self.minInterPatGap = minInterPatGap
            self.maxClusterDuration = maxClusterDuration
            self.refractorySeconds = refractorySeconds
            self.echoRejectDb = echoRejectDb
            self.bufferSize = bufferSize
        }
    }

    private let audioEngine = AVAudioEngine()
    private let lock = NSLock()
    private var analyzer: OnsetAnalyzer?
    private var clusterer: PatClusterer?
    private var voiceGate: VoiceGate?
    public private(set) var voiceSuppressedClusters: Int = 0
    private var isRunning: Bool = false
    private var onsetObserver: (@Sendable (OnsetEvent) -> Void)?

    public init() {}

    public static var microphoneAuthorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func requestMicrophonePermission() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            return true
        }
        return await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                cont.resume(returning: ok)
            }
        }
    }

    /// Start listening. `onPats` is invoked on an arbitrary thread once a pat
    /// cluster terminates (after `gapSeconds` of silence).
    /// `onOnset`, if provided, is invoked for each detected onset (useful for
    /// calibration UIs).
    public func start(
        options: Options = Options(),
        onPats: @escaping @Sendable (Int) -> Void,
        onOnset: (@Sendable (OnsetEvent) -> Void)? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        // Apply configured input device before AVAudioEngine binds.
        let cfg = (try? ConfigStore.shared.load()) ?? AppConfig()
        let pref = cfg.detection.inputDevice
        if pref != "default" && !pref.isEmpty,
           let dev = AudioDevices.device(forUID: pref) {
            _ = AudioDevices.setInputDevice(dev.id, on: audioEngine)
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw DetectorError.noInputDevice
        }

        let analyzer = OnsetAnalyzer(
            sampleRate: format.sampleRate,
            thresholdDb: options.thresholdDb,
            crestFactorMinDb: options.crestFactorMinDb,
            spectralFlatnessMin: options.spectralFlatnessMin,
            maxCentroidHz: options.maxCentroidHz,
            minPeakDb: options.minPeakDb,
            initialNoiseFloorDb: options.initialNoiseFloorDb,
            refractorySeconds: options.refractorySeconds
        )
        let voiceGate: VoiceGate? = (try? VoiceGate(format: format))
        self.voiceGate = voiceGate
        self.voiceSuppressedClusters = 0
        // Wrap user emit closure with voice-gating: drop clusters that overlap
        // with detected speech in the last 1.5s.
        let userOnPats = onPats
        let wrappedEmit: @Sendable (Int) -> Void = { [weak self] count in
            if let gate = self?.voiceGate, gate.isVoiceActive(within: 2.5) {
                self?.lock.lock()
                self?.voiceSuppressedClusters += 1
                self?.lock.unlock()
                return
            }
            userOnPats(count)
        }
        let clusterer = PatClusterer(
            gapSeconds: options.gapSeconds,
            minInterPatGap: options.minInterPatGap,
            maxClusterDuration: options.maxClusterDuration,
            echoRejectDb: options.echoRejectDb,
            emit: wrappedEmit
        )

        self.analyzer = analyzer
        self.clusterer = clusterer
        self.onsetObserver = onOnset

        input.installTap(onBus: 0, bufferSize: options.bufferSize, format: format) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }

        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.analyzer = nil
            self.clusterer = nil
            self.onsetObserver = nil
            throw DetectorError.audioEngineFailed(error)
        }
        isRunning = true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        // Flush any pending cluster.
        if let clusterer, let analyzer {
            clusterer.tick(currentTime: analyzer.elapsedTime + 1.0)
        }
        analyzer = nil
        clusterer = nil
        voiceGate = nil
        onsetObserver = nil
        isRunning = false
    }

    public var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        // Snapshot under lock to avoid races with stop().
        lock.lock()
        let analyzer = self.analyzer
        let clusterer = self.clusterer
        let voiceGate = self.voiceGate
        let observer = self.onsetObserver
        lock.unlock()

        // Feed voice classifier in parallel.
        voiceGate?.feed(buffer: buffer)

        guard let analyzer, let clusterer else { return }
        guard let channelData = buffer.floatChannelData else { return }

        // Voice-active short-circuit: drop onsets and reset any in-progress
        // cluster, so speech can never produce a gesture.
        if let voiceGate, voiceGate.isVoiceActive(within: 2.5) {
            clusterer.reset()
            return
        }

        let count = Int(buffer.frameLength)
        let samples = channelData[0]

        if let onset = analyzer.process(samples: samples, count: count) {
            clusterer.register(onset)
            observer?(onset)
        }
        clusterer.tick(currentTime: analyzer.elapsedTime)
    }
}
