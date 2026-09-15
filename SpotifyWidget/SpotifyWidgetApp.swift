import ServiceManagement
import SwiftUI
import WidgetKit

@main
struct SpotifyWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(delegate.controller)
        } label: {
            MenuBarIcon(controller: delegate.controller)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = PlayerController()
}

struct MenuBarIcon: View {
    @ObservedObject var controller: PlayerController

    var body: some View {
        Image(systemName: controller.snapshot.isPlaying ? "music.note" : "music.note.list")
    }
}

struct MenuContent: View {
    @EnvironmentObject private var controller: PlayerController
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Text(statusLine)
        if controller.snapshot.status == .noPermission {
            Button("Grant Automation Access…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            }
        }

        Divider()

        if controller.snapshot.hasTrack {
            Button(controller.snapshot.isPlaying ? "Pause" : "Play") { Task { await controller.perform(.playPause) } }
            Button("Next Track") { Task { await controller.perform(.next) } }
            Button("Previous Track") { Task { await controller.perform(.previous) } }
            Divider()
        }

        AccountMenu(account: controller.account, snapshot: controller.snapshot) { command in
            Task { await controller.perform(command) }
        }

        Button("Reload Widget") { WidgetCenter.shared.reloadAllTimelines() }
        Toggle("Open at Login", isOn: $openAtLogin)
            .onChange(of: openAtLogin) { _, enabled in
                openAtLogin = controller.setOpenAtLogin(enabled)
            }

        Divider()

        Button("Quit Spotify Widget") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        let s = controller.snapshot
        switch s.status {
        case .playing, .paused: return "\(s.isPlaying ? "▶" : "❚❚") \(s.title) — \(s.artist)"
        case .stopped: return "Nothing playing"
        case .notRunning: return "Spotify isn't running"
        case .noPermission: return "Needs Automation access to Spotify"
        }
    }
}

/// Spotify account items: sign-in and Liked Songs.
struct AccountMenu: View {
    @ObservedObject var account: SpotifyAccount
    let snapshot: NowPlaying
    let perform: (PlayerCommand) -> Void

    var body: some View {
        if account.isConnected {
            if let liked = snapshot.liked, snapshot.hasTrack {
                Button(liked ? "Remove from Liked Songs" : "Save to Liked Songs") { perform(.toggleLike) }
            }
            Button("Disconnect Spotify Account") { account.disconnect() }
        } else {
            Button("Connect Spotify Account…") { account.connect() }
        }
        if let error = account.lastError {
            Text(error)
        }
        Divider()
    }
}
