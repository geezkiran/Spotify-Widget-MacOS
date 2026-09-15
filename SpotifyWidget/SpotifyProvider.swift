import AppKit
import os

final class SpotifyProvider: MusicProvider {
    static let bundleID = "com.spotify.client"
    private static let log = Logger(subsystem: "com.kiran.spotifywidget", category: "spotify")

    private let queue = DispatchQueue(label: "com.kiran.spotifywidget.applescript")

    private static let snapshotSource = """
    tell application id "com.spotify.client"
        set playerState to player state as string
        if playerState is "stopped" then return {playerState}
        set t to current track
        return {playerState, id of t, name of t, artist of t, album of t, duration of t, player position, artwork url of t, shuffling, repeating}
    end tell
    """

    private enum ScriptResult {
        case success(NSAppleEventDescriptor)
        case failure(code: Int)
    }

    /// `tell application` launches the target, so every script is gated on this.
    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    func snapshot() async -> NowPlaying {
        guard isRunning else { return .notRunning }

        switch await run(Self.snapshotSource) {
        case .failure(code: -1743):
            return NowPlaying(status: .noPermission)
        case .failure(let code):
            Self.log.error("Spotify snapshot script failed: \(code, privacy: .public)")
            // -600 / -609: Spotify quit between the running check and the script.
            return isRunning ? NowPlaying(status: .stopped) : .notRunning
        case .success(let list):
            let state = list.atIndex(1)?.stringValue ?? "stopped"
            guard state != "stopped", list.numberOfItems >= 10 else { return NowPlaying(status: .stopped) }
            return NowPlaying(
                status: state == "playing" ? .playing : .paused,
                trackID: list.atIndex(2)?.stringValue ?? "",
                title: list.atIndex(3)?.stringValue ?? "",
                artist: list.atIndex(4)?.stringValue ?? "",
                album: list.atIndex(5)?.stringValue ?? "",
                duration: Double(list.atIndex(6)?.int32Value ?? 0) / 1000, // Spotify reports ms
                position: list.atIndex(7)?.doubleValue ?? 0,
                capturedAt: .now,
                artworkRemoteURL: list.atIndex(8)?.stringValue,
                shuffle: list.atIndex(9)?.booleanValue ?? false,
                repeating: list.atIndex(10)?.booleanValue ?? false
            )
        }
    }

    func perform(_ command: PlayerCommand) async {
        guard isRunning else { return }
        let verb: String
        switch command {
        case .playPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        case .toggleLike: return // Web API only; see SpotifyAccount.
        }
        _ = await run("tell application id \"\(Self.bundleID)\" to \(verb)")
    }

    private func run(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                if let result = NSAppleScript(source: source)?.executeAndReturnError(&error) {
                    continuation.resume(returning: .success(result))
                } else {
                    let code = error?[NSAppleScript.errorNumber] as? Int ?? 0
                    continuation.resume(returning: .failure(code: code))
                }
            }
        }
    }
}
