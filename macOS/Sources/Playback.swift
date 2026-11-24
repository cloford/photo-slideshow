import AppKit
import OSLog

@MainActor
final class Playback {
    private enum Origin { case initial, manual, automatic, jump }
    private struct Search {
        var index: Int
        let direction: Int
        var remaining: Int
        let origin: Origin
        var cloudIssue = false
    }
    private struct Frame {
        let index: Int
        let image: LoadedImage
    }
    private struct ImageRequest {
        let token: UUID
        let index: Int
        let cancel: () -> Void
    }

    let photos: [Photo]
    private let library: any PhotoSource
    private let view: SlideshowView
    private var target: CGSize
    private var visible = false
    private(set) var paused = false
    private var panelOpen = false
    var seconds = 5
    var displayedIndex: Int? { displayed?.index }
    private(set) var displayedRevision: UUID?
    var onJumpFailure: (() -> Void)?
    private var powerWarning = false
    private var active = true
    private var displayed: Frame?
    private var search: Search?
    private var staged: (token: UUID, frame: Frame)?
    private var request: ImageRequest?
    private var refreshing = false
    private var timer: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    var onDisplay: ((String) -> Void)?
    var onFailure: ((Bool) -> Void)?

    init(photos: [Photo], library: any PhotoSource, view: SlideshowView, target: CGSize) {
        self.photos = photos
        self.library = library
        self.view = view
        self.target = target
        view.didDraw = { [weak self] token in self?.confirmDraw(token) }
    }

    func start(after savedID: String?) {
        let index = savedID.flatMap { id in photos.firstIndex { $0.id == id } }
            .map { wrapped($0 + 1) } ?? 0
        startSearch(at: index, direction: 1, origin: .initial)
    }

    func setVisible(_ visible: Bool) {
        guard active, self.visible != visible else { return }
        self.visible = visible
        if visible {
            if search != nil { tryCandidate() }
            else { scheduleNext() }
        } else {
            invalidateTimer()
            discardRequest()
            discardStage()
            if displayed != nil, search?.origin == .automatic { search = nil }
            updateStatus()
        }
    }

    func setTarget(_ size: CGSize) {
        guard size != target else { return }
        target = size
        discardRequest()
        discardStage()
        guard active, visible else { return }
        if search != nil {
            tryCandidate()
        } else if let displayed {
            refreshing = true
            beginForegroundRequest(displayed.index)
        }
    }

    func setPowerWarning(_ warning: Bool) {
        guard powerWarning != warning else { return }
        powerWarning = warning
        updateStatus()
    }

    func togglePause() {
        guard active else { return }
        paused.toggle()
        updateTiming()
        #if SLIDESHOW_QA
        qaTrace("pause \(paused)")
        #endif
    }

    func setPanelOpen(_ open: Bool) {
        guard panelOpen != open else { return }
        panelOpen = open
        updateTiming()
    }

    private func updateTiming() {
        if paused || panelOpen {
            invalidateTimer()
            if displayed != nil, search?.origin == .automatic {
                discardRequest()
                discardStage()
                search = nil
                updateStatus()
            }
        } else if search == nil {
            scheduleNext()
        }
    }

    func jump(to index: Int) {
        guard active, photos.indices.contains(index) else { return }
        startSearch(at: index, direction: 1, origin: .jump)
    }

    func move(_ direction: Int) {
        guard active else { return }
        let startingAt = search?.index ?? displayed?.index
        guard let startingAt, photos.count > 1 else { return }
        startSearch(at: wrapped(startingAt + direction), direction: direction, origin: .manual)
    }

    func stop() {
        active = false
        search = nil
        invalidateTimer()
        discardRequest()
        displayed = nil
        staged = nil
        view.didDraw = nil
        displayedRevision = nil
        view.show(nil)
    }

    private func wrapped(_ index: Int) -> Int { (index + photos.count) % photos.count }

    private func startSearch(at index: Int, direction: Int, origin: Origin) {
        invalidateTimer()
        if request?.index != index || refreshing { discardRequest() }
        discardStage()
        search = Search(index: index, direction: direction, remaining: origin == .jump ? 1 : photos.count, origin: origin)
        updateStatus()
        if visible { tryCandidate() }
    }

