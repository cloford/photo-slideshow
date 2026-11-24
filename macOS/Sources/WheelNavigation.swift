import Foundation

struct WheelNavigation {
    private var lastSample: TimeInterval?
    private var lastStep: TimeInterval?
    private var lastDirection = 0
    private var accumulated = 0.0
    private var steppedInGesture = false

    static func verticalDelta(scrolling: Double, lines: Int64, precise: Bool, inverted: Bool) -> Double {
        // A light wheel notch can carry a whole line plus a much smaller accelerated delta.
        let delta = !precise && lines != 0 ? Double(lines) : scrolling
        return inverted ? -delta : delta
    }

    mutating func resetGesture() {
        accumulated = 0
        steppedInGesture = false
        lastSample = nil
    }

    mutating func step(delta: Double, time: TimeInterval, precise: Bool, phased: Bool) -> Int? {
        guard delta.isFinite, delta != 0 else { return nil }
        let direction = delta < 0 ? 1 : -1
        if lastSample.map({ time - $0 > 0.18 }) ?? true || lastDirection != direction {
            accumulated = 0
            steppedInGesture = false
        }
        lastSample = time
        lastDirection = direction
        let threshold = precise ? (phased && steppedInGesture ? 3.0 : 0.75) : 0.25
        accumulated = min(threshold, accumulated + abs(delta))
        guard accumulated >= threshold else { return nil }

        // One transition per pulse. Drop dense bursts without blocking the next notch.
        let minimumGap = precise ? (phased ? 0.11 : 0.07) : 0.04
        if let lastStep, time - lastStep < minimumGap {
            accumulated = 0
            return nil
        }
        accumulated = 0
        steppedInGesture = true
        lastStep = time
        return direction
    }
}
