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
    static let sidebarWidth: CGFloat = 236
    static let sidebarSpan = sidebarWidth + 1

    static func fitsSidebar(in width: CGFloat) -> Bool {
        width >= minimumContent.width + sidebarSpan
    }

    static func dimensions(for preset: WindowSizePreset, videoPixels: CGSize?, backingScale: CGFloat,
                           available: CGSize, showsSidebar: Bool) -> (content: CGSize, smallPicture: CGSize?)? {
        guard let scale = preset.scale else { return (minimumContent, nil) }
        guard let videoPixels, videoPixels.width > 0, videoPixels.height > 0, backingScale > 0 else { return nil }
        let sidebar = showsSidebar && fitsSidebar(in: available.width) ? sidebarSpan : 0
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
        case previous, back60, back10, play, ahead10, ahead60, next, mute, volume, brightness, audio, subtitles

        var width: CGFloat {
            switch self {
            case .play: return 36
            case .back60, .back10, .ahead10, .ahead60: return 42
            case .brightness: return 50
            case .volume: return 52
            default: return PlaybackControlLayout.iconWidth
            }
        }
    }

    static let inset: CGFloat = 8
    static let iconWidth: CGFloat = 29
    static let spacing: CGFloat = 3
    static let sectionGap: CGFloat = 8
    private static let sections: [[Item]] = [
        [.mute, .volume],
        [.previous, .back60, .back10, .play, .ahead10, .ahead60, .next],
        [.brightness, .audio, .subtitles]
    ]
    private static let priorities: [[Item]] = [
        [.back10, .ahead10], [.brightness], [.previous, .next], [.mute], [.subtitles],
        [.audio], [.volume], [.back60, .ahead60]
    ]

    let sound, transport, options: [Item]
    let playOnly, stackedFooter: Bool
    let leadingSpan, trailingSpan: CGFloat
    var barHeight: CGFloat { stackedFooter ? 68 : 42 }

    private static func rowWidth(_ group: [Item]) -> CGFloat {
        group.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, group.count - 1))
    }

    private static func footerWidth(for items: Set<Item>, timeline: CGFloat) -> CGFloat {
        var widths = sections.map { rowWidth($0.filter(items.contains)) }.filter { $0 > 0 }
        if timeline > 0 { widths.append(timeline) }
        return widths.reduce(0, +) + sectionGap * CGFloat(max(0, widths.count - 1))
    }

    init(size: CGSize, sourceIsHDR: Bool) {
        let width = size.width
        let available = max(0, width - 2 * Self.inset)
        let items = Set(Self.sections.joined().filter { sourceIsHDR || $0 != .brightness })
        // Reserve the two short seeks beside play even in a short, narrow window.
        let shortSeeks = Self.rowWidth([.back10, .play, .ahead10])
        let minimumTimeline = min(150, max(0, available - shortSeeks - Self.sectionGap))
        playOnly = width <= PlayerWindowLayout.minimumContent.width + 1
        let fullTransport = Self.sections[1]
        let fullToolsWidth = Self.footerWidth(for: items.subtracting(fullTransport), timeline: 0)
        let fullSide = max(Self.rowWidth(fullTransport), fullToolsWidth) + Self.sectionGap
        stackedFooter = !playOnly && size.height >= 220 && available - 2 * fullSide < 200
        var visible: Set<Item> = [.play]
        if !playOnly {
            for group in Self.priorities {
                guard group.allSatisfy(items.contains) else { continue }
                let candidate = visible.union(group)
                if Self.footerWidth(for: candidate, timeline: stackedFooter ? 0 : minimumTimeline) <= available {
                    visible = candidate
                }
            }
        }
        sound = Self.sections[0].filter(visible.contains)
        transport = fullTransport.filter(visible.contains)
        options = Self.sections[2].filter(visible.contains)
        let transportWidth = Self.rowWidth(transport)
        let soundWidth = sound.isEmpty ? 0 : Self.rowWidth(sound) + Self.sectionGap
        let optionsWidth = options.isEmpty ? 0 : Self.rowWidth(options) + Self.sectionGap
        let left = stackedFooter ? soundWidth : transportWidth + Self.sectionGap
        let right = optionsWidth + (stackedFooter ? 0 : soundWidth)
        // Balance the sides around the timeline. In short windows, leave enough room to seek.
        let sides = stackedFooter ? max(0, available - transportWidth)
            : min(2 * max(left, right), max(0, available - minimumTimeline))
        leadingSpan = min(max(sides / 2, left), max(0, sides - right))
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

    func contentSize(proposed: CGSize, available: CGSize, showsSidebar: Bool) -> CGSize {
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
        let inline = showsSidebar && PlayerWindowLayout.fitsSidebar(in: available.width)
            && PlayerWindowLayout.fitsSidebar(in: max(minimumPictureWidth, layoutWidth))
        let sidebar = inline ? PlayerWindowLayout.sidebarSpan : 0
        let maximumPictureWidth = min(available.width - sidebar, available.height * aspect)
        let desiredPictureWidth = widthDriven ? proposed.width - sidebar : targetWidth
        let pictureWidth = min(maximumPictureWidth, max(minimumPictureWidth, desiredPictureWidth))
        return CGSize(width: min(available.width, max(minimum.width, pictureWidth) + sidebar),
                      height: min(available.height, max(minimum.height, pictureWidth / aspect)))
    }
}