    private func tryCandidate() {
        guard active, visible, let candidate = search else { return }
        if displayed?.index == candidate.index {
            discardRequest()
            search = nil
            updateStatus()
            scheduleNext()
        } else if request?.index != candidate.index || refreshing {
            discardRequest()
            beginForegroundRequest(candidate.index)
        }
    }

    @discardableResult
    private func skipCandidate(cloudIssue: Bool) -> Bool {
        guard var candidate = search else { return false }
        candidate.remaining -= 1
        candidate.cloudIssue = candidate.cloudIssue || cloudIssue
        #if SLIDESHOW_QA
        qaTrace("skip \(photos[candidate.index].id)")
        #endif
        guard candidate.remaining > 0 else {
            search = nil
            if candidate.origin == .jump, displayed != nil {
                updateStatus()
                scheduleNext()
                onJumpFailure?()
            } else {
                onFailure?(candidate.cloudIssue)
            }
            return false
        }
        candidate.index = wrapped(candidate.index + candidate.direction)
        search = candidate
        return true
    }

    private func beginForegroundRequest(_ index: Int) {
        let token = UUID()
        let cancel = library.requestImage(for: photos[index], size: target) { [weak self] result in
            self?.receive(result, index: index, token: token)
        }
        request = ImageRequest(token: token, index: index, cancel: cancel)
        armTimeout()
    }

    private func receive(_ result: ImageResult, index: Int, token: UUID) {
        guard active, request?.token == token else { return }
        let wasRefreshing = refreshing
        finishForeground()
        switch result {
        case .image(let image):
            let frame = Frame(index: index, image: image)
            if wasRefreshing, visible, displayed?.index == index {
                displayed = frame
                view.show(image)
            } else if search?.index == index, visible {
                stage(frame)
            }
        case .unavailable(let cloud):
            if !wasRefreshing, skipCandidate(cloudIssue: cloud) { tryCandidate() }
        }
    }

    private func finishForeground() {
        timeout?.cancel()
        timeout = nil
        request = nil
        refreshing = false
    }

    private func armTimeout() {
        guard timeout == nil, let token = request?.token else { return }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, active, request?.token == token else { return }
            let wasRefreshing = refreshing
            discardRequest()
            if !wasRefreshing, skipCandidate(cloudIssue: true) { tryCandidate() }
        }
    }

    private func stage(_ frame: Frame) {
        let token = UUID()
        staged = (token, frame)
        view.resetZoom()
        view.show(frame.image, sequence: token)
    }

    private func confirmDraw(_ token: UUID) {
        guard active, visible, let staged, staged.token == token,
              let window = view.window, window.isVisible, window.occlusionState.contains(.visible) else { return }
        displayed = staged.frame
        displayedRevision = token
        self.staged = nil
        search = nil
        let id = photos[staged.frame.index].id
        #if SLIDESHOW_QA
        qaTrace("draw \(id)")
        #endif
        onDisplay?(id)
        scheduleNext()
        // Avoid invalidating views while AppKit is inside draw(_:).
        Task { @MainActor [weak self] in self?.updateStatus() }
    }

    private func scheduleNext() {
        invalidateTimer()
        guard active, visible, let displayed, photos.count > 1 else { return }
        guard !paused, !panelOpen else { return }
        let deadline = ContinuousClock.now + .seconds(seconds)
        timer = Task { [weak self] in
            do { try await Task.sleep(until: deadline) } catch { return }
            guard let self, active, visible, !paused, !panelOpen else { return }
            startSearch(at: wrapped(displayed.index + 1), direction: 1, origin: .automatic)
        }
    }

    private func invalidateTimer() {
        timer?.cancel()
        timer = nil
    }

    private func discardRequest() {
        let previous = request
        finishForeground()
        previous?.cancel()
    }

    private func discardStage() {
        guard staged != nil else { return }
        staged = nil
        view.show(displayed?.image)
    }

    private func updateStatus() {
        if active { view.showStatus(loading: search != nil, powerWarning: powerWarning) }
    }
}
