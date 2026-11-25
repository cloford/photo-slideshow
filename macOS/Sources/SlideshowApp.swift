import AppKit
import OSLog
import Photos

@MainActor
final class SlideshowApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum ScreenMode: String { case preparation, picker, playback, playbackError }

    private let library: any SlideshowLibrary
    private let data: UserData
    private let sourceKey: SourceKey
    private var positions = ScopedPositions()
    private var preferences = PlaybackPreferences()
    private var favorites: [Favorite] = []
    private var favoritesReadable = true
    private var wheel = WheelNavigation()
    private var favoriteWrite: Task<Void, Never>?
    private var preferencesWrite: Task<Void, Never>?
    private let power = DisplaySleep()
    private let previousApplication: NSRunningApplication?
    private var screenID: UInt32?
    private var mode: ScreenMode = .preparation
    private var window: SlideshowWindow?
    private var slideshow: SlideshowView?
    private var picker: AlbumPicker?
    private var playback: Playback?
    private var record: PlaybackRecord?
    private var currentAlbums: [Album] = []
    private var startup: Task<Void, Never>?
    private var authorizationMonitor: Task<Void, Never>?
    private var saveDeadline: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var screenLocked = false
    private var lastWindowState: String?
    private var frameCount = 0
    private var lastFrameLog = ContinuousClock.now
    private var lastPowerAttempt: ContinuousClock.Instant?
    private var sessionActive = true
    private var systemAwake = true
    private var displayAwake = true
    private var powerWarning = false
    private var settingsWarning = false
    private var exiting = false
    private var systemIsWaiting = false
    private var readyToTerminate = false

    init(library: any SlideshowLibrary) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApplication = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ?
            nil : frontmost
        self.library = library
        data = UserData(legacy: PlaybackSettings(bundleID: Bundle.main.bundleIdentifier!))
        sourceKey = SourceKey(library)
        screenID = Self.displayUnderPointer()?.displayID
    }

    private static func displayUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.displayID == screenID }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard targetScreen != nil else {
            appLog.error("No usable display at launch.")
            beginExit(reason: "no target display")
            return
        }
        appLog.notice("Launched. Display=\(self.screenID ?? 0); screens=\(NSScreen.screens.count); previous=\(self.previousApplication?.bundleIdentifier ?? "unknown", privacy: .public)")
        screenLocked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        if let screenID { displayAwake = CGDisplayIsAsleep(screenID) == 0 }
        observeWorkspace()
        let appMenu = NSMenu()
        let root = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(withTitle: "写真スライドショーを終了", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        root.submenu = menu
        appMenu.addItem(root)
        NSApp.mainMenu = appMenu

        startup = Task { [weak self] in
            guard let self else { return }
            var permission = library.authorization
            if permission == .notDetermined {
                showMessage("写真ライブラリへのアクセス許可を確認しています…")
                permission = await library.requestAuthorization()
            }
            appLog.notice("Photos authorization status=\(permission.rawValue)")
            guard !exiting else { return }
            guard permission == .authorized else {
                showAuthorizationError(permission)
                return
            }
            monitorAuthorization()
            do {
                positions = try await data.positions()
            } catch {
                settingsWarning = true
                if sourceKey == .photos, let legacy = await data.legacy.read() {
                    positions.update(legacy, source: .photos)
                }
            }
            record = positions.record(for: sourceKey)
            do { preferences = try await data.preferences() }
            catch { settingsWarning = true }
            do { favorites = try await data.favorites() }
            catch { favoritesReadable = false }
            currentAlbums = await library.albums()
            guard !exiting, !Task.isCancelled, checkAuthorization() else { return }
            appLog.notice("Album catalog loaded; count=\(self.currentAlbums.count)")
            if let record {
                await openAlbum(record.albumID, initial: true)
            } else {
                showPicker()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !exiting, let window { showFront(window) }
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if authorizationMonitor != nil { _ = checkAuthorization() }
        refreshVisibility()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        guard !exiting else { return }
        if targetScreen == nil {
            screenID = Self.displayUnderPointer()?.displayID
        }
        guard let screen = targetScreen else {
            appLog.error("No usable display after screen configuration changed.")
            beginExit(reason: "no target display")
            return
        }
        apply(screen)
        refreshVisibility()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        refreshVisibility(reason: "window occlusion changed")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        beginExit(reason: "window close")
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToTerminate { return .terminateNow }
        systemIsWaiting = true
        beginExit(reason: "application terminate request")
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) { power.release(reason: "application will terminate") }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification, NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let name = note.name
                MainActor.assumeIsolated { self?.workspaceChanged(name) }
            }
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            let observer = distributed.addObserver(forName: Notification.Name(name), object: nil,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screenLocked = locked
                    self?.refreshVisibility(reason: locked ? "screen locked" : "screen unlocked")
                }
            }
            lockObservers.append(observer)
        }
    }

    private func workspaceChanged(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.willSleepNotification: systemAwake = false
        case NSWorkspace.didWakeNotification: systemAwake = true
        case NSWorkspace.screensDidSleepNotification: displayAwake = false
        case NSWorkspace.screensDidWakeNotification: displayAwake = true
        case NSWorkspace.sessionDidResignActiveNotification: sessionActive = false
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionActive = true
        default: break
        }
        refreshVisibility(reason: name.rawValue)
    }

    private func monitorAuthorization() {
        authorizationMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, checkAuthorization() else { return }
                if powerWarning { refreshVisibility(reason: "assertion retry") }
            }
        }
    }

    @discardableResult
    private func checkAuthorization() -> Bool {
        guard !exiting else { return false }
        let status = library.authorization
        guard status == .authorized else {
            authorizationMonitor?.cancel()
            authorizationMonitor = nil
            startup?.cancel()
            showAuthorizationError(status)
            return false
        }
        return true
    }

    private func showAuthorizationError(_ status: PHAuthorizationStatus) {
        let restriction = status == .restricted ? "\nこのMacでは写真へのアクセスが制限されています。" : ""
        showMessage(
            "写真ライブラリへのアクセスが必要です。\nシステム設定の「プライバシーとセキュリティ」→「写真」で、このアプリにフルアクセスを許可してから開き直してください。" + restriction)
    }

    private func openAlbum(_ id: String, initial: Bool) async {
        guard !exiting else { return }
        showPlayback()
        let photos = await library.photos(in: id)
        guard !exiting, !Task.isCancelled, checkAuthorization() else { return }
        guard let photos, !photos.isEmpty else {
            if initial {
                currentAlbums = await library.albums()
                guard !exiting, !Task.isCancelled, checkAuthorization() else { return }
            }
            showPicker(message: photos == nil ? "前回のアルバムが見つかりません。" :
                "このアルバムに表示できる写真がありません。")
            return
        }
        guard let slideshow, let screen = targetScreen else { return }
        appLog.notice("Photo catalog loaded; count=\(photos.count)")
        let playback = Playback(photos: photos, library: library, view: slideshow, target: screen.targetPixels)
        self.playback = playback
        frameCount = 0
        playback.seconds = preferences.seconds
        playback.onDisplay = { [weak self] id in
            guard let self else { return }
            record?.photoID = id
            frameCount += 1
            if frameCount == 1 || .now - lastFrameLog >= .seconds(60) {
                lastFrameLog = .now
                appLog.notice("Frames drawn=\(self.frameCount)")
            }
            Task { @MainActor [weak self] in self?.updateControls() }
        }
        playback.onJumpFailure = { [weak self] in
            appLog.notice("Selected photo unavailable; previous frame retained.")
            self?.slideshow?.flash("選んだ写真を読み込めませんでした。")
        }
        playback.onFailure = { [weak self] cloud in self?.showPlaybackFailure(cloud: cloud) }
        playback.setPowerWarning(powerWarning)
        playback.setPanelOpen(slideshow.panel != nil)
        playback.start(after: preferences.fromBeginning ? nil : record?.photoID)
        updateControls()
        refreshVisibility()
    }

    private func showPicker(message: String? = nil) {
        #if SLIDESHOW_QA
        qaTrace("picker \(message ?? "ready")")
        #endif
        guard !currentAlbums.isEmpty else {
            let empty = "システム写真ライブラリに選べるアルバムが見つかりません。\n「写真」でアルバムを確認してください。"
            showMessage([message, empty].compactMap { $0 }.joined(separator: "\n"))
            return
        }
        guard let window = createWindow(mode: .picker, size: CGSize(width: 510, height: 390)) else { return }
        let picker = AlbumPicker()
        self.picker = picker
        picker.show(currentAlbums, message: pickerMessage(message))
        picker.choose = { [weak self] album in self?.choose(album) }
        wireReturn(picker.returnButton, in: window)
        window.contentView = picker.view
        window.initialFirstResponder = picker.table
        showFront(window)
    }

    private func pickerMessage(_ message: String?) -> String? {
        let warning: String? = settingsWarning ? "アルバムを記憶できませんでした。" : nil
        let lines = [message, warning].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func choose(_ album: Album) {
        guard mode == .picker, !exiting, checkAuthorization() else { return }
        if record?.albumID != album.id {
            record = positions.record(for: sourceKey, album: album.id) ?? PlaybackRecord(albumID: album.id, photoID: nil)
        }
        if let record {
            positions.update(record, source: sourceKey)
            data.save(positions) { [weak self] success in self?.settingsWarning = !success }
        }
        startup?.cancel()
        startup = Task { [weak self] in await self?.openAlbum(album.id, initial: false) }
    }

    private func showMessage(_ message: String) {
        #if SLIDESHOW_QA
        qaTrace("message \(message.components(separatedBy: "\n")[0])")
        #endif
        guard let window = createWindow(mode: .preparation, size: CGSize(width: 510, height: 185)) else { return }
        let body = NSTextField(wrappingLabelWithString: message)
        body.font = .systemFont(ofSize: 15)
        let button = ReturnButton(title: returnTitle, target: nil, action: nil)
        wireReturn(button, in: window)
        let view = NSView()
        for item in [body, button] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            body.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            button.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            button.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18)
        ])
        window.contentView = view
        window.initialFirstResponder = button
        showFront(window)
    }

    private func showPlayback() {
        guard let window = createWindow(mode: .playback, size: .zero) else { return }
        let slideshow = SlideshowView()
        self.slideshow = slideshow
        slideshow.applyPreferences(preferences)
        wireReturn(slideshow.returnButton, in: window)
        slideshow.favoriteStatus.perform = { [weak self] in
            guard let self, slideshowIsPlaying, let index = playback?.displayedIndex else { return }
            changeFavorite(at: index, action: .add)
        }
        window.contentView = slideshow
        window.acceptsMouseMovedEvents = true
        slideshow.previousButton.perform = { [weak self] in self?.move(-1) }
        slideshow.nextButton.perform = { [weak self] in self?.move(1) }
        slideshow.pauseButton.perform = { [weak self] in self?.togglePause() }
        slideshow.listButton.perform = { [weak self] in self?.openPhotoList() }
        slideshow.settingsButton.perform = { [weak self] in self?.openPreferences() }
        slideshow.displayedRevision = { [weak self] in self?.playback?.displayedRevision }
        slideshow.toggleFavorite = { [weak self] in
            guard let self, let index = playback?.displayedIndex else { return }
            changeFavorite(at: index, action: .toggle)
        }
        window.handleWheel = { [weak self] event in self?.handleWheel(event) ?? false }
        window.handleLeftClick = { [weak slideshow] event in slideshow?.handlePhotoClick(event) }
        if let screen = targetScreen { apply(screen) }
        showPlaybackStatus(loading: true)
        showFront(window)
        refreshVisibility()
    }

    private func showPlaybackFailure(cloud: Bool) {
        appLog.error("Playback exhausted image candidates; cloudOrTimeout=\(cloud); frames=\(self.frameCount)")
        #if SLIDESHOW_QA
        qaTrace("failure \(cloud)")
        #endif
        mode = .playbackError
        playback?.stop()
        playback = nil
        var message = "このアルバムの写真を読み込めませんでした。"
        if cloud { message += "\niCloudの写真を読み込めるか、通信状態を確認してください。" }
        if settingsWarning { message += "\nアルバムを記憶できませんでした。" }
        slideshow?.installPanel(nil)
        slideshow?.settingsButton.isEnabled = false
        updateControls()
        slideshow?.showStatus(loading: false, message: message)
        power.release(reason: "playback error")
    }

    private func createWindow(mode: ScreenMode, size: CGSize) -> SlideshowWindow? {
        guard !exiting, let screen = targetScreen else { return nil }
        let previousWindow = window
        playback?.stop()
        playback = nil
        slideshow = nil
        picker = nil
        power.release(reason: "window transition to " + mode.rawValue)
        lastPowerAttempt = nil
        lastWindowState = nil
        powerWarning = false
        self.mode = mode

        let full = mode == .playback
        let rect = full ? screen.frame : Self.centered(size, in: screen.visibleFrame)
        let window = SlideshowWindow(contentRect: rect,
                                     styleMask: full ? .borderless : [.titled, .closable],
                                     backing: .buffered, defer: false)
        window.title = "写真スライドショー"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace, .canJoinAllApplications]
        window.level = full ? .statusBar : .floating
        window.backgroundColor = full ? .black : .windowBackgroundColor
        window.isOpaque = true
        window.hasShadow = !full
        window.handleKey = { [weak self] key, repeatEvent in
            self?.handleKey(key, repeatEvent: repeatEvent) ?? false
        }
        previousWindow?.delegate = nil
        previousWindow?.orderOut(nil)
        self.window = window
        return window
    }

    private static func centered(_ size: CGSize, in frame: CGRect) -> CGRect {
        let width = min(size.width, frame.width)
        let height = min(size.height, frame.height)
        return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    private func apply(_ screen: NSScreen) {
        guard let window else { return }
        if mode == .playback || mode == .playbackError {
            window.setFrame(screen.frame, display: true)
            slideshow?.useInsets(screen.safeAreaInsets)
            playback?.setTarget(screen.targetPixels)
        } else {
            let size = mode == .picker ? CGSize(width: 510, height: 390) : CGSize(width: 510, height: 185)
            window.setFrame(Self.centered(size, in: screen.visibleFrame), display: true)
        }
    }

    private func showFront(_ window: SlideshowWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func wireReturn(_ button: NSButton, in window: SlideshowWindow) {
        button.target = self
        button.action = #selector(returnToPreviousScreen)
        button.setAccessibilityLabel(returnTitle)
        window.returnButton = button
    }

    private func handleKey(_ key: WindowKey, repeatEvent: Bool) -> Bool {
        if let editor = slideshow?.panel as? LayoutEditor {
            if key == .escape && !repeatEvent { editor.finish.perform?() }
            return true
        }
        if key == .escape {
            if !repeatEvent { beginExit(reason: "Escape") }
            return true
        }
        guard mode == .playback, slideshow?.panel == nil else { return false }
        if !repeatEvent {
            switch key {
            case .escape: break
            case .pause: togglePause()
            case .previous: move(-1)
            case .next: move(1)
            }
        }
        return true
    }

    private func move(_ direction: Int) {
        guard slideshow?.panel == nil else { return }
        playback?.move(direction)
    }

    private func togglePause() {
        guard slideshow?.panel == nil else { return }
        playback?.togglePause()
        updateControls()
    }

    private var favoriteIDs: Set<String> {
        Set(favorites.lazy.filter { $0.source == self.sourceKey }.map(\.photoID))
    }

    private func handleWheel(_ event: NSEvent) -> Bool {
        if slideshow?.panel is LayoutEditor { return true }
        guard mode == .playback, slideshow?.panel == nil, playback != nil else {
            wheel = WheelNavigation()
            return false
        }
        guard event.momentumPhase.isEmpty else { return true }
        if event.phase.contains(.began) || event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            wheel.resetGesture()
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { return true }
        let precise = event.hasPreciseScrollingDeltas
        let lines = event.cgEvent?.getIntegerValueField(.scrollWheelEventDeltaAxis1) ?? 0
        let delta = WheelNavigation.verticalDelta(scrolling: event.scrollingDeltaY, lines: lines,
                                                  precise: precise, inverted: event.isDirectionInvertedFromDevice)
        if NSEvent.pressedMouseButtons & 1 != 0 {
            if slideshow?.zoom(for: event, delta: delta) == true { playback?.zoomDidChange() }
            wheel.resetGesture()
            return true
        }
        if let direction = wheel.step(delta: delta, time: event.timestamp, precise: precise,
                                      phased: !event.phase.isEmpty) {
            move(direction)
        }
        return true
    }

    private var displayedPhotoID: String? {
        guard let playback, let index = playback.displayedIndex else { return nil }
        return playback.photos[index].id
    }

    private func updateControls() {
        slideshow?.updateControls(paused: playback?.paused ?? false,
                                  ready: playback != nil && slideshow?.panel == nil)
        let displayedID = displayedPhotoID
        let favorite = favorites.contains { $0.source == sourceKey && $0.photoID == displayedID }
        slideshow?.setFavoriteStatus(favorite, revision: playback?.displayedRevision)
        slideshow?.favoriteStatus.isEnabled = slideshowIsPlaying && displayedID != nil && favoriteWrite == nil
        if favoriteWrite != nil { slideshow?.listButton.isEnabled = false }
        (slideshow?.panel as? PhotosPanel)?.setRemovalEnabled(favoriteWrite == nil)
    }

    private func closePanel() {
        window?.makeFirstResponder(nil)
        slideshow?.installPanel(nil)
        playback?.setPanelOpen(false)
        updateControls()
    }

    private func openPhotoList() {
        guard let slideshow, slideshow.panel == nil, let playback else { return }
        let panel = PhotosPanel(source: library, photos: playback.photos, favorites: favoriteIDs,
                                current: playback.displayedIndex)
        panel.close.perform = { [weak self] in self?.closePanel() }
        panel.removeFavorite = { [weak self] index in self?.changeFavorite(at: index, action: .remove) }
        panel.choose = { [weak self, weak playback] index in
            playback?.jump(to: index)
            self?.closePanel()
        }
        playback.setPanelOpen(true)
        slideshow.installPanel(panel)
        slideshow.layoutSubtreeIfNeeded()
        panel.layoutSubtreeIfNeeded()
        panel.selectCurrent()
        window?.makeFirstResponder(panel.grid)
        updateControls()
    }

    private func openPreferences() {
        guard let slideshow, slideshow.panel == nil else { return }
        let panel = PreferencesPanel(preferences)
        panel.preview = { [weak slideshow] value in slideshow?.applyPreferences(value) }
        panel.editLayout.perform = { [weak self, weak panel, weak slideshow] in
            guard let self, let panel, preferencesWrite == nil else { return }
            let editor = LayoutEditor(panel.previewValue())
            editor.changed = { [weak slideshow] value in slideshow?.applyPreferences(value) }
            editor.finish.perform = { [weak self, weak editor, panel] in
                guard let self, let editor else { return }
                panel.updateLayoutDraft(editor.options)
                self.slideshow?.installPanel(panel)
                self.slideshow?.applyPreferences(panel.previewValue())
                self.window?.makeFirstResponder(nil)
                self.updateControls()
            }
            window?.makeFirstResponder(nil)
            self.slideshow?.installPanel(editor)
            self.slideshow?.applyPreferences(editor.options)
            updateControls()
        }
        panel.save.perform = { [weak self, weak panel] in
            guard let self, let panel, preferencesWrite == nil, let value = panel.value else { return }
            panel.save.isEnabled = false
            preferencesWrite = Task { [weak self, weak panel] in
                guard let self else { return }
                let saved = await data.savePreferences(value)
                preferencesWrite = nil
                if saved {
                    preferences = value
                    self.slideshow?.applyPreferences(value)
                    playback?.seconds = value.seconds
                    if !exiting { closePanel() }
                } else {
                    panel?.error.stringValue = "設定を保存できませんでした。"
                    panel?.save.isEnabled = true
                }
            }
        }
        playback?.setPanelOpen(true)
        slideshow.installPanel(panel)
        window?.makeFirstResponder(nil)
        updateControls()
    }

    private var slideshowIsPlaying: Bool { mode == .playback && slideshow?.panel == nil }

    private enum FavoriteAction { case toggle, add, remove }

    private func changeFavorite(at index: Int, action: FavoriteAction) {
        guard favoriteWrite == nil, let playback, playback.photos.indices.contains(index), let record else { return }
        let photo = playback.photos[index]
        let existing = favorites.firstIndex { $0.source == sourceKey && $0.photoID == photo.id }
        if action == .add && existing != nil || action == .remove && existing == nil { return }
        let add = existing == nil
        let clickedRevision = action == .toggle ? playback.displayedRevision : nil
        guard favoritesReadable else {
            slideshow?.flash("お気に入りを読み込めなかったため保存できません。")
            return
        }
        let albumTitle = currentAlbums.first { $0.id == record.albumID }?.title
        let timestamp = Date()
        favoriteWrite = Task { [weak self] in
            guard let self else { return }
            var updated = favorites
            if let saved = existing {
                updated.remove(at: saved)
            } else {
                let resources = await library.resources(for: photo)
                updated.append(Favorite(source: sourceKey, albumID: record.albumID, albumTitle: albumTitle,
                                        photoID: photo.id, added: timestamp, position: index + 1,
                                        captured: photo.date, modified: photo.modified, pixelWidth: photo.width,
                                        pixelHeight: photo.height, resources: resources))
            }
            if await data.saveFavorites(updated) {
                favorites = updated
                if !exiting {
                    (slideshow?.panel as? PhotosPanel)?.updateFavorites(favoriteIDs)
                    if add {
                        let currentRevision = displayedPhotoID == photo.id ? self.playback?.displayedRevision : nil
                        if let currentRevision {
                            slideshow?.setFavoriteStatus(true, revision: currentRevision)
                        }
                        slideshow?.showFavoriteConfirmation(revision: currentRevision)
                    } else {
                        let currentRevision = displayedPhotoID == photo.id ? self.playback?.displayedRevision : nil
                        slideshow?.showFavoriteRemoval(fallFrom: currentRevision ?? clickedRevision)
                    }
                }
            } else {
                slideshow?.flash("お気に入りを保存できませんでした。")
            }
            favoriteWrite = nil
            updateControls()
        }
        updateControls()
    }

    private func refreshVisibility(reason: String = "playback window ready") {
        guard !exiting, mode == .playback, let window, slideshow != nil else { return }
        let usableSession = sessionActive && systemAwake && displayAwake && !screenLocked
        let occlusionVisible = window.occlusionState.contains(.visible)
        let draw = usableSession && window.isVisible && occlusionVisible
        let state = "active=\(sessionActive) locked=\(screenLocked) awake=\(systemAwake) " +
            "displayAwake=\(displayAwake) windowVisible=\(window.isVisible) occlusionVisible=\(occlusionVisible)"
        if state != lastWindowState {
            lastWindowState = state
            appLog.notice("Playback visibility reason=\(reason, privacy: .public) \(state, privacy: .public)")
        }

        // A window can be briefly occluded while playback still owns an unlocked session.
        if usableSession {
            if !power.isHeld, lastPowerAttempt.map({ .now - $0 >= .seconds(10) }) ?? true {
                lastPowerAttempt = .now
                let warning = !power.prevent(reason: reason)
                if powerWarning != warning {
                    powerWarning = warning
                    if let playback { playback.setPowerWarning(warning) }
                    else { showPlaybackStatus(loading: true) }
                }
            }
        } else {
            lastPowerAttempt = nil
            power.release(reason: reason)
        }
        playback?.setVisible(draw)
    }

    private func showPlaybackStatus(loading: Bool) {
        slideshow?.showStatus(loading: loading, message: settingsWarning ? "アルバムを記憶できませんでした。" : nil,
                              powerWarning: powerWarning)
    }

    @objc private func returnToPreviousScreen() {
        guard !(slideshow?.panel is LayoutEditor) else { return }
        beginExit(reason: "return button")
    }

    private func beginExit(reason: String) {
        guard !exiting else { return }
        exiting = true
        appLog.notice("Playback app exit route=\(reason, privacy: .public) mode=\(self.mode.rawValue, privacy: .public) frames=\(self.frameCount)")
        let returnTarget = NSApp.isActive ? previousApplication : nil

        startup?.cancel()
        authorizationMonitor?.cancel()
        playback?.stop()
        power.release(reason: reason)
        window?.orderOut(nil)
        if let target = returnTarget, !target.isTerminated {
            let own = NSRunningApplication.current
            NSApp.yieldActivation(to: target)
            let accepted = target.activate(from: own, options: [])
            appLog.notice("Exit activation accepted=\(accepted)")
        }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        lockObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        lockObservers.removeAll()

        saveDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            appLog.error("Settings write reached the exit deadline.")
            self?.finishExit()
        }
        Task { [weak self] in
            guard let self else { return }
            await preferencesWrite?.value
            await favoriteWrite?.value
            if let record {
                positions.update(record, source: sourceKey)
                data.save(positions) { [weak self] _ in self?.finishExit() }
            } else {
                finishExit()
            }
        }
    }

    private func finishExit() {
        guard !readyToTerminate else { return }
        readyToTerminate = true
        saveDeadline?.cancel()
        if systemIsWaiting { NSApp.reply(toApplicationShouldTerminate: true) }
        else { NSApp.terminate(nil) }
    }
}

private extension NSScreen {
    var displayID: UInt32? { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }

    var targetPixels: CGSize {
        CGSize(width: ceil((frame.width - safeAreaInsets.left - safeAreaInsets.right) * backingScaleFactor),
               height: ceil((frame.height - safeAreaInsets.top - safeAreaInsets.bottom) * backingScaleFactor))
    }
}
