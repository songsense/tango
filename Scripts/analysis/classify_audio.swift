#!/usr/bin/env swift
// Run Apple's SoundAnalysis (.version1) classifier over an audio file and
// print every per-window classification. Used to diagnose whether SoundAnalysis
// recognizes user speech as speech-class labels.
//
// Usage:
//     swift Scripts/analysis/classify_audio.swift path/to/file.m4a [--top N]

import Foundation
import AVFoundation
import SoundAnalysis

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: classify_audio.swift <audio-file> [--top N]\n", stderr)
    exit(1)
}
let inputPath = CommandLine.arguments[1]
let topN: Int = {
    if let i = CommandLine.arguments.firstIndex(of: "--top"),
       i + 1 < CommandLine.arguments.count,
       let n = Int(CommandLine.arguments[i + 1]) { return n }
    return 5
}()

let inputURL = URL(fileURLWithPath: inputPath)

// Load audio file
let audioFile: AVAudioFile
do {
    audioFile = try AVAudioFile(forReading: inputURL)
} catch {
    fputs("could not open audio file: \(error)\n", stderr)
    exit(2)
}
let inputFormat = audioFile.processingFormat
print("file: \(inputURL.lastPathComponent)")
print("format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")
print("duration: \(Double(audioFile.length) / inputFormat.sampleRate) s")

let analyzer = SNAudioStreamAnalyzer(format: inputFormat)
let request: SNClassifySoundRequest
do {
    request = try SNClassifySoundRequest(classifierIdentifier: .version1)
} catch {
    fputs("SNClassifySoundRequest failed: \(error)\n", stderr)
    exit(3)
}
// Match the production VoiceGate settings.
request.windowDuration = CMTime(seconds: 0.975, preferredTimescale: 48_000)
request.overlapFactor = 0.75

final class Observer: NSObject, SNResultsObserving {
    let topN: Int
    init(topN: Int) { self.topN = topN }
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        let t = CMTimeGetSeconds(r.timeRange.start)
        let dur = CMTimeGetSeconds(r.timeRange.duration)
        let entries = r.classifications.prefix(topN).map { c in
            String(format: "%@:%.2f", c.identifier, c.confidence)
        }.joined(separator: "  ")
        print(String(format: "t=%6.2fs (window %.2fs): %@", t, dur, entries))
    }
    func request(_ request: SNRequest, didFailWithError error: Error) {
        fputs("classifier error: \(error)\n", stderr)
    }
    func requestDidComplete(_ request: SNRequest) {
        print("--- complete ---")
    }
}

let observer = Observer(topN: topN)
do {
    try analyzer.add(request, withObserver: observer)
} catch {
    fputs("add request failed: \(error)\n", stderr)
    exit(4)
}

// Stream the file into the analyzer in 8192-frame chunks.
let bufferSize: AVAudioFrameCount = 8192
let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: bufferSize)!
var framePos: AVAudioFramePosition = 0
do {
    while audioFile.framePosition < audioFile.length {
        try audioFile.read(into: buffer)
        if buffer.frameLength == 0 { break }
        analyzer.analyze(buffer, atAudioFramePosition: framePos)
        framePos += AVAudioFramePosition(buffer.frameLength)
    }
} catch {
    fputs("read failed: \(error)\n", stderr)
    exit(5)
}
analyzer.completeAnalysis()

// Give async observers a moment to flush.
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
