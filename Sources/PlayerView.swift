import AppKit
import SwiftUI

// Use SwiftUI's property wrapper when building with the standalone Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>
private let amber = Color(red: 1, green: 0.68, blue: 0.45)

private struct HDRButtonBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct PlayerView: View {
    @ObservedObject var session: PlayerSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if #available(macOS 14, *) {
            player.focusEffectDisabled()
        } else {
            player
        }
    }

    private var player: some View {
        GeometryReader { area in
            let inline = PlayerWindowLayout.fitsSidebar(in: area.size.width)
            HStack(spacing: 0) {
                video
                    .ignoresSafeArea(.container, edges: .top)
                    .accessibilityHidden(session.showsPlaylist && !inline)
                if session.showsPlaylist && inline {
                    Divider().frame(width: 1)
                    Playlist(session: session).frame(width: PlayerWindowLayout.playlistWidth)
                }
            }
            .overlay {
                if session.showsPlaylist && !inline {
                    ZStack(alignment: .trailing) {
                        Color.black.opacity(0.45).onTapGesture { session.showsPlaylist = false }
                        Playlist(session: session).frame(width: PlayerWindowLayout.playlistWidth)
                    }
                }
            }
            .overlay(alignment: .top) {
                PanelBackground(atTop: true)
                    .frame(height: area.safeAreaInsets.top)
                    .offset(y: -area.safeAreaInsets.top)
                    .opacity(session.controlsVisible ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: session.controlsVisible)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .topLeading) {
                if let notice = session.notice {
                    Text(notice)
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .lineLimit(3).truncationMode(.middle)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 6))
                        .padding(12)
                        .offset(y: session.controlsVisible ? 0 : -area.safeAreaInsets.top)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("playback-message")
                }
            }
        }
        .overlay {
            if let hint = session.dropHint {
                ZStack {
                    Color.black.opacity(0.65)
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(amber, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .padding(12)
                    Text(hint)
                        .font(.title3.weight(.semibold))
                }
                .allowsHitTesting(false)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private var video: some View {
        GeometryReader { proxy in
            let layout = PlaybackControlLayout(size: proxy.size, sourceIsHDR: session.sourceIsHDR)
            let minimum = PlayerWindowLayout.minimumContent
            let atMinimum = proxy.size.width <= minimum.width + 1 && proxy.size.height <= minimum.height + 1
            let smallPicture = atMinimum ? session.smallPictureSize : nil
            ZStack(alignment: .bottom) {
                ZStack {
                    Color.black
                    VideoWindowGestures(fullScreenOnDoubleClick: session.selection != nil)
                        .accessibilityHidden(true)
                    if session.selection == nil {
                        VStack(spacing: 10) {
                            Button { session.openFiles() } label: {
                                Text("동영상 열기")
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 16).frame(height: 36)
                                    .background(.white.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain).help("동영상 열기 (⌘O)")
                            Text("여기에 동영상을 놓아도 됩니다")
                                .font(.caption).foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                        }
                    } else {
                        if let display = session.engine?.displayLayer {
                            VideoSurface(display: display, videoSize: session.videoDisplaySize)
                                .frame(maxWidth: smallPicture?.width, maxHeight: smallPicture?.height)
                                .allowsHitTesting(false)
                        }
                        if session.pipActive {
                            ZStack {
                                Color.black
                                Label("화면 속 화면에서 재생 중", systemImage: "pip.fill").foregroundStyle(.secondary)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)

                if session.selection != nil {
                    ZStack(alignment: .bottom) {
                        if session.controlsVisible {
                            Controls(session: session, layout: layout)
                                .onHover { session.overControls = $0 }
                                .onDisappear { session.overControls = false }
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: layout.barHeight, alignment: .bottom)
                    .allowsHitTesting(session.controlsVisible)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: session.controlsVisible)
                    .backgroundPreferenceValue(HDRButtonBounds.self) { bounds in
                        GeometryReader { geometry in
                            let anchor: PopoverAttachmentAnchor = session.panel == .brightness
                                ? bounds.map { .rect(.rect(geometry[$0])) } ?? .point(.top) : .point(.top)
                            Color.clear
                                .allowsHitTesting(false)
                                .popover(item: $session.panel, attachmentAnchor: anchor, arrowEdge: .bottom) { panel in
                                    switch panel {
                                    case .brightness: BrightnessPanel(session: session)
                                    case .stream(let kind): StreamPanel(session: session, kind: kind)
                                    }
                                }
                        }
                    }
                }
            }
            .clipped()
        }
    }
}

private struct VideoWindowGestures: NSViewRepresentable {
    let fullScreenOnDoubleClick: Bool

    func makeNSView(context: Context) -> GestureView { GestureView() }
    func updateNSView(_ view: GestureView, context: Context) { view.fullScreenOnDoubleClick = fullScreenOnDoubleClick }

    final class GestureView: NSView {
        var fullScreenOnDoubleClick = false
        private var press: NSEvent?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            press = event
        }

        override func mouseDragged(with event: NSEvent) {
            guard let press, let window else { return }
            let start = press.locationInWindow
            let point = event.locationInWindow
            guard hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
            self.press = nil
            // AppKit starts the window drag with the original mouse-down event.
            if !window.styleMask.contains(.fullScreen) { window.performDrag(with: press) }
        }

        override func mouseUp(with event: NSEvent) {
            defer { press = nil }
            if press?.clickCount == 2, fullScreenOnDoubleClick { window?.toggleFullScreen(nil) }
        }
    }
}

private struct PanelBackground: View {
    let atTop: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Color(white: 0.10)
        } else {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.26), location: 0),
                .init(color: .black.opacity(0.50), location: 0.35),
                .init(color: .black.opacity(0.66), location: 1)
            ], startPoint: atTop ? .bottom : .top, endPoint: atTop ? .top : .bottom)
        }
    }
}

