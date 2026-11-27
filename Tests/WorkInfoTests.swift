// Run from the repository root on macOS:
// xcrun swiftc -parse-as-library Sources/{MediaAPI,WorkInfo}.swift Tests/WorkInfoTests.swift -o /tmp/julplayer-work-tests && /tmp/julplayer-work-tests
// Pass a writable SMB directory as the first argument to test Finder visibility on that share.
import Foundation

@main
enum WorkInfoTests {
    static func checkRatings() throws {
        let score = "AniList 69/100 · 2,987명 평가"
        let legacy = "# Example\n\n- **장르**  드라마\n- **AniList 평점**  69/100 · 2,987명 평가\n\n## 메모\n\n- **평점**  내 메모"
        let old = WorkInfoDocument(legacy)
        precondition(old.title == "Example" && old.rating == score && old.bodyLines.contains("- **장르**  드라마"))
        precondition(old.bodyLines.contains("- **평점**  내 메모") && !old.bodyLines.contains { $0.contains("69/100") })
        let web = WorkInfoDocument("# Example\r\n\r\n- **평점**  IMDb 8.2/10\r\n\r\n## 출처")
        precondition(web.rating == "IMDb 8.2/10")
        let note = "내 메모\n- **평점**  9/10"
        let plain = WorkInfoDocument(note)
        precondition(plain.title == nil && plain.bodyLines.joined(separator: "\n") == note)

        for rating in [score, nil] {
            let work = WorkRecord(id: "test", title: "Example", aliases: [], year: nil, format: "", rating: rating,
                                  fields: [("장르", "드라마")], synopsis: "Original synopsis.", sources: [])
            let text = work.markdown()
            let header = "# Example\n\n**평점**  \(rating ?? WorkInfoDocument.noRating)\n\n"
            precondition(text.hasPrefix(header) && WorkInfoDocument(text).rating == rating)
            let korean = try SavedIntroduction.adding("한국어 소개.", to: text, expected: work.synopsis)
            precondition(korean.hasPrefix(header) && WorkInfoDocument(korean).rating == rating)
        }
    }

