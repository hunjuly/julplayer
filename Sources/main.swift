import AppKit
import SwiftUI
import UniformTypeIdentifiers

private extension NSToolbarItem.Identifier {
    static let openFile = Self("openFile")
    static let pin = Self("pin")
    static let pip = Self("pip")
    static let playlist = Self("playlist")
}

@MainActor
private final class PlayerWindow: NSWindow {
    private(set) var mouseDownLocation: CGPoint?

    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.24 }

    override func sendEvent(_ event: NSEvent) {
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
    override var acceptsFirstResponder: Bool { true }

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
        let change = event.hasPreciseScrollingDeltas ? fingerDelta / 500 : min(1, max(-1, fingerDelta)) * 0.05
        session.setVolume(session.volume + change)
        return true
    }

    private func files(from sender: NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL] ?? []).filter { LocalMedia.isVideo($0) || LocalMedia.isSubtitle($0) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        session.dropTarget = !files(from: sender).isEmpty
        return session.dropTarget ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { session.dropTarget = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        session.dropTarget = false
        let urls = files(from: sender)
        session.append(urls)
        return !urls.isEmpty
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSWindowDelegate, NSMenuItemValidation {
    let session = PlayerSession()
    private var window: PlayerWindow!
    private var events: Any?
    private var playlistItem: NSToolbarItem?
    private var pinItem: NSToolbarItem?
    private var pipItem: NSToolbarItem?
    private var pendingURLs = [URL]()
    private var ready = false
    private var updatingToolbar = false
    private let frameSizeKey = "playerWindowFrameSize"
    private var changingFullScreen = false
    private var requestedSize: (preset: WindowSizePreset, selection: UUID?)?
    private var resizingForPreset = false
    private var videoDrag: VideoWindowDrag?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        installMenus()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(1040, screen.width * 0.83, max(640, (screen.height - 135) * 16 / 9))
        window = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: width * 9 / 16),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.delegate = self
        session.window = window
        window.title = ""
        window.toolbarStyle = .unifiedCompact
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
                setWindowFrame(size: size, within: screen)
            }
        }
        session.selectionDidChange = { [weak self] in
            guard let self else { return }
            if let request = self.requestedSize, request.preset != .minimum, request.selection != self.session.selection {
                self.requestedSize = nil
            }
            self.updateTitle()
        }
        session.videoSizeDidChange = { [weak self] in self?.applyRequestedSize() }
        session.windowStateChanged = { [weak self] in self?.updateWindowState() }
        ready = true
        updateToolbar()
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
    func windowWillClose(_ notification: Notification) { session.setPlaying(false) }
    func windowDidDeminiaturize(_ notification: Notification) {
        if session.pipActive { session.pip?.stop() }
    }
    func windowWillStartLiveResize(_ notification: Notification) {
        // AppKit also sends live-resize notifications during a full-screen transition.
        if !resizingForPreset && !changingFullScreen && !window.styleMask.contains(.fullScreen) {
            requestedSize = nil
            session.smallPictureSize = nil
            videoDrag = VideoWindowDrag(video: session.videoDisplaySize,
                                        content: window.contentRect(forFrameRect: window.frame).size,
                                        frame: window.frame, pointer: window.mouseDownLocation ?? NSEvent.mouseLocation)
            if let video = session.videoDisplaySize, !session.showsPlaylist { window.contentAspectRatio = video }
        }
    }
    func windowWillResize(_ sender: NSWindow, to proposedFrame: NSSize) -> NSSize {
        guard let videoDrag, !resizingForPreset, !changingFullScreen, !sender.styleMask.contains(.fullScreen),
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
    }
    func windowDidResize(_ notification: Notification) {
        if ready && !changingFullScreen && !resizingForPreset { updateToolbar() }
        if let window, !window.inLiveResize { rememberWindowSize() }
    }
    func windowWillEnterFullScreen(_ notification: Notification) {
        rememberWindowSize()
        changingFullScreen = true
    }
    func windowWillExitFullScreen(_ notification: Notification) { changingFullScreen = true }
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
            self.applyRequestedSize()
            self.updateToolbar()
            self.updateWindowState()
            self.session.reveal()
            self.session.pip?.fullScreenTransitionFinished()
        }
    }

    private func rememberWindowSize() {
        guard ready, !resizingForPreset, !changingFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromSize(window.frame.size), forKey: frameSizeKey)
    }

    private func setWindowFrame(size: CGSize, within screen: CGRect, animated: Bool = false) {
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let frame = PlayerWindowLayout.frame(of: size, centeredAt: center, within: screen)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func requestSize(_ preset: WindowSizePreset) {
        guard preset == .minimum || session.current != nil else { return }
        requestedSize = (preset, session.selection)
        applyRequestedSize()
    }

    private func applyRequestedSize() {
        guard let request = requestedSize, !changingFullScreen else { return }
        if window.styleMask.contains(.fullScreen) {
            changingFullScreen = true
            window.toggleFullScreen(nil)
            return
        }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let available = window.contentRect(forFrameRect: screen.visibleFrame).size
        guard let size = PlayerWindowLayout.dimensions(for: request.preset, videoPixels: session.videoDisplaySize,
                                                       backingScale: window.backingScaleFactor,
                                                       available: available, showsPlaylist: session.showsPlaylist) else { return }
        requestedSize = nil
        let frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size.content))
        session.reveal()
        resizingForPreset = true
        setWindowFrame(size: frame.size, within: screen.visibleFrame, animated: true)
        resizingForPreset = false
        updateToolbar()
        session.smallPictureSize = size.smallPicture
        rememberWindowSize()
    }

    func applicationWillTerminate(_ notification: Notification) {
        rememberWindowSize()
        if let events { NSEvent.removeMonitor(events) }
        window?.delegate = nil
        session.finish()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if ready {
            session.openFromFinder(urls)
            if !session.pipActive { window.makeKeyAndOrderFront(nil) }
        } else { pendingURLs = urls }
    }
    private func updateWindowState() {
        guard let window else { return }
        let floating = session.pinWhenPlaying && session.playing && !session.pipActive && !window.styleMask.contains(.fullScreen)
        window.level = floating ? .floating : .normal
        pinItem?.image = NSImage(systemSymbolName: session.pinWhenPlaying ? "pin.fill" : "pin", accessibilityDescription: "재생 중 항상 위")
        pinItem?.toolTip = session.pinWhenPlaying ? "재생 중 항상 위 끄기" : "재생 중 항상 위 켜기"
        pipItem?.image = NSImage(systemSymbolName: session.pipActive ? "pip.exit" : "pip.enter", accessibilityDescription: "화면 속 화면")
        playlistItem?.toolTip = session.showsPlaylist ? "재생목록 닫기 (⌘L)" : "재생목록 보기 (⌘L)"
    }

    private func updateTitle() {
        window.title = session.current?.url.lastPathComponent ?? ""
    }

    private func toolbarItems(for width: CGFloat) -> [NSToolbarItem.Identifier] {
        var items: [NSToolbarItem.Identifier] = [.flexibleSpace]
        guard width >= PlayerWindowLayout.seekControlsWidth else { return items }
        items.append(.openFile)
        if width >= PlayerWindowLayout.extendedControlsWidth { items += [.pin, .pip] }
        items.append(.playlist)
        return items
    }
    private func updateToolbar() {
        guard let toolbar = window.toolbar, !updatingToolbar else { return }
        let desired = toolbarItems(for: window.frame.width)
        let current = toolbar.items.map(\.itemIdentifier)
        guard current != desired else { return }
        updatingToolbar = true
        defer { updatingToolbar = false }
        let common = zip(current, desired).prefix { $0.0 == $0.1 }.count
        while toolbar.items.count > common { toolbar.removeItem(at: toolbar.items.count - 1) }
        for id in desired.dropFirst(common) { toolbar.insertItem(withItemIdentifier: id, at: toolbar.items.count) }
        updateWindowState()
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarItems(for: window.frame.width)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarItems(for: .infinity)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case .openFile:
            item.label = "동영상 열기"
            item.toolTip = "동영상 열기 (⌘O)"
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(openFiles)
        case .pin:
            item.label = "재생 중 항상 위"
            item.image = NSImage(systemSymbolName: "pin", accessibilityDescription: item.label)
            item.target = self; item.action = #selector(togglePin)
            pinItem = item
        case .pip:
            item.label = "화면 속 화면"
            item.toolTip = "화면 속 화면 (P)"
            item.image = NSImage(systemSymbolName: "pip.enter", accessibilityDescription: item.label)
            item.target = self; item.action = #selector(togglePiP)
            pipItem = item
        case .playlist:
            item.label = "재생목록"
            item.toolTip = "재생목록 보기 (⌘L)"
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
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "",
                 modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
        }
        let app = menu("JulPlayer")
        add(app, "JulPlayer 정보", #selector(about), target: self)
        app.addItem(.separator())
        add(app, "JulPlayer 가리기", #selector(NSApplication.hide(_:)), key: "h", target: NSApp)
        add(app, "JulPlayer 종료", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)
        let file = menu("파일")
        add(file, "동영상 열기…", #selector(openFiles), key: "o", target: self)
        add(file, "현재 영상과 자막을 휴지통으로 이동…", #selector(trashFile), key: "\u{8}", modifiers: [], target: self)
        add(file, "현재 영상과 자막을 바로 휴지통으로 이동", #selector(trashFileImmediately), key: "\u{8}", target: self)
        let associationItem = NSMenuItem(title: "기본 플레이어로 연결", action: nil, keyEquivalent: "")
        let formats = NSMenu(title: associationItem.title)
        for ext in LocalMedia.videoExtensions {
            let option = formats.addItem(withTitle: ext.uppercased(), action: #selector(associate(_:)), keyEquivalent: "")
            option.target = self; option.representedObject = ext
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
        add(play, "30초 뒤로", #selector(back30), target: self)
        add(play, "30초 앞으로", #selector(forward30), target: self)
        play.addItem(.separator())
        add(play, "음소거 전환", #selector(toggleMute), key: "m", modifiers: [], target: self)
        add(play, "자막 켜기 / 끄기", #selector(toggleCaptions), key: "c", modifiers: [], target: self)
        add(play, "오디오 스트림 및 싱크…", #selector(audioPanel), target: self)
        add(play, "자막 스트림 및 싱크…", #selector(subtitlePanel), target: self)
        let view = menu("보기")
        for preset in WindowSizePreset.allCases {
            let item = view.addItem(withTitle: preset.menuTitle, action: #selector(chooseWindowSize(_:)),
                                    keyEquivalent: String(preset.rawValue))
            item.keyEquivalentModifierMask = []
            item.tag = preset.rawValue
            item.target = self
        }
        view.addItem(.separator())
        add(view, "재생목록 전환", #selector(togglePlaylist), key: "l", target: self)
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
            if event.keyCode == 48 && (modifiers.isEmpty || modifiers == [.shift]) {
                self.session.reveal()
                return event
            }
            if modifiers == [.command] {
                let action: () -> Void
                switch event.keyCode {
                case 51, 117: action = self.trashFileImmediately
                case 123: action = self.previousFile
                case 124: action = self.nextFile
                default: return event
                }
                if !event.isARepeat { action() }
                return nil
            }
            guard modifiers.isEmpty else { return event }
            if let digits = event.charactersIgnoringModifiers, let key = Int(digits), let preset = WindowSizePreset(rawValue: key) {
                if !event.isARepeat { self.requestSize(preset) }
                return nil
            }
            switch event.keyCode {
            case 51: if !event.isARepeat { self.trashFile() }
            case 123: self.backward()
            case 124: self.forward()
            case 125: self.session.setVolume(self.session.volume - 0.05)
            case 126: self.session.setVolume(self.session.volume + 0.05)
            case 49: if !event.isARepeat { self.togglePlay() }
            case 46: if !event.isARepeat { self.toggleMute() }
            case 8: if !event.isARepeat { self.toggleCaptions() }
            case 3, 36, 76: if !event.isARepeat { self.fullScreen() }
            case 35: if !event.isARepeat { self.togglePiP() }
            default: return event
            }
            return nil
        }
    }

    @objc private func openFiles() { session.openFiles() }
    @objc private func chooseWindowSize(_ sender: NSMenuItem) {
        if let preset = WindowSizePreset(rawValue: sender.tag) { requestSize(preset) }
    }
    @objc private func togglePlay() { session.togglePlay() }
    @objc private func backward() { session.seek(to: session.position - 10) }
    @objc private func forward() { session.seek(to: session.position + 10) }
    @objc private func toggleMute() { session.toggleMute() }
    @objc private func fullScreen() { window.toggleFullScreen(nil) }
    @objc private func toggleCaptions() { session.toggleCaptions() }
    @objc private func audioPanel() { session.panel = .audio }
    @objc private func subtitlePanel() { session.panel = .subtitle }
    @objc private func previousFile() { session.stepFile(-1) }
    @objc private func nextFile() { session.stepFile(1) }
    @objc private func back30() { session.seek(to: session.position - 30) }
    @objc private func forward30() { session.seek(to: session.position + 30) }
    @objc private func togglePiP() { session.pip?.toggle() }
    @objc private func togglePin() { session.pinWhenPlaying.toggle() }
    @objc private func trashFile() { session.trashCurrent() }
    @objc private func trashFileImmediately() { session.trashCurrent(requiresConfirmation: false) }
    @objc private func associate(_ sender: NSMenuItem) {
        guard let ext = sender.representedObject as? String, let type = UTType(filenameExtension: ext) else { return }
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type) { [weak self] error in
            DispatchQueue.main.async {
                self?.session.show(error?.localizedDescription ?? "\(ext.uppercased()) 파일의 기본 플레이어를 JulPlayer로 연결했습니다.")
            }
        }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(chooseWindowSize(_:)) {
            return window?.isKeyWindow == true && window.attachedSheet == nil && session.panel == nil
                && !(window.firstResponder is NSTextView) && (item.tag == WindowSizePreset.minimum.rawValue || session.current != nil)
        }
        if item.action == #selector(audioPanel) || item.action == #selector(subtitlePanel) { return session.loaded }
        if [#selector(previousFile), #selector(nextFile), #selector(trashFile), #selector(trashFileImmediately)].contains(item.action) {
            guard window?.isKeyWindow == true, window.attachedSheet == nil, session.panel == nil,
                  !(window.firstResponder is NSTextView) else { return false }
            if item.action == #selector(previousFile) { return session.adjacent(-1) != nil }
            if item.action == #selector(nextFile) { return session.adjacent(1) != nil }
            return session.current != nil && !session.trashInProgress
        }
        if item.action == #selector(togglePin) { item.state = session.pinWhenPlaying ? .on : .off }
        if item.action == #selector(togglePiP) { item.state = session.pipActive ? .on : .off; return session.loaded }
        return true
    }
    @objc private func togglePlaylist() { session.showsPlaylist.toggle() }
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
