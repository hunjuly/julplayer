import AppKit
import SwiftUI

@MainActor
final class WorkInfoModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var document = ""
    @Published private(set) var savedURL: URL?
    @Published private(set) var matches = [WorkRecord]()
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var error = ""
    private var identity: WorkIdentity?
    private var task: Task<Void, Never>?
    private let api: MediaAPI
    private let key: () throws -> String?

    init(api: MediaAPI = MediaAPI(), key: @escaping () throws -> String? = OpenAIKey.read) {
        self.api = api
        self.key = key
    }

    func cancel() {
        task?.cancel()
        task = nil
        if busy { status = "조회를 취소했습니다." }
        busy = false
    }

    private func run(_ status: String, _ operation: @escaping @MainActor () async throws -> Void) {
        cancel()
        self.status = status
        error = ""
        busy = true
        task = Task {
            do { try await operation() } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { self.busy = false }
        }
    }

    func open(movie: URL?) {
        cancel()
        identity = nil
        document = ""
        savedURL = nil
        matches = []
        query = ""
        error = ""
        guard let movie else {
            status = "작품 정보를 볼 영상을 먼저 열어 주세요."
            return
        }
        run("저장된 작품 정보 읽는 중") {
            let (id, cache) = try await Task.detached(priority: .userInitiated) {
                let dir = movie.deletingLastPathComponent()
                let siblings =
                    (try? FileManager.default.contentsOfDirectory(
                        at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                let id = WorkIdentity(
                    movie: movie, siblings: siblings.filter { LocalMedia.videoExtensions.contains($0.pathExtension.lowercased()) })
                for path in id.cacheFiles {
                    if let text = try SidecarFile.read(path) { return (id, (path, text) as (URL, String)?) }
                }
                return (id, nil)
            }.value
            try Task.checkCancellation()
            self.identity = id
            self.query = id.search
            if let (path, text) = cache {
                self.savedURL = path
                self.document = text
                self.status = ""
                return
            }
            guard !id.title.isEmpty else {
                self.status = "검색할 작품명을 입력해 주세요."
                return
            }
            try await self.lookup(id.search, web: false)
        }
    }

    func search(web: Bool) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identity != nil, !text.isEmpty else { return }
        matches = []
        run("작품 찾는 중") { try await self.lookup(text, web: web) }
    }

    private func lookup(_ query: String, web: Bool) async throws {
        guard let identity else { return }
        let credential = try key()
        var results: [WorkRecord]
        var searched = query
        let webQuery = (query == identity.search ? identity.year : nil).map { query + " " + String($0) } ?? query
        if web {
            guard let credential else { throw MediaToolError("웹으로 작품을 찾으려면 OpenAI 설정에 API 키를 등록해 주세요.") }
            results = try await WorkLookup.web(query: webQuery, key: credential, api: api)
        } else {
            status = "AniList에서 작품 찾는 중"
            results = try await WorkLookup.anime(query: query, api: api)
            if results.isEmpty, query.range(of: #"[가-힣]"#, options: .regularExpression) != nil {
                let base = query == identity.search ? identity.title : query
                if let native = try? await WorkLookup.japaneseTitle(for: base, api: api) {
                    let suffix = query == identity.search ? String(query.dropFirst(base.count)) : ""
                    searched = native + suffix
                    results = try await WorkLookup.anime(query: searched, api: api)
                    if results.isEmpty && !suffix.isEmpty {
                        results = try await WorkLookup.anime(query: native, api: api)
                    }
                }
                try Task.checkCancellation()
            }
            if results.isEmpty, let credential, query.range(of: #"[가-힣]"#, options: .regularExpression) != nil {
                let answer = try await api.response(
                    key: credential,
                    instructions:
                        "애니 작품 검색어를 AniList의 일본어 원제 또는 통용 영어 제목 하나로 변환한다. 기수가 있으면 유지한다. 확신이 없으면 빈 문자열에 해당하는 물음표 하나만 반환한다. 제목 외 문장을 쓰지 않는다.",
                    input: query)
                if answer.text != "?", answer.text.count < 160 {
                    searched = answer.text
                    results = try await WorkLookup.anime(query: searched, api: api)
                }
            }
            if results.isEmpty, let credential {
                try Task.checkCancellation()
                status = "웹에서 작품과 출처 확인 중"
                results = try await WorkLookup.web(query: webQuery, key: credential, api: api)
            }
        }
        try Task.checkCancellation()
        matches = results
        if let match = WorkLookup.exact(results, query: searched, year: identity.year)
            ?? (results.count == 1 && !results[0].fromCatalogue && (identity.year == nil || identity.year == results[0].year)
                ? results[0] : nil)
        {
            try await finish(match, credential: credential)
        } else {
            status = results.isEmpty ? "일치하는 작품을 찾지 못했습니다. 원제나 영문 제목으로도 검색할 수 있습니다." : "영상에 해당하는 작품과 시즌을 선택하세요."
        }
    }

    func choose(_ record: WorkRecord, original: Bool = false) {
        run("작품 소개 정리 중") { try await self.finish(record, credential: original ? nil : try self.key()) }
    }

    var canAddKorean: Bool { savedURL != nil && SavedIntroduction(document) != nil }

    func addKorean(settings: @escaping () -> Void) {
        guard let url = savedURL, let introduction = SavedIntroduction(document) else { return }
        run("한국어 소개 작성 중") {
            guard let credential = try self.key() else {
                self.status = ""
                settings()
                return
            }
            let korean = try await WorkLookup.koreanSummary(
                title: introduction.title, synopsis: introduction.original, key: credential, api: self.api)
            try Task.checkCancellation()
            let updated = try await Task.detached(priority: .userInitiated) {
                try SidecarFile.update(url) { current in
                    try SavedIntroduction.adding(korean, to: current, expected: introduction.original)
                }
            }.value
            try Task.checkCancellation()
            self.document = updated
            self.status = ""
        }
    }

    private func finish(_ record: WorkRecord, credential: String?) async throws {
        guard let identity else { return }
        let target = identity.document
        var summary = record.synopsis
        if record.fromCatalogue, let credential {
            status = "스포일러 없는 한국어 소개 작성 중"
            summary = try await WorkLookup.koreanSummary(
                title: record.title, synopsis: record.synopsis, facts: record.fields.map { $0.1 }, key: credential, api: api)
        }
        try Task.checkCancellation()
        let content = record.markdown(summary: summary.isEmpty ? "확인된 작품 소개가 없습니다." : summary, season: identity.season)
        do {
            // A concurrent lookup or a user's own Markdown takes precedence at publication.
            let saved = try await Task.detached(priority: .userInitiated) {
                if try SidecarFile.create(content, at: target) { return content }
                return try SidecarFile.read(target) ?? content
            }.value
            try Task.checkCancellation()
            document = saved
            savedURL = target
            matches = []
            status = ""
        } catch {
            try Task.checkCancellation()
            document = content
            matches = []
            self.error = "작품 정보를 저장할 수 없습니다. " + error.localizedDescription
            status = ""
        }
    }
}

