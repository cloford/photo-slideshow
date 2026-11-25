import AppKit

final class ClockOverlay: NSView {
    var style = PlaybackPreferences.ClockStyle.digital
    private var ticker: Task<Void, Never>?
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(style: PlaybackPreferences.ClockStyle, visible: Bool) {
        self.style = style
        isHidden = !visible
        ticker?.cancel()
        ticker = nil
        guard visible else { return }
        needsDisplay = true
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let scale = bounds.width / 156
        guard scale > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = AffineTransform(scaleByX: scale, byY: scale)
        (transform as NSAffineTransform).concat()
        let bounds = CGRect(x: 0, y: 0, width: 156, height: 84)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        let now = Date()
        if style == .digital {
            let text = NSAttributedString(string: formatter.string(from: now), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 33, weight: .semibold), .foregroundColor: NSColor.white
            ])
            text.draw(at: CGPoint(x: bounds.midX - text.size().width / 2, y: bounds.midY - text.size().height / 2))
            return
        }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - 8
        func hand(_ angle: Double, start: CGFloat, end: CGFloat, width: CGFloat, color: NSColor) {
            let x = sin(angle)
            let y = cos(angle)
            let line = NSBezierPath()
            line.lineWidth = width
            line.lineCapStyle = .round
            line.move(to: CGPoint(x: center.x + x * start, y: center.y + y * start))
            line.line(to: CGPoint(x: center.x + x * end, y: center.y + y * end))
            color.setStroke()
            line.stroke()
        }
        for tick in 0..<12 {
            hand(Double(tick) * .pi / 6, start: radius - 4, end: radius, width: 1.8, color: .white)
        }
        let time = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        let minute = Double(time.minute ?? 0)
        hand(Double((time.hour ?? 0) % 12) * .pi / 6 + minute * .pi / 360,
             start: 0, end: radius * 0.52, width: 4, color: .white)
        hand(minute * .pi / 30, start: 0, end: radius * 0.76, width: 3, color: .white)
        hand(Double(time.second ?? 0) * .pi / 30, start: 0, end: radius * 0.83, width: 1.4, color: .systemOrange)
    }
}
