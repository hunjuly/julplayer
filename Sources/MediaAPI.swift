import Darwin
import Foundation
import Security

struct MediaToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum OpenAIKey {
    private static var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "local.julplayer.mac") + ".openai",
            kSecAttrAccount as String: "api-key",
        ]
    }

    static func read() throws -> String? {
        var query = item
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            let status = SecItemDelete(item as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
            return
        }
        guard !key.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw MediaToolError("API 키에 공백이 들어 있습니다.") }
        let data = Data(key.utf8)
        let status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = item
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            addition[kSecValueData as String] = data
            try check(SecItemAdd(addition as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        throw MediaToolError("키체인에 접근할 수 없습니다. " + (SecCopyErrorMessageString(status, nil) as String? ?? String(status)))
    }
}

enum SidecarFile {
    // Both the temporary file and the final name live on the same volume, including SMB shares.
    static func create(_ text: String, at url: URL) throws -> Bool {
        let fm = FileManager.default
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".julplayer-" + UUID().uuidString)
        try Data(text.utf8).write(to: temporary, options: .withoutOverwriting)
        defer { try? fm.removeItem(at: temporary) }
        if renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) == 0 { return true }
        let code = errno
        if code == EEXIST { return false }
        if code == ENOTSUP || code == EINVAL {
            do {
                try fm.moveItem(at: temporary, to: url)
                return true
            } catch let error as CocoaError where error.code == .fileWriteFileExists { return false }
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }

    static func update(_ url: URL, edit: (String) throws -> String) throws -> String {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<String, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { target in
            result = Result {
                let current = try String(contentsOf: target, encoding: .utf8)
                let updated = try edit(current)
                try updated.write(to: target, atomically: true, encoding: .utf8)
                return updated
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw MediaToolError("작품 정보 파일을 갱신할 수 없습니다.") }
        return try result.get()
    }

    static func read(_ url: URL) throws -> String? {
        do { return try String(contentsOf: url, encoding: .utf8) } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
        { return nil }
    }
}

struct MediaAPI {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func send(_ request: URLRequest) async throws -> Data {
        for attempt in 0...2 {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MediaToolError("서버 응답을 읽을 수 없습니다.") }
            if (200..<300).contains(http.statusCode) { return data }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = body?["error"] as? [String: Any]
            let errors = body?["errors"] as? [[String: Any]]
            let detail = error?["message"] as? String ?? errors?.first?["message"] as? String
            let delay = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(attempt + 1)
            let retryable = [429, 500, 502, 503, 504].contains(http.statusCode) && error?["code"] as? String != "insufficient_quota"
            if retryable, attempt < 2, delay.isFinite, (0...15).contains(delay) {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
            let name =
                ["api.openai.com": "OpenAI", "graphql.anilist.co": "AniList", "ko.wikipedia.org": "위키백과"][request.url?.host ?? ""]
                ?? "서버"
            throw MediaToolError(
                "\(name) 오류 \(http.statusCode). " + (detail ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)))
        }
        throw MediaToolError("서버에 연결할 수 없습니다.")
    }

    struct Answer {
        let text: String
        let sources: [URL]
    }

    func response(key: String, instructions: String, input: String, web: Bool = false, schema: [String: Any]? = nil) async throws
        -> Answer
    {
        var body: [String: Any] = [
            "model": "gpt-5-mini", "instructions": instructions, "input": input, "store": false,
            "reasoning": ["effort": "low"],
        ]
        if let schema { body["text"] = ["format": ["type": "json_schema", "name": "result", "strict": true, "schema": schema]] }
        if web {
            body["tools"] = [["type": "web_search"]]
            body["tool_choice"] = "required"
            body["include"] = ["web_search_call.action.sources"]
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard json?["status"] as? String == "completed", let outputs = json?["output"] as? [[String: Any]] else {
            throw MediaToolError("OpenAI가 응답을 끝내지 못했습니다. 다시 시도해 주세요.")
        }
        var text = [String]()
        var sources = [URL]()
        for item in outputs {
            let content = item["content"] as? [[String: Any]] ?? []
            var records = ((item["action"] as? [String: Any])?["sources"] as? [[String: Any]]) ?? []
            for part in content where part["type"] as? String == "output_text" {
                if let value = part["text"] as? String { text.append(value) }
                records += part["annotations"] as? [[String: Any]] ?? []
            }
            for record in records {
                if let value = record["url"] as? String, let url = URL(string: value),
                    ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !sources.contains(url)
                {
                    sources.append(url)
                }
            }
        }
        let result = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw MediaToolError("OpenAI에서 결과를 받지 못했습니다.") }
        return Answer(text: result, sources: sources)
    }

    func transcribe(_ wav: Data, key: String, language: String?) async throws -> String {
        let boundary = "JulPlayer-" + UUID().uuidString
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: text.utf8) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model", "gpt-transcribe")
        if let language { field("languages[]", language) }
        append(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
        )
        data.append(wav)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        let result = try await send(request)
        struct Transcript: Decodable { let text: String }
        return try JSONDecoder().decode(Transcript.self, from: result).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from answer: String) throws -> T {
        var lines = answer.components(separatedBy: .newlines)
        if lines.first?.hasPrefix("\u{60}\u{60}\u{60}") == true
            && lines.last?.trimmingCharacters(in: .whitespaces) == "\u{60}\u{60}\u{60}"
        {
            lines.removeFirst()
            lines.removeLast()
        }
        do { return try JSONDecoder().decode(type, from: Data(lines.joined(separator: "\n").utf8)) } catch {
            throw MediaToolError("OpenAI 응답 형식이 예상과 다릅니다. 다시 시도해 주세요.")
        }
    }
}