@MainActor
final class CaptionJob: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var message = ""
    @Published private(set) var fraction: Double?
    @Published private(set) var output: URL?
    @Published private(set) var movie: URL?
    @Published private(set) var error = ""
    @Published private var inputLanguages: [URL: [String: CaptionInputLanguage]] = [:]
    private var task: Task<Void, Never>?
    private let generator: SubtitleGenerator
    private let credential: () throws -> String?
    init(
        generator: SubtitleGenerator = SubtitleGenerator(api: MediaAPI(), executable: SubtitleGenerator.bundledTool),
        credential: @escaping () throws -> String? = OpenAIKey.read
    ) {
        self.generator = generator
        self.credential = credential
    }

    func inputLanguage(for movie: URL, track: String) -> CaptionInputLanguage {
        inputLanguages[movie.deletingLastPathComponent()]?[track] ?? .automatic
    }

    func setInputLanguage(_ language: CaptionInputLanguage, for movie: URL, track: String) {
        let folder = movie.deletingLastPathComponent()
        inputLanguages[folder, default: [:]][track] = language == .automatic ? nil : language
    }

    func start(movie: URL, source: CaptionSource, korean: Bool, completed: @escaping @MainActor (URL, URL) -> Void) {
        guard !running else { return }
        self.movie = movie
        output = nil
        error = ""
        fraction = nil
        message = "자막 준비 중"
        running = true
        let language = inputLanguage(for: movie, track: source.id)
        task = Task {
            defer {
                running = false
                task = nil
            }
            do {
                let url = try await generator.generate(
                    movie: movie, source: source, korean: korean, inputLanguage: language, credential: credential
                ) {
                    [weak self] status, value in
                    await self?.progress(status, value: value)
                }
                output = url
                message = "자막을 저장했습니다."
                fraction = nil
                completed(movie, url)
            } catch {
                message = Task.isCancelled ? "자막 생성을 취소했습니다." : ""
                if !Task.isCancelled { self.error = error.localizedDescription }
                fraction = nil
            }
        }
    }
    private func progress(_ status: String, value: Double?) {
        message = status
        fraction = value
    }
    func cancel() { task?.cancel() }
}

