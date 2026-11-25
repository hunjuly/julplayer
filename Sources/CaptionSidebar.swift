import SwiftUI

struct CaptionSidebar: View {
    @ObservedObject var session: PlayerSession
    @ObservedObject var queue: CaptionQueue
    @ViewState private var selected = ""
    @ViewState private var korean = true
    @ViewState private var showQueue = false
    @ViewState private var choosingEpisodes = false
    @ViewState private var episodes = Set<URL>()

    private var choices: [CaptionSource] {
        session.current.map { CaptionSource.choices(movie: $0.url, streams: session.streams) } ?? []
    }
    private var source: CaptionSource? { choices.first { $0.id == selected } }

    private var inputLanguage: Binding<CaptionInputLanguage> {
        guard let movie = session.current?.url, !selected.isEmpty else { return .constant(.automatic) }
        let track = selected
        return Binding(get: { queue.inputLanguage(for: movie, track: track) },
                       set: { queue.setInputLanguage($0, for: movie, track: track) })
    }

    private func chooseTrack() {
        let all = choices
        let foreign = all.filter { $0.language != "ko" }
        let items = korean && !foreign.isEmpty ? foreign : all
        selected = (items.first { $0.kind == .subtitle && $0.selected } ?? items.first { $0.kind == .subtitle }
                    ?? items.first { $0.selected } ?? items.first)?.id ?? ""
        choosingEpisodes = false
        episodes.removeAll()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI 자막").font(.headline)
                Spacer()
                Button { session.sidebar = nil } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("자막 패널 닫기").help("자막 패널 닫기 (Esc)")
            }
            Picker("자막 패널", selection: $showQueue) {
                Text("작업 추가").tag(false)
                Text("대기열 \(queue.items.filter(\.pending).count)").tag(true)
            }.labelsHidden().pickerStyle(.segmented)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if showQueue {
                        if queue.items.isEmpty { Text("대기 중인 작업이 없습니다.").foregroundStyle(.secondary) }
                        ForEach(queue.items) { item in
                            CaptionQueueRow(item: item) { queue.remove(item.id) }
                            Divider()
                        }
                    } else if let movie = session.current?.url {
                        if choosingEpisodes, let source { episodePicker(movie: movie, source: source) }
                        else { setup(movie) }
                    } else {
                        Text("영상을 먼저 열어 주세요.").foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10).buttonStyle(.bordered).controlSize(.small)
        .onAppear { chooseTrack(); showQueue = !queue.items.isEmpty }
        .onChange(of: session.selection) { _ in chooseTrack() }
        .onChange(of: choices) { items in if !items.contains(where: { $0.id == selected }) { chooseTrack() } }
    }

    @ViewBuilder private func setup(_ movie: URL) -> some View {
        Text(movie.lastPathComponent).fontWeight(.semibold).lineLimit(2).truncationMode(.middle).help(movie.lastPathComponent)
        VStack(alignment: .leading, spacing: 3) {
            Text("원본 트랙").font(.caption).foregroundStyle(.secondary)
            Picker("원본 트랙", selection: $selected) {
                if choices.isEmpty { Text("트랙 없음").tag("") }
                ForEach(choices) { Text($0.title).tag($0.id) }
            }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
        Picker("원본 언어", selection: inputLanguage) {
            ForEach(CaptionInputLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
        }.disabled(source == nil)
        Picker("저장할 자막", selection: $korean) {
            Text("원문 + 한국어").tag(true)
            Text("원문만").tag(false)
        }.labelsHidden().pickerStyle(.segmented)
        if let source {
            if source.kind == .audio {
                Text("선택한 음성의 대사 구간을 OpenAI로 보냅니다.").font(.caption).foregroundStyle(.secondary)
            }
            if korean && inputLanguage.wrappedValue != .korean {
                Text("한 편의 원문 자막 전체를 \(queue.translationModel.id) 모델로 번역합니다.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("현재 영상 추가") { add([movie], movie: movie, source: source) }
                if session.clips.contains(where: { $0.url != movie && source.forEpisode($0.url, using: movie) != nil }) {
                    Button("여러 편 선택") { episodes.removeAll(); choosingEpisodes = true }
                }
            }.disabled(!session.loaded)
        }
        Button("OpenAI 설정") { session.openAISettings?() }
    }

    @ViewBuilder private func episodePicker(movie: URL, source: CaptionSource) -> some View {
        Text(source.ordinal.map { "각 영상의 \(source.kind == .audio ? "음성" : "자막") \($0 + 1)번 트랙 사용" }
             ?? "각 영상에 같은 이름 규칙으로 붙은 외부 자막 사용").font(.caption).foregroundStyle(.secondary)
        let files = session.clips.map(\.url).filter { source.forEpisode($0, using: movie) != nil }
        HStack {
            Button("전체 선택") { episodes = Set(files) }
            Button("취소") { choosingEpisodes = false }
            Spacer()
            Button("\(episodes.count)편 추가") {
                add(files.filter { episodes.contains($0) }, movie: movie, source: source)
            }.disabled(episodes.isEmpty)
        }
        ForEach(files, id: \.self) { file in
            Toggle(isOn: Binding(get: { episodes.contains(file) }, set: {
                if $0 { episodes.insert(file) } else { episodes.remove(file) }
            })) {
                Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
            }.toggleStyle(.checkbox).help(file.lastPathComponent)
        }
    }

    private func add(_ movies: [URL], movie: URL, source: CaptionSource) {
        queue.enqueue(movies, using: movie, source: source, korean: korean)
        choosingEpisodes = false
        episodes.removeAll()
        showQueue = true
    }
}

private struct CaptionQueueRow: View {
    let item: CaptionQueue.Item
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.movie.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    .fontWeight(.semibold).help(item.movie.lastPathComponent)
                Spacer(minLength: 0)
                Button(item.pending ? "취소" : "목록에서 제거", action: remove)
                    .help(item.state == .running ? "진행 중인 작업 취소" : "대기열에서 제거")
            }
            Text(item.message).font(.caption).foregroundStyle(item.state == .failed ? Color.orange : .secondary)
                .textSelection(.enabled)
            if item.state == .running {
                ProgressView(value: item.fraction).progressViewStyle(.linear)
            }
            if let url = item.original { SavedFileRow(url: url, label: "원문") }
            if let url = item.output { SavedFileRow(url: url, label: item.original == nil ? "원문" : "한국어") }
        }
    }
}
