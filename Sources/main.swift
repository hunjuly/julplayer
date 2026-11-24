import AppKit
import SwiftUI

private extension NSToolbarItem.Identifier {
    static let filename = Self("filename")
    static let pip = Self("pip")
    static let pin = Self("pin")
    static let playlist = Self("playlist")
}

@MainActor
private final class PlayerWindow: NSWindow {
    private(set) var mouseDownLocation: CGPoint?

    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.24 }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            (contentView as? PlayerHost)?.pointerMoved(with: event)
        default: break
        }
        if event.type == .scrollWheel, let host = contentView as? PlayerHost, host.adjustVolume(for: event) { return }
        if event.type == .leftMouseDown { mouseDownLocation = convertPoint(toScreen: event.locationInWindow) }
        super.sendEvent(event)
        if event.type == .leftMouseUp { mouseDownLocation = nil }
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let view = responder as? NSView, !(view is NSTextView), attachedSheet == nil {
            view.focusRingType = .none
        }
        return super.makeFirstResponder(responder)
    }
}

@MainActor
private final class PlayerHost: NSHostingView<PlayerView> {
    private var session: PlayerSession { rootView.session }
    private var lastPointerLocation = NSEvent.mouseLocation
    override var acceptsFirstResponder: Bool { true }

    func pointerMoved(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        defer { lastPointerLocation = point }
        guard point != lastPointerLocation, let window, event.window === window,
              window.isVisible, !window.isMiniaturized, window.frame.contains(point),
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        session.pointerMoved()
    }

