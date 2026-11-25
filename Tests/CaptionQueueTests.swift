// From the repository root after ./build.sh, in zsh:
// t=$(mktemp -d); player=(Sources/*.swift); fw=$PWD/JulPlayer.app/Contents/Frameworks
// xcrun clang -fobjc-arc -Wno-deprecated-declarations -I Engine/include -c Engine/VideoEngine.m -o "$t/engine.o"
// xcrun swiftc -parse-as-library -import-objc-header Engine/VideoEngine.h ${player:#Sources/main.swift} Tests/CaptionQueueTests.swift "$t/engine.o" "$fw/libmpv.2.dylib" -Xlinker -rpath -Xlinker "$fw" -framework OpenGL -framework IOSurface -o "$t/queue"
// "$t/queue" JulPlayer.app/Contents/Helpers/ffmpeg
import Foundation

private final class CaptionFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body: Data
        if let data = request.httpBody { body = data }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                precondition(count >= 0)
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        } else { preconditionFailure("Missing API body") }

        func respond(_ status: Int, _ json: [String: Any]) {
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
            client?.urlProtocolDidFinishLoading(self)
        }
        if request.url?.lastPathComponent == "transcriptions" {
            precondition(String(decoding: body, as: UTF8.self).contains("name=\"languages[]\"\r\n\r\nja"))
            respond(200, ["text": "おかえり。", "languages": [["code": "ja"]]])
            return
        }
        let payload = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        let input = payload["input"] as! String
        let passage = try! JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any]
        let lines = passage["lines"] as! [[String: Any]]
        let previous = passage["previous"] as! [[String: String]]
        let following = passage["following"] as! [String]
        let first = lines.first!["text"] as! String
        if first == "失敗" { respond(400, ["error": ["message": "fixture error"]]); return }
        if first == "待機" { return } // Held until the test cancels this task.
        if first == "本編0" {
            precondition(lines.count == 45 && previous.isEmpty && following.first == "本編45")
        } else if first == "本編45" {
            precondition(previous.last == ["original": "本編44", "korean": "대사 44"] && following.isEmpty)
        }
        let result = lines.map { ["id": $0["id"]!, "text": "대사 \($0["id"]!)"] }
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: ["lines": result]), as: UTF8.self)
        respond(200, ["status": "completed", "output": [["content": [["type": "output_text", "text": text]]]]])
    }
}

@main
enum CaptionQueueTests {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        preconditionFailure("Caption queue timed out")
    }

    @MainActor static func main() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CaptionFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let generator = SubtitleGenerator(api: MediaAPI(session: session), executable: URL(fileURLWithPath: CommandLine.arguments[1]))
        var finished = [URL]()
        let queue = CaptionQueue(generator: generator, credential: { "test" }) { movie, _, _ in finished.append(movie) }
        let movies = (1...5).map { root.appendingPathComponent("\($0).mkv") }
        let texts = [(0..<51).map { "本編\($0)" }, ["失敗"], ["待機"], ["消去"], ["おはよう。"]]
        for (movie, lines) in zip(movies, texts) {
            try Data().write(to: movie)
            let cues = lines.enumerated().map { SubtitleCue(start: Double($0.offset), end: Double($0.offset) + 0.8, text: $0.element) }
            try SubtitleCue.render(cues).write(to: movie.deletingPathExtension().appendingPathExtension("source.srt"), atomically: true, encoding: .utf8)
        }
        let movie = movies[0]
        for ext in ["ja", "ko"] {
            try "기존 파일".write(to: root.appendingPathComponent("1.\(ext).srt"), atomically: true, encoding: .utf8)
        }
        let source = CaptionSource(id: "s-1", kind: .subtitle, url: root.appendingPathComponent("1.source.srt"),
                                   map: "0:s:0", title: "원본", language: "en", selected: true, ordinal: nil)
        queue.setInputLanguage(.japanese, for: movie, track: source.id)
        queue.enqueue(movies, using: movie, source: source, korean: true)
        queue.enqueue(movies, using: movie, source: source, korean: true)
        precondition(queue.items.count == 5 && queue.items[0].state == .running && queue.items[1].state == .waiting)
        queue.remove(queue.items[3].id)
        queue.setInputLanguage(.english, for: movie, track: source.id)
        try await wait { queue.items[2].original != nil }
        precondition(queue.items.map(\.state) == [.completed, .failed, .running, .waiting])
        queue.remove(queue.items[2].id)
        try await wait { queue.items.last?.state == .completed }
        precondition(queue.items.map(\.state) == [.completed, .failed, .cancelled, .completed] && finished == [movies[0], movies[4]])
        precondition(queue.items.allSatisfy { $0.language == .japanese })
        for item in queue.items {
            let original = try String(contentsOf: item.original!, encoding: .utf8)
            let cues = SubtitleCue.parse(original)
            let index = movies.firstIndex(of: item.movie)!
            precondition(cues.map(\.text) == texts[index])
            if let output = item.output {
                let translated = SubtitleCue.parse(try String(contentsOf: output, encoding: .utf8))
                precondition(translated.map(\.start) == cues.map(\.start) && translated.map(\.end) == cues.map(\.end))
                precondition(translated.first?.text == "대사 0")
            }
        }
        precondition(queue.items[0].original?.lastPathComponent == "1.ai.ja.srt" && queue.items[0].output?.lastPathComponent == "1.ai.ko.srt")
        for ext in ["ja", "ko"] {
            let old = try String(contentsOf: root.appendingPathComponent("1.\(ext).srt"), encoding: .utf8)
            precondition(old == "기존 파일")
        }
        queue.setInputLanguage(.japanese, for: movie, track: source.id)
        queue.enqueue([movie], using: movie, source: source, korean: false)
        try await wait { queue.items.last?.state == .completed }
        precondition(queue.items.last?.output == queue.items[0].original && queue.items.last?.original == nil)

        let audioMovie = root.appendingPathComponent("audio.mkv")
        try await generator.extract(["-f", "lavfi", "-i", "sine=duration=0.75", "-c:a", "pcm_s16le", audioMovie.path],
                                    log: root.appendingPathComponent("fixture.log"))
        let audio = CaptionSource(id: "a-2", kind: .audio, url: movie, map: "0:3", title: "음성", language: "en", selected: false, ordinal: 0)
        queue.setInputLanguage(.japanese, for: movie, track: audio.id)
        queue.enqueue([audioMovie], using: movie, source: audio, korean: true)
        try await wait { queue.items.last?.state == .completed }
        let spoken = queue.items.last!
        let transcript = try String(contentsOf: spoken.original!, encoding: .utf8)
        precondition(spoken.source.map == "0:a:0" && spoken.original?.lastPathComponent == "audio.ja.srt")
        precondition(SubtitleCue.parse(transcript).first?.text == "おかえり。" && spoken.output?.lastPathComponent == "audio.ko.srt")
        print("Caption queue, original/translation files, context, and audio transcription passed.")
    }
}
