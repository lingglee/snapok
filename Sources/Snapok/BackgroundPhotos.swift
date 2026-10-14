import AppKit
import ImageIO

/// Landscape photos bundled as ready-made image backgrounds (Unsplash License; sources in Backgrounds/CREDITS.txt).
@MainActor
enum BackgroundPhotos {
    static let all: [(name: String, title: String)] = [
        ("clouds", L("Above the Clouds", "云海")), ("lake", L("Alpine Lake", "湖光")), ("beach", L("Beach", "海滩")),
        ("dusk", L("Dusk Coast", "晚霞")), ("canyon", L("Canyon", "峡谷")), ("forest", L("Forest", "森林"))
    ]

    private static var thumbnails: [String: NSImage] = [:]

    private static func url(_ name: String) -> URL? {
        Bundle.snapokResources.url(forResource: name, withExtension: "jpg", subdirectory: "Backgrounds")
    }

    static func image(_ name: String) -> NSImage? {
        url(name).flatMap(NSImage.init(contentsOf:))
    }

    static func thumbnail(_ name: String) -> NSImage? {
        if let cached = thumbnails[name] { return cached }
        guard let url = url(name), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 240
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        thumbnails[name] = image
        return image
    }
}