@MainActor
final class MediaToolsController: NSObject, NSWindowDelegate {
    private let session: PlayerSession
    let info = WorkInfoModel()
    let captions = CaptionJob()
    private var infoWindow: NSWindow?, captionWindow: NSWindow?, settingsWindow: NSWindow?
    init(session: PlayerSession) { self.session = session }

    private func makeWindow<Content: View>(_ title: String, size: NSSize, minimum: NSSize, content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        let host = NSHostingView(rootView: content.buttonStyle(.bordered).preferredColorScheme(.dark))
        host.sizingOptions = []
        window.contentView = host
        window.contentMinSize = minimum
        window.setContentSize(size)
        window.center()
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.level = session.window?.level ?? .normal
        return window
    }

    func showInfo() {
        if infoWindow == nil {
            infoWindow = makeWindow(
                "작품 정보", size: NSSize(width: 510, height: 520), minimum: NSSize(width: 350, height: 280),
                content: WorkInfoView(model: info, settings: { [weak self] in self?.showSettings() }))
        }
        if infoWindow?.isVisible != true { info.open(movie: session.current?.url) }
        infoWindow?.makeKeyAndOrderFront(nil)
    }

    func showCaptions() {
        session.panel = nil
        if captionWindow == nil {
            captionWindow = makeWindow(
                "AI 자막 생성", size: NSSize(width: 470, height: 310), minimum: NSSize(width: 370, height: 285),
                content: CaptionToolView(session: session, job: captions, settings: { [weak self] in self?.showSettings() }))
        }
        captionWindow?.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(
                "OpenAI 설정", size: NSSize(width: 430, height: 190), minimum: NSSize(width: 370, height: 175),
                content: AIKeyView(close: { [weak self] in self?.settingsWindow?.close() }))
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func setWindowLevel(_ level: NSWindow.Level) {
        for window in [infoWindow, captionWindow, settingsWindow] { window?.level = level }
    }

    func selectionChanged() { if infoWindow?.isVisible == true { info.open(movie: session.current?.url) } }
    func windowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        if window === infoWindow {
            info.cancel()
            infoWindow = nil
        }
        if window === settingsWindow { settingsWindow = nil }
        if window === captionWindow { captionWindow = nil }
    }
    func shutdown() {
        captions.cancel()
        info.cancel()
        infoWindow?.close()
        captionWindow?.close()
        settingsWindow?.close()
    }
}

private struct SavedFileRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Text(url.lastPathComponent)
                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                .help(url.lastPathComponent)
            Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .fixedSize()
        }
    }
}

