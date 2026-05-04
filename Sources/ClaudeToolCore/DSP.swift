import Foundation
import Accelerate

public struct OnePoleHighPass {
    public let alpha: Float
    private var prevIn: Float = 0
    private var prevOut: Float = 0

    public init(cutoffHz: Float, sampleRate: Float) {
        let rc = 1 / (2 * .pi * cutoffHz)
        let dt = 1 / sampleRate
        self.alpha = rc / (rc + dt)
    }

    public mutating func process(_ x: Float) -> Float {
        let y = alpha * (prevOut + x - prevIn)
        prevIn = x
        prevOut = y
        return y
    }
}

public struct OnsetEvent: Sendable, Equatable {
    public let timestamp: TimeInterval
    public let peakDb: Float
    public let rmsDb: Float
    public let spectralFlatness: Float
    public let spectralCentroidHz: Float

    public init(
        timestamp: TimeInterval,
        peakDb: Float,
        rmsDb: Float,
        spectralFlatness: Float = 1.0,
        spectralCentroidHz: Float = 0
    ) {
        self.timestamp = timestamp
        self.peakDb = peakDb
        self.rmsDb = rmsDb
        self.spectralFlatness = spectralFlatness
        self.spectralCentroidHz = spectralCentroidHz
    }
}

/// FFT-based spectral flatness. Pats/impacts produce broadband energy
/// (flatness ≳ 0.2). Voice/music are harmonic (flatness < 0.1).
public final class SpectralAnalyzer {
    private let n: Int
    private let halfN: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let realIn: UnsafeMutablePointer<Float>
    private let imagIn: UnsafeMutablePointer<Float>
    private let magSq: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let window: UnsafeMutablePointer<Float>

    public init(fftSize: Int = 512) {
        precondition(fftSize >= 32 && (fftSize & (fftSize - 1)) == 0, "fftSize must be a power of 2")
        self.n = fftSize
        self.halfN = fftSize / 2
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2))!
        self.realIn = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        self.imagIn = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        self.magSq = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        self.windowed = UnsafeMutablePointer<Float>.allocate(capacity: n)
        self.window = UnsafeMutablePointer<Float>.allocate(capacity: n)
        realIn.initialize(repeating: 0, count: halfN)
        imagIn.initialize(repeating: 0, count: halfN)
        magSq.initialize(repeating: 0, count: halfN)
        windowed.initialize(repeating: 0, count: n)
        window.initialize(repeating: 0, count: n)
        vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        realIn.deallocate()
        imagIn.deallocate()
        magSq.deallocate()
        windowed.deallocate()
        window.deallocate()
    }

    public struct Stats: Sendable, Equatable {
        public let flatness: Float       // [0,1]: high = broadband (impulse), low = harmonic (voice)
        public let centroidHz: Float     // weighted center frequency
    }

    /// Returns flatness + spectral centroid for the first `n` samples (or padded).
    public func analyze(samples: UnsafePointer<Float>, count: Int, sampleRate: Float) -> Stats {
        let copyCount = min(count, n)
        for i in 0..<copyCount { windowed[i] = samples[i] * window[i] }
        for i in copyCount..<n { windowed[i] = 0 }

        var split = DSPSplitComplex(realp: realIn, imagp: imagIn)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfN))
        }

        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, magSq, 1, vDSP_Length(halfN))

        // Skip very-low bins (DC + ~150Hz) to avoid AC hum / room rumble bias.
        let lowBin = 2
        let nBins = halfN - lowBin
        guard nBins > 0 else { return Stats(flatness: 0, centroidHz: 0) }

        // Compute spectral flatness on MAGNITUDES (sqrt of magSq), matching
        // the Python analysis script — power-flatness has ~quadratically
        // smaller values than magnitude-flatness, so thresholds must match.
        var sumLog: Float = 0
        var sumMag: Float = 0
        var weightedFreqSum: Float = 0
        let binHz = sampleRate / Float(n)
        for i in lowBin..<halfN {
            let mag = max(magSq[i], 1e-24).squareRoot()
            sumLog += log(mag)
            sumMag += mag
            weightedFreqSum += Float(i) * binHz * mag
        }
        if sumMag < 1e-12 { return Stats(flatness: 0, centroidHz: 0) }
        let arithMean = sumMag / Float(nBins)
        let geomMean = exp(sumLog / Float(nBins))
        let flatness = geomMean / arithMean
        let centroid = weightedFreqSum / sumMag
        return Stats(flatness: flatness, centroidHz: centroid)
    }

    /// Convenience: flatness only.
    public func flatness(samples: UnsafePointer<Float>, count: Int) -> Float {
        analyze(samples: samples, count: count, sampleRate: 48000).flatness
    }
}

