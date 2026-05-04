import Foundation
import ClaudeToolCore

/// Step-by-step user-driven calibration. The window controller calls
/// `begin()` / `startStep()` / `finishStep()` / `nextStep()` in response to
/// button clicks. There are 3 pat steps after a 3-second auto ambient phase.
@MainActor
final class CalibrationFlow {
    enum Phase: Equatable, Sendable {
        case idle
        case ambientListening(remaining: Double)
        case stepReady(label: Int, stepIndex: Int, totalSteps: Int)
        case stepListening(label: Int, stepIndex: Int, totalSteps: Int, gestures: [Int])
        case stepReview(label: Int, stepIndex: Int, totalSteps: Int, gestures: [Int])
        case tuning
        case completed
        case cancelled
        case failed(reason: String)
    }

    struct LabeledTrial: Sendable {
        let expectedCount: Int
        let onsets: [OnsetEvent]
    }

    struct Result: Sendable {
        let ambientFloorDb: Float
        let ambientP95Db: Float
        let trialsByLabel: [Int: [LabeledTrial]]
        let recommendedThresholdDb: Float
        let recommendedCrestFactorDb: Float
        let recommendedSpectralFlatnessMin: Float
        let recommendedEchoRejectDb: Float
        let perLabelAccuracy: [Int: Double]
        let overallAccuracy: Double

        var passed: Bool { overallAccuracy >= 0.7 }
    }

