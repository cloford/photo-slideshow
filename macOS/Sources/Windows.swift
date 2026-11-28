import AppKit

let returnTitle = "元の画面に戻る"

final class ReturnButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum WindowKey {
    case escape, pause, previous, next
}

final class SlideshowWindow: NSWindow {
    var handleKey: ((WindowKey, Bool) -> Bool)?
    var returnButton: NSButton?
    var handleWheel: ((NSEvent) -> Bool)?
    var handleLeftClick: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, handleWheel?(event) == true { return }
        if event.type == .leftMouseDown || event.type == .leftMouseUp { handleLeftClick?(event) }
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            let key: WindowKey?
            switch event.keyCode {
            case 53: key = .escape
            case 49: key = .pause
            case 123: key = .previous
            case 124: key = .next
            default: key = nil
            }
            if let key, handleKey?(key, event.isARepeat) == true { return }
            if !event.isARepeat, (event.keyCode == 36 || event.keyCode == 76),
               let returnButton, firstResponder === returnButton {
                returnButton.performClick(nil)
                return
            }
        }
        super.sendEvent(event)
    }
}

@MainActor
final class AlbumPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView()
    let heading = NSTextField(labelWithString: "")
    let table = NSTableView()
    let playButton = NSButton(title: "再生", target: nil, action: nil)
    let returnButton = ReturnButton(title: returnTitle, target: nil, action: nil)
    private let scroll = NSScrollView()
    private let column = NSTableColumn(identifier: .init("album"))
    private var albums: [Album] = []
    private var labels: [String] = []
    var choose: ((Album) -> Void)?

    override init() {
        super.init()
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.maximumNumberOfLines = 0
        heading.lineBreakMode = .byWordWrapping
        heading.cell?.wraps = true
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        table.addTableColumn(column)
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 26
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(selectAlbum(_:))
        table.setAccessibilityLabel("アルバム一覧")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        playButton.target = self
        playButton.action = #selector(selectAlbum(_:))
        playButton.bezelStyle = .rounded
        playButton.keyEquivalent = "\r"
        returnButton.bezelStyle = .rounded
        returnButton.setAccessibilityLabel(returnTitle)

        let buttons = NSStackView(views: [returnButton, playButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        for child in [heading, scroll, buttons] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),
            buttons.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 36)
        ])
    }

    func show(_ albums: [Album], message: String?) {
        self.albums = albums
        labels = Album.labels(for: albums)
        heading.stringValue = message.map { "\($0)\nアルバムを選んでください。" } ?? "アルバムを選んでください。"
        table.deselectAll(nil)
        playButton.isEnabled = false
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { albums.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: labels[row])
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = labels[row]
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        playButton.isEnabled = albums.indices.contains(table.selectedRow)
    }

    @objc private func selectAlbum(_ sender: Any?) {
        let index = table.selectedRow
        guard albums.indices.contains(index) else { return }
        if sender as? NSTableView === table, table.clickedRow != index { return }
        choose?(albums[index])
    }
}

final class SlideshowView: NSView {
    let returnButton = ReturnButton(title: returnTitle, target: nil, action: nil)
    let previousButton = ActionButton("前へ")
    let pauseButton = ActionButton("一時停止")
    let nextButton = ActionButton("次へ")
    let listButton = ActionButton("写真一覧")
    let settingsButton = ActionButton("設定")
    private let bar = NSView()
    private let sectionDivider = NSView()
    private let returnDivider = NSView()
    let favoriteStatus = ActionButton("お気に入りに登録")
    private let fallingStar = PassiveImageView()
    private var fallTask: Task<Void, Never>?
    private let bouncingHeart = PassiveImageView()
    private var bounceTask: Task<Void, Never>?
    private var bouncingRevision: UUID?
    private var favoriteRevision: UUID?
    private var fallingRevision: UUID?
    private var photoIsFavorite = false
    private var iconSize: CGFloat = 32
    private static let pink = NSColor(srgbRed: 1, green: 0.36, blue: 0.62, alpha: 1)
    private static let outline = NSColor(srgbRed: 0.62, green: 0.65, blue: 0.70, alpha: 1)
    private static let iconColor = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
    private let permanentHeart = FavoriteIndicator()
    private let favoriteIndicator = FavoriteIndicator()
    #if SLIDESHOW_QA
    private var lastLayoutTrace = ""
    #endif
    private var confirmationRevision: UUID?
    private var editingLayout: Bool { panel is LayoutEditor }
    private var geometry: OverlayFrames { OverlayFrames(safe: safeRect, settings: settings) }
    private var indicatorTask: Task<Void, Never>?
    private var firstClickRevision: UUID?
    private var pressedRevision: UUID?
    private var zoomScale: CGFloat = 1
    private var zoomOffset = CGPoint.zero
    private var settings = PlaybackPreferences()
    private let clock = ClockOverlay(frame: .zero)
    var displayedRevision: (() -> UUID?)?
    var addFavorite: (() -> Void)?
    private let notice = NSTextField(wrappingLabelWithString: "")
    private var tracking: NSTrackingArea?
    private var hideTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private(set) var panel: NSView?
    private var forceControls = false
    private var insets = NSEdgeInsets()
    private var photo: LoadedImage?
    private var sequence: UUID?
    private var loading = false
    private var message: String?
    private var powerWarning = false
    var didDraw: ((UUID) -> Void)?

