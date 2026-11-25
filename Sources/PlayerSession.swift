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
    @Published var showsRemaining = false
    @Published var showsPlaylist = false { didSet { windowStateChanged?() } }
    @Published var dropHint: String?
    @Published private(set) var controlsVisible = true { didSet { windowStateChanged?() } }
    @Published var pinWhenPlaying = UserDefaults.standard.bool(forKey: "pinWhenPlaying") {
        didSet { UserDefaults.standard.set(pinWhenPlaying, forKey: "pinWhenPlaying"); windowStateChanged?() }
    }
    @Published var pipActive = false { didSet { windowStateChanged?() } }
    @Published private(set) var notice: String?
    @Published private(set) var loaded = false
    @Published private(set) var deletionInProgress = false
    @Published var smallPictureSize: CGSize?

    var openCaptionGenerator: (() -> Void)?
    var openWorkInfo: (() -> Void)?
    var selectionDidChange: (() -> Void)?
    var videoSizeDidChange: (() -> Void)?
    var windowStateChanged: (() -> Void)?
    weak var window: NSWindow?
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
    private var noticeEnds = TimeInterval.infinity
    private var timer: Timer?
    private var playbackActivity: NSObjectProtocol?
    private var folderScan: Task<Void, Never>?
    // mpv can pause itself on the last frame before the next poll reports EOF.
    private var playRequested = false
    private var ended = false
    private var manualSubs: [URL: [URL]] = [:]
    private var pendingSubtitles = [URL]()
    private var explicitSubtitleID: Int?
    private var fileTicket = 0
    private static let volumeKey = "playbackVolume"
    private static let beforeMuteKey = "volumeBeforeMute"
    private static let subtitleSizeKey = "subtitleSize"
    private static let brightnessKey = "videoBrightnessMultiplier"
    private let defaults: UserDefaults
    private var sidecarsReady = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        timer?.invalidate(); timer = nil
        folderScan?.cancel()
        fileTicket += 1; folderScan = nil; playRequested = false
        loaded = false
        setPlayingUI(false)
        pip?.shutdown()
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
            playRequested = false; ended = false; loaded = false; videoDisplaySize = nil; setPlayingUI(false)
            sourceIsHDR = false
            show("재생할 수 없습니다. \(current.title) (\(error))", seconds: 12)
            pip?.invalidate(); return
        }
        let justLoaded = changes["loaded"] as? Bool == true
        if justLoaded {
            loaded = true; ended = false
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
            ended = true
            pip?.invalidate()
        } else if !scrubbing, now - lastSeek > 0.25, let eof = changes["eof"] as? Bool {
            ended = eof
        }
        advanceAfterEnd()
        if controlsVisible && !overControls && !scrubbing && panel == nil
            && window?.attachedSheet == nil && now - lastPointerActivity >= Self.controlsTimeout {
            controlsVisible = false
        }
    }

    private func advanceAfterEnd() {
        guard ended, playRequested, !scrubbing else { return }
        if let next = adjacent(1) { select(next) }
        else if folderScan == nil { playRequested = false }
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
    func setPlaying(_ value: Bool) {
        guard let current else { return }
        playRequested = value
        if value && ended && !loaded { select(current); return }
        if value && loaded && (ended || (duration > 0 && position >= duration - 0.08)) { seek(to: 0) }
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
    func seek(to value: Double) -> Double? {
        guard loaded, duration > 0, value.isFinite else { return nil }
        ended = false
        position = min(duration, max(0,value)); lastSeek = ProcessInfo.processInfo.systemUptime
        engine?.seek(position)
        return position
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
        playRequested = clip != nil
        videoDisplaySize = nil
        sourceIsHDR = false
        smallPictureSize = nil
        if clip == nil {
            controlsVisible = true
        } else if selection == nil {
            controlsVisible = ProcessInfo.processInfo.systemUptime - lastPointerActivity < Self.controlsTimeout
        }
        loaded = false; ended = false; setPlayingUI(false); selection = clip?.id
        position = 0; lastSeek = 0; streams = []; subtitleDelay = 0; audioDelay = 0; panel = nil
        overControls = false
        if engine != nil { notice = nil }
        selectionDidChange?(); pip?.invalidate()
        guard let clip else { pip?.stop(); engine?.stop(); return }
        if let engine, !engine.load(clip.url.path, paused: true) {
            playRequested = false
            show("파일을 열 수 없습니다. \(clip.title)")
        }
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
        pendingSubtitles = subtitles
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
    private func addSubtitles(_ urls: [URL]) {
        guard let movie = current?.url, !urls.isEmpty, let engine else { return }
        guard loaded && sidecarsReady else { pendingSubtitles += urls; return }
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
            guard selectStream(.subtitle, id: track.id, in: choices) else { continue }
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
            addSubtitles(requested)
        }
    }

    func deleteCurrent(requiresConfirmation: Bool = true) {
        guard !deletionInProgress, let clip = current, let window,
              window.attachedSheet == nil else { return }
        deletionInProgress = true
        let movie = clip.url
        let resumeIfKept = playRequested
        if resumeIfKept { setPlaying(false) }
        let shared = Set(manualSubs.filter { $0.key != movie }.flatMap(\.value).map(\.standardizedFileURL))
        let attached = manualSubs[movie, default: []]
        Task {
            var deleted = false
            defer {
                deletionInProgress = false
                if !deleted && resumeIfKept && selection == clip.id { setPlaying(true) }
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