private extension View {
    func footerShadow() -> some View {
        shadow(color: .black.opacity(0.82), radius: 1.4, x: 0, y: 0.6)
    }
}

private struct Controls: View {
    @ObservedObject var session: PlayerSession
    let layout: PlaybackControlLayout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var volumeSymbol: String {
        if session.volume == 0 { return "speaker.slash.fill" }
        return session.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }

    var body: some View {
        VStack(spacing: 0) {
            if layout.playOnly {
                control(.play)
            } else {
                if layout.stackedFooter { timeline }
                HStack(spacing: 0) {
                    Group {
                        if layout.stackedFooter { row(layout.sound).footerShadow() }
                        else { timeline.padding(.trailing, PlaybackControlLayout.sectionGap) }
                    }
                    .frame(width: layout.leadingSpan, alignment: .leading)
                    row(layout.transport)
                    HStack(spacing: PlaybackControlLayout.sectionGap) {
                        if !layout.stackedFooter && !layout.sound.isEmpty { row(layout.sound) }
                        if !layout.options.isEmpty { row(layout.options) }
                    }
                    .footerShadow()
                    .frame(width: layout.trailingSpan, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, PlaybackControlLayout.inset)
        .frame(maxWidth: .infinity)
        .frame(height: layout.barHeight)
        .background {
            VideoWindowGestures(fullScreenOnDoubleClick: false).accessibilityHidden(true)
        }
        .background { PanelBackground(atTop: false) }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: layout.stackedFooter)
    }

    private var timeline: some View {
        HStack(spacing: 10) {
            Text(timecode(session.position))
            PlayerSlider(
                value: session.duration > 0 ? session.position / session.duration : 0,
                tint: amber, name: "재생 위치", reading: timecode(session.position),
                trackHeight: 7, thumbDiameter: 14, hitHeight: 32,
                hoverLabel: { timecode($0 * session.duration) },
                change: { session.seek(to: $0 * session.duration) },
                tracking: { session.scrubbing = $0 }
            )
            .disabled(session.duration == 0)
            Button { session.showsRemaining.toggle() } label: {
                Text(session.duration == 0 ? "–:––" : session.showsRemaining
                     ? "−" + timecode(session.duration - session.position) : timecode(session.duration))
            }
            .buttonStyle(.plain)
            .help(session.showsRemaining ? "전체 시간 표시" : "남은 시간 표시")
            .accessibilityLabel(session.showsRemaining ? "남은 시간" : "전체 시간")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.96))
        .footerShadow()
    }

    private func row(_ items: [PlaybackControlLayout.Item]) -> some View {
        HStack(spacing: PlaybackControlLayout.spacing) {
            ForEach(items, id: \.self) { item in
                control(item).frame(width: item.width)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func control(_ item: PlaybackControlLayout.Item) -> some View {
        switch item {
        case .mute:
            IconControl(volumeSymbol, label: session.volume == 0 ? "음소거 해제 (M)" : "음소거 (M)", action: session.toggleMute)
        case .volume:
            PlayerSlider(value: session.volume, tint: .white.opacity(0.86), name: "볼륨",
                         reading: "\(session.volumePercent)%", change: session.setVolume)
        case .brightness:
            Button { session.panel = .brightness } label: {
                HStack(spacing: 3) {
                    Image(systemName: "sun.max")
                    Text("×\(session.videoBrightness)").monospacedDigit()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(amber)
                .frame(width: item.width, height: 30)
            }
            .buttonStyle(HUDButtonStyle())
            .help("HDR 밝기").accessibilityLabel("HDR 밝기").accessibilityValue("\(session.videoBrightness)배")
            .anchorPreference(key: HDRButtonBounds.self, value: .bounds) { $0 }
            .onDisappear { if session.panel == .brightness { session.panel = nil } }
        case .audio:
            IconControl("waveform", label: "오디오 스트림 및 싱크") { session.panel = .stream(.audio) }
        case .subtitles:
            let on = session.streams.contains { $0.kind == .subtitle && $0.selected }
            IconControl(on ? "captions.bubble.fill" : "captions.bubble", label: "자막 스트림 및 싱크") { session.panel = .stream(.subtitle) }
        case .trash:
            HStack(spacing: 0) {
                Divider().frame(height: 15)
                Spacer(minLength: 0)
                IconControl("trash", label: "현재 영상과 자막 삭제 (⌫)", size: 15) { session.deleteCurrent() }
                    .disabled(session.deletionInProgress)
            }
        case .previous: fileButton(-1)
        case .next: fileButton(1)
        case .back60: seekButton(-60, symbol: "arrow.left")
        case .back10: seekButton(-10, symbol: "gobackward")
        case .ahead10: seekButton(10, symbol: "goforward")
        case .ahead60: seekButton(60, symbol: "arrow.right")
        case .play:
            let label = session.playing ? "일시 정지" : "재생"
            Button { session.togglePlay() } label: {
                Image(systemName: session.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .medium))
                    .offset(x: session.playing ? 0 : 1)
                    .foregroundStyle(.white)
                    .frame(width: item.width, height: 34)
            }
            .buttonStyle(HUDButtonStyle()).accessibilityLabel(label).help("\(label) (Space)")
        }
    }

    private func fileButton(_ direction: Int) -> some View {
        let available = session.adjacent(direction) != nil
        return IconControl(direction < 0 ? "backward.end.fill" : "forward.end.fill",
                           label: direction < 0 ? "이전 파일 (⌘←)" : "다음 파일 (⌘→)", size: 14) { session.stepFile(direction) }
            .disabled(!available).opacity(available ? 1 : 0.32)
            .footerShadow()
    }

    private func seekButton(_ seconds: Int, symbol: String) -> some View {
        let backwards = seconds < 0
        let number = abs(seconds)
        let key = (number == 60 ? "⌥" : "") + (backwards ? "←" : "→")
        let label = "\(number)초 \(backwards ? "뒤로" : "앞으로") (\(key))"
        return Button {
            session.seek(to: session.position + Double(seconds))
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(HUDButtonStyle()).help(label).accessibilityLabel(label)
    }
}

private struct IconControl: View {
    let symbol: String
    let label: String
    var size: CGFloat = 16
    let action: () -> Void
    init(_ symbol: String, label: String, size: CGFloat = 16, action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.size = size
        self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .medium))
                .foregroundStyle(.white.opacity(0.93))
                .frame(width: PlaybackControlLayout.iconWidth, height: 30)
        }
        .buttonStyle(HUDButtonStyle()).help(label).accessibilityLabel(label)
    }
}

private struct HUDButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverSurface(pressed: configuration.isPressed, content: configuration.label)
    }
    private struct HoverSurface<Content: View>: View {
        let pressed: Bool
        let content: Content
        @ViewState private var hovered = false
        var body: some View {
            content.contentShape(Rectangle())
                .background(.white.opacity(pressed ? 0.19 : hovered ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 6))
                .onHover { hovered = $0 }
        }
    }
}

