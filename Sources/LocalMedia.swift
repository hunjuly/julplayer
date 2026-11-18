import Foundation
import UniformTypeIdentifiers

enum LocalMedia {
    static let videoExtensions = ["mkv", "mov", "mp4", "m4v", "avi", "webm", "ts", "m2ts", "mts", "mpg", "mpeg", "wmv", "flv", "3gp", "ogv", "vob", "m2v", "mxf", "divx", "asf", "rmvb"]
    static let subtitleExtensions = ["srt", "smi", "sami", "vtt", "ass", "ssa", "sub", "idx", "sup", "ttml", "lrc", "sbv"]
    static let types = [UTType.movie, .video] + videoExtensions.compactMap { UTType(filenameExtension: $0) }
    static let subtitleTypes = subtitleExtensions.compactMap { UTType(filenameExtension: $0) }

    static func isVideo(_ url: URL) -> Bool {
        guard url.isFileURL && !url.hasDirectoryPath else { return false }
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return true }
        let type = UTType(filenameExtension: ext) ?? (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        return type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true
    }
    static func isSubtitle(_ url: URL) -> Bool { url.isFileURL && !url.hasDirectoryPath && subtitleExtensions.contains(url.pathExtension.lowercased()) }

    private static func files(in directory: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        return items.filter { url in
            guard isVideo(url) || isSubtitle(url), let values = try? url.resourceValues(forKeys: keys) else { return false }
            if values.isRegularFile == true { return true }
            return values.isSymbolicLink == true && (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    static func folderPlaylist(for selected: [URL]) -> [URL] {
        var directories = Set<URL>(), seen = Set<URL>()
        var result = [URL]()
        for url in selected.map(\.standardizedFileURL) {
            let dir = url.deletingLastPathComponent()
            if directories.insert(dir).inserted {
                let files = (try? files(in: dir)) ?? []
                let ordered = files.filter(isVideo).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                for item in ordered where seen.insert(item.standardizedFileURL).inserted { result.append(item.standardizedFileURL) }
            }
            if seen.insert(url).inserted { result.append(url) }
        }
        return result
    }

    private static func stem(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
    }
    private static let tags: Set<String> = Set(Locale.LanguageCode.isoLanguageCodes.map { $0.identifier.lowercased() }).union([
        "ko","kor","kr","korean","한국어","한글","한글자막","en","eng","english","영어","ja","jpn","jp","일본어","zh","chi","zho","chs","cht","중국어",
        "deu","ger","fra","fre","spa","rus","ita","por","pol","ara","tur","tha","vie","ind","nld","dut","swe","fin","nor","dan","hin","heb","ukr",
        "us","uk","gb","cn","tw","hk","br","pt","ca","latn","hans","hant","forced","sdh","cc","hi","default","full","signs","songs","dialogue","commentary","subs","sub","dub"
    ]).union(subtitleExtensions)

    private static func matches(_ subtitle: URL, _ movieStem: String) -> Bool {
        let name = stem(subtitle)
        if name == movieStem { return true }
        guard name.hasPrefix(movieStem) else { return false }
        let rest = String(name.dropFirst(movieStem.count))
        let separators = CharacterSet(charactersIn: " ._-[]()")
        guard let first = rest.unicodeScalars.first, separators.contains(first) else { return false }
        let parts = rest.components(separatedBy: separators).filter { !$0.isEmpty }
        return !parts.isEmpty && parts.allSatisfy { tags.contains($0) }
    }

    static func sidecars(for movie: URL, deleting: Bool = false) -> [URL] {
        guard let contents = try? files(in: movie.deletingLastPathComponent()) else { return [] }
        let name = stem(movie)
        let others = contents.filter { isVideo($0) && $0.standardizedFileURL != movie.standardizedFileURL }.map(stem)
        if deleting && others.contains(name) { return [] }
        func subtitleRank(_ sub: URL) -> Int {
            let trail = String(stem(sub).dropFirst(name.count))
            let tokens = trail.components(separatedBy: CharacterSet(charactersIn: " ._-[]()")).filter { !$0.isEmpty }
            if tokens.allSatisfy(subtitleExtensions.contains) { return 0 }
            return tokens.contains(where: { ["ko","kor","kr","한국어","한글","korean"].contains($0) }) ? 1 : 2
        }
        return contents.filter { sub in
            isSubtitle(sub) && matches(sub, name) && !others.contains { $0.count > name.count && matches(sub, $0) }
        }.sorted {
            let left = subtitleRank($0), right = subtitleRank($1)
            return left == right ? $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending : left < right
        }
    }

    struct TrashEntry {
        let url: URL
        let volume: UInt64
        let inode: UInt64
        init(_ url: URL) throws {
            self.url = url
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            volume = (attrs[.systemNumber] as? NSNumber)?.uint64Value ?? 0
            inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }
    }
    static func trashEntries(movie: URL, attached: [URL], shared: Set<URL>) throws -> [TrashEntry] {
        let matching = sidecars(for: movie, deleting: true)
        let autoLoaded = Set(sidecars(for: movie).map(\.standardizedFileURL))
        let explicit = attached.filter { !autoLoaded.contains($0.standardizedFileURL) && isSubtitle($0) && FileManager.default.fileExists(atPath: $0.path) }
        var seen = Set<URL>()
        let subtitles = (matching + explicit).filter { !shared.contains($0.standardizedFileURL) }
        return try ([movie] + subtitles).map(\.standardizedFileURL).filter { seen.insert($0).inserted }.map(TrashEntry.init)
    }

    static func trash(_ entries: [TrashEntry]) throws {
        let fm = FileManager.default
        var moved: [(URL, URL)] = []
        do {
            for entry in entries {
                let url = entry.url
                let current = try TrashEntry(url)
                guard entry.volume == current.volume && entry.inode == current.inode else {
                    throw NSError(domain: "JulPlayer.Trash", code: 2, userInfo: [NSLocalizedDescriptionKey: "확인한 뒤 파일이 변경되었습니다. " + url.lastPathComponent])
                }
                var destination: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &destination)
                if let destination { moved.append((url, destination as URL)) }
            }
        } catch {
            var unrestored: [String] = []
            for (original, trashed) in moved.reversed() {
                do { try fm.moveItem(at: trashed, to: original) }
                catch { unrestored.append(original.lastPathComponent) }
            }
            let details = unrestored.isEmpty ? "" : "\n휴지통에 있는 파일: " + unrestored.joined(separator: ", ")
            throw NSError(domain: "JulPlayer.Trash", code: 1, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription + details])
        }
    }
}
