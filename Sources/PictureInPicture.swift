import AVKit
import SwiftUI

struct VideoSurface: NSViewRepresentable {
    let display: AVSampleBufferDisplayLayer
    let videoSize: CGSize?
    func makeNSView(context: Context) -> SurfaceView { SurfaceView(display) }
    func updateNSView(_ view: SurfaceView, context: Context) { view.videoSize = videoSize }

    final class SurfaceView: NSView {
        let display: AVSampleBufferDisplayLayer
        var videoSize: CGSize? {
            didSet { if oldValue != videoSize { needsLayout = true } }
        }
        init(_ display: AVSampleBufferDisplayLayer) {
            self.display = display
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(display)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            guard !bounds.isEmpty else { return }
            let frame = videoSize.map { AVMakeRect(aspectRatio: $0, insideRect: bounds) } ?? bounds
            guard display.frame != frame else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            display.frame = frame
            CATransaction.commit()
        }
    }
}

@MainActor
final class PictureInPicture: NSObject, @preconcurrency AVPictureInPictureControllerDelegate, @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    private enum Phase { case idle, leavingFullScreen, starting, active, stopping }

    private weak var session: PlayerSession?
    private var controller: AVPictureInPictureController?
    private var phase = Phase.idle
    private var panelOutput: VideoSurface.SurfaceView?
    var screen: NSScreen? { panelOutput?.window?.screen }
    private var previouslyVisiblePanels: Set<ObjectIdentifier> = []
    private var minimizedPlayer = false
    private var returnToFullScreen = false
    var isSupported: Bool { controller != nil }
    var canStart: Bool {
        guard controller?.isPictureInPicturePossible == true, let session, session.loaded, session.videoDisplaySize != nil,
              let layer = session.engine?.displayLayer, layer.superlayer != nil, !layer.bounds.isEmpty else { return false }
        if #available(macOS 14.4, *) { return layer.isReadyForDisplay }
        return true
    }

    init(session: PlayerSession, layer: AVSampleBufferDisplayLayer) {
        self.session = session
        super.init()
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        controller = AVPictureInPictureController(contentSource: source)
        controller?.delegate = self
    }

    func attachPanelOutputIfNeeded() {
        guard phase == .active, panelOutput?.window?.isVisible != true, let engine = session?.engine else { return }
        let panel = NSApp.windows.lazy.compactMap { $0 as? NSPanel }.first {
            $0.isVisible && $0.isExcludedFromWindowsMenu && $0.styleMask.contains(.nonactivatingPanel)
                && !$0.styleMask.contains(.titled) && !previouslyVisiblePanels.contains(ObjectIdentifier($0))
        }
        guard let content = panel?.contentView else { return }
        // AVKit's sample-buffer mirror can crop to the inline view. Present the same
        // decoded frames directly in its panel, below the system's playback controls.
        let output = panelOutput ?? VideoSurface.SurfaceView(AVSampleBufferDisplayLayer())
        output.display.videoGravity = .resizeAspect
        output.display.controlTimebase = engine.displayLayer.controlTimebase
        output.frame = content.bounds
        output.autoresizingMask = [.width, .height]
        content.addSubview(output, positioned: .above, relativeTo: nil)
        output.layoutSubtreeIfNeeded()
        panelOutput = output
        engine.setPictureInPictureDisplayLayer(output.display)
    }

    private func detachPanelOutput() {
        if let panelOutput {
            session?.engine?.setPictureInPictureDisplayLayer(nil)
            panelOutput.removeFromSuperview()
            self.panelOutput = nil
        }
        previouslyVisiblePanels.removeAll()
    }

    func toggle() {
        if phase == .active { stop(); return }
        guard phase == .idle else { return }
        guard canStart else {
            session?.show("영상이 준비되면 화면 속 화면을 시작할 수 있습니다.")
            return
        }
        if let window = session?.window, window.styleMask.contains(.fullScreen) {
            returnToFullScreen = true
            phase = .leavingFullScreen
            window.toggleFullScreen(nil)
        } else {
            start()
        }
    }

    func fullScreenTransitionFinished() {
        guard phase == .leavingFullScreen else { return }
        guard session?.window?.styleMask.contains(.fullScreen) == false else {
            phase = .idle
            returnToFullScreen = false
            return
        }
        start()
    }

    private func start() {
        guard let controller, canStart else {
            phase = .idle
            restoreFullScreenIfNeeded()
            session?.show("영상이 준비되면 화면 속 화면을 시작할 수 있습니다.")
            return
        }
        previouslyVisiblePanels = Set(NSApp.windows.compactMap { $0 is NSPanel && $0.isVisible ? ObjectIdentifier($0) : nil })
        phase = .starting
        if let session, !session.callActive { session.setPlaying(true) }
        session?.showFeedback("화면 속 화면 시작")
        controller.startPictureInPicture()
    }

    func invalidate() { controller?.invalidatePlaybackState() }

    func stop() {
        if phase == .leavingFullScreen {
            phase = .idle
            returnToFullScreen = false
            return
        }
        guard phase == .active || phase == .starting else { return }
        phase = .stopping
        controller?.stopPictureInPicture()
    }

    func shutdown() {
        controller?.delegate = nil
        stop()
        detachPanelOutput()
    }

    private func showPlayerWindow() -> Bool {
        guard let window = session?.window else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private func restoreFullScreenIfNeeded() {
        guard returnToFullScreen else { return }
        returnToFullScreen = false
        if let window = session?.window, !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        if phase == .stopping { controller.stopPictureInPicture(); return }
        phase = .active
        session?.pipActive = true
        attachPanelOutputIfNeeded()
        if let window = session?.window, !window.isMiniaturized {
            minimizedPlayer = true
            window.miniaturize(nil)
        }
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) { phase = .stopping }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        phase = .idle
        session?.pipActive = false
        detachPanelOutput()
        if minimizedPlayer { _ = showPlayerWindow() }
        minimizedPlayer = false
        restoreFullScreenIfNeeded()
        session?.showFeedback("화면 속 화면 종료")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        phase = .idle
        session?.pipActive = false
        detachPanelOutput()
        restoreFullScreenIfNeeded()
        session?.show(error.localizedDescription)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        phase = .stopping
        completionHandler(showPlayerWindow())
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) { session?.setPlaying(playing) }
    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { session?.playing != true }
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        guard let seconds = session?.duration, seconds > 0 else { return .invalid }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        attachPanelOutputIfNeeded()
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        guard let session else { completion(); return }
        session.seek(to: session.position + skipInterval.seconds, completion: completion)
    }
}
