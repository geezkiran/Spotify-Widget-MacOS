import AppIntents

struct PlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Play or Pause"

    func perform() async throws -> some IntentResult {
        // Flip the state immediately so the widget responds before the host app confirms.
        var s = SharedStore.load()
        if s.hasTrack {
            s.position = s.position(at: .now)
            s.capturedAt = .now
            s.status = s.isPlaying ? .paused : .playing
            SharedStore.save(s)
        }
        PlayerCommand.playPause.post()
        return .result()
    }
}

struct ToggleLikeIntent: AppIntent {
    static var title: LocalizedStringResource = "Save to Liked Songs"

    func perform() async throws -> some IntentResult {
        var s = SharedStore.load()
        if let liked = s.liked {
            s.liked = !liked
            SharedStore.save(s)
        }
        PlayerCommand.toggleLike.post()
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track"

    func perform() async throws -> some IntentResult {
        PlayerCommand.next.post()
        return .result()
    }
}

struct PreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"

    func perform() async throws -> some IntentResult {
        PlayerCommand.previous.post()
        return .result()
    }
}