private struct PlayerSlider: View {
    let value: Double
    let tint: Color
    let name: String
    let reading: String
    var trackHeight: CGFloat = 3
    var thumbDiameter: CGFloat = 8
    var hitHeight: CGFloat = 21
    var hoverLabel: ((Double) -> String)?
    let change: (Double) -> Void
    var tracking: (Bool) -> Void = { _ in }
    @ViewState private var hover: Double?
    @ViewState private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let activeThumbDiameter = thumbDiameter + 2
            let inset = activeThumbDiameter / 2
            let span = max(1, proxy.size.width - 2 * inset)
            let fraction = min(1, max(0, value))
            let x = inset + fraction * span
            let y = proxy.size.height / 2
            let prominent = hover != nil || dragging
            let thickness = prominent ? trackHeight + 1 : trackHeight
            let diameter = prominent ? activeThumbDiameter : thumbDiameter
            ZStack {
                Capsule().fill(.white.opacity(0.40))
                    .frame(width: span, height: thickness)
                    .position(x: inset + span / 2, y: y)
                Capsule().fill(tint)
                    .frame(width: span * fraction, height: thickness)
                    .position(x: inset + span * fraction / 2, y: y)
                Circle().fill(tint).frame(width: diameter, height: diameter)
                    .position(x: x, y: y)
                if let hover, let hoverLabel {
                    Text(hoverLabel(hover)).font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize().position(x: max(20, min(proxy.size.width - 20, inset + hover * span)), y: -10)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover = min(1, max(0, (point.x - inset) / span))
                case .ended: hover = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { event in
                    if !dragging { dragging = true; tracking(true) }
                    change(min(1, max(0, (event.location.x - inset) / span)))
                }
                .onEnded { _ in dragging = false; tracking(false) })
        }
        .frame(height: hitHeight)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { value }, set: change), in: 0...1) { Text(name) }
                .accessibilityValue(reading)
        }
    }
}

