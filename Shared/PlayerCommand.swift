import Foundation

/// Commands sent from the widget to the host app over Darwin notifications (allowed from the sandbox).
enum PlayerCommand: String, CaseIterable {
    case playPause, next, previous, toggleLike

    var notificationName: String { "com.kiran.spotifywidget.command.\(rawValue)" }

    init?(notificationName: String) {
        guard let match = Self.allCases.first(where: { $0.notificationName == notificationName }) else { return nil }
        self = match
    }

    func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil, nil, true
        )
    }
}
