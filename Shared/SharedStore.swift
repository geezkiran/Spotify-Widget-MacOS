import Foundation

/// Snapshot + artwork files shared between the host app and the widget extension.
enum SharedStore {
    private static var snapshotURL: URL { AppGroup.containerURL.appendingPathComponent("snapshot.json") }

    static func fileURL(_ name: String) -> URL {
        AppGroup.containerURL.appendingPathComponent(name)
    }

    static func load() -> NowPlaying {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(NowPlaying.self, from: data)
        else { return .notRunning }
        return snapshot
    }

    static func save(_ snapshot: NowPlaying) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }
}
