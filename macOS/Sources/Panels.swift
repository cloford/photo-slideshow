import AppKit

final class ActionButton: NSButton {
    var perform: (() -> Void)?
    var singleClickOnly = false

    init(_ title: String) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        action = #selector(pressed)
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if !singleClickOnly || event.clickCount == 1 { super.mouseDown(with: event) }
    }

    @objc private func pressed() { perform?() }
}

@MainActor
func panelSurface(_ panel: NSView) {
    panel.wantsLayer = true
    panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    panel.layer?.cornerRadius = 14
    panel.layer?.borderWidth = 1
    panel.layer?.borderColor = NSColor.separatorColor.cgColor
}

@MainActor
func panelStack(_ views: [NSView], in panel: NSView) {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    panel.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
        stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
        stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
        stack.bottomAnchor.constraint(lessThanOrEqualTo: panel.bottomAnchor, constant: -16)
    ])
}

private final class SettingsDocumentView: NSView { override var isFlipped: Bool { true } }

final class PreferencesPanel: NSView, NSTextFieldDelegate {
    let seconds = NSTextField(string: "")
    let start = NSSegmentedControl(labels: ["前回の続き", "先頭から"], trackingMode: .selectOne, target: nil, action: nil)
    let area = NSSegmentedControl(labels: ["画面全体", "操作バー分の余白を確保"], trackingMode: .selectOne, target: nil, action: nil)
    let edge = NSSegmentedControl(labels: ["上", "下", "カスタム"], trackingMode: .selectOne, target: nil, action: nil)
    let clock = NSSwitch()
    let clockStyle = NSSegmentedControl(labels: ["アナログ", "デジタル"], trackingMode: .selectOne, target: nil, action: nil)
    let clockSide = NSSegmentedControl(labels: ["左上", "右上", "カスタム"], trackingMode: .selectOne, target: nil, action: nil)
    let hideSeconds = NSTextField(string: "")
    let noticeSide = NSSegmentedControl(labels: ["左上", "右上", "カスタム"], trackingMode: .selectOne, target: nil, action: nil)
    let editLayout = ActionButton("配置を編集")
    let save = ActionButton("閉じる")
    var preview: ((PlaybackPreferences) -> Void)?
    private var draft: PlaybackPreferences
    let error = NSTextField(labelWithString: "")
    private let stepper = NSStepper()

