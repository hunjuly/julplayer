// xcrun swiftc -parse-as-library Sources/WindowSizing.swift Tests/PlaybackControlLayoutTests.swift -o /tmp/julplayer-layout-tests && /tmp/julplayer-layout-tests
import AppKit

@main
enum PlaybackControlLayoutTests {
    static func main() {
        for hdr in [false, true] {
            let wide = PlaybackControlLayout(size: CGSize(width: 960, height: 540), sourceIsHDR: hdr)
            let stacked = PlaybackControlLayout(size: CGSize(width: 550, height: 300), sourceIsHDR: hdr)
            let compact = PlaybackControlLayout(size: CGSize(width: 510, height: 300), sourceIsHDR: hdr)
            let expected: [PlaybackControlLayout.Item] = [.audio, .subtitles, .workInfo, .trash]
            precondition(!wide.stackedFooter && stacked.stackedFooter)
            let fullTransport: [PlaybackControlLayout.Item] = [.previous, .back60, .back10, .play, .ahead10, .ahead60, .next]
            precondition(wide.transport == fullTransport)
            precondition(compact.transport == [.previous, .back10, .play, .ahead10, .next] && compact.sound == [.mute, .volume])
            for layout in [wide, stacked, compact] {
                precondition(layout.options == (hdr ? [.brightness] : []) + expected)
            }

            let minimum = PlaybackControlLayout(size: PlayerWindowLayout.minimumContent, sourceIsHDR: hdr)
            precondition(minimum.playOnly && minimum.transport == [.play])
            precondition(minimum.sound.isEmpty && minimum.options.isEmpty)

            for width in 282...960 {
                for height in [165, 300] {
                    let layout = PlaybackControlLayout(size: CGSize(width: width, height: height), sourceIsHDR: hdr)
                    let options = layout.options
                    precondition(layout.transport.contains(.back10) && layout.transport.contains(.ahead10))
                    precondition(layout.transport.contains(.back60) == layout.transport.contains(.ahead60))
                    if layout.transport.contains(.back60) {
                        precondition(layout.transport == fullTransport && layout.sound == [.mute, .volume])
                        precondition(options == (hdr ? [.brightness] : []) + expected)
                    }
                    guard !options.isEmpty else { continue }
                    let widthNeeded = options.reduce(CGFloat.zero) { $0 + $1.width }
                        + CGFloat(options.count - 1) * PlaybackControlLayout.spacing
                    precondition(layout.trailingSpan >= widthNeeded)
                }
            }
        }
        print("Playback control layout tests passed.")
    }
}
