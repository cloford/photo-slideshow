import AppKit

final class ActionButton: NSButton {
    var perform: (() -> Void)?

    init(_ title: String) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        action = #selector(pressed)
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
    let edge = NSSegmentedControl(labels: ["上", "下"], trackingMode: .selectOne, target: nil, action: nil)
    let clock = NSSwitch()
    let clockStyle = NSSegmentedControl(labels: ["アナログ", "デジタル"], trackingMode: .selectOne, target: nil, action: nil)
    let clockSide = NSSegmentedControl(labels: ["左上", "右上"], trackingMode: .selectOne, target: nil, action: nil)
    let save = ActionButton("保存して閉じる")
    let close = ActionButton("閉じる")
    let error = NSTextField(labelWithString: "")
    private let stepper = NSStepper()

    init(_ preferences: PlaybackPreferences) {
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
        edge.selectedSegment = preferences.barEdge == .top ? 0 : 1
        clock.state = preferences.clockVisible ? .on : .off
        clockStyle.selectedSegment = preferences.clockStyle == .analog ? 0 : 1
        clockSide.selectedSegment = preferences.clockSide == .left ? 0 : 1
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
        let footer = NSStackView(views: [close, save])
        footer.translatesAutoresizingMaskIntoConstraints = false
        let footerRow = NSView()
        footerRow.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.trailingAnchor.constraint(equalTo: footerRow.trailingAnchor),
            footer.topAnchor.constraint(equalTo: footerRow.topAnchor),
            footer.bottomAnchor.constraint(equalTo: footerRow.bottomAnchor)
        ])
        let items: [NSView] = [
            title, NSBox(), heading("再生"), row("1枚の表示時間", value), row("", presets),
            row("起動位置", start), NSBox(), heading("画面表示"), row("画像の表示領域", area),
            row("", hint), row("操作バーの位置", edge), NSBox(), heading("時計"),
            row("時計を表示", clock), row("時計の種類", clockStyle), row("時計の位置", clockSide),
            NSBox(), error, footerRow
        ]
        let stack = NSStackView(views: items)
        for box in items.compactMap({ $0 as? NSBox }) {
            box.boxType = .separator
            box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        footerRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        var preferences = PlaybackPreferences(seconds: value, fromBeginning: start.selectedSegment == 1)
        preferences.reserveBarSpace = area.selectedSegment == 1
        preferences.barEdge = edge.selectedSegment == 0 ? .top : .bottom
        preferences.clockVisible = clock.state == .on
        preferences.clockStyle = clockStyle.selectedSegment == 0 ? .analog : .digital
        preferences.clockSide = clockSide.selectedSegment == 0 ? .left : .right
        return preferences
    }

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

final class PhotoRow: NSTableCellView {
    private let picture = NSImageView()
    private let label = NSTextField(labelWithString: "")
    let remove = ActionButton("お気に入り解除")
    private var cancel: (() -> Void)?
    private var metadata: Task<Void, Never>?
    private var token = UUID()

    func stop() { cancel?(); cancel = nil; metadata?.cancel(); token = UUID() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(picture)
        addSubview(label)
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(remove)
        NSLayoutConstraint.activate([
            picture.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            picture.centerYAnchor.constraint(equalTo: centerYAnchor),
            picture.widthAnchor.constraint(equalToConstant: 66),
            picture.heightAnchor.constraint(equalToConstant: 46),
            label.leadingAnchor.constraint(equalTo: picture.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -8),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            remove.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }

    func show(_ photo: Photo, index: Int, source: any PhotoSource, favorite: Bool) {
        stop()
        let request = token
        let date = photo.date?.formatted(date: .abbreviated, time: .shortened)
        let line = ["\(index + 1)" + (favorite ? " ★" : ""), date].compactMap { $0 }.joined(separator: "   ")
        label.stringValue = line
        picture.image = nil
        cancel = source.requestThumbnail(for: photo, size: CGSize(width: 132, height: 92)) { [weak self] result in
            guard let self, token == request, case .image(let image) = result else { return }
            picture.image = image.image
        }
        metadata = Task { [weak self] in
            let name = await source.resources(for: photo).first?.filename
            guard let self, !Task.isCancelled, token == request, let name else { return }
            label.stringValue = line + "   " + name
        }
    }
}

final class PhotosPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let source: any PhotoSource
    private let photos: [Photo]
    private var favorites: Set<String>
    private var removalEnabled = true
    private let current: Int?
    private var indices: [Int] = []
    let table = NSTableView()
    let close = ActionButton("閉じる")
    private let filter = ActionButton("お気に入りのみ")
    private let empty = NSTextField(labelWithString: "このアルバムにお気に入りはありません。")
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
        let scroll = NSScrollView()
        for view in [title, close, filter, scroll, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        filter.setButtonType(.pushOnPushOff)
        filter.perform = { [weak self] in self?.reload() }
        let column = NSTableColumn(identifier: .init("photo"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 54
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityLabel("アルバム内の写真")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
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
        guard removalEnabled != enabled else { return }
        removalEnabled = enabled
        table.enumerateAvailableRowViews { [table] _, row in
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PhotoRow)?.remove.isEnabled = enabled
        }
    }

    func updateFavorites(_ favorites: Set<String>) {
        self.favorites = favorites
        let offset = table.enclosingScrollView?.contentView.bounds.origin
        reload()
        if let scroll = table.enclosingScrollView, let offset {
            scroll.contentView.scroll(to: offset)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func reload() {
        indices = photos.indices.filter { filter.state == .off || favorites.contains(photos[$0].id) }
        #if SLIDESHOW_QA
        qaTrace("list filtered=\(filter.state == .on) rows=\(indices.count)")
        #endif
        table.reloadData()
        empty.isHidden = !indices.isEmpty
        selectCurrent()
    }

    func selectCurrent() {
        if let current, let row = indices.firstIndex(of: current) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { indices.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("photo-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? PhotoRow ?? PhotoRow(frame: .zero)
        cell.identifier = identifier
        let index = indices[row]
        let favorite = favorites.contains(photos[index].id)
        cell.remove.isHidden = !favorite
        cell.remove.isEnabled = removalEnabled
        cell.remove.setAccessibilityLabel("\(index + 1)枚目のお気に入り解除")
        cell.remove.perform = { [weak self] in self?.removeFavorite?(index) }
        cell.show(photos[index], index: index, source: source, favorite: favorite)
        return cell
    }

    @objc private func clicked() {
        let row = table.clickedRow
        if indices.indices.contains(row) { choose?(indices[row]) }
    }
}