    init() {
        super.init(frame: .zero)
        configureIcon(previousButton, symbol: "chevron.left", name: "前へ")
        configureIcon(pauseButton, symbol: "pause.fill", name: "一時停止")
        configureIcon(nextButton, symbol: "chevron.right", name: "次へ")
        configureIcon(listButton, symbol: "square.grid.2x2", name: "写真一覧")
        configureIcon(settingsButton, symbol: "gearshape", name: "設定")
        configureIcon(returnButton, symbol: "arrow.uturn.backward", name: returnTitle)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.105, blue: 0.118, alpha: 1).cgColor
        bar.layer?.borderColor = NSColor(srgbRed: 0.25, green: 0.25, blue: 0.27, alpha: 1).cgColor
        bar.layer?.borderWidth = 1
        for divider in [sectionDivider, returnDivider] {
            divider.wantsLayer = true
            divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        }
        for item in [previousButton, pauseButton, nextButton, listButton, favoriteStatus,
                     settingsButton, returnButton, sectionDivider, returnDivider] {
            bar.addSubview(item)
        }
        favoriteStatus.singleClickOnly = true
        favoriteStatus.setAccessibilityElement(true)
        favoriteStatus.setAccessibilityRole(.button)
        configureIcon(favoriteStatus, symbol: "heart", name: "お気に入りに登録")
        addSubview(bar)
        clock.isHidden = true
        addSubview(clock)
        fallingStar.wantsLayer = true
        fallingStar.isHidden = true
        addSubview(fallingStar)
        bouncingHeart.wantsLayer = true
        bouncingHeart.isHidden = true
        addSubview(bouncingHeart)
        renderFavoriteStatus()
        notice.alignment = .center
        notice.textColor = .white
        notice.drawsBackground = true
        notice.backgroundColor = NSColor.black.withAlphaComponent(0.9)
        notice.isHidden = true
        addSubview(notice)
        permanentHeart.wantsLayer = true
        permanentHeart.isHidden = true
        addSubview(permanentHeart)
        favoriteIndicator.wantsLayer = true
        favoriteIndicator.isHidden = true
        addSubview(favoriteIndicator)
        updateControls(paused: false, ready: false)
        bar.isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { true }

    func useInsets(_ insets: NSEdgeInsets) {
        self.insets = insets
        needsLayout = true
        needsDisplay = true
    }

    func show(_ photo: LoadedImage?, sequence: UUID? = nil) {
        self.photo = photo
        if photo == nil {
            firstClickRevision = nil
            pressedRevision = nil
            resetZoom()
        }
        self.sequence = sequence
        needsDisplay = true
    }

    func applyPreferences(_ value: PlaybackPreferences) {
        let oldArea = pictureArea
        let clockChanged = settings.clockStyle != value.clockStyle || settings.clockVisible != value.clockVisible
        let visible = value.clockVisible || editingLayout
        let visibilityChanged = clock.isHidden == visible
        settings = value
        if clockChanged || visibilityChanged {
            clock.configure(style: value.clockStyle, visible: visible)
        }
        refreshPermanentHeart()
        if oldArea != pictureArea { resetZoom() }
        needsLayout = true
        needsDisplay = true
    }

    func resetZoom() {
        zoomScale = 1
        zoomOffset = .zero
        needsDisplay = true
    }

    func showStatus(loading: Bool, message: String? = nil, powerWarning: Bool = false) {
        self.loading = loading
        self.message = message
        self.powerWarning = powerWarning
        let force = message != nil
        if force != forceControls {
            forceControls = force
            refreshBar()
        }
        needsDisplay = true
    }