struct BrightnessPanel: View {
    @ObservedObject var session: PlayerSession

    var body: some View {
        let range = PlayerSession.brightnessRange
        let selection = Binding(get: { Double(session.videoBrightness) },
                                set: { session.setVideoBrightness(Int($0.rounded())) })
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("영상 밝기").font(.headline)
                Spacer()
                Text("×\(session.videoBrightness)").monospacedDigit().fontWeight(.semibold)
                    .foregroundStyle(amber).accessibilityHidden(true)
            }
            Slider(value: selection, in: Double(range.lowerBound)...Double(range.upperBound), step: 1) {
                Text("영상 밝기")
            }
            .labelsHidden().tint(amber)
            .accessibilityValue("\(session.videoBrightness)배")
            HStack {
                Text("×\(range.lowerBound)")
                Spacer()
                Text("×\(range.upperBound)")
            }
            .font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .padding(14).frame(width: 224).preferredColorScheme(.dark)
    }
}

private struct StreamPanel: View {
    @ObservedObject var session: PlayerSession
    let kind: StreamKind
    private var delay: Double { kind == .audio ? session.audioDelay : session.subtitleDelay }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(kind == .audio ? "오디오 스트림" : "자막 스트림").font(.headline)
            let rows = session.streams.filter { $0.kind == kind }
            ScrollView {
                VStack(spacing: 1) {
                    ChoiceRow(title: "끔", selected: !rows.contains(where: \.selected)) { session.selectStream(kind, id: -1) }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        ChoiceRow(title: "\(index + 1)번 · \(row.title)", selected: row.selected) { session.selectStream(kind, id: row.id) }
                    }
                }
            }.frame(height: min(174, CGFloat(rows.count + 1) * 30))
            if kind == .subtitle {
                HStack(spacing: 14) {
                    Button("외부 자막 열기…", action: session.chooseSubtitles)
                    Button("AI 자막 생성…") { session.openCaptionGenerator?() }
                }.buttonStyle(.link)
                Picker("자막 크기", selection: $session.subtitleSize) {
                    ForEach(SubtitleSize.allCases, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                }.pickerStyle(.menu)
            }
            Divider()
            HStack {
                Text(kind == .audio ? "오디오 싱크" : "자막 싱크").font(.subheadline.weight(.semibold))
                Spacer()
                Button { session.setDelay(kind, seconds: 0) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain).help("싱크 초기화").accessibilityLabel("싱크 초기화")
            }
            HStack {
                Button { session.setDelay(kind, seconds: delay - 0.1) } label: { Image(systemName: "minus") }
                    .accessibilityLabel("0.1초 앞당기기")
                Spacer()
                Text(String(format: "%+.1f초",delay)).monospacedDigit()
                Spacer()
                Button { session.setDelay(kind, seconds: delay + 0.1) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("0.1초 늦추기")
            }
        }.padding(13).frame(width: 250).preferredColorScheme(.dark)
    }
}

private struct ChoiceRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if selected { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(amber) }
            }
            .padding(.horizontal, 8).frame(height: 29)
        }
        .buttonStyle(HUDButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct Playlist: View {
    @ObservedObject var session: PlayerSession

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(session.clips) { clip in
                        let selected = session.selection == clip.id
                        let name = clip.url.lastPathComponent
                        Button { session.select(clip) } label: {
                            HStack(spacing: 8) {
                                Text(name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                if selected { Image(systemName: "checkmark").foregroundStyle(amber) }
                            }
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .padding(.horizontal, 9).frame(height: 30)
                            .background(selected ? .white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(HUDButtonStyle()).help(name)
                        .accessibilityLabel(name).accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(6)
            }
            .onAppear { if let id = session.selection { reader.scrollTo(id, anchor: .center) } }
            .onChange(of: session.selection) { id in if let id { reader.scrollTo(id, anchor: .center) } }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.09, green: 0.095, blue: 0.105))
        .accessibilityLabel("재생목록")
    }
}
