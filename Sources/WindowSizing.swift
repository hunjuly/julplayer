import AppKit

enum WindowSizePreset: Int, CaseIterable {
    case minimum = 1, half, actual

    var menuTitle: String {
        switch self {
        case .minimum: return "최소 창 크기"
        case .half: return "영상 크기 50%"
        case .actual: return "영상 크기 100%"
        }
    }
}

enum PlayerWindowLayout {
    static let minimumContent = CGSize(width: 280, height: 158)
    static let seekControlsWidth: CGFloat = 360
    static let fileControlsWidth: CGFloat = 480
    static let extendedControlsWidth: CGFloat = 620
    static let playlistWidth: CGFloat = 236
    static let playlistSpan = playlistWidth + 1

    static func fitsSidebar(in width: CGFloat) -> Bool {
        width >= minimumContent.width + playlistSpan
    }

    static func dimensions(for preset: WindowSizePreset, videoPixels: CGSize?, backingScale: CGFloat,
                           available: CGSize, showsPlaylist: Bool) -> (content: CGSize, smallPicture: CGSize?)? {
        if preset == .minimum { return (minimumContent, nil) }
        guard let videoPixels, videoPixels.width > 0, videoPixels.height > 0, backingScale > 0 else { return nil }
        let sidebar = showsPlaylist && fitsSidebar(in: available.width) ? playlistSpan : 0
        let pointsPerPixel = min((preset == .half ? 0.5 : 1) / backingScale,
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
