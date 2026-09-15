import Foundation

/// Receives `PlayerCommand`s posted by the widget's App Intents.
final class CommandListener {
    private let handler: (PlayerCommand) -> Void

    init(handler: @escaping (PlayerCommand) -> Void) {
        self.handler = handler
        let observer = Unmanaged.passUnretained(self).toOpaque()
        for command in PlayerCommand.allCases {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                observer,
                { _, observer, name, _, _ in
                    guard let observer, let name,
                          let command = PlayerCommand(notificationName: name.rawValue as String)
                    else { return }
                    Unmanaged<CommandListener>.fromOpaque(observer).takeUnretainedValue().handler(command)
                },
                command.notificationName as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
}
