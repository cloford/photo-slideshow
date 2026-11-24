import IOKit.pwr_mgt
import OSLog

@MainActor
final class DisplaySleep {
    private var assertion: IOPMAssertionID?

    var isHeld: Bool { assertion != nil }

    func prevent(reason: String = "test") -> Bool {
        if assertion != nil { return true }
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithDescription(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            "PhotoSlideshow: playback session" as CFString, nil, nil, nil, 0, nil, &id)
        guard status == kIOReturnSuccess else {
            appLog.error("Display sleep assertion failed (\(status)).")
            return false
        }
        appLog.notice("Display assertion acquired id=\(id) reason=\(reason, privacy: .public)")
        assertion = id
        return true
    }

    func release(reason: String = "test") {
        guard let assertion else { return }
        let status = IOPMAssertionRelease(assertion)
        if status == kIOReturnSuccess {
            self.assertion = nil
            appLog.notice("Display assertion released id=\(assertion) reason=\(reason, privacy: .public)")
        } else {
            appLog.error("Display sleep assertion release failed (\(status)).")
        }
    }
}
