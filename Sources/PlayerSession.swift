import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct Clip: Identifiable {
    let id = UUID()
    let url: URL
    var title: String { url.deletingPathExtension().lastPathComponent }
    var duration: Double?
    init(file: URL) { url = file }
}

enum StreamKind: String, Identifiable, CaseIterable {
    case subtitle = "sub", audio = "audio"
    var id: Self { self }
    var trackProperty: String { self == .audio ? "aid" : "sid" }
    var ordinalKey: String { "streamOrdinal." + rawValue }
    var disabledKey: String { "streamDisabled." + rawValue }
}

enum SubtitleSize: String, CaseIterable {
    case small, normal, large

    var title: String {
        switch self {
        case .small: return "작게"
        case .normal: return "보통"
        case .large: return "크게"
        }
    }

    var scale: Double {
        switch self {
        case .small: return 1.1
        case .normal: return 1.35
        case .large: return 1.6
        }
    }
}

enum PlaybackPanel: Hashable, Identifiable {
    case stream(StreamKind), brightness
    var id: Self { self }
}

enum PlayerSidebar { case playlist, captions }

struct MediaStream: Identifiable, Equatable {
    let id: Int
    let kind: StreamKind
    let title: String
    var selected: Bool
    let externalURL: URL?
    let codec: String
    let languageCode: String?
    let ffIndex: Int?
    init?(_ entry: [String: Any]) {
        guard let key = entry["type"] as? String, let kind = StreamKind(rawValue: key), let id = entry["id"] as? Int else { return nil }
        self.kind = kind; self.id = id
        codec = (entry["codec"] as? String ?? "").lowercased()
        languageCode = entry["lang"] as? String
        ffIndex = (entry["ff-index"] as? Int).flatMap { $0 >= 0 ? $0 : nil }
        selected = entry["selected"] as? Bool == true
        let locale = Locale(identifier: "ko")
        let language = (entry["lang"] as? String).flatMap { locale.localizedString(forLanguageCode: $0) ?? $0 }
        externalURL = (entry["external-filename"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL }
        var parts = [entry["title"] as? String, language].compactMap { $0 }.filter { !$0.isEmpty }
        if parts.count == 2 && parts[0] == parts[1] { parts.removeLast() }
        if parts.isEmpty { parts = [externalURL?.lastPathComponent ?? "트랙 \(id)"] }
        if kind == .subtitle, let externalURL {
            let filename = externalURL.lastPathComponent
            parts = ["외부", filename] + parts.filter { $0 != filename && !filename.hasSuffix("." + $0) }
        }
        if let codec = entry["codec"] as? String, kind == .audio { parts.append(codec.uppercased()) }
        title = parts.joined(separator: " · ")
    }
}

func timecode(_ seconds: Double) -> String {
    let value = Int(max(0, seconds.isFinite ? seconds : 0))
    return value >= 3600 ? String(format: "%d:%02d:%02d",value/3600,value/60%60,value%60)
                         : String(format: "%02d:%02d",value/60,value%60)
}

@MainActor
final class PlayerSession: ObservableObject {
    @Published private(set) var clips: [Clip] = []
    @Published private(set) var selection: UUID?
    @Published private(set) var position = 0.0
    @Published private(set) var playing = false
    @Published private(set) var volume: Double
    static let brightnessRange = 1...10
    @Published private(set) var videoBrightness: Int
    @Published private(set) var sourceIsHDR = false
    @Published var subtitleSize: SubtitleSize {
        didSet {
            defaults.set(subtitleSize.rawValue, forKey: Self.subtitleSizeKey)
            _ = engine?.setNumber(subtitleSize.scale, forOption: "sub-scale")
        }
    }
    @Published private(set) var streams: [MediaStream] = []
    @Published private(set) var subtitleDelay = 0.0
    @Published private(set) var audioDelay = 0.0
    @Published var panel: PlaybackPanel? { didSet { windowStateChanged?() } }
    @Published var sidebar: PlayerSidebar? { didSet { windowStateChanged?() } }
    @Published var dropHint: String?
    @Published private(set) var controlsVisible = true { didSet { windowStateChanged?() } }
    @Published var pipActive = false { didSet { windowStateChanged?() } }
    @Published private(set) var notice: String?
    @Published private(set) var loaded = false
    @Published private(set) var deletionInProgress = false { didSet { windowStateChanged?() } }
    @Published var smallPictureSize: CGSize?

