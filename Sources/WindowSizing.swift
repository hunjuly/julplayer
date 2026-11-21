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
        case previous, next, mute, volume, brightness, audio, subtitles, trash

        var width: CGFloat {
            switch self {
            case .brightness: return 50
            case .volume: return 52
            case .trash: return PlaybackControlLayout.iconWidth + 7
            default: return PlaybackControlLayout.iconWidth
            }
        }
    }

    static let inset: CGFloat = 8
    static let iconWidth: CGFloat = 29
    static let spacing: CGFloat = 3
    static let sectionGap: CGFloat = 8
    static let transportSpacing: CGFloat = 12
    private static let sections: [[Item]] = [
        [.previous, .next],
        [.mute, .volume],
        [.brightness, .audio, .subtitles, .trash]
    ]
    private static let priorities: [[Item]] = [
        [.brightness], [.previous, .next], [.mute], [.subtitles], [.audio], [.trash], [.volume]
    ]

    let files, sound, options: [Item]
    let playOnly, stackedFooter, showsLongSeeks: Bool
    let barHeight, playDiameter, shortSeekDiameter, longSeekDiameter: CGFloat

    // Each nonempty group shares a row with the timeline (or a spacer in the two-row layout).
    private static func footerWidth(for items: Set<Item>, timeline: CGFloat) -> CGFloat {
        sections.reduce(timeline) { width, section in
            let group = section.filter(items.contains)
            guard !group.isEmpty else { return width }
            return width + sectionGap + group.reduce(0) { $0 + $1.width } + spacing * CGFloat(group.count - 1)
        }
    }

    init(size: CGSize, sourceIsHDR: Bool) {
        let width = size.width
        let available = max(0, width - 2 * Self.inset)
        let items = Set(Self.sections.joined().filter { sourceIsHDR || $0 != .brightness })
        playOnly = width <= PlayerWindowLayout.minimumContent.width + 1
        stackedFooter = !playOnly && size.height >= 220 && Self.footerWidth(for: items, timeline: 250) > available
        barHeight = playOnly ? 0 : (stackedFooter ? 66 : 42)
        let clearDiameter = size.height - 2 * (max(40, barHeight) + 6)
        playDiameter = min(width >= 900 ? 80 : 72, max(44, clearDiameter))
        shortSeekDiameter = max(42, (playDiameter * 0.76).rounded())
        longSeekDiameter = max(36, (playDiameter * 0.60).rounded())
        let fullTransport = playDiameter + 2 * (shortSeekDiameter + longSeekDiameter) + 4 * Self.transportSpacing
        showsLongSeeks = !playOnly && fullTransport <= available

        var visible = Set<Item>()
        if !playOnly {
            for group in Self.priorities {
                guard group.allSatisfy(items.contains) else { continue }
                let candidate = visible.union(group)
                if Self.footerWidth(for: candidate, timeline: stackedFooter ? 0 : 164) <= available {
                    visible = candidate
                }
            }
        }
        files = Self.sections[0].filter(visible.contains)
        sound = Self.sections[1].filter(visible.contains)
        options = Self.sections[2].filter(visible.contains)
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
