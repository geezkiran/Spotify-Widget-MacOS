import AppKit
import ImageIO

/// Downloads album art, shrinks it to widget-safe size, and keeps only the current track's file.
actor ArtworkCache {
    private var current: (trackID: String, file: String)?

    func localFile(trackID: String, remoteURL: String) async -> String? {
        if let current, current.trackID == trackID { return current.file }

        guard let url = URL(string: remoteURL),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let jpeg = Self.downscaledJPEG(data, maxPixels: 640)
        else { return nil }

        let name = "artwork-\(trackID.replacingOccurrences(of: ":", with: "_")).jpg"
        do {
            try jpeg.write(to: SharedStore.fileURL(name), options: .atomic)
        } catch {
            return nil
        }

        if let old = current, old.file != name {
            try? FileManager.default.removeItem(at: SharedStore.fileURL(old.file))
        }
        current = (trackID, name)
        return name
    }

    private static func downscaledJPEG(_ data: Data, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
