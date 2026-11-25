import AppKit

final class LayoutEditor: NSView {
    let finish = ActionButton("設定に戻る")
    var changed: ((PlaybackPreferences) -> Void)?
    var safe = CGRect.zero {
        didSet {
            if oldValue != safe { needsLayout = true; needsDisplay = true }
        }
    }
    private(set) var options: PlaybackPreferences
    private let itemPicker = NSSegmentedControl(labels: OverlayItem.allCases.map(\.title),
                                                trackingMode: .selectOne, target: nil, action: nil)
    private let footer = NSStackView()
    private struct Drag {
        let item: OverlayItem
        let point: CGPoint
        let frame: CGRect
        let corner: CGPoint?
    }
    private var drag: Drag?
    private var selected: OverlayItem { OverlayItem.allCases[max(0, itemPicker.selectedSegment)] }
    private var geometry: OverlayFrames { OverlayFrames(safe: safe, settings: options) }

    init(_ options: PlaybackPreferences) {
        self.options = options
        super.init(frame: .zero)
        let resetPosition = ActionButton("位置を戻す")
        let resetSize = ActionButton("サイズを戻す")
        let resetAll = ActionButton("すべて初期値に戻す")
        resetPosition.perform = { [weak self] in self?.reset(position: true, size: false) }
        resetSize.perform = { [weak self] in self?.reset(position: false, size: true) }
        resetAll.perform = { [weak self] in self?.reset(position: true, size: true, all: true) }
        itemPicker.selectedSegment = 0
        itemPicker.target = self
        itemPicker.action = #selector(picked)
        itemPicker.setAccessibilityLabel("配置を編集する要素")
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.97).cgColor
        footer.layer?.cornerRadius = 9
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        for view in [itemPicker, resetPosition, resetSize, resetAll, finish] {
            footer.addArrangedSubview(view)
        }
        addSubview(footer)
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityLabel("配置を編集")
    }

    required init?(coder: NSCoder) { nil }

    @objc private func picked() { needsLayout = true; needsDisplay = true }

    private func publish() {
        needsLayout = true
        needsDisplay = true
        changed?(options)
    }

    private func reset(position: Bool, size: Bool, all: Bool = false) {
        for item in all ? OverlayItem.allCases : [selected] {
            if position { options.resetPosition(item) }
            if size {
                var placement = options.placement(item)
                placement.scale = 1
                options.setPlacement(placement, for: item)
            }
        }
        publish()
    }

    override func layout() {
        super.layout()
        let size = footer.fittingSize
        // Keep the controls away from the element being edited as it approaches the lower strip.
        let bottom = CGRect(x: safe.midX - size.width / 2, y: safe.minY + 6, width: size.width, height: size.height)
        let top = bottom.offsetBy(dx: 0, dy: safe.maxY - 6 - bottom.maxY)
        footer.frame = (drag?.frame ?? geometry.frame(selected)).intersects(bottom) ? top : bottom
    }

    private func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY),
         CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for item in [selected] + OverlayItem.allCases.filter({ $0 != selected }) {
            let frame = geometry.frame(item)
            let corner = corners(frame).first { hypot(point.x - $0.x, point.y - $0.y) <= 10 }
            if corner != nil || frame.contains(point) {
                itemPicker.selectedSegment = OverlayItem.allCases.firstIndex(of: item) ?? 0
                drag = Drag(item: item, point: point, frame: frame, corner: corner)
                needsDisplay = true
                return
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - drag.point.x
        let dy = point.y - drag.point.y
        let base = geometry.baseSize(drag.item)
        var scale = options.placement(drag.item).scale
        var result = drag.frame.offsetBy(dx: dx, dy: dy)
        if let corner = drag.corner {
            let sx: CGFloat = corner.x == drag.frame.minX ? -1 : 1
            let sy: CGFloat = corner.y == drag.frame.minY ? -1 : 1
            let anchor = CGPoint(x: corner.x - sx * drag.frame.width, y: corner.y - sy * drag.frame.height)
            let limits = geometry.limits(drag.item)
            let projected = (dx * sx * base.width + dy * sy * base.height) /
                (base.width * base.width + base.height * base.height)
            let roomX = (sx < 0 ? anchor.x - safe.minX : safe.maxX - anchor.x) / base.width
            let roomY = (sy < 0 ? anchor.y - safe.minY : safe.maxY - anchor.y) / base.height
            scale = max(limits.lowerBound, min(limits.upperBound, roomX, roomY, drag.frame.width / base.width + projected))
            let size = CGSize(width: base.width * scale, height: base.height * scale)
            result = CGRect(x: anchor.x - (sx < 0 ? size.width : 0), y: anchor.y - (sy < 0 ? size.height : 0),
                            width: size.width, height: size.height)
        }
        options.setPlacement(geometry.placement(for: result, scale: scale), for: drag.item)
        publish()
    }

    override func mouseUp(with event: NSEvent) { drag = nil; needsLayout = true; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        for item in OverlayItem.allCases {
            let frame = geometry.frame(item)
            (item == selected ? NSColor.systemTeal : NSColor.white.withAlphaComponent(0.8)).setStroke()
            let outline = NSBezierPath(rect: frame)
            outline.lineWidth = 2
            outline.stroke()
            for point in corners(frame) {
                NSColor.black.setFill()
                CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10).fill()
                NSBezierPath(rect: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)).stroke()
            }
        }
        guard drag != nil else { return }
        NSColor.systemTeal.withAlphaComponent(0.75).setStroke()
        let frame = geometry.frame(selected)
        for x in [safe.minX + 1, safe.midX, safe.maxX - 1]
            where [frame.minX, frame.midX, frame.maxX].contains(where: { abs($0 - x) < 14 }) {
            NSBezierPath.strokeLine(from: CGPoint(x: x, y: safe.minY), to: CGPoint(x: x, y: safe.maxY))
        }
        for y in [safe.minY + 1, safe.midY, safe.maxY - 1]
            where [frame.minY, frame.midY, frame.maxY].contains(where: { abs($0 - y) < 14 }) {
            NSBezierPath.strokeLine(from: CGPoint(x: safe.minX, y: y), to: CGPoint(x: safe.maxX, y: y))
        }
    }
}