    init(_ preferences: PlaybackPreferences) {
        draft = preferences
        super.init(frame: .zero)
        panelSurface(self)
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor(srgbRed: 0.105, green: 0.11, blue: 0.12, alpha: 1).cgColor
        layer?.cornerRadius = 22
        let title = NSTextField(labelWithString: "設定")
        title.font = .boldSystemFont(ofSize: 28)
        seconds.placeholderString = "秒数"
        seconds.setAccessibilityLabel("1枚の表示秒数")
        seconds.delegate = self
        seconds.widthAnchor.constraint(equalToConstant: 64).isActive = true
        stepper.minValue = 1
        stepper.maxValue = 300
        stepper.increment = 1
        stepper.target = self
        stepper.action = #selector(stepped)
        setSeconds(preferences.seconds)
        let value = NSStackView(views: [seconds, stepper,
                                       NSTextField(labelWithString: "秒（1〜300）")])
        value.spacing = 8
        let presets = NSStackView(views: PlaybackPreferences.presets.map { number in
            let button = ActionButton("\(number)秒")
            button.perform = { [weak self] in self?.window?.makeFirstResponder(nil); self?.setSeconds(number) }
            return button
        })
        start.selectedSegment = preferences.fromBeginning ? 1 : 0
        area.selectedSegment = preferences.reserveBarSpace ? 1 : 0
        clock.state = preferences.clockVisible ? .on : .off
        clockStyle.selectedSegment = preferences.clockStyle == .analog ? 0 : 1
        hideSeconds.setAccessibilityLabel("操作バーを隠すまで")
        hideSeconds.stringValue = String(preferences.barHideSeconds)
        hideSeconds.widthAnchor.constraint(equalToConstant: 64).isActive = true
        updateLayoutDraft(preferences)
        for control in [edge, clock, clockStyle, clockSide, area, noticeSide] as [NSControl] {
            control.target = self
            control.action = #selector(previewChanged)
        }
        save.bezelColor = .controlAccentColor
        save.keyEquivalent = "\r"
        error.textColor = .systemRed

        func row(_ label: String, _ control: NSView) -> NSStackView {
            let title = NSTextField(labelWithString: label)
            title.font = .systemFont(ofSize: 16, weight: .semibold)
            if let field = control as? NSControl { field.controlSize = .large }
            title.widthAnchor.constraint(equalToConstant: 206).isActive = true
            control.setAccessibilityLabel(label)
            let row = NSStackView(views: [title, control])
            row.spacing = 14
            return row
        }
        func heading(_ name: String) -> NSTextField {
            let label = NSTextField(labelWithString: name)
            label.font = .boldSystemFont(ofSize: 17)
            return label
        }
        let hint = NSTextField(labelWithString: "「画面全体」では操作バーを写真に重ねます。")
        hint.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [editLayout, NSView(), save])
        footer.distribution = .fill
        footer.translatesAutoresizingMaskIntoConstraints = false
        editLayout.setContentHuggingPriority(.required, for: .horizontal)
        save.setContentHuggingPriority(.required, for: .horizontal)
        error.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)
        addSubview(error)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            error.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            error.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            error.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6)
        ])
        let items: [NSView] = [
            title, NSBox(), heading("再生"), row("1枚の表示時間", value), row("", presets),
            row("起動位置", start), NSBox(), heading("画面表示"), row("画像の表示領域", area),
            row("", hint), row("操作バーの位置", edge), NSBox(), heading("時計"),
            row("時計を表示", clock), row("時計の種類", clockStyle), row("時計の位置", clockSide),
            NSBox(), heading("操作バーと通知"),
            row("操作バーを隠すまで", NSStackView(views: [hideSeconds, NSTextField(labelWithString: "秒（1〜60）")])),
            row("お気に入りの位置", noticeSide)
        ]
        let stack = NSStackView(views: items)
        for box in items.compactMap({ $0 as? NSBox }) {
            box.boxType = .separator
            box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let content = SettingsDocumentView()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = content
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: error.topAnchor, constant: -6),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 25),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22)
        ])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
        content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    var value: PlaybackPreferences? {
        window?.makeFirstResponder(nil)
        guard let value = Int(seconds.stringValue.trimmingCharacters(in: .whitespaces)), (1...300).contains(value)
        else { error.stringValue = "1〜300秒の整数を入力してください。"; return nil }
        guard let delay = Int(hideSeconds.stringValue.trimmingCharacters(in: .whitespaces)), (1...60).contains(delay)
        else { error.stringValue = "バーを隠す時間は1〜60秒で入力してください。"; return nil }
        var preferences = previewValue()
        preferences.seconds = value
        preferences.fromBeginning = start.selectedSegment == 1
        preferences.barHideSeconds = delay
        return preferences
    }

    func updateLayoutDraft(_ value: PlaybackPreferences) {
        draft = value
        func setChoices(_ control: NSSegmentedControl, placement: OverlayPlacement, preset: Int) {
            control.setEnabled(placement.position != nil, forSegment: 2)
            control.selectedSegment = placement.custom ? 2 : preset
        }
        setChoices(edge, placement: value.barPlacement, preset: value.barEdge == .top ? 0 : 1)
        setChoices(clockSide, placement: value.clockPlacement, preset: value.clockSide == .left ? 0 : 1)
        setChoices(noticeSide, placement: value.heartPlacement, preset: value.noticeSide == .left ? 0 : 1)
    }

    func previewValue() -> PlaybackPreferences {
        var preferences = draft
        preferences.reserveBarSpace = area.selectedSegment == 1
        preferences.barPlacement.usePresetPosition = edge.selectedSegment != 2
        if edge.selectedSegment != 2 {
            preferences.barEdge = edge.selectedSegment == 0 ? .top : .bottom
        }
        preferences.clockVisible = clock.state == .on
        preferences.clockStyle = clockStyle.selectedSegment == 0 ? .analog : .digital
        preferences.clockPlacement.usePresetPosition = clockSide.selectedSegment != 2
        if clockSide.selectedSegment != 2 {
            preferences.clockSide = clockSide.selectedSegment == 0 ? .left : .right
        }
        preferences.heartPlacement.usePresetPosition = noticeSide.selectedSegment != 2
        if noticeSide.selectedSegment != 2 {
            preferences.noticeSide = noticeSide.selectedSegment == 0 ? .left : .right
        }
        return preferences
    }

    @objc private func previewChanged() { preview?(previewValue()) }

    private func setSeconds(_ value: Int) {
        seconds.stringValue = String(value)
        stepper.integerValue = value
        error.stringValue = ""
    }

    func controlTextDidChange(_ notification: Notification) {
        if let value = Int(seconds.stringValue), (1...300).contains(value) {
            stepper.integerValue = value
        }
    }

    @objc private func stepped() {
        let next = stepper.integerValue
        window?.makeFirstResponder(nil)
        setSeconds(next)
    }
}

