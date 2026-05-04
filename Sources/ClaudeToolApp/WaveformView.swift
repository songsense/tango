import AppKit

@MainActor
final class WaveformView: NSView {
    var monitor: AudioMonitor?
    var voiceActive: Bool = false   // toggled by parent each redraw tick
    private var beatTimes: [Date] = []  // recent onsets
    private let beatFadeSeconds: TimeInterval = 0.6
    private let dbMinFloor: Float = -80
    private let dbMaxCeiling: Float = 0

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func registerBeat() {
        beatTimes.append(Date())
        if beatTimes.count > 32 { beatTimes.removeFirst(beatTimes.count - 32) }
        needsDisplay = true
    }

    func setNeedsRedrawSoon() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds

        // Background — turn red-tinted when voice is active so you instantly
        // see the gate is engaged.
        if voiceActive {
            ctx.setFillColor(NSColor(red: 0.18, green: 0.04, blue: 0.04, alpha: 1).cgColor)
        } else {
            ctx.setFillColor(NSColor(white: 0.06, alpha: 1).cgColor)
        }
        ctx.fill(bounds)

        if voiceActive {
            let banner = NSAttributedString(
                string: "🔇 VOICE DETECTED — gestures suppressed",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor(red: 1.0, green: 0.6, blue: 0.6, alpha: 0.95)
                ]
            )
            banner.draw(at: NSPoint(x: 12, y: bounds.height - 22))
        }

        guard let monitor else { return }
        let snap = monitor.snapshot()
        let samples = snap.samples
        let floor = snap.floorDb
        let n = samples.count
        guard n > 0 else { return }

        let barWidth = bounds.width / CGFloat(n)
        let barInset: CGFloat = max(0, barWidth - 1) > 0 ? 1.0 : 0
        let centerY = bounds.midY

        // Beat flash overlay (most recent beat dominates)
        let now = Date()
        if let mostRecent = beatTimes.last {
            let age = now.timeIntervalSince(mostRecent)
            if age < beatFadeSeconds {
                let alpha = CGFloat(1.0 - age / beatFadeSeconds)
                let flash = NSColor(red: 1.0, green: 0.55, blue: 0.0, alpha: alpha * 0.35)
                ctx.setFillColor(flash.cgColor)
                ctx.fill(bounds)
            }
        }

        // Threshold/floor reference line (yellow horizontal line at the noise floor)
        let floorY = mappedHeight(floor, bounds: bounds) + centerY - bounds.height/2
        ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(0.5)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0, y: centerY + (centerY - floorY)/2))
        ctx.addLine(to: CGPoint(x: bounds.width, y: centerY + (centerY - floorY)/2))
        ctx.strokePath()

        // Waveform bars: oldest on left, newest on right; bars grow from center.
        for i in 0..<n {
            let dbVal = samples[i]
            let h = mappedHeight(dbVal, bounds: bounds)
            let x = CGFloat(i) * barWidth
            let rect = CGRect(
                x: x,
                y: centerY - h/2,
                width: max(1, barWidth - barInset),
                height: max(1, h)
            )
            // Color gradient by recency: older = dim green, newest = bright cyan
            let recency = CGFloat(i) / CGFloat(n - 1)  // 0 = oldest, 1 = newest
            let color = NSColor(
                red: 0.10 + 0.10 * recency,
                green: 0.85,
                blue: 0.40 + 0.40 * recency,
                alpha: 0.55 + 0.45 * recency
            )
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
        }

        // Beat markers — vertical lines at the rightmost edge for each recent beat,
        // sliding left over time so they appear to flow with the waveform.
        let viewSpanSeconds: TimeInterval = 6.0
        for beat in beatTimes {
            let age = now.timeIntervalSince(beat)
            if age > viewSpanSeconds { continue }
            let t = 1.0 - age / viewSpanSeconds   // 1 = right edge, 0 = left edge
            let x = bounds.minX + bounds.width * CGFloat(t)
            let alpha = CGFloat(max(0, 1.0 - age / viewSpanSeconds))
            ctx.setStrokeColor(NSColor(red: 1, green: 0.6, blue: 0.1, alpha: alpha).cgColor)
            ctx.setLineWidth(2)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: bounds.height))
            ctx.strokePath()
        }
    }

    /// Map a dB value to a height in pixels (0..bounds.height).
    private func mappedHeight(_ db: Float, bounds: NSRect) -> CGFloat {
        let clamped = max(dbMinFloor, min(dbMaxCeiling, db))
        let norm = (clamped - dbMinFloor) / (dbMaxCeiling - dbMinFloor)  // 0..1
        return CGFloat(norm) * bounds.height
    }
}
