import AppKit

enum WindowSizePreset: Int, CaseIterable {
    case minimum = 0, half, actual, double

    var scale: CGFloat? {
        switch self {
        case .minimum: return nil
        case .half: return 0.5
        case .actual: return 1
        case .double: return 2
        }
    }

    var menuTitle: String {
        switch self {
        case .minimum: return "최소 창 크기"
        case .half: return "영상 크기 50%"
        case .actual: return "영상 크기 100%"
        case .double: return "영상 크기 200%"
        }
    }
}

enum PlayerWindowLayout {
    static let minimumContent = CGSize(width: 280, height: 158)
    static let playlistWidth: CGFloat = 236
    static let playlistSpan = playlistWidth + 1

    static func fitsSidebar(in width: CGFloat) -> Bool {
        width >= minimumContent.width + playlistSpan
    }

    static func dimensions(for preset: WindowSizePreset, videoPixels: CGSize?, backingScale: CGFloat,
                           available: CGSize, showsPlaylist: Bool) -> (content: CGSize, smallPicture: CGSize?)? {
        guard let scale = preset.scale else { return (minimumContent, nil) }
        guard let videoPixels, videoPixels.width > 0, videoPixels.height > 0, backingScale > 0 else { return nil }
        let sidebar = showsPlaylist && fitsSidebar(in: available.width) ? playlistSpan : 0
        let pointsPerPixel = min(scale / backingScale,
                                 (available.width - sidebar) / videoPixels.width,
                                 available.height / videoPixels.height)
        let picture = CGSize(width: videoPixels.width * pointsPerPixel, height: videoPixels.height * pointsPerPixel)
        let content = CGSize(width: max(minimumContent.width, picture.width) + sidebar,
                             height: max(minimumContent.height, picture.height))
        let needsMatte = picture.width < minimumContent.width && picture.height < minimumContent.height
        return (content, needsMatte ? picture : nil)
    }

    static func frame(of size: CGSize, centeredAt center: CGPoint, within screen: CGRect) -> CGRect {
        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)
        let x = min(max(screen.minX, center.x - width / 2), screen.maxX - width)
        let y = min(max(screen.minY, center.y - height / 2), screen.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct PlaybackControlLayout: Equatable {
    enum Item: Hashable {
        case mute, volume, audio, subtitles, previous, back60, back10, play, ahead10, ahead60, next, trash

        var width: CGFloat {
            switch self {
            case .play: return 32
            case .volume: return 52
            case .trash: return PlaybackControlLayout.iconWidth + 7
            default: return PlaybackControlLayout.iconWidth
            }
        }
    }

    static let inset: CGFloat = 8
    static let iconWidth: CGFloat = 29
    static let spacing: CGFloat = 3
    private static let sectionGap: CGFloat = 9
    private static let sections: [[Item]] = [
        [.mute, .volume],
        [.previous, .back60, .back10, .play, .ahead10, .ahead60, .next],
        [.audio, .subtitles, .trash]
    ]
    // Reveal related pairs together. Keep the volume slider until after the buttons fit.
    private static let priorities: [[Item]] = [
        [.back10, .ahead10], [.previous, .next], [.mute], [.back60, .ahead60],
        [.subtitles], [.audio], [.trash], [.volume]
    ]

    let leading, transport, trailing: [Item]
    let leadingSpan, trailingSpan: CGFloat
    var playOnly: Bool { transport.count == 1 }
    var barHeight: CGFloat { playOnly ? 44 : 68 }

    private static func rowWidth(_ items: [Item]) -> CGFloat {
        items.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, items.count - 1))
    }

    init(width: CGFloat) {
        let available = max(0, width - 2 * Self.inset)
        var visible: Set<Item> = [.play]
        if width > PlayerWindowLayout.minimumContent.width + 1 {
            for group in Self.priorities {
                let candidate = visible.union(group)
                let sections = Self.sections.map { $0.filter(candidate.contains) }.filter { !$0.isEmpty }
                let required = sections.map(Self.rowWidth).reduce(0, +) + CGFloat(sections.count - 1) * Self.sectionGap
                guard required <= available else { break }
                visible = candidate
            }
        }
        leading = Self.sections[0].filter(visible.contains)
        transport = Self.sections[1].filter(visible.contains)
        trailing = Self.sections[2].filter(visible.contains)
        // Center transport whenever possible, then borrow space from the shorter side.
        let sides = max(0, available - Self.rowWidth(transport))
        let minLeft = leading.isEmpty ? 0 : Self.rowWidth(leading) + Self.sectionGap
        let minRight = trailing.isEmpty ? 0 : Self.rowWidth(trailing) + Self.sectionGap
        leadingSpan = min(max(sides / 2, minLeft), max(0, sides - minRight))
        trailingSpan = sides - leadingSpan
    }
}

struct VideoWindowDrag {
    private enum Edge { case side, topOrBottom, corner }
    private let edge: Edge
    private let initialContent: CGSize
    private let aspect: CGFloat

    init?(video: CGSize?, content: CGSize, frame: CGRect, pointer: CGPoint) {
        guard let video, video.width > 0, video.height > 0 else { return nil }
        aspect = video.width / video.height
        initialContent = content
        let onSide = min(abs(pointer.x - frame.minX), abs(pointer.x - frame.maxX)) <= 12
        let onEnd = min(abs(pointer.y - frame.minY), abs(pointer.y - frame.maxY)) <= 12
        if onSide && !onEnd { edge = .side }
        else if onEnd && !onSide { edge = .topOrBottom }
        else { edge = .corner }
    }

    func contentSize(proposed: CGSize, available: CGSize, showsPlaylist: Bool) -> CGSize {
        let widthDriven: Bool
        switch edge {
        case .side: widthDriven = true
        case .topOrBottom: widthDriven = false
        case .corner:
            widthDriven = abs(proposed.width - initialContent.width) >= abs(proposed.height - initialContent.height) * aspect
        }

        let minimum = PlayerWindowLayout.minimumContent
        let minimumPictureWidth = max(minimum.width, minimum.height * aspect)
        let targetWidth = widthDriven ? proposed.width : proposed.height * aspect
        // When both sidebar layouts fit the requested height, keep the one the drag started with.
        let layoutWidth = widthDriven ? targetWidth : max(initialContent.width, targetWidth)
        let inline = showsPlaylist && PlayerWindowLayout.fitsSidebar(in: available.width)
            && PlayerWindowLayout.fitsSidebar(in: max(minimumPictureWidth, layoutWidth))
        let sidebar = inline ? PlayerWindowLayout.playlistSpan : 0
        let maximumPictureWidth = min(available.width - sidebar, available.height * aspect)
        let desiredPictureWidth = widthDriven ? proposed.width - sidebar : targetWidth
        let pictureWidth = min(maximumPictureWidth, max(minimumPictureWidth, desiredPictureWidth))
        return CGSize(width: min(available.width, max(minimum.width, pictureWidth) + sidebar),
                      height: min(available.height, max(minimum.height, pictureWidth / aspect)))
    }
}
