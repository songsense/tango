import XCTest
@testable import ClaudeToolCore

final class OnsetAnalyzerTests: XCTestCase {

    private func makeAnalyzer(threshold: Float = 6.0, crest: Float = 6.0, floor: Float = -55) -> OnsetAnalyzer {
        // Disable centroid + min-peak filters for these synthetic-impulse tests
        // (synthetic test signal has high Nyquist content that would trigger
        // the centroid filter; these tests validate the threshold/refractory
        // logic, not the keystroke filter).
        OnsetAnalyzer(
            sampleRate: 48_000,
            thresholdDb: threshold,
            crestFactorMinDb: crest,
            maxCentroidHz: 1_000_000,
            minPeakDb: -100,
            initialNoiseFloorDb: floor,
            noiseFloorAlpha: 0.05
        )
    }

    /// Generate a buffer of `count` samples filled with random low-amplitude noise.
    private func ambient(count: Int, amp: Float = 0.001) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        return (0..<count).map { _ in
            let v = Float.random(in: -1...1, using: &rng)
            return v * amp
        }
    }

    /// Generate a buffer that contains a single sharp impulse at `position`.
    private func impulse(count: Int, position: Int, amp: Float = 0.4) -> [Float] {
        var b = ambient(count: count, amp: 0.001)
        for i in 0..<min(48, count - position) {
            // 1 ms impulse, exponentially decaying
            let t = Float(i) / 48.0
            b[position + i] = amp * exp(-t * 8) * (i % 2 == 0 ? 1 : -1)
        }
        return b
    }

    func testAmbientProducesNoOnsets() {
        let analyzer = makeAnalyzer()
        // Warm up noise floor with a few seconds of quiet
        let buffer = ambient(count: 1024)
        for _ in 0..<300 {
            buffer.withUnsafeBufferPointer { ptr in
                _ = analyzer.process(samples: ptr.baseAddress!, count: ptr.count)
            }
        }
        var onsets = 0
        for _ in 0..<200 {
            buffer.withUnsafeBufferPointer { ptr in
                if analyzer.process(samples: ptr.baseAddress!, count: ptr.count) != nil {
                    onsets += 1
                }
            }
        }
        XCTAssertEqual(onsets, 0, "Quiet ambient noise should not trigger onsets (got \(onsets)).")
    }

    func testImpulseProducesOnset() {
        let analyzer = makeAnalyzer()
        // Warm up noise floor
        let quiet = ambient(count: 1024)
        for _ in 0..<200 {
            quiet.withUnsafeBufferPointer { ptr in
                _ = analyzer.process(samples: ptr.baseAddress!, count: ptr.count)
            }
        }
        var detected = 0
        // Send one buffer with an impulse
        let pat = impulse(count: 1024, position: 100, amp: 0.5)
        pat.withUnsafeBufferPointer { ptr in
            if analyzer.process(samples: ptr.baseAddress!, count: ptr.count) != nil {
                detected += 1
            }
        }
        XCTAssertEqual(detected, 1, "Impulse should produce exactly one onset.")
    }

    func testRefractoryRejectsImmediateRetrigger() {
        let analyzer = makeAnalyzer()
        let quiet = ambient(count: 1024)
        for _ in 0..<200 {
            quiet.withUnsafeBufferPointer { ptr in
                _ = analyzer.process(samples: ptr.baseAddress!, count: ptr.count)
            }
        }
        var detected = 0
        // Two adjacent impulse buffers — within 80ms refractory (each buffer ~21ms at 48kHz)
        for _ in 0..<2 {
            let pat = impulse(count: 1024, position: 50, amp: 0.5)
            pat.withUnsafeBufferPointer { ptr in
                if analyzer.process(samples: ptr.baseAddress!, count: ptr.count) != nil {
                    detected += 1
                }
            }
        }
        XCTAssertEqual(detected, 1, "Refractory period should suppress the second adjacent impulse.")
    }
}

private final class EmissionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func append(_ v: Int) {
        lock.lock(); values.append(v); lock.unlock()
    }
    var snapshot: [Int] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

final class PatClustererTests: XCTestCase {
    func testThreeOnsetsEmitOnce() {
        let log = EmissionLog()
        let clusterer = PatClusterer(gapSeconds: 0.7) { count in
            log.append(count)
        }
        clusterer.register(OnsetEvent(timestamp: 0.0, peakDb: -20, rmsDb: -30))
        clusterer.register(OnsetEvent(timestamp: 0.2, peakDb: -20, rmsDb: -30))
        clusterer.register(OnsetEvent(timestamp: 0.4, peakDb: -20, rmsDb: -30))
        clusterer.tick(currentTime: 1.5)
        XCTAssertEqual(log.snapshot, [3])
    }

