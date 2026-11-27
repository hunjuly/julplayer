// From the repository root after ./build.sh, in zsh:
// t=$(mktemp -d); player=(Sources/*.swift); fw=$PWD/JulPlayer.app/Contents/Frameworks
// xcrun clang -fobjc-arc -Wno-deprecated-declarations -I Engine/include -c Engine/VideoEngine.m -o "$t/engine.o"
// xcrun swiftc -parse-as-library -import-objc-header Engine/VideoEngine.h ${player:#Sources/main.swift} Tests/PictureInPicturePlaybackTests.swift "$t/engine.o" "$fw/libmpv.2.dylib" -Xlinker -rpath -Xlinker "$fw" -framework OpenGL -framework IOSurface -o "$t/pip"
// "$t/pip" JulPlayer.app/Contents/Helpers/ffmpeg
import AVKit

@main @MainActor
enum PictureInPicturePlaybackTests {
    static func wait(_ message: String, until ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !ready() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        precondition(ready(), message)
    }

    static func main() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("01.mp4"), last = folder.appendingPathComponent("02.mp4")
        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        ffmpeg.arguments = ["-v", "error", "-f", "lavfi", "-i", "color=s=64x48:r=24:d=24", "-c:v", "mpeg4", first.path]
        try ffmpeg.run()
        ffmpeg.waitUntilExit()
        precondition(ffmpeg.terminationStatus == 0)
        try FileManager.default.copyItem(at: first, to: last)

        let session = PlayerSession(defaults: UserDefaults(suiteName: folder.lastPathComponent)!)
        session.start(opening: [first])
        defer { session.finish() }
        wait("Folder playlist did not start") { session.playing && session.duration > 20 && session.clips.count == 2 }
        let pip = session.pip!
        let controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: AVSampleBufferDisplayLayer(), playbackDelegate: pip))
        let clock = session.engine!.displayLayer.controlTimebase!
        var completions = 0
        func skip(_ seconds: Int) {
            let expected = completions + 1
            pip.pictureInPictureController(controller, skipByInterval: CMTime(value: Int64(seconds), timescale: 1)) {
                completions += 1
            }
            wait("PiP seek did not complete exactly once") { completions == expected }
        }
        func play(_ value: Bool) { pip.pictureInPictureController(controller, setPlaying: value) }

        // macOS sends pause, skip, then resume when the floating window's forward button is pressed.
        for _ in 0..<3 { play(false); skip(10); play(true) }
        wait("PiP restarted the first file or skipped the start of the next one") {
            session.current?.url == last && session.playing && session.position > 0 && session.position < 2
        }
        play(false)
        skip(10)
        precondition(!session.playing && CMTimebaseGetRate(clock) == 0)
        skip(-10)
        precondition(!session.playing && CMTimebaseGetTime(clock).seconds < 2)
        skip(30)
        play(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        precondition(session.current?.url == last && !session.playing && session.position > 23)
        play(true)
        wait("Explicit replay of the last file did not start") { session.playing && session.position > 0 && session.position < 2 }
        precondition(completions == 6)
        print("Picture in Picture playback tests passed.")
    }
}