    lazy var captionQueue = CaptionQueue(defaults: defaults) { [weak self] movie, output, original in
        guard let self, current?.url == movie else { return }
        addSubtitles([output])
        if let original { addSubtitles([original], select: false) }
        showFeedback("AI 자막 준비됨")
    }
    var openAISettings: (() -> Void)?
    var selectionDidChange: (() -> Void)?
    var videoSizeDidChange: (() -> Void)?
    var windowStateChanged: (() -> Void)?
    weak var window: NSWindow?
    weak var playlistArea: NSView?
    @Published private(set) var videoDisplaySize: CGSize?
    var current: Clip? { clips.first { $0.id == selection } }
    var duration: Double { current?.duration ?? 0 }
    var volumePercent: Int { Int((volume * 100).rounded()) }
    var overControls = false {
        didSet {
            if oldValue && !overControls { lastPointerActivity = ProcessInfo.processInfo.systemUptime }
        }
    }
    var scrubbing = false
    let engine: VideoEngine?
    private(set) var pip: PictureInPicture?
    private static let controlsTimeout: TimeInterval = 2
    private var lastPointerActivity = -TimeInterval.infinity
    private var lastSeek: TimeInterval = 0
    private var seekCompletions: [() -> Void] = []
    private var noticeEnds = TimeInterval.infinity
    private var timer: Timer?
    private var playbackActivity: NSObjectProtocol?
    private var folderScan: Task<Void, Never>?
    private let callMonitor: CallActivityMonitor
    private(set) var callActive = false
    private var resumeAfterCall: UUID?
    // mpv can pause itself on the last frame before the next poll reports EOF.
    private var playRequested = false
    private enum EndState { case none, reached, playlistFinished }
    private var endState = EndState.none
    private var manualSubs: [URL: [URL]] = [:]
    private var pendingSubtitles = [(url: URL, select: Bool)]()
    private var explicitSubtitleID: Int?
    private var fileTicket = 0
    private static let volumeKey = "playbackVolume"
    private static let beforeMuteKey = "volumeBeforeMute"
    private static let subtitleSizeKey = "subtitleSize"
    private static let brightnessKey = "videoBrightnessMultiplier"
    private let defaults: UserDefaults
    private var sidecarsReady = false

    init(defaults: UserDefaults = .standard, callMonitor: CallActivityMonitor = CallActivityMonitor()) {
        self.defaults = defaults
        self.callMonitor = callMonitor
        let initialVolume = 0.68
        defaults.register(defaults: [Self.volumeKey: initialVolume, Self.beforeMuteKey: initialVolume])
        volume = defaults.double(forKey: Self.volumeKey)
        let savedBrightness = defaults.integer(forKey: Self.brightnessKey)
        videoBrightness = Self.brightnessRange.contains(savedBrightness) ? savedBrightness : 1
        subtitleSize = defaults.string(forKey: Self.subtitleSizeKey).flatMap(SubtitleSize.init(rawValue:)) ?? .normal
        do { engine = try VideoEngine.make() }
        catch { engine = nil; notice = error.localizedDescription }
    }