    static func checkGuides() throws {
        let review = URL(string: "https://example.org/review")!
        let guide = WorkGuide(synopsis: "두 사람의 출발점.\n\n초반의 분위기.", verdict: "느린 호흡을 좋아한다면 볼 만하다.",
                              craft: "긴 쇼트가 관찰할 시간을 준다.", review: nil, spoiler: "결말에 관한 해석.", sources: [review])
        var work = WorkRecord(id: "test", title: "Example", aliases: [], year: 2020, format: "영화", rating: "8/10",
                              fields: [("출시 연도", "2020년")], synopsis: "Original synopsis.", sources: [review])
        let raw = work.markdown()
        work.guide = guide
        let rich = work.markdown()
        let parsed = WorkInfoDocument(rich)
        precondition(parsed.hasGuide && parsed.rating == "8/10" && parsed.catalogueFacts == ["- **출시 연도**  2020년"])
        precondition(parsed.bodyLines.firstIndex(of: WorkGuide.verdictHeading)! < parsed.bodyLines.firstIndex(of: "## 줄거리와 분위기")!)
        precondition(!parsed.bodyLines.contains(guide.spoiler!) && parsed.spoilerLines.contains(guide.spoiler!))
        precondition(parsed.sources == [review])
        precondition(rich.hasSuffix("## 스포일러 주의\n\n결말에 관한 해석.\n"))
        precondition(rich.components(separatedBy: review.absoluteString).count == 2)
        precondition(WorkInfoDocument(raw).spoilerLines.isEmpty)

        for synopsis in ["Original synopsis.", "내가 작성한 기존 소개."] {
            let old = raw.replacingOccurrences(of: "Original synopsis.", with: synopsis)
            let notes = "\n## 메모\n\n직접 쓴 메모.\n"
            let crlf = (old + notes).replacingOccurrences(of: "\n", with: "\r\n")
            let updated = try guide.adding(to: crlf, title: "Example", original: synopsis)
            let lf = updated.replacingOccurrences(of: "\r\n", with: "\n")
            precondition(!lf.contains("\r") && !updated.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
            precondition(lf.contains(notes) && lf.contains("## 줄거리와 분위기\n\n" + guide.synopsis))
            let heading = synopsis == "Original synopsis." ? "## 원문 소개" : "## 기존 소개"
            precondition(lf.contains(heading + "\n\n" + synopsis) && lf.hasSuffix("## 스포일러 주의\n\n결말에 관한 해석.\n"))
            let repeated = try guide.adding(to: updated, title: "Example", original: synopsis)
            precondition(repeated == updated)
        }
        let quiet = WorkGuide(synopsis: "소개", verdict: "판단", craft: "연출", review: nil, spoiler: nil, sources: [])
        let noSpoiler = try quiet.adding(to: raw, title: "Example", original: work.synopsis)
        precondition(!noSpoiler.contains(WorkGuide.spoilerHeading))
        let annotated = raw + "\n## 스포일러 주의\n\n직접 쓴 결말 메모.\n"
        let withBoth = try guide.adding(to: annotated, title: "Example", original: work.synopsis)
        let spoilers = WorkInfoDocument(withBoth).spoilerLines
        precondition(spoilers.contains("직접 쓴 결말 메모.") && spoilers.contains(guide.spoiler!))
        precondition(withBoth.components(separatedBy: WorkGuide.spoilerHeading).count == 2)
        do {
            _ = try guide.adding(to: raw, title: "Example", original: "이전 버전")
            preconditionFailure("Changed introduction was overwritten")
        } catch is MediaToolError {}
    }

    static func main() throws {
        try checkRatings()
        try checkGuides()
        let files = FileManager.default
        let base = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? files.temporaryDirectory
        let root = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }

        let decomposed = "카우보이 비밥/시즌 2".decomposedStringWithCanonicalMapping
        let season = root.appendingPathComponent(decomposed, isDirectory: true)
        try files.createDirectory(at: season, withIntermediateDirectories: true)
        let episodes = ["01.mkv", "02.mkv"].map { season.appendingPathComponent($0) }
        for episode in episodes { try Data().write(to: episode) }
        // Finder and enumerators may express the same path with distinct Unicode and mount prefixes.
        let siblings = try files.contentsOfDirectory(at: season, includingPropertiesForKeys: nil)
        for (index, episode) in episodes.enumerated() {
            let work = WorkIdentity(movie: episode.standardizedFileURL, siblings: siblings)
            precondition(work.search == "카우보이 비밥 Season 2" && work.episode == index + 1)
            precondition(work.document.lastPathComponent == "작품정보.md")
        }

        let releases = ["Example.S01E01.mkv", "Example.S02E01.mkv"].map { root.appendingPathComponent($0) }
        let first = WorkIdentity(movie: releases[0], siblings: releases)
        let second = WorkIdentity(movie: releases[1], siblings: releases)
        precondition(first.document.lastPathComponent == "작품정보 S01.md")
        precondition(second.document.lastPathComponent == "작품정보 S02.md")
        let film = root.appendingPathComponent("Another Movie (1998) [1080p].mkv")
        let mixed = releases + [film]
        precondition(WorkIdentity(movie: releases[0], siblings: mixed).document.lastPathComponent == "Example.S01E01.md")
        let standalone = WorkIdentity(movie: film, siblings: mixed)
        precondition(standalone.title == "Another Movie" && standalone.year == 1998)
        precondition(standalone.document.lastPathComponent == "Another Movie (1998) [1080p].md")

        let original = "# Example\n\n## 줄거리와 분위기\n\nOriginal synopsis.\n\n## 출처\n\n- AniList\n"
        let url = first.document
        let created = try SidecarFile.create(original, at: url)
        let overwritten = try SidecarFile.create("duplicate", at: url)
        precondition(created && !overwritten)
        let subtitle = root.appendingPathComponent("Example.ja.srt")
        let addedSubtitle = try SidecarFile.create("1\n00:00:00,000 --> 00:00:01,000\nExample\n", at: subtitle)
        precondition(addedSubtitle)
        func visibleFiles() throws -> Set<String> {
            let entries = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            return Set(entries.map(\.lastPathComponent))
        }
        let afterCreation = try visibleFiles()
        precondition(afterCreation.contains(url.lastPathComponent) && afterCreation.contains(subtitle.lastPathComponent))
        let notes = "\n직접 추가한 메모\n"
        try (original + notes).write(to: url, atomically: true, encoding: .utf8)
        var legacyFile = url
        var attributes = URLResourceValues()
        attributes.isHidden = true
        try legacyFile.setResourceValues(attributes)
        let whileHidden = try visibleFiles()
        precondition(!whileHidden.contains(url.lastPathComponent))
        let translated = try SidecarFile.update(url) { text in
            try SavedIntroduction.adding("한국어 소개.", to: text, expected: "Original synopsis.")
        }
        let saved = try SidecarFile.read(url)
        precondition(saved == translated && translated.contains("## 원문 소개\n\nOriginal synopsis.") && translated.hasSuffix(notes))
        precondition(SavedIntroduction(translated)?.needsTranslation == false)
        let afterUpdate = try visibleFiles()
        precondition(afterUpdate.contains(url.lastPathComponent))
        print("Work information regression tests passed.")
    }
}
