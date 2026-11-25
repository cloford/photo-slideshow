import AppKit

enum OverlayItem: String, CaseIterable, Codable, Sendable {
    case clock, heart, bar

    var title: String {
        switch self {
        case .clock: "時計"
        case .heart: "お気に入り"
        case .bar: "操作バー"
        }
    }
}

struct OverlayPosition: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

struct OverlayPlacement: Codable, Equatable, Sendable {
    var position: OverlayPosition?
    var scale: Double = 1
    var usePresetPosition: Bool?
    var custom: Bool { position != nil && usePresetPosition != true }
}

struct OverlayFrames {
    let safe: CGRect
    var settings: PlaybackPreferences

    func baseSize(_ item: OverlayItem) -> CGSize {
        let size: CGSize
        switch item {
        case .clock: size = CGSize(width: 156, height: 84)
        case .heart: size = CGSize(width: 64, height: 64)
        case .bar: size = CGSize(width: 828, height: 90)
        }
        let fit = min(1, safe.width / 1050, safe.height / 600)
        return CGSize(width: size.width * fit, height: size.height * fit)
    }

    func limits(_ item: OverlayItem) -> ClosedRange<CGFloat> {
        let size = baseSize(item)
        return 0.55...max(0.55, min(2, safe.width / size.width, safe.height / size.height))
    }

    func clamped(_ frame: CGRect) -> CGRect {
        CGRect(x: min(max(safe.minX, frame.minX), safe.maxX - frame.width),
               y: min(max(safe.minY, frame.minY), safe.maxY - frame.height),
               width: frame.width, height: frame.height)
    }

    func frame(_ item: OverlayItem) -> CGRect {
        let base = baseSize(item)
        let placement = settings.placement(item)
        let scale = min(limits(item).upperBound, max(limits(item).lowerBound, placement.scale))
        let width = base.width * scale
        let height = base.height * scale
        if placement.custom, let position = placement.position {
            return CGRect(x: safe.minX + (safe.width - width) * min(1, max(0, position.x)),
                          y: safe.maxY - height - (safe.height - height) * min(1, max(0, position.y)),
                          width: width, height: height)
        }
        let sideMargin = 24 * min(1, safe.height / 600, safe.width / 1050)
        let x: CGFloat
        if item == .bar { x = safe.midX - width / 2 }
        else {
            let left = item == .clock ? settings.clockSide == .left : settings.noticeSide == .left
            x = left ? safe.minX + sideMargin : safe.maxX - sideMargin - width
        }
        let margin = item == .bar ? 56 * base.height / 90 : sideMargin
        let y = item == .bar && settings.barEdge == .bottom ? safe.minY + margin : safe.maxY - margin - height
        return clamped(CGRect(x: x, y: y, width: width, height: height))
    }

    func placement(for frame: CGRect, scale: CGFloat) -> OverlayPlacement {
        let frame = clamped(frame)
        let x = safe.width > frame.width ? (frame.minX - safe.minX) / (safe.width - frame.width) : 0
        let y = safe.height > frame.height ? (safe.maxY - frame.maxY) / (safe.height - frame.height) : 0
        return OverlayPlacement(position: OverlayPosition(x: x, y: y), scale: scale)
    }

    private func avoid(_ obstacle: CGRect, with frame: CGRect) -> CGRect {
        let margin: CGFloat = 10
        guard frame.intersects(obstacle.insetBy(dx: -margin, dy: -margin)) else { return frame }
        let alternatives = [
            CGRect(origin: CGPoint(x: frame.minX, y: obstacle.minY - frame.height - margin), size: frame.size),
            CGRect(origin: CGPoint(x: frame.minX, y: obstacle.maxY + margin), size: frame.size),
            CGRect(origin: CGPoint(x: obstacle.minX - frame.width - margin, y: frame.minY), size: frame.size),
            CGRect(origin: CGPoint(x: obstacle.maxX + margin, y: frame.minY), size: frame.size)
        ]
        return alternatives.filter { safe.contains($0) }.min {
            hypot($0.minX - frame.minX, $0.minY - frame.minY) < hypot($1.minX - frame.minX, $1.minY - frame.minY)
        } ?? frame
    }

    func overlays(editing: Bool) -> [OverlayItem: CGRect] {
        let bar = frame(.bar)
        let wantedClock = frame(.clock)
        let wantedHeart = frame(.heart)
        if editing { return [.bar: bar, .clock: wantedClock, .heart: wantedHeart] }
        var clock = avoid(bar, with: wantedClock)
        var heart = avoid(bar, with: wantedHeart)
        if settings.clockVisible &&
            (heart.intersects(clock.insetBy(dx: -10, dy: -10)) ||
             wantedHeart.intersects(wantedClock.insetBy(dx: -10, dy: -10))) {
            let stackedY = clock.minY - heart.height - 10
            let shift = max(0, safe.minY - stackedY)
            clock.origin.y += shift
            heart.origin.y = stackedY + shift
            let group = clock.union(heart)
            let moved = avoid(bar, with: group)
            clock = clock.offsetBy(dx: moved.minX - group.minX, dy: moved.minY - group.minY)
            heart = heart.offsetBy(dx: moved.minX - group.minX, dy: moved.minY - group.minY)
        }
        return [.bar: bar, .clock: clock, .heart: heart]
    }

    func pictureArea(aspect: CGFloat) -> CGRect {
        guard settings.reserveBarSpace else { return safe }
        let bar = frame(.bar).insetBy(dx: -12, dy: -12).intersection(safe)
        let alternatives = [
            CGRect(x: safe.minX, y: bar.maxY, width: safe.width, height: safe.maxY - bar.maxY),
            CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: bar.minY - safe.minY),
            CGRect(x: safe.minX, y: safe.minY, width: bar.minX - safe.minX, height: safe.height),
            CGRect(x: bar.maxX, y: safe.minY, width: safe.maxX - bar.maxX, height: safe.height)
        ]
        return alternatives.max {
            min($0.width / aspect, $0.height) < min($1.width / aspect, $1.height)
        } ?? safe
    }
}
