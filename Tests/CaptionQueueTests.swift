// From the repository root after ./build.sh, in zsh:
// t=$(mktemp -d); player=(Sources/*.swift); fw=$PWD/JulPlayer.app/Contents/Frameworks
// xcrun clang -fobjc-arc -Wno-deprecated-declarations -I Engine/include -c Engine/VideoEngine.m -o "$t/engine.o"
// xcrun swiftc -parse-as-library -import-objc-header Engine/VideoEngine.h ${player:#Sources/main.swift} Tests/CaptionQueueTests.swift "$t/engine.o" "$fw/libmpv.2.dylib" -Xlinker -rpath -Xlinker "$fw" -framework OpenGL -framework IOSurface -o "$t/queue"
// "$t/queue" JulPlayer.app/Contents/Helpers/ffmpeg
import Foundation
import os

private final class CaptionFixture: URLProtocol {
    static let wholeEpisodeRequests = OSAllocatedUnfairLock(initialState: 0)
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
        let input = payload["input"] as! [[String: Any]]
        let parts = input[0]["content"] as! [[String: String]]
        precondition(parts.map { $0["type"] } == ["input_text", "input_text"])
        let passage = try! JSONSerialization.jsonObject(with: Data(parts[1]["text"]!.utf8)) as! [String: Any]
        precondition(payload["model"] as? String == "gpt-6.2-sol" && payload["stream"] as? Bool == true && payload["truncation"] as? String == "disabled")
        let original = SubtitleCue.parse(parts[0]["text"]!)
        precondition(SubtitleCue.render(original) == parts[0]["text"])
        let first = original.first!.text
        let ids = (passage["firstID"] as! Int)...(passage["lastID"] as! Int)
        let previous = passage["previous"] as! [[String: Any]]
        if first == "失敗" { respond(400, ["error": ["message": "fixture error"]]); return }
        if first == "本編0" {
            Self.wholeEpisodeRequests.withLock { $0 += 1 }
            precondition(ids == 1...480 && original.last?.text == "本編479" && original.last?.start == 479 && previous.isEmpty)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        func event(_ type: String, _ fields: [String: Any]) {
            var json = fields
            json["type"] = type
            let data = try! JSONSerialization.data(withJSONObject: json)
            client?.urlProtocol(self, didLoad: Data("event: \(type)\r\ndata: ".utf8) + data + Data("\r\n\r\n".utf8))
        }
        func finish(_ text: String, limit: String? = nil) {
            let status = limit == nil ? "completed" : "incomplete"
            var json: [String: Any] = ["status": status, "output": [["content": [["type": "output_text", "text": text]]]]]
            if let limit { json["incomplete_details"] = ["reason": limit] }
            event("response.\(status)", ["response": json])
            client?.urlProtocolDidFinishLoading(self)
        }
        if first == "待機" {
            event("response.output_text.delta", ["delta": #"{"lines":[{"id":1,"text":"진행 중"}"#])
            return // Hold the connection open until the queue cancels it.
        }
        if first == "続き" {
            precondition(original.count == 7 && original.last?.text == "終わり")
            if ids.lowerBound == 1 {
                precondition(ids == 1...7)
                let partial = #"{"lines":[{"id":1,"text":"괄호 }와 \"대사\""},{"id":2,"text":"이어서"},{"id":3,"text":"끊긴"#
                for chunk in partial { event("response.output_text.delta", ["delta": String(chunk)]) }
                finish(partial, limit: "max_output_tokens")
                return
            }
            precondition(ids == 3...7 && previous.last?["text"] as? String == "이어서")
        }
        if first == "再開" {
            precondition(original.count == 4)
            if ids == 1...4 { finish("", limit: "max_output_tokens"); return }
            precondition(ids == 1...2 || ids == 3...4)
        }
        if first == "未完" {
            precondition(ids == 1...4)
            finish("", limit: "content_filter")
            return
        }
        var result: [[String: Any]] = ids.reversed().map { ["id": $0, "text": "대사 \($0)"] }
        if first == "欠番" { result.removeFirst() }
        if first == "重複" { result[0] = result[1] }
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: ["lines": result]), as: UTF8.self)
        event("response.output_text.delta", ["delta": text])
        finish(text)
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
        let texts = [(0..<480).map { "本編\($0)" }, ["失敗"], ["待機"], ["消去"], ["おはよう。"]]
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
        try await wait { queue.items[2].message == "한국어 자막 수신 1 / 1" }
        precondition(queue.items[2].original != nil && queue.items[2].output == nil)
        precondition(queue.items.map(\.state) == [.completed, .failed, .running, .waiting])
        queue.remove(queue.items[2].id)
        try await wait { queue.items.last?.state == .completed }
        precondition(queue.items.map(\.state) == [.completed, .failed, .cancelled, .completed] && finished == [movies[0], movies[4]])
        precondition(CaptionFixture.wholeEpisodeRequests.withLock { $0 } == 1)
        precondition(queue.items.allSatisfy { $0.language == .japanese })
        for item in queue.items {
            let original = try String(contentsOf: item.original!, encoding: .utf8)
            let cues = SubtitleCue.parse(original)
            let index = movies.firstIndex(of: item.movie)!
            precondition(cues.map(\.text) == texts[index])
            if let output = item.output {
                let translated = SubtitleCue.parse(try String(contentsOf: output, encoding: .utf8))
                precondition(translated.map(\.start) == cues.map(\.start) && translated.map(\.end) == cues.map(\.end))
                precondition(translated.map(\.text) == (1...cues.count).map { "대사 \($0)" })
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

        for script in [["続き", "二", "三", "四", "五", "六", "終わり"], ["再開", "二", "三", "四"]] {
            let cues = script.enumerated().map { SubtitleCue(start: Double($0.offset), end: Double($0.offset + 1), text: $0.element) }
            let translated = try await generator.translate(cues, key: "test", inputLanguage: .japanese) { _, _ in }
            let expected = script.indices.map { "대사 \($0 + 1)" }
            precondition(translated.map(\.text) == (script.count == 7 ? ["괄호 }와 \"대사\"", "이어서"] + expected.dropFirst(2) : expected))
            precondition(translated.map(\.end) == cues.map(\.end))
        }
        for marker in ["欠番", "重複", "未完"] {
            let script = [marker, "二", "三", "四"]
            let cues = script.enumerated().map { SubtitleCue(start: Double($0.offset), end: Double($0.offset + 1), text: $0.element) }
            do {
                _ = try await generator.translate(cues, key: "test", inputLanguage: .japanese) { _, _ in }
                preconditionFailure("An invalid translation was accepted")
            } catch is MediaToolError {}
        }
        print("Caption queue, whole-episode translation, output-limit recovery, and SRT integrity passed.")
    }
}
