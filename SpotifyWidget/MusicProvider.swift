import Foundation

/// A local music app the widget can display and control. Spotify today; Apple Music can be added as another conformer.
protocol MusicProvider {
    func snapshot() async -> NowPlaying
    func perform(_ command: PlayerCommand) async
}