public final class OnsetAnalyzer {
    public let sampleRate: Double
    public var thresholdDb: Float
    public var crestFactorMinDb: Float
    public var spectralFlatnessMin: Float
    public var maxCentroidHz: Float       // reject onsets with centroid above this (keystroke filter)
    public var minPeakDb: Float           // reject onsets softer than this (absolute, kills soft typing)
    public var noiseFloorAlpha: Float
    public let refractorySeconds: TimeInterval
    public let warmupSeconds: TimeInterval
    public let smoothingFactor: Float    // EMA over RMS to suppress single-buffer spikes

    public private(set) var noiseFloorDb: Float
    public private(set) var lastRejectedCentroid: Float = 0   // for diagnostics
    public private(set) var lastRejectedPeak: Float = -.infinity
    public private(set) var rejectedCentroidCount: Int = 0
    public private(set) var rejectedPeakCount: Int = 0

    private var smoothedRmsDb: Float
    private var refractoryUntil: TimeInterval = -.infinity
    private var elapsedSamples: UInt64 = 0
    private var highPass: OnePoleHighPass
    private let spectral: SpectralAnalyzer
    private var filterBuf: [Float] = []

    public init(
        sampleRate: Double,
        thresholdDb: Float = 5.0,
        crestFactorMinDb: Float = 4.0,
        spectralFlatnessMin: Float = 0.0,    // disabled: doesn't discriminate on a wideband mic
        maxCentroidHz: Float = 8000,         // effectively off
        minPeakDb: Float = -38,              // tuned from labeled recordings: keystrokes peak at p95=-38.5dB
        initialNoiseFloorDb: Float = -40,
        noiseFloorAlpha: Float = 0.03,
        refractorySeconds: TimeInterval = 0.25,
        warmupSeconds: TimeInterval = 0.6,
        smoothingFactor: Float = 0.5,
        highPassCutoffHz: Float = 200,
        fftSize: Int = 1024
    ) {
        self.sampleRate = sampleRate
        self.thresholdDb = thresholdDb
        self.crestFactorMinDb = crestFactorMinDb
        self.spectralFlatnessMin = spectralFlatnessMin
        self.maxCentroidHz = maxCentroidHz
        self.minPeakDb = minPeakDb
        self.noiseFloorDb = initialNoiseFloorDb
        self.smoothedRmsDb = initialNoiseFloorDb
        self.noiseFloorAlpha = noiseFloorAlpha
        self.refractorySeconds = refractorySeconds
        self.warmupSeconds = warmupSeconds
        self.smoothingFactor = smoothingFactor
        self.highPass = OnePoleHighPass(cutoffHz: highPassCutoffHz, sampleRate: Float(sampleRate))
        self.spectral = SpectralAnalyzer(fftSize: fftSize)
    }

    /// Returns an OnsetEvent if this buffer contains the start of a pat, else nil.
    public func process(samples: UnsafePointer<Float>, count: Int) -> OnsetEvent? {
        guard count > 0 else { return nil }

        if filterBuf.count < count {
            filterBuf = [Float](repeating: 0, count: count)
        }
        var sumSq: Float = 0
        var peak: Float = 0
        for i in 0..<count {
            let y = highPass.process(samples[i])
            filterBuf[i] = y
            sumSq += y * y
            let a = abs(y)
            if a > peak { peak = a }
        }
        let rms = (sumSq / Float(count)).squareRoot()
        let rawRmsDb = 20 * log10(max(rms, 1e-7))
        let peakDb = 20 * log10(max(peak, 1e-7))

        // EMA smoothing reduces single-buffer spikes (e.g., a dropped audio packet)
        smoothedRmsDb = smoothedRmsDb * (1 - smoothingFactor) + rawRmsDb * smoothingFactor

        let bufferDuration = TimeInterval(count) / sampleRate
        let bufferStart = TimeInterval(elapsedSamples) / sampleRate
        elapsedSamples &+= UInt64(count)

        // Warmup: aggressively learn the floor, never emit.
        if bufferStart < warmupSeconds {
            let alpha: Float = 0.3
            noiseFloorDb = noiseFloorDb * (1 - alpha) + rawRmsDb * alpha
            smoothedRmsDb = noiseFloorDb
            return nil
        }

        if bufferStart < refractoryUntil {
            return nil
        }

        let aboveFloor = rawRmsDb - noiseFloorDb
        let crest = peakDb - rawRmsDb

        if aboveFloor > thresholdDb && crest > crestFactorMinDb {
            // Absolute peak amplitude floor — kills soft typing without
            // needing to look at spectrum.
            if peakDb < minPeakDb {
                rejectedPeakCount += 1
                lastRejectedPeak = peakDb
                let target = min(rawRmsDb, noiseFloorDb + 6)
                noiseFloorDb = noiseFloorDb * (1 - noiseFloorAlpha) + target * noiseFloorAlpha
                return nil
            }
            // Spectral analysis on the high-passed candidate buffer.
            let stats = filterBuf.withUnsafeBufferPointer { ptr in
                spectral.analyze(samples: ptr.baseAddress!, count: count, sampleRate: Float(sampleRate))
            }
            if stats.flatness < spectralFlatnessMin {
                // Looks harmonic (voice/music) — reject.
                let target = min(rawRmsDb, noiseFloorDb + 6)
                noiseFloorDb = noiseFloorDb * (1 - noiseFloorAlpha) + target * noiseFloorAlpha
                return nil
            }
            // High-centroid filter — keystrokes peak ~3-8 kHz, clap/tap-desk peak <2.5 kHz.
            if stats.centroidHz > maxCentroidHz {
                rejectedCentroidCount += 1
                lastRejectedCentroid = stats.centroidHz
                let target = min(rawRmsDb, noiseFloorDb + 6)
                noiseFloorDb = noiseFloorDb * (1 - noiseFloorAlpha) + target * noiseFloorAlpha
                return nil
            }
            refractoryUntil = bufferStart + refractorySeconds
            return OnsetEvent(
                timestamp: bufferStart + bufferDuration / 2,
                peakDb: peakDb,
                rmsDb: rawRmsDb,
                spectralFlatness: stats.flatness,
                spectralCentroidHz: stats.centroidHz
            )
        } else {
            let target = min(rawRmsDb, noiseFloorDb + 6)
            noiseFloorDb = noiseFloorDb * (1 - noiseFloorAlpha) + target * noiseFloorAlpha
            return nil
        }
    }