    func testTwoClustersSeparatedByGap() {
        let log = EmissionLog()
        let clusterer = PatClusterer(gapSeconds: 0.7) { count in
            log.append(count)
        }
        clusterer.register(OnsetEvent(timestamp: 0.0, peakDb: -20, rmsDb: -30))
        clusterer.register(OnsetEvent(timestamp: 0.3, peakDb: -20, rmsDb: -30))
        clusterer.tick(currentTime: 1.5)
        clusterer.register(OnsetEvent(timestamp: 1.6, peakDb: -20, rmsDb: -30))
        clusterer.tick(currentTime: 2.5)
        XCTAssertEqual(log.snapshot, [2, 1])
    }

    func testMaxPatsForcesEmit() {
        let log = EmissionLog()
        let clusterer = PatClusterer(gapSeconds: 0.7, maxPats: 3) { count in
            log.append(count)
        }
        // Use spacing > minInterPatGap (120ms) so each onset is accepted.
        clusterer.register(OnsetEvent(timestamp: 0.0, peakDb: -20, rmsDb: -30))
        clusterer.register(OnsetEvent(timestamp: 0.2, peakDb: -20, rmsDb: -30))
        clusterer.register(OnsetEvent(timestamp: 0.4, peakDb: -20, rmsDb: -30))
        XCTAssertEqual(log.snapshot, [3])
    }

    func testEchoesAreMerged() {
        let log = EmissionLog()
        let clusterer = PatClusterer(gapSeconds: 0.7) { count in
            log.append(count)
        }
        // One real pat + two echoes within 120ms — should count as 1.
        clusterer.register(OnsetEvent(timestamp: 0.0, peakDb: -20, rmsDb: -30))
        clusterer.register(OnsetEvent(timestamp: 0.04, peakDb: -25, rmsDb: -35))
        clusterer.register(OnsetEvent(timestamp: 0.08, peakDb: -28, rmsDb: -38))
        clusterer.tick(currentTime: 1.0)
        XCTAssertEqual(log.snapshot, [1])
    }

    func testEchoRejectedByPeakDifference() {
        let log = EmissionLog()
        let clusterer = PatClusterer(gapSeconds: 0.7, echoRejectDb: 10) { count in
            log.append(count)
        }
        // Strong pat at peak -10dB, then a soft echo at -25dB 200ms later
        // (well past minInterPatGap, so timing wouldn't reject it).
        clusterer.register(OnsetEvent(timestamp: 0.0, peakDb: -10, rmsDb: -20))
        clusterer.register(OnsetEvent(timestamp: 0.20, peakDb: -25, rmsDb: -35))
        clusterer.tick(currentTime: 1.0)
        XCTAssertEqual(log.snapshot, [1], "Soft echo > 10dB below peak should be rejected.")
    }

    func testEqualPatsAccepted() {
        let log = EmissionLog()
        let clusterer = PatClusterer(gapSeconds: 0.7, echoRejectDb: 10) { count in
            log.append(count)
        }
        // Three pats with similar peaks — should all count.
        clusterer.register(OnsetEvent(timestamp: 0.0, peakDb: -10, rmsDb: -20))
        clusterer.register(OnsetEvent(timestamp: 0.25, peakDb: -12, rmsDb: -22))
        clusterer.register(OnsetEvent(timestamp: 0.5, peakDb: -11, rmsDb: -21))
        clusterer.tick(currentTime: 1.5)
        XCTAssertEqual(log.snapshot, [3])
    }

    func testOverlongClusterRejected() {
        let log = EmissionLog()
        let clusterer = PatClusterer(gapSeconds: 0.7, maxClusterDuration: 1.0) { count in
            log.append(count)
        }
        // Onsets spread over > 1s — not a deliberate gesture.
        clusterer.register(OnsetEvent(timestamp: 0.0, peakDb: -20, rmsDb: -30))
        clusterer.register(OnsetEvent(timestamp: 0.6, peakDb: -20, rmsDb: -30))
        clusterer.register(OnsetEvent(timestamp: 1.2, peakDb: -20, rmsDb: -30))
        clusterer.tick(currentTime: 2.0)
        XCTAssertEqual(log.snapshot, [])
    }
}
