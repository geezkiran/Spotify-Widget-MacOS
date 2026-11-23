import AppKit
import Combine
import SwiftUI

/// A Dynamic Island–style now-playing strip around the MacBook notch: the cover on its left,
/// a moving three-bar waveform on its right, exactly as tall as the notch. Shown while playing,
/// and for a few seconds after pausing (with the waveform at rest) before it folds back into the notch.
/// Clicking it expands it downward into a player with the track and playback controls.
@MainActor
final class NotchPlayer {
    static let enabledKey = "showInNotch"
    /// How long the strip stays out after playback pauses before folding back into the notch.
    static let pausedHideDelay: TimeInterval = 3

    private let model = NotchModel()
    private var panel: NSPanel?
    private var frames: (compact: NSRect, expanded: NSRect)?
    private var cancellables: Set<AnyCancellable> = []
    private var clickMonitor: Any?
    private var hideAfterPause: DispatchWorkItem?
    private var screensAsleep = false
    private var screenLocked = false

    init(player: PlayerController) {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])

        model.perform = { command in Task { await player.perform(command) } }
        model.setExpanded = { [weak self] in self?.setExpanded($0) }

        player.$snapshot
            .sink { [weak self] in self?.update($0) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in UserDefaults.standard.bool(forKey: Self.enabledKey) }
            .removeDuplicates()
            .sink { [weak self] _ in self?.layout() }
            .store(in: &cancellables)

        // Nothing to draw or listen for while nobody can see the strip.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { [weak self] _ in self?.screensAsleep = true; self?.updateOnScreen() }
            .store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in self?.screensAsleep = false; self?.updateOnScreen() }
            .store(in: &cancellables)
        let distributed = DistributedNotificationCenter.default()
        distributed.publisher(for: .init("com.apple.screenIsLocked"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.screenLocked = true; self?.updateOnScreen() }
            .store(in: &cancellables)
        distributed.publisher(for: .init("com.apple.screenIsUnlocked"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.screenLocked = false; self?.updateOnScreen() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
            .sink { [weak self] note in
                guard let self, note.object as? NSPanel === self.panel else { return }
                self.updateOnScreen()
            }
            .store(in: &cancellables)

        // A click anywhere else closes the expanded player. Global monitors only see other apps' events.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.setExpanded(false) }
        }

        layout()
    }

    private func update(_ snapshot: NowPlaying) {
        model.isPlaying = snapshot.isPlaying
        model.title = snapshot.title
        model.artist = snapshot.artist
        model.liked = snapshot.hasTrack ? snapshot.liked : nil
        if snapshot.artworkFile != model.artworkFile {
            model.artworkFile = snapshot.artworkFile
            model.artwork = snapshot.artworkFile.flatMap { NSImage(contentsOf: SharedStore.fileURL($0)) }
        }
        if !snapshot.hasTrack { setExpanded(false) }
        updateVisibility(snapshot)
        updateMouseHandling()
        updateAudio()
    }

    /// Opens as soon as playback starts. After a pause it stays out, still, for `pausedHideDelay`
    /// before collapsing; resuming within that time cancels the collapse. With no track it closes at once.
    private func updateVisibility(_ snapshot: NowPlaying) {
        if snapshot.isPlaying {
            cancelPendingHide()
            model.visible = true
        } else if !snapshot.hasTrack {
            cancelPendingHide()
            model.visible = false
        } else if model.visible, hideAfterPause == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hideAfterPause = nil
                self.model.visible = false
                self.updateMouseHandling()
            }
            hideAfterPause = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pausedHideDelay, execute: work)
        }
    }

    private func cancelPendingHide() {
        hideAfterPause?.cancel()
        hideAfterPause = nil
    }

    /// Whether the strip can be seen at all: the display is awake, the screen unlocked, the panel not covered.
    private func updateOnScreen() {
        let visible = panel.map { $0.occlusionState.contains(.visible) } ?? false
        let onScreen = visible && !screensAsleep && !screenLocked
        if model.onScreen != onScreen { model.onScreen = onScreen }
        updateAudio()
    }

    /// Listens to Spotify's audio only while the waveform is on screen and moving.
    private func updateAudio() {
        AudioLevelMonitor.shared.setActive(panel != nil && model.isPlaying && model.onScreen)
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != model.expanded, let panel, let frames else { return }
        if expanded {
            // Grow the window first, so the shape has room to animate into.
            panel.setFrame(frames.expanded, display: true)
            model.expanded = true
        } else {
            model.expanded = false
            // Shrink the window once the shape has animated back, so it stops covering the menu bar.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, !self.model.expanded, let frames = self.frames else { return }
                self.panel?.setFrame(frames.compact, display: true)
            }
        }
        updateMouseHandling()
    }

    /// Clicks pass through while nothing is showing.
    private func updateMouseHandling() {
        panel?.ignoresMouseEvents = !(model.visible || model.expanded)
    }

    /// Places the panel over the notch of the first screen that has one, or removes it.
    private func layout() {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey),
              let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else {
            model.expanded = false
            panel?.orderOut(nil)
            panel = nil
            updateOnScreen()
            return
        }

        let height = screen.safeAreaInsets.top
        let notchWidth = screen.frame.width - left.width - right.width
        model.notchWidth = notchWidth
        model.height = height

        let centerX = screen.frame.minX + left.width + notchWidth / 2
        func frame(_ size: CGSize) -> NSRect {
            let width = size.width + 2 * NotchMetrics.flare
            return NSRect(x: centerX - width / 2, y: screen.frame.maxY - size.height, width: width, height: size.height)
        }
        frames = (frame(model.compactSize), frame(model.expandedSize))

        let panel = self.panel ?? makePanel()
        panel.setFrame(model.expanded ? frames!.expanded : frames!.compact, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        updateMouseHandling()
        updateOnScreen()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Notch Player"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Above the menu bar, so the strip reads as part of the notch.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = FirstClickHostingView(rootView: NotchView(model: model))
        return panel
    }
}