    public func reset(noiseFloorDb: Float? = nil) {
        if let n = noiseFloorDb { self.noiseFloorDb = n }
        smoothedRmsDb = self.noiseFloorDb
        refractoryUntil = -.infinity
        elapsedSamples = 0
    }

    public var elapsedTime: TimeInterval {
        TimeInterval(elapsedSamples) / sampleRate
    }
}

public final class PatClusterer {
    public let gapSeconds: TimeInterval         // post-cluster silence to flush
    public let minInterPatGap: TimeInterval     // merge onsets closer than this
    public let maxClusterDuration: TimeInterval // reject clusters longer than this
    public var echoRejectDb: Float              // reject onsets weaker than (clusterPeak - this) dB — mutable so callers can adjust live
    public let maxPats: Int

    private var firstOnsetTime: TimeInterval = -.infinity
    private var lastAcceptedOnsetTime: TimeInterval = -.infinity
    private var clusterPeakDb: Float = -.infinity
    private var pendingCount: Int = 0
    private let emit: @Sendable (Int) -> Void

    public init(
        gapSeconds: TimeInterval = 0.7,
        minInterPatGap: TimeInterval = 0.12,
        maxClusterDuration: TimeInterval = 2.0,
        echoRejectDb: Float = 10.0,
        maxPats: Int = 5,
        emit: @escaping @Sendable (Int) -> Void
    ) {
        self.gapSeconds = gapSeconds
        self.minInterPatGap = minInterPatGap
        self.maxClusterDuration = maxClusterDuration
        self.echoRejectDb = echoRejectDb
        self.maxPats = maxPats
        self.emit = emit
    }

    public func register(_ onset: OnsetEvent) {
        let t = onset.timestamp

        // Long gap → flush previous, start new cluster.
        if pendingCount > 0 && t - lastAcceptedOnsetTime > gapSeconds {
            flushIfValid()
        }

        // Within an active cluster: enforce inter-pat gap (debounce echoes).
        if pendingCount > 0 && t - lastAcceptedOnsetTime < minInterPatGap {
            return
        }

        // Within an active cluster: reject onsets significantly softer than the
        // cluster's peak — those are physical echoes / case ringing of a real pat.
        if pendingCount > 0 && onset.peakDb < clusterPeakDb - echoRejectDb {
            return
        }

        if pendingCount == 0 {
            firstOnsetTime = t
            clusterPeakDb = onset.peakDb
        } else {
            clusterPeakDb = max(clusterPeakDb, onset.peakDb)
        }
        pendingCount += 1
        lastAcceptedOnsetTime = t

        // Cluster duration cap.
        if t - firstOnsetTime > maxClusterDuration {
            reset()
            return
        }

        if pendingCount >= maxPats {
            flushIfValid()
        }
    }

    public func tick(currentTime: TimeInterval) {
        if pendingCount > 0 && currentTime - lastAcceptedOnsetTime > gapSeconds {
            flushIfValid()
        }
    }

    public func reset() {
        pendingCount = 0
        firstOnsetTime = -.infinity
        lastAcceptedOnsetTime = -.infinity
        clusterPeakDb = -.infinity
    }

    private func flushIfValid() {
        let count = pendingCount
        let span = lastAcceptedOnsetTime - firstOnsetTime
        reset()
        guard count > 0 else { return }
        if count > 1 && span > maxClusterDuration { return }
        emit(count)
    }
}
