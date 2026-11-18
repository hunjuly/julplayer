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

enum StreamKind: String, Identifiable {
    case subtitle = "sub", audio = "audio"
    var id: Self { self }
}
struct MediaStream: Identifiable, Equatable {
    let id: Int
    let kind: StreamKind
    let title: String
    let selected: Bool
    init?(_ entry: [String: Any]) {
        guard let key = entry["type"] as? String, let kind = StreamKind(rawValue: key), let id = entry["id"] as? Int else { return nil }
        self.kind = kind; self.id = id
        selected = entry["selected"] as? Bool == true
        let locale = Locale(identifier: "ko")
        let language = (entry["lang"] as? String).flatMap { locale.localizedString(forLanguageCode: $0) ?? $0 }
        let external = (entry["external-filename"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        var parts = [entry["title"] as? String, language].compactMap { $0 }.filter { !$0.isEmpty }
        if parts.count == 2 && parts[0] == parts[1] { parts.removeLast() }
        if parts.isEmpty { parts = [external ?? "트랙 \(id)"] }
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
    @Published private(set) var volume = 0.68
    @Published private(set) var streams: [MediaStream] = []
    @Published private(set) var subtitleDelay = 0.0
    @Published private(set) var audioDelay = 0.0
    @Published var panel: StreamKind? { didSet { reveal() } }
    @Published var showsRemaining = false
    @Published var showsPlaylist = false { didSet { reveal(); windowStateChanged?() } }
    @Published var dropTarget = false
    @Published private(set) var controlsVisible = true
    @Published var pinWhenPlaying = UserDefaults.standard.bool(forKey: "pinWhenPlaying") {
        didSet { UserDefaults.standard.set(pinWhenPlaying, forKey: "pinWhenPlaying"); windowStateChanged?() }
    }
    @Published var pipActive = false { didSet { windowStateChanged?() } }
    @Published private(set) var notice: String?
    @Published private(set) var loaded = false
    @Published private(set) var trashInProgress = false
    @Published var smallPictureSize: CGSize?

    var selectionDidChange: (() -> Void)?
    var videoSizeDidChange: (() -> Void)?
    var windowStateChanged: (() -> Void)?
    weak var window: NSWindow?
    @Published private(set) var videoDisplaySize: CGSize?
    var current: Clip? { clips.first { $0.id == selection } }
    var duration: Double { current?.duration ?? 0 }
    var overControls = false { didSet { reveal() } }
    var scrubbing = false { didSet { reveal() } }
    let engine: VideoEngine?
    private(set) var pip: PictureInPicture?
    private var lastInteraction = ProcessInfo.processInfo.systemUptime
    private var lastSeek: TimeInterval = 0
    private var noticeEnds = TimeInterval.infinity
    private var timer: Timer?
    private var beforeMute = 0.68
    private var folderScan: Task<Void, Never>?
    // mpv can pause itself on the last frame before the next poll reports EOF.
    private var playRequested = false
    private var ended = false
    private var manualSubs: [URL: [URL]] = [:]
    private var fileTicket = 0

    init() {
        do { engine = try VideoEngine.make() }
        catch { engine = nil; notice = error.localizedDescription }
    }

    func start(opening urls: [URL]) {
        if let engine {
            pip = PictureInPicture(session: self, layer: engine.displayLayer)
            _ = engine.setNumber(volume * 100, forOption: "volume")
            let clock = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer = clock
            RunLoop.main.add(clock, forMode: .common)
        }
        if !urls.isEmpty { openFromFinder(urls) }
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
    func reveal() {
        lastInteraction = ProcessInfo.processInfo.systemUptime
        if !controlsVisible { controlsVisible = true }
    }
    func show(_ text: String, seconds: Double = 4) {
        notice = text; noticeEnds = ProcessInfo.processInfo.systemUptime + seconds; reveal()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if notice != nil && now >= noticeEnds { notice = nil }
        if pipActive { pip?.attachPanelOutputIfNeeded() }
        guard let current, let changes = engine?.poll() else { return }
        if let error = changes["error"] as? String {
            playRequested = false; ended = false; loaded = false; videoDisplaySize = nil; setPlayingUI(false)
            show("재생할 수 없습니다. \(current.title) (\(error))", seconds: 12)
            pip?.invalidate(); return
        }
        if changes["loaded"] as? Bool == true {
            loaded = true; ended = false
            engine?.setPaused(!playRequested)
            attachSidecars(for: current.url, ticket: fileTicket)
            pip?.invalidate()
        }
        if let width = changes["displayWidth"] as? Int, let height = changes["displayHeight"] as? Int {
            let size = CGSize(width: width, height: height)
            if size != videoDisplaySize {
                videoDisplaySize = size
                videoSizeDidChange?()
            }
        }
        if let rows = changes["tracks"] as? [[String: Any]] {
            let values = rows.compactMap(MediaStream.init)
            if values != streams { streams = values }
        }
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
        if playing && controlsVisible && !overControls && !scrubbing && !showsPlaylist && panel == nil && now-lastInteraction > 2.8 {
            controlsVisible = false
        }
    }

    private func advanceAfterEnd() {
        guard ended, playRequested, !scrubbing else { return }
        if let next = adjacent(1) { select(next) }
        else if folderScan == nil { playRequested = false }
    }

    private func setPlayingUI(_ value: Bool) {
        if playing != value { playing = value; if !value { reveal() }; windowStateChanged?(); pip?.invalidate() }
    }
    func setPlaying(_ value: Bool) {
        guard let current else { return }
        playRequested = value
        if value && ended && !loaded { select(current); return }
        if value && loaded && (ended || (duration > 0 && position >= duration - 0.08)) { seek(to: 0) }
        engine?.setPaused(!value)
        if loaded { setPlayingUI(value) }
        reveal()
    }
    func togglePlay() {
        if current == nil { openFiles() }
        else { setPlaying(loaded ? !playing : !playRequested) }
    }
    func seek(to value: Double) {
        guard loaded && duration > 0 else { return }
        ended = false
        position = min(duration, max(0,value)); lastSeek = ProcessInfo.processInfo.systemUptime
        engine?.seek(position); reveal()
    }
    func setVolume(_ value: Double) {
        volume = min(1,max(0,value)); _ = engine?.setNumber(volume * 100, forOption: "volume"); reveal()
    }
    func toggleMute() {
        if volume > 0 { beforeMute = volume; setVolume(0) } else { setVolume(beforeMute) }
    }
    func selectStream(_ kind: StreamKind, id: Int) {
        if engine?.selectTrack(id, property: kind == .audio ? "aid" : "sid") != true { show("스트림을 전환할 수 없습니다.") }
        reveal()
    }
    func toggleCaptions() {
        let subs = streams.filter { $0.kind == .subtitle }
        if let first = subs.first { selectStream(.subtitle, id: subs.contains(where: \.selected) ? -1 : first.id) }
    }
    func setDelay(_ kind: StreamKind, seconds: Double) {
        guard seconds.isFinite else { return }
        let value = (min(3600,max(-3600,seconds))*1000).rounded()/1000
        guard engine?.setNumber(value, forOption: kind == .audio ? "audio-delay" : "sub-delay") == true else {
            show("싱크를 변경할 수 없습니다.")
            return
        }
        if kind == .audio { audioDelay = value } else { subtitleDelay = value }
        reveal()
    }

    func select(_ clip: Clip?) {
        fileTicket += 1
        playRequested = clip != nil
        videoDisplaySize = nil
        smallPictureSize = nil
        loaded = false; ended = false; setPlayingUI(false); selection = clip?.id
        position = 0; lastSeek = 0; streams = []; subtitleDelay = 0; audioDelay = 0; panel = nil
        overControls = false
        if engine != nil { notice = nil }
        reveal(); selectionDidChange?(); pip?.invalidate()
        guard let clip else { pip?.stop(); engine?.stop(); return }
        if let engine, !engine.load(clip.url.path, paused: false) {
            playRequested = false
            show("파일을 열 수 없습니다. \(clip.title)")
        }
    }
    func adjacent(_ offset: Int) -> Clip? {
        guard let i = clips.firstIndex(where: { $0.id == selection }), clips.indices.contains(i+offset) else { return nil }
        return clips[i+offset]
    }
    func stepFile(_ offset: Int) { if let clip = adjacent(offset) { select(clip) } }

    func openFromFinder(_ input: [URL]) {
        let files = input.map(\.standardizedFileURL).filter(LocalMedia.isVideo)
        guard let first = files.first else { addSubtitles(input.filter(LocalMedia.isSubtitle)); return }
        folderScan?.cancel()
        let clip = Clip(file: first)
        clips = [clip]; select(clip)
        folderScan = Task {
            let found = await Task.detached(priority: .userInitiated) { LocalMedia.folderPlaylist(for: files) }.value
            guard !Task.isCancelled else { return }
            let known = Dictionary(clips.map { ($0.url, $0) }, uniquingKeysWith: { a,_ in a })
            let inFolder = Set(found)
            let appended = clips.filter { !inFolder.contains($0.url) }
            clips = found.map { known[$0] ?? Clip(file: $0) } + appended
            folderScan = nil
            advanceAfterEnd()
        }
    }

    func append(_ urls: [URL]) {
        let videos = urls.map(\.standardizedFileURL).filter(LocalMedia.isVideo)
        if current == nil, !videos.isEmpty { openFromFinder(videos); return }
        for url in videos where !clips.contains(where: { $0.url == url }) { clips.append(Clip(file: url)) }
        addSubtitles(urls.filter(LocalMedia.isSubtitle))
    }
    func openFiles(appendToList: Bool = false) {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = appendToList ? "재생목록에 추가" : "동영상 열기"
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.allowedContentTypes = LocalMedia.types
        panel.beginSheetModal(for: window) { [weak self] reply in
            guard reply == .OK else { return }
            if appendToList { self?.append(panel.urls) } else { self?.openFromFinder(panel.urls) }
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
        guard loaded else { return }
        for url in urls where LocalMedia.isSubtitle(url) {
            if engine?.addSubtitle(url.path, select: true) == true, let movie = current?.url {
                var prior = manualSubs[movie, default: []]
                if !prior.contains(url) { prior.append(url); manualSubs[movie] = prior }
            }
        }
    }
    private func attachSidecars(for movie: URL, ticket: Int) {
        Task {
            let files = await Task.detached(priority: .userInitiated) { LocalMedia.sidecars(for: movie) }.value
            guard ticket == fileTicket else { return }
            var used = Set<URL>()
            let all = files + manualSubs[movie, default: []]
            for url in all where used.insert(url.standardizedFileURL).inserted {
                // VobSub's .idx loads the companion .sub by itself.
                if url.pathExtension.lowercased() == "sub" && all.contains(where: { $0.deletingPathExtension() == url.deletingPathExtension() && $0.pathExtension.lowercased() == "idx" }) { continue }
                _ = engine?.addSubtitle(url.path, select: used.count == 1)
            }
        }
    }

    func trashCurrent(requiresConfirmation: Bool = true) {
        guard !trashInProgress, let clip = current, let window,
              window.attachedSheet == nil else { return }
        trashInProgress = true
        let movie = clip.url
        let resumeIfKept = playRequested
        if resumeIfKept { setPlaying(false) }
        let shared = Set(manualSubs.filter { $0.key != movie }.flatMap(\.value).map(\.standardizedFileURL))
        let attached = manualSubs[movie, default: []]
        Task {
            var moved = false
            defer {
                trashInProgress = false
                if !moved && resumeIfKept && selection == clip.id { setPlaying(true) }
            }
            do {
                let entries = try await Task.detached(priority: .userInitiated) {
                    try LocalMedia.trashEntries(movie: movie, attached: attached, shared: shared)
                }.value
                guard selection == clip.id, window.attachedSheet == nil else { return }
                if requiresConfirmation {
                    guard await confirmTrash(entries, movie: movie, in: window), selection == clip.id else { return }
                }
                try await Task.detached(priority: .userInitiated) { try LocalMedia.trash(entries) }.value
                moved = true
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
                show(count == 0 ? "영상을 휴지통으로 옮겼습니다." : "영상과 자막 \(count)개를 휴지통으로 옮겼습니다.")
            } catch { show(error.localizedDescription, seconds: 10) }
        }
    }

    private func confirmTrash(_ entries: [LocalMedia.TrashEntry], movie: URL, in window: NSWindow) async -> Bool {
        let count = entries.count - 1
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 0 ? "이 영상을 휴지통으로 옮길까요?" : "영상과 연결된 자막 \(count)개를 휴지통으로 옮길까요?"
        alert.informativeText = entries.map { entry in
            entry.url.deletingLastPathComponent() == movie.deletingLastPathComponent() ? entry.url.lastPathComponent : entry.url.path
        }.joined(separator: "\n")
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: "휴지통으로 이동").hasDestructiveAction = true
        return await alert.beginSheetModal(for: window) == .alertSecondButtonReturn
    }
}
