import AppKit
import UniformTypeIdentifiers

struct VideoFileFormat {
    let identifier: String
    let extensions: [String]

    static let supported: [Self] = {
        let documents = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
        return documents.compactMap { document in
            guard let suffixes = document["CFBundleTypeExtensions"] as? [String],
                  let identifier = (document["LSItemContentTypes"] as? [String])?.first else { return nil }
            let extensions = suffixes.filter(LocalMedia.videoExtensions.contains)
            return extensions.isEmpty ? nil : Self(identifier: identifier, extensions: extensions)
        }
    }()

    private static func userCancelled(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError { return true }
        if error.domain == NSOSStatusErrorDomain && error.code == Int(userCanceledErr) { return true }
        guard let cause = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return userCancelled(cause)
    }

    @MainActor
    static func associate(_ formats: [Self], with application: URL) async -> String {
        let workspace = NSWorkspace.shared
        let destination = application.resolvingSymlinksInPath().path
        func isDefault(_ type: UTType) -> Bool {
            workspace.urlForApplication(toOpen: type)?.resolvingSymlinksInPath().path == destination
        }

        var cancelled = false
        var firstError: String?
        for format in formats {
            guard let type = UTType(format.identifier), !isDefault(type) else { continue }
            do {
                try await workspace.setDefaultApplication(at: application, toOpen: type)
            } catch let error as NSError {
                if userCancelled(error) {
                    cancelled = true
                    break
                }
                if firstError == nil { firstError = error.localizedDescription }
            }
        }

        let extensions = formats.flatMap(\.extensions)
        let remaining = formats.filter { format in
            guard let type = UTType(format.identifier) else { return true }
            return !isDefault(type)
        }.flatMap(\.extensions)
        if remaining.isEmpty {
            let label = formats.count == 1 ? extensions.joined(separator: " / ").uppercased() : "동영상 확장자 \(extensions.count)개"
            return "\(label)의 기본 앱은 JulPlayer입니다."
        }
        let count = "\(extensions.count)개 중 \(extensions.count - remaining.count)개가 연결되어 있습니다."
        if cancelled { return "연결을 중단했습니다. \(count)" }
        let list = remaining.joined(separator: ", ").uppercased()
        return "\(count) \(list) 연결에 실패했습니다." + (firstError.map { "\n" + $0 } ?? "")
    }
}