/// Takes the first click, so the strip and its buttons respond without the app being active first.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var isPlaying = false
    /// Whether the strip is out from under the notch: while playing, and for a while after pausing.
    @Published var visible = false
    /// Whether the panel can actually be seen (display awake, screen unlocked, not covered).
    @Published var onScreen = true
    @Published var expanded = false
    @Published var title = ""
    @Published var artist = ""
    /// Whether the track is in Liked Songs; nil hides the like button (no account connected, or unknown).
    @Published var liked: Bool?
    @Published var artwork: NSImage?
    @Published var notchWidth: CGFloat = 0
    @Published var height: CGFloat = 32
    var artworkFile: String?
    var perform: (PlayerCommand) -> Void = { _ in }
    var setExpanded: (Bool) -> Void = { _ in }

    var wing: CGFloat { NotchMetrics.wingWidth(height: height) }
    var compactSize: CGSize { CGSize(width: notchWidth + 2 * wing, height: height) }
    var expandedSize: CGSize { CGSize(width: notchWidth + 2 * wing + 110, height: height + 118) }
}

enum NotchMetrics {
    /// Each side container is a square the notch's height, plus a little breathing room.
    static func wingWidth(height: CGFloat) -> CGFloat { height + 8 }
    static func inset(height: CGFloat) -> CGFloat { (height * 0.16).rounded() }
    /// Radius of the outward curve at each top corner, where the strip meets the menu bar.
    static let flare: CGFloat = 6
}