    var onPhase: ((Phase) -> Void)?
    var onCandidate: ((OnsetEvent) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var phase: Phase = .idle {
        didSet { onPhase?(phase) }
    }

    private let monitor = AudioMonitor()
    private let stepLabels = [1, 2, 3]

    private var currentStepIndex = 0
    private var ambientRms: [Float] = []
    private var ambientFloorDb: Float = -50
    private var ambientP95Db: Float = -40

    /// Per-step onsets captured (regardless of clustering) — used for grid search.
    private var stepOnsets: [Int: [OnsetEvent]] = [:]
    /// Per-step gesture counts emitted by current analyzer — used for live UI.
    private var stepGestures: [Int: [Int]] = [:]
    private var currentLabel: Int = 1
    private var currentStepStartTime: TimeInterval = 0

    private var ambientTask: Task<Void, Never>?
    private var cancelled = false

    var liveMonitor: AudioMonitor { monitor }

    func cancel() {
        cancelled = true
        ambientTask?.cancel()
        monitor.stop()
        phase = .cancelled
    }

    /// Begin the flow. Starts the mic in capture mode and runs the 3-second ambient
    /// phase automatically. Then transitions to .stepReady for step 1 and waits for
    /// the user to call startStep().
    func begin() {
        cancelled = false
        ambientRms = []
        stepOnsets = [:]
        stepGestures = [:]
        currentStepIndex = 0

        monitor.onSample = { [weak self] rms, _ in
            guard let self else { return }
            if case .ambientListening = self.phase {
                self.ambientRms.append(rms)
            }
        }
        monitor.onOnset = { [weak self] event in
            guard let self else { return }
            self.onCandidate?(event)
            if case .stepListening(let label, _, _, _) = self.phase {
                self.stepOnsets[label, default: []].append(event)
            }
        }
        monitor.onPat = { [weak self] count in
            guard let self else { return }
            if case .stepListening(let label, let idx, let total, var gestures) = self.phase {
                gestures.append(count)
                self.stepGestures[label, default: []].append(count)
                self.phase = .stepListening(label: label, stepIndex: idx, totalSteps: total, gestures: gestures)
            }
        }

        do {
            // Capture-mode: very permissive, every candidate onset is captured.
            try monitor.start(
                thresholdDb: 4,
                crestFactorMinDb: 4,
                spectralFlatnessMin: 0.0,
                initialFloorDb: -30,
                refractorySeconds: 0.20,
                echoRejectDb: 100  // disable echo rejection during capture; we add it back in tuning
            )
        } catch {
            phase = .failed(reason: "Mic error: \(error.localizedDescription)")
            return
        }

        ambientTask = Task { @MainActor [weak self] in
            await self?.runAmbient()
        }
    }

    private func runAmbient() async {
        // 600 ms warmup
        try? await Task.sleep(nanoseconds: 600_000_000)
        if cancelled { return }
        ambientRms = []

        let end = Date().addingTimeInterval(3.0)
        while Date() < end && !cancelled {
            phase = .ambientListening(remaining: max(0, end.timeIntervalSinceNow))
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if cancelled { return }

        ambientFloorDb = robustNoiseFloor(ambientRms)
        ambientP95Db = percentile(ambientRms, 0.95)
        log("ambient floor=\(ambientFloorDb) dB, p95=\(ambientP95Db) dB, n=\(ambientRms.count)")

        // Move to step 1 ready
        currentStepIndex = 0
        currentLabel = stepLabels[0]
        phase = .stepReady(label: currentLabel, stepIndex: 1, totalSteps: stepLabels.count)
    }

    /// Called by UI when user clicks "Start step". Begin listening for gestures.
    func startStep() {
        guard case .stepReady(let label, let idx, let total) = phase else { return }
        // Reset analyzer for clean step
        monitor.resetAnalyzer(noiseFloorDb: ambientFloorDb)
        // Tighter live thresholds so the on-screen count is realistic, while
        // raw onsets are still captured for tuning.
        monitor.setThreshold(
            10,
            crestFactorMinDb: 8,
            spectralFlatnessMin: 0.08
        )
        monitor.setEchoReject(10)

        stepOnsets[label] = []
        stepGestures[label] = []
        currentLabel = label
        currentStepStartTime = Date().timeIntervalSinceReferenceDate
        phase = .stepListening(label: label, stepIndex: idx, totalSteps: total, gestures: [])
    }

    /// Called by UI when user clicks "I'm done with this step".
    func finishStep() {
        guard case .stepListening(let label, let idx, let total, let gestures) = phase else { return }
        // Switch back to permissive mode for next step's capture
        monitor.setThreshold(
            4,
            crestFactorMinDb: 4,
            spectralFlatnessMin: 0.0
        )
        phase = .stepReview(label: label, stepIndex: idx, totalSteps: total, gestures: gestures)
    }

    /// Called by UI when user clicks "Next step" / "Run tuning".
    func nextStep() async {
        currentStepIndex += 1
        if currentStepIndex >= stepLabels.count {
            await runTuning()
        } else {
            currentLabel = stepLabels[currentStepIndex]
            phase = .stepReady(label: currentLabel, stepIndex: currentStepIndex + 1, totalSteps: stepLabels.count)
        }
    }

    private func runTuning() async {
        monitor.stop()
        phase = .tuning
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Build LabeledTrial set: each step contributes potentially many trials
        // (one per gesture-cluster). Slice the captured onset stream by 700ms gap.
        var trialsByLabel: [Int: [LabeledTrial]] = [:]
        for (label, onsets) in stepOnsets {
            let trials = sliceIntoTrials(onsets: onsets, gapSeconds: 0.7)
            trialsByLabel[label] = trials.map { LabeledTrial(expectedCount: label, onsets: $0) }
        }

        let allTrials = trialsByLabel.values.flatMap { $0 }
        log("tuning on \(allTrials.count) trials: \(trialsByLabel.mapValues { $0.count })")

        // Run grid search off the main actor so the UI stays responsive.
        let floor = ambientFloorDb
        let trialsCopy = allTrials
        let tuned: TuningResult = await Task.detached(priority: .userInitiated) {
            return CalibrationFlow.staticTune(trials: trialsCopy, floorDb: floor)
        }.value

        let result = Result(
            ambientFloorDb: ambientFloorDb,
            ambientP95Db: ambientP95Db,
            trialsByLabel: trialsByLabel,
            recommendedThresholdDb: tuned.thresholdDb,
            recommendedCrestFactorDb: tuned.crestDb,
            recommendedSpectralFlatnessMin: tuned.flatness,
            recommendedEchoRejectDb: tuned.echoReject,
            perLabelAccuracy: tuned.perLabelAccuracy,
            overallAccuracy: tuned.accuracy
        )
        log("tuned: t=\(tuned.thresholdDb) c=\(tuned.crestDb) f=\(tuned.flatness) er=\(tuned.echoReject) acc=\(tuned.accuracy)")
        // IMPORTANT: assign cachedResult BEFORE switching phase, so the UI sees
        // the result on the .completed callback.
        cachedResult = result
        phase = .completed
    }

    private(set) var cachedResult: Result?

    /// Cut a long onset stream into trial groups by 700ms silence gap.
    private func sliceIntoTrials(onsets: [OnsetEvent], gapSeconds: Double) -> [[OnsetEvent]] {
        guard !onsets.isEmpty else { return [] }
        var trials: [[OnsetEvent]] = []
        var current: [OnsetEvent] = [onsets[0]]
        for i in 1..<onsets.count {
            let gap = onsets[i].timestamp - onsets[i - 1].timestamp
            if gap > gapSeconds {
                trials.append(current)
                current = [onsets[i]]
            } else {
                current.append(onsets[i])
            }
        }
        trials.append(current)
        return trials
    }

    // MARK: - Tuning

    fileprivate struct TuningResult {
        let thresholdDb: Float
        let crestDb: Float
        let flatness: Float
        let echoReject: Float
        let perLabelAccuracy: [Int: Double]
        let accuracy: Double
    }

    nonisolated fileprivate static func staticTune(trials: [LabeledTrial], floorDb: Float) -> TuningResult {
        let dummy = CalibrationFlow.tuneCore(trials: trials, floorDb: floorDb)
        return dummy
    }

    nonisolated fileprivate static func tuneCore(trials: [LabeledTrial], floorDb: Float) -> TuningResult {
        let thresholdGrid: [Float] = [4, 6, 8, 10, 12, 14, 16, 18]
        let crestGrid: [Float] = [4, 6, 8, 10, 12]
        let flatGrid: [Float] = [0.0, 0.05, 0.10, 0.15]
        let echoGrid: [Float] = [6, 8, 10, 12, 14]

        var best = TuningResult(
            thresholdDb: 8, crestDb: 6, flatness: 0.06, echoReject: 10,
            perLabelAccuracy: [:], accuracy: 0
        )

        for t in thresholdGrid {
            for c in crestGrid {
                for f in flatGrid {
                    for er in echoGrid {
                        var perLabelHits: [Int: Int] = [1: 0, 2: 0, 3: 0]
                        var perLabelTotal: [Int: Int] = [1: 0, 2: 0, 3: 0]
                        for trial in trials {
                            let count = simulateClusterCount(
                                onsets: trial.onsets,
                                floorDb: floorDb,
                                thresholdDb: t,
                                crestDb: c,
                                flatness: f,
                                echoRejectDb: er
                            )
                            perLabelTotal[trial.expectedCount, default: 0] += 1
                            if count == trial.expectedCount {
                                perLabelHits[trial.expectedCount, default: 0] += 1
                            }
                        }
                        let totalHits = perLabelHits.values.reduce(0, +)
                        let totalTrials = perLabelTotal.values.reduce(0, +)
                        guard totalTrials > 0 else { continue }
                        let accuracy = Double(totalHits) / Double(totalTrials)
                        var perLabelAcc: [Int: Double] = [:]
                        for (k, v) in perLabelTotal where v > 0 {
                            perLabelAcc[k] = Double(perLabelHits[k] ?? 0) / Double(v)
                        }
                        let isBetter = accuracy > best.accuracy
                            || (accuracy == best.accuracy && t > best.thresholdDb)
                        if isBetter {
                            best = TuningResult(
                                thresholdDb: t,
                                crestDb: c,
                                flatness: f,
                                echoReject: er,
                                perLabelAccuracy: perLabelAcc,
                                accuracy: accuracy
                            )
                        }
                    }
                }
            }
        }
        return best
    }

    nonisolated private static func simulateClusterCount(
        onsets: [OnsetEvent],
        floorDb: Float,
        thresholdDb: Float,
        crestDb: Float,
        flatness: Float,
        echoRejectDb: Float
    ) -> Int {
        let survivors = onsets.filter { e in
            (e.rmsDb - floorDb) >= thresholdDb
                && (e.peakDb - e.rmsDb) >= crestDb
                && e.spectralFlatness >= flatness
        }
        guard !survivors.isEmpty else { return 0 }
        let minGap: TimeInterval = 0.12
        let maxDuration: TimeInterval = 2.0
        var count = 0
        var clusterStart: TimeInterval = -.infinity
        var lastAccepted: TimeInterval = -.infinity
        var clusterPeak: Float = -.infinity
        for e in survivors {
            if count == 0 {
                clusterStart = e.timestamp
                lastAccepted = e.timestamp
                clusterPeak = e.peakDb
                count = 1
            } else if e.timestamp - lastAccepted < minGap {
                continue
            } else if e.peakDb < clusterPeak - echoRejectDb {
                continue
            } else {
                count += 1
                lastAccepted = e.timestamp
                if e.peakDb > clusterPeak { clusterPeak = e.peakDb }
            }
        }
        if count > 1 && (lastAccepted - clusterStart) > maxDuration {
            return 0
        }
        return count
    }

    // MARK: - Stats helpers

    private func robustNoiseFloor(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -50 }
        let sorted = samples.sorted()
        let lowerHalf = sorted.prefix(max(1, sorted.count / 2))
        let mid = lowerHalf.count / 2
        return Array(lowerHalf)[mid]
    }

    private func percentile(_ samples: [Float], _ p: Double) -> Float {
        guard !samples.isEmpty else { return -50 }
        let sorted = samples.sorted()
        let idx = min(sorted.count - 1, Int(Double(sorted.count - 1) * p))
        return sorted[idx]
    }

    private func log(_ s: String) {
        onLog?(s)
    }
}
