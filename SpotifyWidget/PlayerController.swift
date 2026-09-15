import AppKit
import ServiceManagement
import WidgetKit

/// Watches the music provider and publishes snapshots to the widget.
@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var snapshot: NowPlaying = .notRunning

    let account = SpotifyAccount()
    private let provider: MusicProvider = SpotifyProvider()
    private let artwork = ArtworkCache()
    private var commandListener: CommandListener?
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var lastPublished: NowPlaying?
    /// Liked state per track URI. Re-fetched after a minute so likes made in Spotify itself show up.
    private var likedCache: [String: (liked: Bool, fetchedAt: Date)] = [:]
    /// The last skip requested from the widget. A track change shortly after it is attributed to that skip.
    private var pendingSkip: (direction: SkipDirection, at: Date)?

    init() {
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == SpotifyProvider.bundleID else { return }
                Task { @MainActor in await self?.refresh() }
            })
        }

        commandListener = CommandListener { [weak self] command in
            Task { @MainActor in await self?.perform(command) }
        }

        // Catches seeks and anything Spotify doesn't notify about. Cheap: only real changes reload the widget.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }

        account.onChange = { [weak self] in
            Task { @MainActor in
                self?.lastPublished = nil
                await self?.refresh()
            }
        }

        Task { await refresh() }
    }

    func refresh() async {
        var next = await provider.snapshot()
        if next.hasTrack, let remote = next.artworkRemoteURL {
            next.artworkFile = await artwork.localFile(trackID: next.trackID, remoteURL: remote)
        }
        next.liked = await likedState(for: next)
        next.skipDirection = skipDirection(for: next)
        let last = lastPublished ?? snapshot
        let titleChanged = next.hasTrack && last.hasTrack && last.title != next.title
        next.previousTitle = titleChanged ? last.title : last.previousTitle
        next.titleChanges = last.titleChanges + (titleChanged ? 1 : 0)
        let artistChanged = next.hasTrack && last.hasTrack && last.artist != next.artist
        next.previousArtist = artistChanged ? last.artist : last.previousArtist
        next.artistChanges = last.artistChanges + (artistChanged ? 1 : 0)
        snapshot = next
        publishIfNeeded(next)
    }

    func perform(_ command: PlayerCommand) async {
        switch command {
        case .playPause, .next, .previous:
            // Set before performing: Spotify's change notification can trigger a refresh while we wait.
            if command == .next { pendingSkip = (.forward, .now) }
            if command == .previous { pendingSkip = (.backward, .now) }
            await provider.perform(command)
            try? await Task.sleep(for: .milliseconds(300))
        case .toggleLike:
            await toggleLike()
        }
        // The widget may have written an optimistic state; force the real one to be written back.
        lastPublished = nil
        await refresh()
    }

    /// A new track takes the direction of a recent skip, or forward if it just played on; the same track keeps its direction.
    private func skipDirection(for s: NowPlaying) -> SkipDirection? {
        let last = lastPublished ?? snapshot
        if last.trackID == s.trackID { return last.skipDirection }
        defer { pendingSkip = nil }
        if let pending = pendingSkip, pending.at.timeIntervalSinceNow > -3 { return pending.direction }
        return .forward
    }

    private func likedState(for s: NowPlaying) async -> Bool? {
        guard account.isConnected, s.hasTrack, Self.isSavable(s.trackID) else { return nil }
        let uri = s.trackID
        if let cached = likedCache[uri], cached.fetchedAt.timeIntervalSinceNow > -60 {
            return cached.liked
        }
        guard let liked = await account.isLiked(uri) else { return likedCache[uri]?.liked }
        likedCache[uri] = (liked, .now)
        return liked
    }

    private func toggleLike() async {
        let s = snapshot
        guard s.hasTrack, Self.isSavable(s.trackID),
              let current = likedCache[s.trackID]?.liked ?? s.liked
        else { return }
        if await account.setLiked(s.trackID, !current) {
            likedCache[s.trackID] = (!current, .now)
        }
    }

    /// Local files have `spotify:local:` URIs, which the Web API can't save.
    private static func isSavable(_ uri: String) -> Bool {
        uri.hasPrefix("spotify:track:")
    }

    /// Returns whether the login item is enabled after the change.
    func setOpenAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Open at Login change failed: \(error)")
        }
        return SMAppService.mainApp.status == .enabled
    }

    private func publishIfNeeded(_ next: NowPlaying) {
        if let last = lastPublished, !Self.isMeaningfulChange(from: last, to: next) { return }
        lastPublished = next
        SharedStore.save(next)
        WidgetCenter.shared.reloadTimelines(ofKind: AppGroup.widgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: AppGroup.minimalWidgetKind)
    }

    private static func isMeaningfulChange(from a: NowPlaying, to b: NowPlaying) -> Bool {
        let now = Date.now
        return a.status != b.status
            || a.trackID != b.trackID
            || a.title != b.title
            || a.artworkFile != b.artworkFile
            || a.shuffle != b.shuffle
            || a.repeating != b.repeating
            || a.liked != b.liked
            || abs(a.position(at: now) - b.position(at: now)) > 2
    }
}
