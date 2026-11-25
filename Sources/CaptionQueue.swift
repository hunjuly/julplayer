import Foundation
import Combine

@MainActor
final class CaptionQueue: ObservableObject {
    struct Item: Identifiable {
        enum State { case waiting, running, completed, failed, cancelled }

        let id = UUID()
        let movie: URL
        let source: CaptionSource
        let language: CaptionInputLanguage
        let korean: Bool
        var state = State.waiting
        var message = "대기 중"
        var fraction: Double?
        var original: URL?
        var output: URL?

        var pending: Bool { state == .waiting || state == .running }
    }

    @Published private(set) var items = [Item]()
    @Published var translationModel: SubtitleModel {
        didSet {
            if translationModel == .standard { defaults.removeObject(forKey: Self.modelKey) }
            else { defaults.set(translationModel.id, forKey: Self.modelKey) }
        }
    }
    @Published private var inputLanguages = [URL: [String: CaptionInputLanguage]]()
    private static let modelKey = "subtitleTranslationModel"
    private let defaults: UserDefaults
    private var worker: Task<Void, Never>?
    private let generator: SubtitleGenerator
    private let credential: () throws -> String?
    private let completed: (URL, URL, URL?) -> Void

    init(generator: SubtitleGenerator = SubtitleGenerator(api: MediaAPI(), executable: SubtitleGenerator.bundledTool),
         credential: @escaping () throws -> String? = OpenAIKey.read, defaults: UserDefaults = .standard,
         completed: @escaping (URL, URL, URL?) -> Void) {
        self.defaults = defaults
        translationModel = (try? SubtitleModel(defaults.string(forKey: Self.modelKey) ?? "")) ?? .standard
        self.generator = generator
        self.credential = credential
        self.completed = completed
    }

    func inputLanguage(for movie: URL, track: String) -> CaptionInputLanguage {
        inputLanguages[movie.deletingLastPathComponent()]?[track] ?? .automatic
    }

    func setInputLanguage(_ language: CaptionInputLanguage, for movie: URL, track: String) {
        inputLanguages[movie.deletingLastPathComponent(), default: [:]][track] = language == .automatic ? nil : language
    }

    func enqueue(_ movies: [URL], using movie: URL, source: CaptionSource, korean: Bool) {
        let language = inputLanguage(for: movie, track: source.id)
        for episode in movies {
            guard let track = source.forEpisode(episode, using: movie) else { continue }
            let pending = items.contains {
                $0.pending && $0.movie == episode && $0.korean == korean
                    && $0.language == language && $0.source.url == track.url && $0.source.kind == track.kind
                    && $0.source.ordinal == track.ordinal
            }
            if !pending { items.append(Item(movie: episode, source: track, language: language, korean: korean)) }
        }
        startNext()
    }

    func remove(_ id: UUID) {
        if items.first(where: { $0.id == id })?.state == .running {
            worker?.cancel()
        } else {
            items.removeAll { $0.id == id }
        }
    }

    func stop() {
        items.removeAll { $0.state == .waiting }
        worker?.cancel()
    }

    private func update(_ id: UUID, _ edit: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        edit(&items[index])
    }

    private func startNext() {
        guard worker == nil, let item = items.first(where: { $0.state == .waiting }) else { return }
        let model = translationModel
        update(item.id) {
            $0.state = .running
            $0.message = "자막 준비 중"
        }
        worker = Task {
            do {
                let url = try await generator.generate(
                    movie: item.movie, source: item.source, korean: item.korean, inputLanguage: item.language, model: model,
                    credential: credential, originalSaved: { url in
                        await self.update(item.id) { $0.original = url }
                    }, progress: { message, fraction in
                        await self.update(item.id) { $0.message = message; $0.fraction = fraction }
                    })
                update(item.id) {
                    $0.output = url
                    $0.state = .completed
                    $0.message = "저장 완료"
                }
                completed(item.movie, url, items.first(where: { $0.id == item.id })?.original)
            } catch {
                update(item.id) {
                    $0.state = Task.isCancelled ? .cancelled : .failed
                    $0.message = Task.isCancelled ? "취소됨" : error.localizedDescription
                }
            }
            worker = nil
            startNext()
        }
    }
}