private struct WorkInfoView: View {
    @ObservedObject var model: WorkInfoModel
    let settings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.savedURL != nil || !model.document.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(model.document.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                            if line.hasPrefix("# ") {
                                Text(String(line.dropFirst(2))).font(.title2.bold())
                            } else if line.hasPrefix("## ") {
                                Text(String(line.dropFirst(3))).font(.headline).padding(.top, 7)
                            } else if !line.isEmpty {
                                let raw = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
                                Text(
                                    (try? AttributedString(
                                        markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                                        ?? AttributedString(raw))
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .environment(
                    \.openURL,
                    OpenURLAction { url in
                        ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
                    })
                if let url = model.savedURL {
                    Divider()
                    HStack {
                        SavedFileRow(url: url)
                        Spacer()
                        if model.busy {
                            ProgressView().controlSize(.small)
                            Button("취소", action: model.cancel)
                        } else if model.canAddKorean {
                            Button("한국어 소개 추가") { model.addKorean(settings: settings) }
                        }
                    }
                }
            } else {
                HStack {
                    TextField("작품명 또는 원제", text: $model.query).onSubmit { model.search(web: false) }
                    Button("검색") { model.search(web: false) }.disabled(model.query.isEmpty)
                    Button("웹 검색") { model.search(web: true) }.disabled(model.query.isEmpty)
                }
                if model.busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(model.status)
                        Spacer()
                        Button("취소") { model.cancel() }
                    }
                } else if !model.status.isEmpty {
                    Text(model.status).foregroundStyle(.secondary)
                }
                if !model.busy {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.matches) { record in
                                Button {
                                    model.choose(record)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(record.title).fontWeight(.semibold)
                                        if !record.detail.isEmpty { Text(record.detail).font(.caption).foregroundStyle(.secondary) }
                                    }.multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                                }
                                if !model.error.isEmpty && record.fromCatalogue {
                                    Button("AniList 원문으로 저장") { model.choose(record, original: true) }
                                }
                            }
                        }
                    }
                } else {
                    Spacer()
                }
                Button("OpenAI 설정", action: settings)
            }
            if !model.error.isEmpty { Text(model.error).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct CaptionToolView: View {
    @ObservedObject var session: PlayerSession
    @ObservedObject var job: CaptionJob
    let settings: () -> Void
    @ViewState private var selected = ""
    @ViewState private var korean = true
    private var choices: [CaptionSource] {
        session.current.map { CaptionSource.choices(movie: $0.url, streams: session.streams) } ?? []
    }
    private var inputLanguage: Binding<CaptionInputLanguage> {
        guard let movie = session.current?.url, !selected.isEmpty else { return .constant(.automatic) }
        let track = selected
        return Binding(
            get: { job.inputLanguage(for: movie, track: track) },
            set: { job.setInputLanguage($0, for: movie, track: track) })
    }
    private var fileName: String { (job.running ? job.movie : session.current?.url)?.lastPathComponent ?? "영상을 먼저 열어 주세요." }
    private func reset() {
        let items = choices
        selected =
            (items.first { $0.kind == .subtitle && $0.selected } ?? items.first { $0.kind == .subtitle }
            ?? items.first { $0.selected } ?? items.first)?.id ?? ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(fileName).font(.headline).lineLimit(1).truncationMode(.middle)
            if !job.running {
                Picker("원본 트랙", selection: $selected) {
                    if choices.isEmpty { Text("트랙 없음").tag("") }
                    ForEach(choices) { Text($0.title).tag($0.id) }
                }
                Picker("원본 언어", selection: inputLanguage) {
                    ForEach(CaptionInputLanguage.allCases, id: \.self) { language in
                        Text(language.title).tag(language)
                    }
                }.disabled(!choices.contains { $0.id == selected })
                Picker("저장할 자막", selection: $korean) {
                    Text("한국어").tag(true)
                    Text("원어").tag(false)
                }.pickerStyle(.segmented)
            }
            if !job.running, let source = choices.first(where: { $0.id == selected }) {
                if source.kind == .audio {
                    Text("선택한 음성의 대사 구간을 OpenAI로 보냅니다.").font(.caption).foregroundStyle(.secondary)
                } else if korean && inputLanguage.wrappedValue != .korean {
                    Text("번역이 필요하면 선택한 자막의 대사를 OpenAI로 보냅니다.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if job.running {
                if let progress = job.fraction { ProgressView(value: progress) } else { ProgressView().controlSize(.small) }
            }
            if job.running || job.movie == session.current?.url {
                if !job.message.isEmpty { Text(job.message).font(.callout) }
                if !job.error.isEmpty { Text(job.error).foregroundStyle(.orange).textSelection(.enabled) }
                if let output = job.output {
                    SavedFileRow(url: output)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button("OpenAI 설정", action: settings)
                Spacer()
                if job.running {
                    Button("생성 취소", action: job.cancel)
                } else {
                    Button("자막 생성") {
                        guard let movie = session.current?.url, let source = choices.first(where: { $0.id == selected }) else {
                            return
                        }
                        job.start(movie: movie, source: source, korean: korean) { movie, result in
                            if session.current?.url == movie {
                                session.openMedia([result])
                                session.showFeedback("AI 자막 준비됨")
                            }
                        }
                    }.keyboardShortcut(.defaultAction).disabled(!session.loaded || !choices.contains { $0.id == selected })
                }
            }
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { reset() }.onChange(of: session.selection) { _ in reset() }
            .onChange(of: choices) { items in if !items.contains(where: { $0.id == selected }) { reset() } }
    }
}

private struct AIKeyView: View {
    let close: () -> Void
    @Environment(\.openURL) private var openURL
    @ViewState private var input = ""
    @ViewState private var hasKey = false
    @ViewState private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("개인 API 키를 이 Mac의 키체인에 저장합니다. OpenAI 사용료는 연결한 API 계정에 청구됩니다.").font(.callout)
            SecureField(hasKey ? "새 API 키" : "OpenAI API 키", text: $input)
            if !error.isEmpty { Text(error).foregroundStyle(.orange) }
            HStack {
                if hasKey {
                    Button("저장된 키 삭제") { save("") }
                } else {
                    Button { openURL(URL(string: "https://platform.openai.com/api-keys")!) } label: {
                        Label("API 키 발급", systemImage: "arrow.up.right")
                    }
                }
                Spacer()
                Button("저장") { save(input) }.keyboardShortcut(.defaultAction).disabled(
                    input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { do { hasKey = try OpenAIKey.read() != nil } catch { self.error = error.localizedDescription } }
    }
    private func save(_ key: String) {
        do {
            try OpenAIKey.save(key)
            input = ""
            close()
        } catch { self.error = error.localizedDescription }
    }
}