    func start(opening urls: [URL]) {
        if let engine {
            callMonitor.start { [weak self] active in self?.callActivityChanged(active) }
            pip = PictureInPicture(session: self, layer: engine.displayLayer)
            _ = engine.setNumber(volume * 100, forOption: "volume")
            _ = engine.setNumber(subtitleSize.scale, forOption: "sub-scale")
            let clock = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer = clock
            RunLoop.main.add(clock, forMode: .common)
        }
        if !urls.isEmpty { openMedia(urls) }
    }
    func finish() {
        callMonitor.stop()
        callActive = false
        resumeAfterCall = nil
        captionQueue.stop()
        timer?.invalidate(); timer = nil
        folderScan?.cancel()
        fileTicket += 1; folderScan = nil; playRequested = false
        loaded = false
        setPlayingUI(false)
        pip?.shutdown()
        finishPendingSeeks()
        engine?.shutdown()
    }
    func pointerMoved() {
        lastPointerActivity = ProcessInfo.processInfo.systemUptime
        if !controlsVisible { controlsVisible = true }
    }
    func show(_ text: String, seconds: Double = 4) {
        noticeEnds = ProcessInfo.processInfo.systemUptime + seconds
        if notice != text { notice = text }
    }
    func showFeedback(_ text: String) {
        if selection != nil { show(text, seconds: 1.5) }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if notice != nil && now >= noticeEnds { notice = nil }
        if pipActive { pip?.attachPanelOutputIfNeeded() }
        guard let current, let player = engine else { return }
        let screen = (pipActive ? pip?.screen : nil) ?? window?.screen
        let supportsHDR = (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
        let changes = player.poll(hdrDisplay: supportsHDR, brightness: videoBrightness)
        if changes["brightnessUnavailable"] as? Bool == true {
            setVideoBrightness(1)
            show("선택한 영상 밝기를 적용할 수 없어 원본 밝기로 재생합니다.")
        }
        if let error = changes["error"] as? String {
            resumeAfterCall = nil
            playRequested = false; endState = .none; loaded = false; videoDisplaySize = nil; setPlayingUI(false)
            sourceIsHDR = false
            show("재생할 수 없습니다. \(current.title) (\(error))", seconds: 12)
            pip?.invalidate(); finishPendingSeeks(); return
        }
        let justLoaded = changes["loaded"] as? Bool == true
        if justLoaded {
            loaded = true; endState = .none
            attachSidecars(for: current.url, ticket: fileTicket)
            pip?.invalidate()
        }
        if let hdr = changes["sourceHDR"] as? Bool, hdr != sourceIsHDR { sourceIsHDR = hdr }
        if let width = changes["displayWidth"] as? Int, let height = changes["displayHeight"] as? Int {
            let size = CGSize(width: width, height: height)
            if size != videoDisplaySize {
                videoDisplaySize = size
                videoSizeDidChange?()
            }
        }
        if let rows = changes["tracks"] as? [[String: Any]] {
            applyStreamChoices(to: rows.compactMap(MediaStream.init))
        }
        if justLoaded { engine?.setPaused(!playRequested) }
        if let seconds = changes["duration"] as? Double, seconds.isFinite, seconds > 0,
           let i = clips.firstIndex(where: { $0.id == selection }), clips[i].duration != seconds {
            clips[i].duration = seconds; pip?.invalidate()
        }
        if let time = changes["position"] as? Double, time.isFinite, !scrubbing, now - lastSeek > 0.24,
           abs(time - position) > 0.025 { position = max(0, time) }
        if let actual = changes["playing"] as? Bool { setPlayingUI(actual) }
        if changes["fileEnded"] as? Bool == true {
            loaded = false
            if endState == .none { endState = .reached }
            pip?.invalidate()
        } else if endState == .none, !scrubbing, now - lastSeek > 0.25, changes["eof"] as? Bool == true {
            endState = .reached
        }
        advanceAfterEnd()
        if selection == current.id, !justLoaded,
           changes["timelineReady"] as? Bool == true || changes["fileEnded"] as? Bool == true {
            finishPendingSeeks()
        }
        if controlsVisible && !overControls && !scrubbing && panel == nil
            && window?.attachedSheet == nil && now - lastPointerActivity >= Self.controlsTimeout {
            controlsVisible = false
        }
    }

    private func advanceAfterEnd() {
        guard endState == .reached, playRequested, !scrubbing else { return }
        if let next = adjacent(1) { select(next) }
        else if folderScan == nil {
            endState = .playlistFinished
            playRequested = false
            if loaded { engine?.setPaused(true) }
            setPlayingUI(false)
        }
    }

    private func setPlayingUI(_ value: Bool) {
        guard playing != value else { return }
        playing = value
        if value {
            playbackActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled], reason: "JulPlayer video playback")
        } else {
            if let playbackActivity { ProcessInfo.processInfo.endActivity(playbackActivity) }
            playbackActivity = nil
        }
        windowStateChanged?()
        pip?.invalidate()
    }
    private func callActivityChanged(_ active: Bool) {
        callActive = active
        if active {
            guard playRequested, let selection else { return }
            setPlaying(false)
            resumeAfterCall = selection
            showFeedback("통화로 일시 정지")
        } else if let interrupted = resumeAfterCall, interrupted == selection {
            setPlaying(true)
            showFeedback("통화 종료 · 재생")
        }
    }