    private var safeRect: CGRect {
        CGRect(x: insets.left, y: insets.bottom,
               width: max(1, bounds.width - insets.left - insets.right),
               height: max(1, bounds.height - insets.top - insets.bottom))
    }

    override func layout() {
        super.layout()
        let safe = safeRect
        let frames = geometry.overlays(editing: editingLayout)
        bar.frame = frames[.bar] ?? .zero
        let width = bar.frame.width
        let height = bar.frame.height
        let scale = width / 828
        bar.layer?.cornerRadius = 20 * scale
        let icons = [previousButton, pauseButton, nextButton, listButton, favoriteStatus, settingsButton, returnButton]
        for (item, center) in zip(icons, [48.0, 130.0, 213.0, 309.0, 460.0, 610.0, 761.0]) {
            let size = (item === favoriteStatus ? 38.0 : 68.0) * scale
            item.frame = CGRect(x: center * scale - size / 2, y: (height - size) / 2, width: size, height: size)
        }
        for (divider, x) in zip([sectionDivider, returnDivider], [265.0, 703.0]) {
            divider.frame = CGRect(x: x * scale, y: 24 * scale, width: 1, height: 42 * scale)
        }
        if iconSize != 32 * scale {
            iconSize = 32 * scale
            for (button, symbol) in [(previousButton, "chevron.left"), (nextButton, "chevron.right"),
                                     (listButton, "square.grid.2x2"), (settingsButton, "gearshape"),
                                     (returnButton, "arrow.uturn.backward")] {
                button.image = symbolImage(symbol)
            }
            pauseButton.image = symbolImage(pauseButton.toolTip == "再開" ? "play.fill" : "pause.fill")
            renderFavoriteStatus()
        }
        notice.frame = CGRect(x: safe.midX - width / 2, y: safe.maxY - 58, width: width, height: 38)
        clock.frame = frames[.clock] ?? .zero
        clock.needsDisplay = true
        let indicator = frames[.heart] ?? .zero
        permanentHeart.frame = indicator
        favoriteIndicator.frame = indicator
        permanentHeart.needsDisplay = true
        favoriteIndicator.needsDisplay = true
        #if SLIDESHOW_QA
        func coordinates(_ frame: CGRect) -> String {
            [frame.minX, bounds.height - frame.maxY, frame.width, frame.height].map { String(format: "%.2f", $0) }
                .joined(separator: ",")
        }
        let encoded = [editingLayout ? "edit" : "play", clock.isHidden ? "off" : "on",
                       coordinates(clock.frame), coordinates(indicator), coordinates(bar.frame), coordinates(pictureArea)]
            .joined(separator: " ")
        if encoded != lastLayoutTrace {
            lastLayoutTrace = encoded
            qaTrace("overlays " + encoded)
        }
        #endif
        refreshBar()
        if let editor = panel as? LayoutEditor {
            editor.frame = bounds
            editor.safe = safe
        } else if let panel {
            let size = panel is PreferencesPanel ? CGSize(width: 730, height: min(705, safe.height - 32)) :
                CGSize(width: 660, height: max(1, min(620, safe.height - 70)))
            let width = min(size.width, safe.width - 30)
            panel.frame = CGRect(x: safe.midX - width / 2, y: safe.midY - size.height / 2,
                                 width: width, height: size.height)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.inVisibleRect, .activeAlways, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { refreshBar(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { refreshBar() }
    override func mouseExited(with event: NSEvent) { refreshBar() }

    func handlePhotoClick(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let activeSurface = panel == nil && bounds.contains(point) && (bar.isHidden || !bar.frame.contains(point))
        let revision = activeSurface ? displayedRevision?() : nil
        if event.type == .leftMouseDown {
            pressedRevision = revision
            if revision == nil { firstClickRevision = nil }
            return
        }
        defer { pressedRevision = nil }
        guard let revision, pressedRevision == revision else {
            firstClickRevision = nil
            return
        }
        if event.clickCount == 1 {
            firstClickRevision = revision
        } else {
            if event.clickCount == 2, firstClickRevision == revision { addFavorite?() }
            firstClickRevision = nil
        }
    }

    func zoom(for event: NSEvent, delta: CGFloat) -> Bool {
        firstClickRevision = nil
        defer { pressedRevision = nil }
        // Once zooming, the button remains held even though this click cannot become a favorite gesture.
        guard delta.isFinite, delta != 0, displayedRevision?() != nil, let photo else { return false }
        let oldRect = imageRect(for: photo.image.size)
        let point = convert(event.locationInWindow, from: nil)
        let next = min(8, max(1, zoomScale * exp(-max(-5, min(5, delta)) * 0.13)))
        guard next != zoomScale else { return false }
        let ratio = next / zoomScale
        zoomScale = next
        let area = pictureArea
        let width = oldRect.width * ratio
        let height = oldRect.height * ratio
        let center = CGPoint(x: point.x + (oldRect.midX - point.x) * ratio,
                             y: point.y + (oldRect.midY - point.y) * ratio)
        let limitX = max(0, (width - area.width) / 2)
        let limitY = max(0, (height - area.height) / 2)
        zoomOffset = next == 1 ? .zero : CGPoint(
            x: min(limitX, max(-limitX, center.x - area.midX)),
            y: min(limitY, max(-limitY, center.y - area.midY)))
        needsDisplay = true
        return true
    }

    private func symbolImage(_ symbol: String) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium))
    }

    private func configureIcon(_ button: NSButton, symbol: String, name: String) {
        button.title = ""
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = Self.iconColor
        button.image = symbolImage(symbol)
        button.toolTip = name
        button.setAccessibilityLabel(name)
    }

    func setFavoriteStatus(_ favorite: Bool, revision: UUID?) {
        guard photoIsFavorite != favorite || favoriteRevision != revision else { return }
        photoIsFavorite = favorite
        if revision != favoriteRevision, confirmationRevision != nil {
            indicatorTask?.cancel()
            favoriteIndicator.layer?.removeAllAnimations()
            favoriteIndicator.isHidden = true
            confirmationRevision = nil
        }
        favoriteRevision = revision
        renderFavoriteStatus()
        refreshPermanentHeart()
    }

    private func renderFavoriteStatus() {
        favoriteStatus.image = symbolImage(photoIsFavorite && !editingLayout ? "heart.fill" : "heart")
        favoriteStatus.contentTintColor = photoIsFavorite && !editingLayout ? Self.pink : Self.outline
        let label = photoIsFavorite ? "お気に入りを解除" : "お気に入りに登録"
        favoriteStatus.setAccessibilityLabel(label)
        favoriteStatus.toolTip = label
        let animating = favoriteRevision != nil &&
            (favoriteRevision == fallingRevision || favoriteRevision == bouncingRevision)
        if animating { favoriteStatus.image = nil }
    }

    func showFavoriteRemoval(fallFrom revision: UUID?) {
        showFavoriteConfirmation(removed: true)
        guard let revision else { return }
        bounceTask?.cancel()
        bouncingHeart.layer?.removeAllAnimations()
        bouncingHeart.isHidden = true
        bouncingRevision = nil
        fallTask?.cancel()
        fallingStar.layer?.removeAllAnimations()
        layoutSubtreeIfNeeded()
        fallingRevision = revision
        renderFavoriteStatus()
        fallingStar.image = symbolImage("heart.fill")
        fallingStar.contentTintColor = Self.pink
        fallingStar.frame = convert(favoriteStatus.frame, from: bar)
        fallingStar.isHidden = false
        let origin = fallingStar.frame
        let rotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rotation.values = [0.0, -0.40, -0.75, -1.75]
        rotation.keyTimes = [0, 0.16, 0.40, 1]
        rotation.duration = 0.85
        fallingStar.layer?.add(rotation, forKey: "favorite-fall-spin")
        #if SLIDESHOW_QA
        qaTrace("favorite fall started")
        #endif
        fallTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                fallingStar.animator().setFrameOrigin(CGPoint(x: origin.minX + 5, y: origin.minY + 10))
            }
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.71
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                fallingStar.animator().setFrameOrigin(CGPoint(x: origin.minX + 35, y: -origin.height - 12))
            }
            guard !Task.isCancelled else { return }
            fallingStar.isHidden = true
            fallingRevision = nil
            renderFavoriteStatus()
            #if SLIDESHOW_QA
            qaTrace("favorite fall ended")
            #endif
        }
    }

    private func refreshPermanentHeart() {
        #if SLIDESHOW_QA
        let wasHidden = permanentHeart.isHidden
        #endif
        permanentHeart.filled = !editingLayout
        permanentHeart.isHidden = !editingLayout && !(photoIsFavorite && favoriteRevision != nil)
        #if SLIDESHOW_QA
        if permanentHeart.isHidden != wasHidden { qaTrace("permanent heart " + (permanentHeart.isHidden ? "off" : "on")) }
        #endif
        permanentHeart.needsDisplay = true
    }

    func pulseFavorite(revision: UUID) {
        showFavoriteConfirmation(revision: revision, subtle: true)
    }

    func showFavoriteConfirmation(removed: Bool = false, revision: UUID? = nil, subtle: Bool = false) {
        confirmationRevision = revision
        if !removed && !subtle && !bar.isHidden { bounceFavorite() }
        favoriteIndicator.removed = removed
        favoriteIndicator.filled = !removed
        favoriteIndicator.glow = removed ? 0 : subtle ? 0.60 : 1
        favoriteIndicator.needsDisplay = true
        #if SLIDESHOW_QA
        if removed { qaTrace("favorite removal indicator shown") }
        else { qaTrace(subtle ? "favorite existing pulse" : "favorite filled registration") }
        #endif
        indicatorTask?.cancel()
        favoriteIndicator.layer?.removeAllAnimations()
        favoriteIndicator.isHidden = false
        favoriteIndicator.alphaValue = 1
        refreshPermanentHeart()
        #if SLIDESHOW_QA
        qaTrace("favorite indicator shown")
        #endif
        indicatorTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(subtle ? 90 : 600)) } catch { return }
            guard let self else { return }
            refreshPermanentHeart()
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = subtle ? 0.27 : 0.45
                favoriteIndicator.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            favoriteIndicator.isHidden = true
            confirmationRevision = nil
            refreshPermanentHeart()
            #if SLIDESHOW_QA
            qaTrace("favorite indicator hidden")
            #endif
        }
    }

    private func bounceFavorite() {
        guard let revision = favoriteRevision else { return }
        layoutSubtreeIfNeeded()
        fallTask?.cancel()
        fallingStar.layer?.removeAllAnimations()
        fallingStar.isHidden = true
        fallingRevision = nil
        bounceTask?.cancel()
        bouncingHeart.layer?.removeAllAnimations()
        bouncingRevision = revision
        renderFavoriteStatus()
        bouncingHeart.frame = convert(favoriteStatus.frame, from: bar)
        bouncingHeart.image = symbolImage("heart.fill")
        bouncingHeart.contentTintColor = Self.pink
        bouncingHeart.isHidden = false
        let offset: CGFloat = (bar.frame.midY > safeRect.midY ? -42 : 42) * bar.frame.width / 828
        let origin = bouncingHeart.frame
        let target = origin.insetBy(dx: -3, dy: -3).offsetBy(dx: 0, dy: offset)
        #if SLIDESHOW_QA
        qaTrace("favorite bounce")
        #endif
        bounceTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bouncingHeart.animator().frame = target
            }
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.30
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bouncingHeart.animator().frame = origin
            }
            guard !Task.isCancelled else { return }
            bouncingRevision = nil
            bouncingHeart.isHidden = true
            renderFavoriteStatus()
        }
    }

    private func refreshBar(at point: CGPoint? = nil) {
        guard let window else { return }
        let location = point ?? convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let near = bounds.contains(location) && bar.frame.insetBy(dx: -max(8, bar.frame.width / 828 * 22),
                                                               dy: -max(8, bar.frame.width / 828 * 22)).contains(location)
        if near || panel != nil || forceControls {
            hideTask?.cancel()
            hideTask = nil
            bar.isHidden = false
        } else if !bar.isHidden && hideTask == nil {
            hideTask = Task { [weak self] in
                guard let delay = self?.settings.barHideSeconds else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self else { return }
                hideTask = nil
                if panel == nil, !forceControls {
                    bar.isHidden = true
                    refreshBar()
                }
            }
        }
    }

    func installPanel(_ next: NSView?) {
        if next is LayoutEditor {
            indicatorTask?.cancel()
            fallTask?.cancel()
            bounceTask?.cancel()
            for effect in [favoriteIndicator, fallingStar, bouncingHeart] {
                effect.layer?.removeAllAnimations()
                effect.isHidden = true
            }
            confirmationRevision = nil
            fallingRevision = nil
            bouncingRevision = nil
        }
        panel?.removeFromSuperview()
        panel = next
        firstClickRevision = nil
        if let next { addSubview(next) }
        clock.configure(style: settings.clockStyle, visible: settings.clockVisible || editingLayout)
        renderFavoriteStatus()
        refreshPermanentHeart()
        needsLayout = true
        needsDisplay = true
        refreshBar()
    }

    func flash(_ message: String) {
        notice.stringValue = message
        notice.isHidden = false
        needsLayout = true
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            self?.notice.isHidden = true
        }
    }

    func updateControls(paused: Bool, ready: Bool) {
        let pauseName = paused ? "再開" : "一時停止"
        if pauseButton.toolTip != pauseName {
            configureIcon(pauseButton, symbol: paused ? "play.fill" : "pause.fill", name: pauseName)
        }
        for button in [previousButton, pauseButton, nextButton, listButton] { button.isEnabled = ready }
    }

    private var pictureArea: CGRect {
        let size = photo?.image.size ?? CGSize(width: 16, height: 9)
        return geometry.pictureArea(aspect: size.width / max(1, size.height))
    }

    private func imageRect(for size: CGSize) -> CGRect {
        let safe = pictureArea
        let scale = min(safe.width / size.width, safe.height / size.height) * zoomScale
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: safe.midX + zoomOffset.x - width / 2, y: safe.midY + zoomOffset.y - height / 2,
                      width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        var occupied = CGRect.zero
        if let photo {
            occupied = imageRect(for: photo.image.size)
            NSGraphicsContext.current?.imageInterpolation = .high
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: pictureArea).addClip()
            photo.image.draw(in: occupied, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            if let sequence, !occupied.isEmpty, dirtyRect.intersects(occupied) {
                // The visible window's draw pass determines the saved position.
                didDraw?(sequence)
            }
        }
        if panel is PreferencesPanel {
            NSColor.black.withAlphaComponent(0.52).setFill()
            dirtyRect.fill()
        }
        let warning = powerWarning ? "自動消灯を抑えられませんでした" : nil
        let status = [message, loading ? "写真を読み込み中…" : nil, warning].compactMap { $0 }
        if !status.isEmpty { drawStatus(status.joined(separator: "\n"), avoiding: occupied) }
    }

    private func drawStatus(_ text: String, avoiding photoRect: CGRect) {
        let safe = safeRect.insetBy(dx: 24, dy: 12)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let text = NSAttributedString(string: text, attributes: attributes)
        let width = min(640, safe.width)
        guard width > 0 else { return }
        let height = ceil(text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        let x = safe.midX - width / 2
        let positions = photoRect.isEmpty ? [safe.midY - height / 2] :
            [returnButton.frame.midY - height / 2, safe.maxY - height,
             photoRect.minY - height - 12, photoRect.maxY + 12]
        for y in positions {
            let rect = CGRect(x: x, y: y, width: width, height: height)
            guard safe.contains(rect), !rect.intersects(photoRect),
                  !rect.intersects(bar.frame) else { continue }
            text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            break
        }
    }
}

