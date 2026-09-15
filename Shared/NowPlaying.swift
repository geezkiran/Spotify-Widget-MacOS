import Foundation

enum PlayerStatus: String, Codable {
    case playing, paused, stopped, notRunning, noPermission
}

/// Which way the player moved to reach the current track, so the widget can animate the change to match.
enum SkipDirection: String, Codable {
    case forward, backward
}

struct NowPlaying: Codable, Equatable {
    var status: PlayerStatus
    var trackID: String = ""
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    /// Seconds.
    var duration: TimeInterval = 0
    /// Seconds, as of `capturedAt`.
    var position: TimeInterval = 0
    var capturedAt: Date = .now
    var artworkRemoteURL: String?
    /// File name inside the App Group container.
    var artworkFile: String?
    var shuffle = false
    var repeating = false
    /// Whether the track is in Liked Songs. Nil when no account is connected, the state is unknown,
    /// or the track can't be saved (local files); the widget hides the heart then.
    var liked: Bool?
    /// How the current track was reached. Nil (treated as forward) for older snapshots.
    var skipDirection: SkipDirection?
    /// The title and artist before they last changed, so the widget can animate them out in the current skip direction.
    var previousTitle: String?
    var previousArtist: String?
    /// How many times the title and artist have changed. The widget alternates text slots on each change.
    var titleChanges = 0
    var artistChanges = 0

    static let notRunning = NowPlaying(status: .notRunning)
    static let placeholder = NowPlaying(
        status: .paused, trackID: "placeholder", title: "Song Title",
        artist: "Artist", album: "Album", duration: 200, position: 70
    )

    var isPlaying: Bool { status == .playing }
    var hasTrack: Bool { (status == .playing || status == .paused) && !trackID.isEmpty }

    /// Wall-clock time the track would have started, so timer-based views can show progress without reloads.
    var startDate: Date { capturedAt.addingTimeInterval(-position) }
    var endDate: Date { startDate.addingTimeInterval(duration) }

    func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return position }
        return min(duration, max(0, date.timeIntervalSince(startDate)))
    }
}