/// The strip's outline: rounded bottom corners, and top corners that curve outward into the menu bar
/// like the notch's own. The flares sit outside the body, `flare` wide on each side.
struct NotchShape: Shape {
    var flare: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, radius) }
        set { (flare, radius) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + flare, right = rect.maxX - flare
        let radius = min(radius, (right - left) / 2, rect.height - flare)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.minY), tangent2End: CGPoint(x: left, y: rect.maxY), radius: flare)
        path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: flare)
        path.closeSubpath()
        return path
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let shown = model.visible || model.expanded
        // The flares shrink away when hidden, so the strip folds back to exactly the notch.
        let flare = shown ? NotchMetrics.flare : 0
        let radius = model.expanded ? 24 : model.height / 2.6
        let shape = NotchShape(flare: flare, radius: radius)
        let size = model.expanded ? model.expandedSize
            : shown ? model.compactSize
            : CGSize(width: model.notchWidth, height: model.height)

        ZStack(alignment: .top) {
            if model.expanded {
                expanded
            }
            morphing(shown: shown, width: size.width)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .padding(.horizontal, flare)
        .background(.black, in: shape)
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture { model.setExpanded(!model.expanded) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: shown)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.expanded)
    }

    /// The cover and the waveform are single views that morph between their places in the strip and in the
    /// expanded player: each one grows or shrinks and moves to its new spot as the shape opens or closes.
    /// When hidden, both sit tucked behind the middle of the notch, where nothing shows.
    private func morphing(shown: Bool, width: CGFloat) -> some View {
        let wing = model.wing
        let inset = NotchMetrics.inset(height: model.height)
        // Distance from the middle of the notch to the middle of each side container in the strip.
        let side = shown ? (model.notchWidth + wing) / 2 : 0
        let row = model.height + 8 + Self.coverSize / 2
        // The strip's icons sit a little above the notch's middle, so they line up with the menu bar's content.
        let stripY = model.height / 2 - Self.stripLift
        let coverSize = model.expanded ? Self.coverSize : model.height - 2 * inset + 3
        let coverCenter = model.expanded
            ? CGPoint(x: Self.sidePadding + Self.coverSize / 2, y: row)
            : CGPoint(x: width / 2 - side, y: stripY)
        let waveSize = model.expanded ? Self.waveSize : CGSize(width: wing, height: model.height - 2 * (inset + 2))
        let waveCenter = model.expanded
            ? CGPoint(x: width - Self.sidePadding - Self.waveSize.width / 2, y: row)
            : CGPoint(x: width / 2 + side, y: stripY)

        return ZStack(alignment: .topLeading) {
            cover(cornerRadius: model.expanded ? 10 : 6)
                .frame(width: coverSize, height: coverSize)
                .position(coverCenter)
            Waveform(isPlaying: model.isPlaying, onScreen: model.onScreen)
                .frame(width: waveSize.width, height: waveSize.height)
                .position(waveCenter)
        }
        .frame(width: width, height: model.expanded ? model.expandedSize.height : model.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private static let coverSize: CGFloat = 52
    private static let waveSize = CGSize(width: 22, height: 20)
    private static let sidePadding: CGFloat = 20
    private static let stripLift: CGFloat = 2

    private var expanded: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Color.clear
                    .frame(width: Self.coverSize, height: Self.coverSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(model.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let liked = model.liked {
                    Button { model.perform(.toggleLike) } label: {
                        LikeIconShape(liked: liked)
                            .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(liked ? Color(red: 0.12, green: 0.84, blue: 0.38) : .white)
                            .frame(width: 24, height: 24)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(liked ? "Remove from Liked Songs" : "Save to Liked Songs")
                }
                Color.clear
                    .frame(width: Self.waveSize.width, height: Self.waveSize.height)
            }
            HStack(spacing: 6) {
                control("backward.fill", size: 18) { model.perform(.previous) }
                control(model.isPlaying ? "pause.fill" : "play.fill", size: 26) { model.perform(.playPause) }
                control("forward.fill", size: 18) { model.perform(.next) }
            }
        }
        .padding(.top, model.height + 8)
        .padding(.horizontal, Self.sidePadding)
        .frame(width: model.expandedSize.width, height: model.expandedSize.height, alignment: .top)
        // Drops straight down from under the notch as the shape grows, and lifts straight back up when it closes.
        .transition(.move(edge: .top))
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(.white)
                .frame(width: 54, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverHighlightButtonStyle())
    }

    private func cover(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return Group {
            if let artwork = model.artwork {
                Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
            } else {
                shape.fill(Color.white.opacity(0.15))
                    .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.7)))
            }
        }
        .clipShape(shape)
    }
}