    func adjustVolume(for event: NSEvent) -> Bool {
        guard session.loaded, !session.pipActive, session.panel == nil, window?.attachedSheet == nil,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              event.momentumPhase.isEmpty, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return false }
        if session.showsPlaylist {
            guard PlayerWindowLayout.fitsSidebar(in: bounds.width),
                  point.x < bounds.maxX - PlayerWindowLayout.playlistSpan else { return false }
        }
        let fingerDelta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        let change = event.hasPreciseScrollingDeltas ? fingerDelta / 250 : min(1, max(-1, fingerDelta)) * 0.10
        session.adjustVolume(by: change)
        return true
    }

    private func files(from sender: NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL] ?? []).filter { LocalMedia.isVideo($0) || LocalMedia.isSubtitle($0) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = files(from: sender)
        if urls.contains(where: LocalMedia.isVideo) { session.dropHint = "놓아서 동영상 재생" }
        else if session.current != nil && !urls.isEmpty { session.dropHint = "놓아서 자막 열기" }
        else { session.dropHint = nil }
        return session.dropHint == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { session.dropHint = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        session.dropHint = nil
        let urls = files(from: sender)
        guard !urls.isEmpty, session.current != nil || urls.contains(where: LocalMedia.isVideo) else { return false }
        session.openMedia(urls)
        return true
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSWindowDelegate, NSMenuItemValidation {
    let session = PlayerSession()
    private var window: PlayerWindow!
    private let filename = NSTextField(labelWithString: "")
    private var events: Any?
    private var pipItem: NSToolbarItem?
    private var pinItem: NSToolbarItem?
    private var playlistItem: NSToolbarItem?
    private var pendingURLs = [URL]()
    private var ready = false
    private var associatingFiles = false
    private let frameSizeKey = "playerWindowFrameSize"
    private var changingFullScreen = false
    private var cursorHiddenForPlayback = false
    private var requestedSize: (preset: WindowSizePreset, selection: UUID?)?
    private var needsVideoHeight = false
    private var resizingWindow = false
    private var videoDrag: VideoWindowDrag?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        installMenus()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(1040, screen.width * 0.83, max(640, (screen.height - 135) * 16 / 9))
        window = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: width * 9 / 16),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.delegate = self
        session.window = window
        window.title = ""
        window.titleVisibility = .hidden
        filename.font = .systemFont(ofSize: 13, weight: .semibold)
        filename.lineBreakMode = .byTruncatingMiddle
        // Let AppKit shrink the filename before moving buttons into the overflow menu.
        let flexible = NSLayoutConstraint.Priority(rawValue: 1)
        filename.setContentCompressionResistancePriority(flexible, for: .horizontal)
        filename.setContentHuggingPriority(flexible, for: .horizontal)
        filename.widthAnchor.constraint(greaterThanOrEqualToConstant: 1).isActive = true
        window.toolbarStyle = .unifiedCompact
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.backgroundColor = NSColor(white: 0.075, alpha: 1)
        let toolbar = NSToolbar(identifier: "playerToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.delegate = self
        window.toolbar = toolbar

        let host = PlayerHost(rootView: PlayerView(session: session))
        host.sizingOptions = []
        host.focusRingType = .none
        host.registerForDraggedTypes([.fileURL])
        window.contentView = host
        window.contentMinSize = PlayerWindowLayout.minimumContent
        window.initialFirstResponder = host
        window.setContentSize(NSSize(width: width, height: width * 9 / 16))
        window.center()
        if let saved = UserDefaults.standard.string(forKey: frameSizeKey) {
            let size = NSSizeFromString(saved)
            if size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
                window.setFrame(centeredFrame(size: size, within: screen), display: true)
            }
        }
        session.selectionDidChange = { [weak self] in
            guard let self else { return }
            self.needsVideoHeight = false
            if let request = self.requestedSize, request.preset != .minimum, request.selection != self.session.selection {
                self.requestedSize = nil
            }
            self.updateTitle()
        }
        session.videoSizeDidChange = { [weak self] in
            self?.needsVideoHeight = true
            self?.applyWindowSize()
        }
        session.windowStateChanged = { [weak self] in self?.updateWindowState() }
        ready = true
        session.start(opening: pendingURLs)
        pendingURLs.removeAll()
        updateTitle()
        updateWindowState()
        installShortcuts()
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(host)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillResignActive(_ notification: Notification) { setPlaybackCursorHidden(false) }
    func windowDidResignKey(_ notification: Notification) { setPlaybackCursorHidden(false) }
    func windowDidBecomeKey(_ notification: Notification) { updateWindowState() }
    func windowWillClose(_ notification: Notification) { session.setPlaying(false) }
    func windowDidDeminiaturize(_ notification: Notification) {
        if session.pipActive { session.pip?.stop() }
        applyWindowSize()
    }
    func windowWillStartLiveResize(_ notification: Notification) {
        // AppKit also sends live-resize notifications during a full-screen transition.
        if !resizingWindow && !changingFullScreen && !window.styleMask.contains(.fullScreen) {
            requestedSize = nil
            session.smallPictureSize = nil
            videoDrag = VideoWindowDrag(video: session.videoDisplaySize,
                                        content: window.contentRect(forFrameRect: window.frame).size,
                                        frame: window.frame, pointer: window.mouseDownLocation ?? NSEvent.mouseLocation)
            if let video = session.videoDisplaySize, !session.showsPlaylist { window.contentAspectRatio = video }
        }
    }
    func windowWillResize(_ sender: NSWindow, to proposedFrame: NSSize) -> NSSize {
        guard let videoDrag, !resizingWindow, !changingFullScreen, !sender.styleMask.contains(.fullScreen),
              let screen = sender.screen ?? NSScreen.main else { return proposedFrame }
        let proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: proposedFrame)).size
        let available = sender.contentRect(forFrameRect: screen.visibleFrame).size
        let size = videoDrag.contentSize(proposed: proposed, available: available, showsPlaylist: session.showsPlaylist)
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        // Setting unrestricted resize increments clears AppKit's temporary aspect constraint.
        if window.contentAspectRatio != .zero { window.contentResizeIncrements = CGSize(width: 1, height: 1) }
        videoDrag = nil
        rememberWindowSize()
        if needsVideoHeight || requestedSize != nil {
            DispatchQueue.main.async { [weak self] in self?.applyWindowSize() }
        }
    }
    func windowDidResize(_ notification: Notification) {
        if let window, !window.inLiveResize { rememberWindowSize() }
    }
    func windowWillEnterFullScreen(_ notification: Notification) {
        rememberWindowSize()
        changingFullScreen = true
    }
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        proposedOptions.subtracting(.autoHideToolbar)
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        changingFullScreen = true
        setPlaybackCursorHidden(false)
    }
    func windowDidEnterFullScreen(_ notification: Notification) { finishFullScreenTransition() }
    func windowDidExitFullScreen(_ notification: Notification) { finishFullScreenTransition() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { finishFullScreenTransition() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        if window.styleMask.contains(.fullScreen) { requestedSize = nil }
        finishFullScreenTransition()
    }

    private func finishFullScreenTransition() {
        // AppKit finishes restoring the window and its toolbar after the delegate returns.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.changingFullScreen else { return }
            self.changingFullScreen = false
            self.applyWindowSize()
            self.updateWindowState()
            self.session.pip?.fullScreenTransitionFinished()
        }
    }

    private func rememberWindowSize() {
        guard ready, !resizingWindow, !changingFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromSize(window.frame.size), forKey: frameSizeKey)
    }

    private func centeredFrame(size: CGSize, within screen: CGRect) -> CGRect {
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        return PlayerWindowLayout.frame(of: size, centeredAt: center, within: screen)
    }

    private func requestSize(_ preset: WindowSizePreset) {
        guard preset == .minimum || session.current != nil else { return }
        requestedSize = (preset, session.selection)
        applyWindowSize()
    }

    private func applyWindowSize() {
        guard requestedSize != nil || needsVideoHeight, !changingFullScreen, !resizingWindow else { return }
        if window.styleMask.contains(.fullScreen) {
            if requestedSize != nil {
                changingFullScreen = true
                window.toggleFullScreen(nil)
            }
            return
        }
        guard !window.isMiniaturized, !window.inLiveResize, let screen = window.screen ?? NSScreen.main else { return }
        let available = window.contentRect(forFrameRect: screen.visibleFrame).size
        let target: CGRect
        if let request = requestedSize {
            guard let size = PlayerWindowLayout.dimensions(for: request.preset, videoPixels: session.videoDisplaySize,
                                                          backingScale: window.backingScaleFactor, available: available,
                                                          showsPlaylist: session.showsPlaylist) else { return }
            let frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size.content))
            target = centeredFrame(size: frame.size, within: screen.visibleFrame)
            session.smallPictureSize = size.smallPicture
            session.showFeedback(request.preset.menuTitle)
        } else {
            guard let video = session.videoDisplaySize, video.width > 0, video.height > 0 else { return }
            let current = window.frame
            var content = window.contentRect(forFrameRect: current)
            let sidebar = session.showsPlaylist && PlayerWindowLayout.fitsSidebar(in: content.width) ? PlayerWindowLayout.playlistSpan : 0
            let height = ((content.width - sidebar) * video.height / video.width).rounded()
            content.size.height = min(available.height, max(PlayerWindowLayout.minimumContent.height, height))
            let frameHeight = window.frameRect(forContentRect: content).height
            let y = min(max(screen.visibleFrame.minY, current.maxY - frameHeight), screen.visibleFrame.maxY - frameHeight)
            target = CGRect(x: current.minX, y: y, width: current.width, height: frameHeight)
        }
        requestedSize = nil
        needsVideoHeight = false
        guard target != window.frame else { return }
        resizingWindow = true
        window.setFrame(target, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        resizingWindow = false
        rememberWindowSize()
        if needsVideoHeight || requestedSize != nil {
            DispatchQueue.main.async { [weak self] in self?.applyWindowSize() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        setPlaybackCursorHidden(false)
        rememberWindowSize()
        if let events { NSEvent.removeMonitor(events) }
        window?.delegate = nil
        session.finish()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if ready {
            session.openMedia(urls)
            if !session.pipActive { window.makeKeyAndOrderFront(nil) }
        } else { pendingURLs = urls }
    }
    private func updateWindowState() {
        guard let window else { return }
        let visible = session.controlsVisible
        if window.toolbar?.isVisible != visible { window.toolbar?.isVisible = visible }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = !visible
        }
        let floating = session.pinWhenPlaying && session.playing && !session.pipActive && !window.styleMask.contains(.fullScreen)
        window.level = floating ? .floating : .normal
        pipItem?.image = NSImage(systemSymbolName: session.pipActive ? "pip.exit" : "pip.enter", accessibilityDescription: "화면 속 화면")
        pinItem?.image = NSImage(systemSymbolName: session.pinWhenPlaying ? "pin.fill" : "pin", accessibilityDescription: "재생 중 항상 위")
        pinItem?.toolTip = session.pinWhenPlaying ? "재생 중 항상 위 끄기" : "재생 중 항상 위 켜기"
        playlistItem?.toolTip = session.showsPlaylist ? "재생목록 닫기 (L)" : "재생목록 보기 (L)"
        let hideCursor = !visible && !session.pipActive && !changingFullScreen && !session.showsPlaylist && session.panel == nil
            && window.styleMask.contains(.fullScreen) && window.isKeyWindow && NSApp.isActive
            && window.attachedSheet == nil && window.frame.contains(NSEvent.mouseLocation)
        setPlaybackCursorHidden(hideCursor)
    }

    private func setPlaybackCursorHidden(_ hidden: Bool) {
        guard hidden != cursorHiddenForPlayback else { return }
        cursorHiddenForPlayback = hidden
        NSCursor.setHiddenUntilMouseMoves(hidden)
    }

    private func updateTitle() {
        window.title = session.current?.url.lastPathComponent ?? ""
        filename.stringValue = window.title
        filename.toolTip = window.title
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.filename, .flexibleSpace, .pip, .pin, .playlist]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case .filename:
            item.view = filename
            item.visibilityPriority = .low
            item.isBordered = false
        case .pip:
            item.label = "화면 속 화면"
            item.toolTip = "화면 속 화면 (P)"
            item.image = NSImage(systemSymbolName: "pip.enter", accessibilityDescription: item.label)
            item.target = self; item.action = #selector(togglePiP)
            pipItem = item
        case .pin:
            item.label = "재생 중 항상 위"
            item.image = NSImage(systemSymbolName: "pin", accessibilityDescription: item.label)
            item.toolTip = "재생 중 항상 위 켜기"
            item.target = self; item.action = #selector(togglePin)
            pinItem = item
        case .playlist:
            item.label = "재생목록"
            item.toolTip = "재생목록 보기 (L)"
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(togglePlaylist)
            playlistItem = item
        default: return nil
        }
        return item
    }

    private func installMenus() {
        let bar = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let top = NSMenuItem()
            let child = NSMenu(title: title)
            top.submenu = child
            bar.addItem(top)
            return child
        }
        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "",
                 modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            return item
        }
        let app = menu("JulPlayer")
        add(app, "JulPlayer 정보", #selector(about), target: self)
        app.addItem(.separator())
        add(app, "JulPlayer 가리기", #selector(NSApplication.hide(_:)), key: "h", target: NSApp)
        add(app, "JulPlayer 종료", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)
        let file = menu("파일")
        add(file, "동영상 열기…", #selector(openFiles), key: "o", target: self)
        add(file, "현재 영상과 자막 삭제…", #selector(deleteFile), key: "\u{8}", modifiers: [], target: self)
        add(file, "현재 영상과 자막 바로 삭제", #selector(deleteFileImmediately), key: "\u{8}", target: self)
        let associationItem = NSMenuItem(title: "기본 플레이어로 연결", action: nil, keyEquivalent: "")
        let formats = NSMenu(title: associationItem.title)
        add(formats, "모든 동영상 형식 연결", #selector(associate(_:)), target: self).representedObject = VideoFileFormat.supported
        formats.addItem(.separator())
        for format in VideoFileFormat.supported {
            for ext in format.extensions {
                add(formats, ext.uppercased(), #selector(associate(_:)), target: self).representedObject = [format]
            }
        }
        associationItem.submenu = formats; file.addItem(associationItem)
        file.addItem(.separator())
        add(file, "창 닫기", #selector(NSWindow.performClose(_:)), key: "w")
        let play = menu("재생")
        add(play, "재생 / 일시 정지", #selector(togglePlay), key: " ", modifiers: [], target: self)
        add(play, "이전 파일", #selector(previousFile), key: "\u{F702}", target: self)
        add(play, "다음 파일", #selector(nextFile), key: "\u{F703}", target: self)
        add(play, "10초 뒤로", #selector(backward), target: self)
        add(play, "10초 앞으로", #selector(forward), target: self)
        add(play, "60초 뒤로", #selector(back60), key: "\u{F702}", modifiers: [.option], target: self)
        add(play, "60초 앞으로", #selector(forward60), key: "\u{F703}", modifiers: [.option], target: self)
        play.addItem(.separator())
        let brightnessItem = play.addItem(withTitle: "영상 밝기", action: nil, keyEquivalent: "")
        let brightnessMenu = NSMenu(title: brightnessItem.title)
        let brightnessSlider = NSMenuItem()
        let brightnessView = NSHostingView(rootView: BrightnessPanel(session: session))
        brightnessView.frame.size = brightnessView.fittingSize
        brightnessSlider.view = brightnessView
        brightnessMenu.addItem(brightnessSlider)
        brightnessItem.submenu = brightnessMenu
        add(play, "음소거 전환", #selector(toggleMute), key: "m", modifiers: [], target: self)
        add(play, "자막 켜기 / 끄기", #selector(toggleCaptions), key: "c", modifiers: [], target: self)
        add(play, "오디오 스트림 및 싱크…", #selector(audioPanel), target: self)
        add(play, "자막 스트림 및 싱크…", #selector(subtitlePanel), target: self)
        let sizeItem = play.addItem(withTitle: "자막 크기", action: nil, keyEquivalent: "")
        let sizes = NSMenu(title: sizeItem.title)
        for size in SubtitleSize.allCases {
            add(sizes, size.title, #selector(chooseSubtitleSize(_:)), target: self).representedObject = size
        }
        sizeItem.submenu = sizes
        let view = menu("보기")
        for preset in WindowSizePreset.allCases {
            let item = view.addItem(withTitle: preset.menuTitle, action: #selector(chooseWindowSize(_:)),
                                    keyEquivalent: preset == .minimum ? "" : String(preset.rawValue))
            item.keyEquivalentModifierMask = []
            item.tag = preset.rawValue
            item.target = self
        }
        view.addItem(.separator())
        add(view, "재생목록 전환", #selector(togglePlaylist), key: "l", modifiers: [], target: self)
        add(view, "전체 화면 전환", #selector(fullScreen), key: "f", modifiers: [.control, .command], target: self)
        add(view, "재생 중 항상 위", #selector(togglePin), target: self)
        add(view, "화면 속 화면", #selector(togglePiP), key: "p", modifiers: [], target: self)
        let windows = menu("윈도우")
        add(windows, "최소화", #selector(NSWindow.performMiniaturize(_:)), key: "m")
        add(windows, "확대 / 축소", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = windows
        NSApp.mainMenu = bar
    }

    private func installShortcuts() {
        events = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window.attachedSheet == nil, self.session.panel == nil else { return event }
            if self.window.firstResponder is NSTextView { return event }
            let modifiers = event.modifierFlags.intersection([.command,.option,.control,.shift])
            if modifiers == [.command] {
                let action: () -> Void
                switch event.keyCode {
                case 51, 117: action = self.deleteFileImmediately
                case 123: action = self.previousFile
                case 124: action = self.nextFile
                default: return event
                }
                if !event.isARepeat { action() }
                return nil
            }
            if modifiers == [.option] {
                switch event.keyCode {
                case 123: self.back60()
                case 124: self.forward60()
                default: return event
                }
                return nil
            }
            guard modifiers.isEmpty else { return event }
            if let digits = event.charactersIgnoringModifiers, let key = Int(digits),
               let preset = WindowSizePreset(rawValue: key), preset != .minimum {
                if !event.isARepeat { self.requestSize(preset) }
                return nil
            }
            switch event.keyCode {
            case 51: if !event.isARepeat { self.deleteFile() }
            case 123: self.backward()
            case 124: self.forward()
            case 125: self.session.adjustVolume(by: -0.05)
            case 126: self.session.adjustVolume(by: 0.05)
            case 49: if !event.isARepeat { self.togglePlay() }
            case 46: if !event.isARepeat { self.toggleMute() }
            case 8: if !event.isARepeat { self.toggleCaptions() }
            case 3, 36, 76: if !event.isARepeat { self.fullScreen() }
            case 35: if !event.isARepeat { self.togglePiP() }
            case 37: if !event.isARepeat { self.togglePlaylist() }
            default: return event
            }
            return nil
        }
    }

    @objc private func openFiles() { session.openFiles() }
    @objc private func chooseWindowSize(_ sender: NSMenuItem) {
        if let preset = WindowSizePreset(rawValue: sender.tag) { requestSize(preset) }
    }
    @objc private func togglePlay() {
        if let playing = session.togglePlay() { session.showFeedback(playing ? "재생" : "일시 정지") }
    }
    private func skip(_ seconds: Int) {
        if let position = session.seek(to: session.position + Double(seconds)) {
            session.showFeedback("\(abs(seconds))초 \(seconds < 0 ? "뒤로" : "앞으로") · \(timecode(position))")
        }
    }
    @objc private func backward() { skip(-10) }
    @objc private func forward() { skip(10) }
    @objc private func back60() { skip(-60) }
    @objc private func forward60() { skip(60) }
    @objc private func toggleMute() {
        session.toggleMute()
        session.showFeedback(session.volume == 0 ? "음소거" : "음소거 해제 · 음량 \(session.volumePercent)%")
    }
    @objc private func fullScreen() {
        session.showFeedback(window.styleMask.contains(.fullScreen) ? "창 모드" : "전체 화면")
        window.toggleFullScreen(nil)
    }
    @objc private func toggleCaptions() { session.toggleCaptions() }
    @objc private func chooseSubtitleSize(_ sender: NSMenuItem) {
        if let size = sender.representedObject as? SubtitleSize { session.subtitleSize = size }
    }
    @objc private func audioPanel() { session.panel = .stream(.audio) }
    @objc private func subtitlePanel() { session.panel = .stream(.subtitle) }
    private func stepFile(_ offset: Int) {
        if let clip = session.stepFile(offset) {
            session.showFeedback("\(offset < 0 ? "이전 영상" : "다음 영상") · \(clip.url.lastPathComponent)")
        } else {
            session.showFeedback(offset < 0 ? "첫 번째 영상" : "마지막 영상")
        }
    }
    @objc private func previousFile() { stepFile(-1) }
    @objc private func nextFile() { stepFile(1) }
    @objc private func togglePiP() { session.pip?.toggle() }
    @objc private func togglePin() { session.pinWhenPlaying.toggle() }
    @objc private func deleteFile() { session.deleteCurrent() }
    @objc private func deleteFileImmediately() { session.deleteCurrent(requiresConfirmation: false) }
    @objc private func associate(_ sender: NSMenuItem) {
        guard !associatingFiles, let formats = sender.representedObject as? [VideoFileFormat], !formats.isEmpty else { return }
        associatingFiles = true
        Task {
            defer { associatingFiles = false }
            let result = await VideoFileFormat.associate(formats, with: Bundle.main.bundleURL)
            session.show(result, seconds: 8)
        }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(associate(_:)) { return !associatingFiles }
        if let size = item.representedObject as? SubtitleSize {
            item.state = size == session.subtitleSize ? .on : .off
            return true
        }
        if item.action == #selector(chooseWindowSize(_:)) {
            return window?.isKeyWindow == true && window.attachedSheet == nil && session.panel == nil
                && !(window.firstResponder is NSTextView) && (item.tag == WindowSizePreset.minimum.rawValue || session.current != nil)
        }
        if item.action == #selector(audioPanel) || item.action == #selector(subtitlePanel) { return session.loaded }
        if [#selector(togglePlaylist), #selector(previousFile), #selector(nextFile), #selector(deleteFile), #selector(deleteFileImmediately),
            #selector(back60), #selector(forward60)].contains(item.action) {
            guard window?.isKeyWindow == true, window.attachedSheet == nil, session.panel == nil,
                  !(window.firstResponder is NSTextView) else { return false }
            if item.action == #selector(togglePlaylist) { return true }
            if item.action == #selector(back60) || item.action == #selector(forward60) { return session.loaded }
            if item.action == #selector(previousFile) { return session.adjacent(-1) != nil }
            if item.action == #selector(nextFile) { return session.adjacent(1) != nil }
            return session.current != nil && !session.deletionInProgress
        }
        if item.action == #selector(togglePin) { item.state = session.pinWhenPlaying ? .on : .off }
        if item.action == #selector(togglePiP) { item.state = session.pipActive ? .on : .off; return session.loaded }
        return true
    }
    @objc private func togglePlaylist() {
        session.showsPlaylist.toggle()
        session.showFeedback(session.showsPlaylist ? "재생목록 열림" : "재생목록 닫힘")
    }
    @objc private func about() {
        let credits = NSAttributedString(string: "재생 엔진 · mpv / FFmpeg")
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "JulPlayer", .credits: credits])
    }
}

@main
private enum JulPlayerApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