    func setPlaying(_ value: Bool) {
        resumeAfterCall = nil
        guard let current, value != playRequested else { return }
        playRequested = value
        // PiP pauses for a skip and resumes after its completion, even at EOF.
        if value && endState == .reached { advanceAfterEnd(); return }
        if value && endState == .playlistFinished {
            if !loaded { select(current); return }
            seek(to: 0)
        }
        if loaded {
            engine?.setPaused(!value)
            setPlayingUI(value)
        }
    }
    @discardableResult
    func togglePlay() -> Bool? {
        guard current != nil else { openFiles(); return nil }
        let requested = loaded ? !playing : !playRequested
        setPlaying(requested)
        return requested
    }
    @discardableResult
    func seek(to value: Double, completion: (() -> Void)? = nil) -> Double? {
        guard loaded, duration > 0, value.isFinite else { completion?(); return nil }
        if let completion { seekCompletions.append(completion) }
        let destination = min(duration, max(0, value))
        if destination == duration, playRequested, !scrubbing, let next = adjacent(1) {
            select(next)
            return destination
        }
        endState = destination == duration ? .reached : .none
        position = destination; lastSeek = ProcessInfo.processInfo.systemUptime
        engine?.seek(position)
        return destination
    }
    private func finishPendingSeeks() {
        guard !seekCompletions.isEmpty else { return }
        let completed = seekCompletions
        seekCompletions.removeAll()
        completed.forEach { $0() }
    }
    func skip(by seconds: Int) {
        let previous = selection
        guard let destination = seek(to: position + Double(seconds)), selection == previous else { return }
        showFeedback("\(timecode(destination)) / \(timecode(duration))")
    }
    func setVideoBrightness(_ multiplier: Int) {
        guard Self.brightnessRange.contains(multiplier), multiplier != videoBrightness else { return }
        videoBrightness = multiplier
        defaults.set(multiplier, forKey: Self.brightnessKey)
    }
    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        let level = min(1, max(0, value))
        if level != volume {
            if level == 0 { defaults.set(volume, forKey: Self.beforeMuteKey) }
            volume = level
            defaults.set(level, forKey: Self.volumeKey)
            _ = engine?.setNumber(level * 100, forOption: "volume")
        }
    }
    func adjustVolume(by change: Double) {
        setVolume(volume + change)
        showFeedback("음량 \(volumePercent)%")
    }
    func toggleMute() {
        setVolume(volume > 0 ? 0 : defaults.double(forKey: Self.beforeMuteKey))
    }
    private func ordinal(for kind: StreamKind, count: Int) -> Int {
        let saved = defaults.integer(forKey: kind.ordinalKey)
        return saved > 0 && saved <= count ? saved : 1
    }

    private func preferredTrack(in options: [MediaStream], ordinal: Int) -> MediaStream {
        let remembered = options[ordinal - 1]
        guard remembered.kind == .subtitle else { return remembered }
        if let explicitSubtitleID, let chosen = options.first(where: { $0.id == explicitSubtitleID }) { return chosen }
        if remembered.externalURL != nil { return remembered }
        return options.first { $0.externalURL != nil } ?? remembered
    }

    private func applyStreamChoices(to tracks: [MediaStream]) {
        var values = tracks
        for kind in StreamKind.allCases {
            let options = tracks.filter { $0.kind == kind }
            guard !options.isEmpty else { continue }
            let number = ordinal(for: kind, count: options.count)
            let disabled = defaults.bool(forKey: kind.disabledKey)
            let target = disabled ? -1 : preferredTrack(in: options, ordinal: number).id
            if (options.first(where: \.selected)?.id ?? -1) != target {
                guard engine?.selectTrack(target, property: kind.trackProperty) == true else { continue }
                for i in values.indices where values[i].kind == kind { values[i].selected = values[i].id == target }
            }
            // External subtitles can add the saved slot after the embedded tracks arrive.
            if !disabled, kind == .audio || sidecarsReady, number != defaults.integer(forKey: kind.ordinalKey) {
                defaults.set(number, forKey: kind.ordinalKey)
            }
        }
        if values != streams { streams = values }
    }

    func selectStream(_ kind: StreamKind, id: Int) {
        _ = selectStream(kind, id: id, in: streams.filter { $0.kind == kind })
    }

    private func selectStream(_ kind: StreamKind, id: Int, in choices: [MediaStream], rememberTrack: Bool = true) -> Bool {
        let index = choices.firstIndex { $0.id == id }
        guard loaded, id < 0 || index != nil else { return false }
        guard engine?.selectTrack(id, property: kind.trackProperty) == true else { show("스트림을 전환할 수 없습니다."); return false }
        if let index, rememberTrack {
            defaults.set(index + 1, forKey: kind.ordinalKey)
            if kind == .subtitle { explicitSubtitleID = id }
        }
        defaults.set(id < 0, forKey: kind.disabledKey)
        if let rows = engine?.trackList() { applyStreamChoices(to: rows.compactMap(MediaStream.init)) }
        return true
    }
    func toggleCaptions() {
        let subs = streams.filter { $0.kind == .subtitle }
        guard !subs.isEmpty else { showFeedback("자막 없음"); return }
        let preferred = preferredTrack(in: subs, ordinal: ordinal(for: .subtitle, count: subs.count))
        let id = subs.contains(where: \.selected) ? -1 : preferred.id
        if selectStream(.subtitle, id: id, in: subs, rememberTrack: false) {
            showFeedback(id < 0 ? "자막 끔" : "자막 켬 · \(preferred.title)")
        }
    }
    func setDelay(_ kind: StreamKind, seconds: Double) {
        guard seconds.isFinite else { return }
        let value = (min(3600,max(-3600,seconds))*1000).rounded()/1000
        guard engine?.setNumber(value, forOption: kind == .audio ? "audio-delay" : "sub-delay") == true else {
            show("싱크를 변경할 수 없습니다.")
            return
        }
        if kind == .audio { audioDelay = value } else { subtitleDelay = value }
    }

    func select(_ clip: Clip?) {
        fileTicket += 1
        sidecarsReady = false
        explicitSubtitleID = nil
        pendingSubtitles.removeAll()
        resumeAfterCall = nil
        playRequested = clip != nil && (!callActive || playRequested)
        videoDisplaySize = nil
        sourceIsHDR = false
        smallPictureSize = nil
        if clip == nil {
            controlsVisible = true
        } else if selection == nil {
            controlsVisible = ProcessInfo.processInfo.systemUptime - lastPointerActivity < Self.controlsTimeout
        }
        loaded = false; endState = .none; setPlayingUI(false); selection = clip?.id
        position = 0; lastSeek = 0; streams = []; subtitleDelay = 0; audioDelay = 0; panel = nil
        overControls = false
        if engine != nil { notice = nil }
        selectionDidChange?()
        guard let clip else { pip?.stop(); engine?.stop(); pip?.invalidate(); finishPendingSeeks(); return }
        if let engine, !engine.load(clip.url.path, paused: true) {
            playRequested = false
            show("파일을 열 수 없습니다. \(clip.title)")
            finishPendingSeeks()
        }
        pip?.invalidate()
    }
    func adjacent(_ offset: Int) -> Clip? {
        guard let i = clips.firstIndex(where: { $0.id == selection }), clips.indices.contains(i+offset) else { return nil }
        return clips[i+offset]
    }
    @discardableResult
    func stepFile(_ offset: Int) -> Clip? {
        guard let clip = adjacent(offset) else { return nil }
        select(clip)
        return clip
    }

    func openMedia(_ input: [URL]) {
        let files = input.map(\.standardizedFileURL).filter(LocalMedia.isVideo)
        let subtitles = input.map(\.standardizedFileURL).filter(LocalMedia.isSubtitle)
        guard let first = files.first else { addSubtitles(subtitles); return }
        folderScan?.cancel()
        let clip = Clip(file: first)
        clips = [clip]; select(clip)
        pendingSubtitles = subtitles.map { ($0, true) }
        folderScan = Task {
            let found = await Task.detached(priority: .userInitiated) { LocalMedia.folderPlaylist(for: files) }.value
            guard !Task.isCancelled else { return }
            let known = Dictionary(clips.map { ($0.url, $0) }, uniquingKeysWith: { a,_ in a })
            clips = found.map { known[$0] ?? Clip(file: $0) }
            folderScan = nil
            advanceAfterEnd()
        }
    }

    func openFiles() {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "동영상 열기"
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.allowedContentTypes = LocalMedia.types
        panel.beginSheetModal(for: window) { [weak self] reply in
            guard reply == .OK else { return }
            self?.openMedia(panel.urls)
        }
    }
    func chooseSubtitles() {
        panel = nil
        guard let window, window.attachedSheet == nil else { return }
        let picker = NSOpenPanel()
        picker.title = "외부 자막 열기"; picker.allowsMultipleSelection = true; picker.allowedContentTypes = LocalMedia.subtitleTypes
        picker.beginSheetModal(for: window) { [weak self] answer in if answer == .OK { self?.addSubtitles(picker.urls) } }
    }
    func showCaptionQueue() {
        panel = nil
        sidebar = .captions
    }
    func dismissPlaylist() {
        if sidebar == .playlist { sidebar = nil }
    }

    private func addSubtitles(_ urls: [URL], select: Bool = true) {
        guard let movie = current?.url, !urls.isEmpty, let engine else { return }
        guard loaded && sidecarsReady else { pendingSubtitles += urls.map { ($0, select) }; return }
        for url in urls where LocalMedia.isSubtitle(url) {
            let file = url.standardizedFileURL
            let matchesFile: (MediaStream) -> Bool = { $0.externalURL?.path == file.path }
            var choices = streams.filter { $0.kind == .subtitle }
            if !choices.contains(where: matchesFile) {
                guard engine.addSubtitle(file.path), let rows = engine.trackList() else {
                    show("자막 파일을 열 수 없습니다. " + file.lastPathComponent)
                    continue
                }
                choices = rows.compactMap(MediaStream.init).filter { $0.kind == .subtitle }
            }
            guard let track = choices.first(where: matchesFile) else {
                show("자막 트랙을 찾을 수 없습니다. " + file.lastPathComponent)
                continue
            }
            if select {
                guard selectStream(.subtitle, id: track.id, in: choices) else { continue }
            } else if let rows = engine.trackList() {
                applyStreamChoices(to: rows.compactMap(MediaStream.init))
            }
            if !manualSubs[movie, default: []].contains(where: { $0.path == file.path }) {
                manualSubs[movie, default: []].append(file)
            }
        }
    }
    private func attachSidecars(for movie: URL, ticket: Int) {
        Task {
            let files = await Task.detached(priority: .userInitiated) { LocalMedia.sidecars(for: movie) }.value
            guard ticket == fileTicket, loaded, let engine else { return }
            var used = Set(streams.compactMap { $0.externalURL?.path })
            let all = files + manualSubs[movie, default: []]
            for url in all where used.insert(url.standardizedFileURL.path).inserted {
                // VobSub's .idx loads the companion .sub by itself.
                if url.pathExtension.lowercased() == "sub" && all.contains(where: { $0.deletingPathExtension() == url.deletingPathExtension() && $0.pathExtension.lowercased() == "idx" }) { continue }
                _ = engine.addSubtitle(url.path)
            }
            sidecarsReady = true
            if let rows = engine.trackList() { applyStreamChoices(to: rows.compactMap(MediaStream.init)) }
            let requested = pendingSubtitles
            pendingSubtitles.removeAll()
            for request in requested { addSubtitles([request.url], select: request.select) }
        }
    }

    func deleteCurrent(requiresConfirmation: Bool = true) {
        guard !deletionInProgress, let clip = current, let window,
              window.attachedSheet == nil else { return }
        deletionInProgress = true
        let movie = clip.url
        let resumeIfKept = playRequested || resumeAfterCall == clip.id
        if resumeIfKept { setPlaying(false) }
        let shared = Set(manualSubs.filter { $0.key != movie }.flatMap(\.value).map(\.standardizedFileURL))
        let attached = manualSubs[movie, default: []]
        Task {
            var deleted = false
            defer {
                deletionInProgress = false
                if !deleted && resumeIfKept && selection == clip.id {
                    if callActive { resumeAfterCall = clip.id }
                    else { setPlaying(true) }
                }
            }
            do {
                let entries = try await Task.detached(priority: .userInitiated) {
                    try LocalMedia.deletionEntries(movie: movie, attached: attached, shared: shared)
                }.value
                guard selection == clip.id, window.attachedSheet == nil else { return }
                if requiresConfirmation {
                    guard await confirmDeletion(entries, movie: movie, in: window), selection == clip.id else { return }
                }
                try await Task.detached(priority: .userInitiated) { try LocalMedia.delete(entries) }.value
                deleted = true
                manualSubs.removeValue(forKey: movie)
                // A shortcut can arrive before Finder's initial folder scan finishes.
                await folderScan?.value
                if let i = clips.firstIndex(where: { $0.url == movie }) {
                    let wasCurrent = current?.url == movie
                    clips.remove(at: i)
                    if wasCurrent {
                        let next = clips.indices.contains(i) ? clips[i] : clips.last
                        select(next)
                    }
                }
                let count = entries.count - 1
                show(count == 0 ? "영상을 삭제했습니다." : "영상과 자막 \(count)개를 삭제했습니다.")
            } catch { show(error.localizedDescription, seconds: 10) }
        }
    }

    private func confirmDeletion(_ entries: [LocalMedia.FileIdentity], movie: URL, in window: NSWindow) async -> Bool {
        let count = entries.count - 1
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 0 ? "이 영상을 영구 삭제할까요?" : "영상과 연결된 자막 \(count)개를 영구 삭제할까요?"
        alert.informativeText = entries.map { entry in
            entry.url.deletingLastPathComponent() == movie.deletingLastPathComponent() ? entry.url.lastPathComponent : entry.url.path
        }.joined(separator: "\n")
        let delete = alert.addButton(withTitle: "삭제")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = "\r"
        alert.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = delete
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { answer in
                continuation.resume(returning: answer == .alertFirstButtonReturn)
            }
            alert.window.defaultButtonCell = delete.cell as? NSButtonCell
            alert.window.makeFirstResponder(delete)
        }
    }
}