/// A plain button that lights up a faint rounded background under the pointer, a little brighter while pressed.
private struct HoverHighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(configuration: configuration)
    }

    private struct HoverHighlight: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(configuration.isPressed ? 0.18 : hovering ? 0.1 : 0))
                }
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// Three vertical bars following Spotify's bass, mids and treble, like an equalizer. Flat when paused.
/// Falls back to bars bouncing out of phase when the audio can't be read (before macOS 14.2, or before the tap is ready).
///
/// Drawn with three plain Core Animation layers moved by a 30 fps display link, rather than a SwiftUI
/// TimelineView: each frame is then just a layer geometry change, with no view graph update or re-render,
/// and frames where no bar visibly moves are skipped altogether.
struct Waveform: NSViewRepresentable {
    let isPlaying: Bool
    /// Stops the display link while the strip can't be seen.
    let onScreen: Bool

    func makeNSView(context: Context) -> WaveformView { WaveformView() }

    func updateNSView(_ view: WaveformView, context: Context) {
        view.update(isPlaying: isPlaying, onScreen: onScreen)
    }

    static func dismantleNSView(_ view: WaveformView, coordinator: ()) {
        view.stop()
    }
}

final class WaveformView: NSView {
    private static let restLevel: Double = 0.25
    /// Changes smaller than this (a share of the bar's height) aren't worth a frame.
    private static let minimumChange: Double = 0.004
    private static let speeds = SIMD3<Double>(5.1, 7.3, 6.2)
    private static let phases = SIMD3<Double>(0, 1.9, 3.7)

    private let bars = (0..<3).map { _ in CALayer() }
    private var link: CADisplayLink?
    private var isPlaying = false
    private var onScreen = true
    private var levels = SIMD3<Double>(repeating: restLevel)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for bar in bars {
            bar.backgroundColor = NSColor.white.cgColor
            layer?.addSublayer(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(isPlaying: Bool, onScreen: Bool) {
        self.isPlaying = isPlaying
        self.onScreen = onScreen
        if !isPlaying { setLevels(SIMD3(repeating: Self.restLevel)) }
        updateLink()
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLink()
    }

    override func layout() {
        super.layout()
        layoutBars()
    }

    private func updateLink() {
        let run = isPlaying && onScreen && window != nil
        if run, link == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !run {
            stop()
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        if let live = AudioLevelMonitor.shared.levels() {
            // The curve keeps small changes small, so only clear peaks reach the top.
            let curved = SIMD3<Double>(Double(pow(live[0], 1.4)), Double(pow(live[1], 1.4)), Double(pow(live[2], 1.4)))
            setLevels(0.25 + 0.75 * curved)
        } else {
            let t = link.targetTimestamp
            var wave = SIMD3<Double>()
            for i in 0..<3 {
                let s = Self.speeds[i], p = Self.phases[i]
                wave[i] = abs((sin(t * s + p) + sin(t * s * 0.53 + p * 2)) / 2)
            }
            setLevels(0.3 + 0.7 * wave)
        }
    }

    private func setLevels(_ next: SIMD3<Double>) {
        // Always settle exactly at rest when paused; otherwise skip changes too small to see.
        let settling = next == SIMD3(repeating: Self.restLevel)
        let delta = next - levels
        let change = max(abs(delta.x), abs(delta.y), abs(delta.z))
        guard next != levels, settling || change >= Self.minimumChange else { return }
        levels = next
        layoutBars()
    }

    private func layoutBars() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let barWidth = max(2, size.height / 6)
        let spacing = barWidth * 0.8
        var x = (size.width - 3 * barWidth - 2 * spacing) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let height = size.height * levels[i]
            bar.frame = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
            bar.cornerRadius = barWidth / 2
            x += barWidth + spacing
        }
        CATransaction.commit()
    }
}
