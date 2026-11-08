import AppKit
import Combine
import SwiftUI

/// A Dynamic Island–style now-playing strip around the MacBook notch: the cover on its left,
/// a moving three-bar waveform on its right, exactly as tall as the notch. Shown only while playing.
@MainActor
final class NotchPlayer {
    static let enabledKey = "showInNotch"

    private let model = NotchModel()
    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []

    init(player: PlayerController) {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])

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

        layout()
    }

    private func update(_ snapshot: NowPlaying) {
        model.isPlaying = snapshot.isPlaying
        if snapshot.artworkFile != model.artworkFile {
            model.artworkFile = snapshot.artworkFile
            model.artwork = snapshot.artworkFile.flatMap { NSImage(contentsOf: SharedStore.fileURL($0)) }
        }
    }

    /// Places the panel over the notch of the first screen that has one, or removes it.
    private func layout() {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey),
              let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else {
            panel?.orderOut(nil)
            panel = nil
            return
        }

        let height = screen.safeAreaInsets.top
        let notchWidth = screen.frame.width - left.width - right.width
        let wing = NotchMetrics.wingWidth(height: height)
        let frame = NSRect(
            x: screen.frame.minX + left.width - wing,
            y: screen.frame.maxY - height,
            width: notchWidth + 2 * wing,
            height: height
        )
        model.notchWidth = notchWidth
        model.height = height

        let panel = self.panel ?? makePanel()
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
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
        panel.contentView = NSHostingView(rootView: NotchView(model: model))
        return panel
    }
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var isPlaying = false
    @Published var artwork: NSImage?
    @Published var notchWidth: CGFloat = 0
    @Published var height: CGFloat = 32
    var artworkFile: String?
}

enum NotchMetrics {
    /// Each side container is a square the notch's height, plus a little breathing room.
    static func wingWidth(height: CGFloat) -> CGFloat { height + 8 }
    static func inset(height: CGFloat) -> CGFloat { (height * 0.16).rounded() }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let wing = NotchMetrics.wingWidth(height: model.height)
        let inset = NotchMetrics.inset(height: model.height)
        let radius = model.height / 2.6

        HStack(spacing: 0) {
            cover(inset: inset)
                .frame(width: wing, height: model.height)
            Spacer(minLength: model.notchWidth)
            Waveform(isPlaying: model.isPlaying)
                .padding(.vertical, inset + 2)
                .frame(width: wing, height: model.height)
        }
        // Retracts into the notch when playback stops, and grows out of it when it starts.
        .frame(width: model.isPlaying ? model.notchWidth + 2 * wing : model.notchWidth, height: model.height)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius))
        .opacity(model.isPlaying ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: model.isPlaying)
    }

    @ViewBuilder
    private func cover(inset: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Group {
            if let artwork = model.artwork {
                Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
            } else {
                shape.fill(Color.white.opacity(0.15))
                    .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.7)))
            }
        }
        .frame(width: model.height - 2 * inset, height: model.height - 2 * inset)
        .clipShape(shape)
    }
}

/// Three vertical bars bouncing out of phase, like an equalizer. Flat when paused.
struct Waveform: View {
    let isPlaying: Bool
    private static let speeds: [Double] = [5.1, 7.3, 6.2]
    private static let phases: [Double] = [0, 1.9, 3.7]

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let barWidth = max(2, geo.size.height / 6)
                HStack(alignment: .center, spacing: barWidth * 0.8) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule()
                            .fill(Color(red: 0.12, green: 0.84, blue: 0.38))
                            .frame(width: barWidth, height: geo.size.height * level(i, t))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private func level(_ i: Int, _ t: Double) -> CGFloat {
        guard isPlaying else { return 0.25 }
        let wave = (sin(t * Self.speeds[i] + Self.phases[i]) + sin(t * Self.speeds[i] * 0.53 + Self.phases[i] * 2)) / 2
        return 0.3 + 0.7 * CGFloat(abs(wave))
    }
}