final class PhotoTile: NSCollectionViewItem {
    private let picture = NSImageView()
    private let openPhoto = ActionButton("")
    let remove = ActionButton("")
    private var cancel: (() -> Void)?
    private var requestID = UUID()

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        picture.imageScaling = .scaleProportionallyUpOrDown
        openPhoto.isBordered = false
        for item in [picture, openPhoto, remove] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        remove.imagePosition = .imageOnly
        remove.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        remove.contentTintColor = NSColor(srgbRed: 1, green: 0.36, blue: 0.62, alpha: 1)
        remove.isBordered = false
        remove.wantsLayer = true
        remove.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        remove.layer?.cornerRadius = 10
        remove.toolTip = "この写真のお気に入りを解除"
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            picture.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),
            picture.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            picture.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            openPhoto.topAnchor.constraint(equalTo: view.topAnchor),
            openPhoto.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            openPhoto.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            openPhoto.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            remove.widthAnchor.constraint(equalToConstant: 22),
            remove.heightAnchor.constraint(equalToConstant: 20),
            remove.topAnchor.constraint(equalTo: view.topAnchor, constant: 3),
            remove.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3)
        ])
    }

    func stop() {
        requestID = UUID()
        cancel?()
        cancel = nil
    }

    override func prepareForReuse() {
        stop()
        super.prepareForReuse()
    }

    func configure(photo: Photo, index: Int, source: any PhotoSource, favorite: Bool, current: Bool,
                   canRemove: Bool, select: @escaping () -> Void, unmark: @escaping () -> Void) {
        stop()
        loadViewIfNeeded()
        view.layer?.borderWidth = current ? 3 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        openPhoto.setAccessibilityLabel("\(index + 1)枚目を表示" + (current ? "、現在の写真" : ""))
        openPhoto.perform = select
        remove.setAccessibilityLabel("\(index + 1)枚目のお気に入り解除")
        remove.perform = unmark
        remove.isHidden = !favorite
        remove.isEnabled = canRemove
        picture.image = nil
        let token = requestID
        #if SLIDESHOW_QA
        qaTrace("thumbnail \(index)")
        #endif
        cancel = source.requestThumbnail(for: photo, size: CGSize(width: 300, height: 220)) { [weak self] result in
            guard let self, requestID == token, case .image(let image) = result else { return }
            picture.image = image.image
        }
    }
}

final class PhotosPanel: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private let source: any PhotoSource
    private let photos: [Photo]
    private var favorites: Set<String>
    private let current: Int?
    private var indices: [Int] = []
    private var removalEnabled = true
    private let scroll = NSScrollView()
    private let filter = NSSegmentedControl(labels: ["すべて", "お気に入り"], trackingMode: .selectOne, target: nil, action: nil)
    private let empty = NSTextField(labelWithString: "お気に入りの写真はありません。")
    private let tileID = NSUserInterfaceItemIdentifier("photo-tile")
    let grid = NSCollectionView()
    let close = ActionButton("閉じる")
    var choose: ((Int) -> Void)?
    var removeFavorite: ((Int) -> Void)?

    init(source: any PhotoSource, photos: [Photo], favorites: Set<String>, current: Int?) {
        self.source = source
        self.photos = photos
        self.favorites = favorites
        self.current = current
        super.init(frame: .zero)
        panelSurface(self)
        let title = NSTextField(labelWithString: "写真一覧")
        title.font = .boldSystemFont(ofSize: 18)
        filter.selectedSegment = 0
        filter.target = self
        filter.action = #selector(filterChanged)
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 140, height: 108)
        layout.minimumLineSpacing = 10
        layout.minimumInteritemSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        grid.collectionViewLayout = layout
        grid.register(PhotoTile.self, forItemWithIdentifier: tileID)
        grid.dataSource = self
        grid.delegate = self
        grid.setAccessibilityLabel("サムネイル一覧")
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        for child in [title, filter, close, scroll, empty] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            filter.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -12),
            filter.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: close.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: close.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
        reload()
    }

    required init?(coder: NSCoder) { nil }

    func setRemovalEnabled(_ enabled: Bool) {
        removalEnabled = enabled
        for case let tile as PhotoTile in grid.visibleItems() { tile.remove.isEnabled = enabled }
    }

    func updateFavorites(_ favorites: Set<String>) {
        self.favorites = favorites
        let offset = scroll.contentView.bounds.origin
        reload()
        scroll.contentView.scroll(to: offset)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func filterChanged() { reload(); selectCurrent() }

    private func reload() {
        let filtered = filter.selectedSegment == 1
        indices = photos.indices.filter { !filtered || favorites.contains(photos[$0].id) }
        #if SLIDESHOW_QA
        qaTrace("list filtered=\(filtered) rows=\(indices.count)")
        #endif
        grid.reloadData()
        empty.isHidden = !indices.isEmpty
    }

    func selectCurrent() {
        grid.layoutSubtreeIfNeeded()
        if let current, let index = indices.firstIndex(of: current) {
            grid.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .centeredVertically)
        }
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        indices.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let tile = grid.makeItem(withIdentifier: tileID, for: indexPath) as! PhotoTile
        let index = indices[indexPath.item]
        let photo = photos[index]
        tile.configure(photo: photo, index: index, source: source, favorite: favorites.contains(photo.id),
                       current: current == index, canRemove: removalEnabled,
                       select: { [weak self] in self?.choose?(index) },
                       unmark: { [weak self] in self?.removeFavorite?(index) })
        return tile
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        (item as? PhotoTile)?.stop()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            for case let tile as PhotoTile in grid.visibleItems() { tile.stop() }
        }
    }
}
