import Foundation
import AVFoundation
import SoundAnalysis

/// Wraps Apple's SoundAnalysis built-in sound classifier (`.version1`) into a
/// simple "is voice currently active?" gate. Runs alongside the DSP onset
/// detector — we feed it the same audio buffers, then consult it before
/// emitting a pat cluster.
///
/// The built-in classifier covers ~300 sound categories including `speech`,
/// `singing`, `shout`, etc. We treat any of those above `confidenceThreshold`
/// as "voice active" for the next `cooldownSeconds`.
public final class VoiceGate: @unchecked Sendable {
    public static let speechClasses: Set<String> = [
        "speech", "narration_monologue", "conversation",
        "shout", "yell", "whispering",
        "singing", "humming", "whistling",
        "child_speech", "male_speech", "female_speech"
    ]

    private let analyzer: SNAudioStreamAnalyzer
    private let request: SNClassifySoundRequest
    private let observer: VoiceObserver
    private var elapsedFrames: AVAudioFramePosition = 0
    private let queue = DispatchQueue(label: "tango.voicegate.analysis", qos: .userInitiated)

    public init(format: AVAudioFormat, confidenceThreshold: Double = 0.3) throws {
        self.analyzer = SNAudioStreamAnalyzer(format: format)
        self.request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        // Default window is 3s — first speech detection wouldn't arrive until
        // 3s into talking, which means clusters in the first 3s aren't gated.
        // Drop to the model's minimum (0.975s) and overlap 75% so a new
        // classification arrives every ~250ms.
        self.request.windowDuration = CMTime(seconds: 0.975, preferredTimescale: 48_000)
        self.request.overlapFactor = 0.75
        self.observer = VoiceObserver(threshold: confidenceThreshold)
        try analyzer.add(request, withObserver: observer)
    }

    /// Returns the model's top classification regardless of class type, for debugging.
    public var topClassification: (label: String, confidence: Double, age: TimeInterval) {
        observer.topSnapshot()
    }

    /// Returns the full top-3 list so we can see what the classifier is producing.
    public var top3: [(label: String, confidence: Double)] {
        observer.top3()
    }

    /// Feed an audio buffer into the analyzer. Safe to call from the audio thread.
    public func feed(buffer: AVAudioPCMBuffer) {
        let pos = elapsedFrames
        elapsedFrames += AVAudioFramePosition(buffer.frameLength)
        // SoundAnalysis is documented as thread-safe; dispatching to a serial
        // background queue keeps inference work off the audio thread.
        queue.async { [analyzer] in
            analyzer.analyze(buffer, atAudioFramePosition: pos)
        }
    }

    /// True if speech-class audio was detected within `seconds` ago.
    public func isVoiceActive(within seconds: TimeInterval = 1.5) -> Bool {
        observer.isActive(within: seconds)
    }

    /// Recently-seen confidence + label, for diagnostics.
    public var lastObservation: (label: String, confidence: Double, age: TimeInterval) {
        observer.snapshot()
    }
}

private final class VoiceObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private let threshold: Double
    private var lastSpeechTime: Date = .distantPast
    private var lastSpeechLabel: String = ""
    private var lastSpeechConfidence: Double = 0
    private var lastTopLabel: String = ""
    private var lastTopConfidence: Double = 0
    private var lastTop3: [(String, Double)] = []

    init(threshold: Double) {
        self.threshold = threshold
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        // Best speech-class label
        var bestSpeech = ""
        var bestSpeechConf: Double = 0
        for c in r.classifications.prefix(20) {
            if VoiceGate.speechClasses.contains(c.identifier) && c.confidence > bestSpeechConf {
                bestSpeechConf = c.confidence
                bestSpeech = c.identifier
            }
        }
        // Top classification regardless of class
        let topClassifications = r.classifications.prefix(3).map { ($0.identifier, $0.confidence) }
        lock.lock()
        lastSpeechConfidence = bestSpeechConf
        lastSpeechLabel = bestSpeech
        if bestSpeechConf >= threshold {
            lastSpeechTime = Date()
        }
        if let first = topClassifications.first {
            lastTopLabel = first.0
            lastTopConfidence = first.1
        }
        lastTop3 = Array(topClassifications)
        lock.unlock()
    }

    func isActive(within seconds: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastSpeechTime) < seconds
    }

    func snapshot() -> (label: String, confidence: Double, age: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        return (lastSpeechLabel, lastSpeechConfidence, Date().timeIntervalSince(lastSpeechTime))
    }

    func topSnapshot() -> (label: String, confidence: Double, age: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        return (lastTopLabel, lastTopConfidence, Date().timeIntervalSince(lastSpeechTime))
    }

    func top3() -> [(label: String, confidence: Double)] {
        lock.lock(); defer { lock.unlock() }
        return lastTop3
    }
}
