import SwiftUI
import WidgetKit

struct NowPlayingView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetContentMargins) private var margins
    let entry: NowPlayingEntry
    /// Whether the medium layout shows elapsed and total time under the progress bar.
    var showTimes = false

    var body: some View {
        Group {
            if entry.snapshot.hasTrack {
                switch family {
                case .systemSmall: SmallView(entry: entry)
                default: MediumView(entry: entry, showTimes: showTimes)
                }
            } else {
                EmptyStateView(status: entry.snapshot.status)
            }
        }
        .padding(margins)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        // The cover is content, not the container background: macOS replaces the container
        // background with glass when another app is focused, which would force a different layout.
        .background { BackdropView(image: entry.backdrop) }
        .containerBackground(for: .widget) { Color(white: 0.12) }
        .widgetURL(URL(string: "spotify:"))
    }
}

struct SmallView: View {
    let entry: NowPlayingEntry

    static let titleSize: CGFloat = 15

    var body: some View {
        let s = entry.snapshot
        VStack(alignment: .leading, spacing: 2) {
            LikeButton(liked: s.liked)
            Spacer(minLength: 4)
            HStack(alignment: .center, spacing: 6) {
                SlidingText(text: s.title, previous: s.previousTitle, changes: s.titleChanges, direction: s.skipDirection, fadesOverflow: true, marquee: entry.marquee)
                    .font(.system(size: Self.titleSize, weight: .medium))
                Spacer(minLength: 0)
                ControlsRow(isPlaying: s.isPlaying, compact: true)
            }
            ProgressRow(snapshot: s)
                .padding(.top, 4)
        }
    }
}

struct MediumView: View {
    let entry: NowPlayingEntry
    var showTimes = false

    var body: some View {
        let s = entry.snapshot
        return VStack(alignment: .leading, spacing: 0) {
            LikeButton(liked: s.liked)
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    SlidingText(text: s.title, previous: s.previousTitle, changes: s.titleChanges, direction: s.skipDirection, fadesOverflow: true, marquee: entry.marquee)
                        .font(.system(size: SmallView.titleSize, weight: .medium))
                    SlidingText(text: s.artist, previous: s.previousArtist, changes: s.artistChanges, direction: s.skipDirection, delay: 0.05)
                        .font(.subheadline)
                        .opacity(0.8)
                }
                Spacer(minLength: 0)
                ControlsRow(isPlaying: s.isPlaying)
            }
            ProgressRow(snapshot: s, showTimes: showTimes)
                .padding(.top, 6)
        }
    }
}

struct ProgressRow: View {
    let snapshot: NowPlaying
    var showTimes = false

    var body: some View {
        let s = snapshot
        let live = s.isPlaying && s.duration > 0 && s.endDate > .now
        VStack(spacing: 2) {
            // Both variants use the same label-less form and a fixed height so the row doesn't shift between states.
            Group {
                // Timer-driven views animate on their own, so progress costs no widget reloads.
                if live {
                    ProgressView(timerInterval: s.startDate...s.endDate, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                } else {
                    ProgressView(value: min(s.position, s.duration), total: max(s.duration, 1)) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                }
            }
            .labelsHidden()
            .frame(height: 4)

            if showTimes {
                HStack {
                    // Only use a timer view while playing; a paused timer still redraws every frame.
                    if live {
                        Text(timerInterval: s.startDate...s.endDate, countsDown: false)
                    } else {
                        Text(Self.format(s.position))
                    }
                    Spacer()
                    Text(Self.format(s.duration))
                }
                .font(.caption2.monospacedDigit())
                .opacity(0.7)
            }
        }
        .progressViewStyle(.linear)
        .tint(.white)
        .widgetAccentable()
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct ControlsRow: View {
    let isPlaying: Bool
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            if !compact {
                Button(intent: PreviousTrackIntent()) {
                    Image(systemName: "backward.fill")
                }
            }
            Button(intent: PlayPauseIntent()) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: compact ? 30 : 28, height: compact ? 30 : 28)
                    .contentShape(Rectangle())
            }
            if !compact {
                Button(intent: NextTrackIntent()) {
                    Image(systemName: "forward.fill")
                }
            }
        }
        .buttonStyle(.plain)
        .widgetAccentable()
    }
}

/// Saves or removes the track from Liked Songs. Hidden when no account is connected or the state is unknown.
struct LikeButton: View {
    let liked: Bool?

    var body: some View {
        if let liked {
            Button(intent: ToggleLikeIntent()) {
                // Sized by a hidden circle symbol in the play/pause button's font, so the two icons match.
                // The shape's circle fills 20/24 of its frame, hence the slight overhang.
                Image(systemName: "circle")
                    .font(.title2)
                    .hidden()
                    .overlay {
                        LikeIconShape(liked: liked)
                            .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                            .padding(-1)
                    }
                    .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .widgetAccentable()
            // Tucked toward the top-left corner; an offset leaves the rest of the layout where it is.
            .offset(x: -4, y: -4)
        }
    }
}

struct EmptyStateView: View {
    let status: PlayerStatus

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title)
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.caption)
                .opacity(0.7)
                .multilineTextAlignment(.center)
        }
    }

    private var icon: String {
        switch status {
        case .noPermission: "lock.fill"
        case .notRunning: "music.note"
        default: "pause.circle"
        }
    }

    private var message: String {
        switch status {
        case .noPermission: "Needs access"
        case .notRunning: "Spotify isn't open"
        default: "Nothing playing"
        }
    }

    private var detail: String {
        switch status {
        case .noPermission: "Allow Spotify Widget to control Spotify in System Settings"
        case .notRunning: "Click to open Spotify"
        default: "Play something in Spotify"
        }
    }
}

struct BackdropView: View {
    let image: NSImage?

    var body: some View {
        if let image {
            // Overlay on a clear view so the image can't grow the layout past the widget bounds.
            Color.clear.overlay {
                Image(nsImage: image)
                    .resizable()
                    .fullColorInAccentedMode()
                    .aspectRatio(contentMode: .fill)
            }
            .clipped()
        }
    }
}

private extension Image {
    @ViewBuilder
    func fullColorInAccentedMode() -> some View {
        if #available(macOS 15.0, *) {
            widgetAccentedRenderingMode(.fullColor)
        } else {
            self
        }
    }
}
