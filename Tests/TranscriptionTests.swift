// xcrun swiftc -parse-as-library Sources/MediaAPI.swift Tests/TranscriptionTests.swift -o /tmp/julplayer-transcription-tests && /tmp/julplayer-transcription-tests
import Foundation

private final class TranscriptionFixture: URLProtocol {
    static let audio = Data("RIFFtest-audio".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body: Data
        if let data = request.httpBody {
            body = data
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var data = Data()
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                precondition(count >= 0)
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        } else { preconditionFailure("Missing multipart body") }

        let parts = String(decoding: body, as: UTF8.self)
        precondition(body.range(of: Self.audio) != nil)
        precondition(!parts.contains("name=\"language") && parts.contains("gpt-transcribe"))
        let url = request.url!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"text":"こんにちは。","languages":[{"code":"ja"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
enum TranscriptionTests {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TranscriptionFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let result = try await MediaAPI(session: session).transcribe(TranscriptionFixture.audio, key: "test")
        precondition(result.text == "こんにちは。" && result.languages?.map(\.code) == ["ja"])
        print("Transcription language regression test passed.")
    }
}