private final class PassiveImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class FavoriteIndicator: NSView {
    var removed = false
    var filled = false
    var glow: CGFloat = 0
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let scale = bounds.width / 64
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = AffineTransform(scaleByX: scale, byY: scale)
        (transform as NSAffineTransform).concat()
        let bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        if glow == 0 {
            NSColor.black.withAlphaComponent(0.76).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()
        }
        let glyph = NSAttributedString(string: filled ? "♥" : "♡", attributes: [
            .font: NSFont.systemFont(ofSize: 43, weight: .semibold),
            .foregroundColor: filled ? NSColor(srgbRed: 1, green: 0.36, blue: 0.62, alpha: 1) : NSColor.white
        ])
        let point = CGPoint(x: bounds.midX - glyph.size().width / 2, y: bounds.midY - glyph.size().height / 2)
        if glow > 0 {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(srgbRed: 1, green: 0.44, blue: 0.69, alpha: glow)
            shadow.shadowBlurRadius = 13
            shadow.shadowOffset = .zero
            shadow.set()
            glyph.draw(at: point)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            glyph.draw(at: point)
        }
        if removed {
            let mark = NSAttributedString(string: "×", attributes: [
                .font: NSFont.systemFont(ofSize: 23, weight: .bold),
                .foregroundColor: NSColor(srgbRed: 1, green: 0.38, blue: 0.40, alpha: 1)
            ])
            let origin = CGPoint(x: 40, y: 8)
            NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 37, y: 9, width: 21, height: 21)).fill()
            mark.draw(at: origin)
        }
    }
}
