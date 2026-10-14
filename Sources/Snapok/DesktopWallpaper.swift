import AppKit
import ScreenCaptureKit

/// The desktop wallpaper as an image, for the "Desktop Wallpaper" background.
/// Dynamic, Aerial, and Photos wallpapers have no still image file (macOS reports a placeholder or a video), so the
/// wallpaper is captured from the Dock's wallpaper window — exactly what the desktop shows. The file is the fallback,
/// for when Screen Recording access is missing.
@MainActor
enum DesktopWallpaper {
    private static var captured: [CGDirectDisplayID: NSImage] = [:]

    /// The best image available right away: the last capture for this screen, else the wallpaper file.
    static func cached(for screen: NSScreen?) -> NSImage? {
        guard let screen = screen ?? NSScreen.main else { return nil }
        if let id = displayID(screen), let image = captured[id] { return image }
        return NSWorkspace.shared.desktopImageURL(for: screen).flatMap(NSImage.init(contentsOf:))
    }

    /// Captures the wallpaper as shown on `screen` and remembers it; nil without Screen Recording access.
    static func capture(for screen: NSScreen?) async -> NSImage? {
        guard let screen = screen ?? NSScreen.main, let id = displayID(screen), CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == id }),
                  let window = wallpaperWindow(in: content.windows, covering: display.frame) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
            configuration.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
            configuration.showsCursor = false
            configuration.captureResolution = .best
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let image = NSImage(cgImage: cgImage, size: screen.frame.size)
            captured[id] = image
            return image
        } catch {
            log("wallpaper capture failed", error: error)
            return nil
        }
    }

    /// The Dock draws each display's wallpaper in a "Wallpaper-…" window below the desktop icons.
    private static func wallpaperWindow(in windows: [SCWindow], covering frame: CGRect) -> SCWindow? {
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let candidates = windows.filter {
            $0.windowLayer < iconLevel && abs($0.frame.width - frame.width) < 2 && abs($0.frame.height - frame.height) < 2
                && abs($0.frame.minX - frame.minX) < 2 && abs($0.frame.minY - frame.minY) < 2
        }
        return candidates.first { $0.owningApplication?.bundleIdentifier == "com.apple.dock" && ($0.title ?? "").hasPrefix("Wallpaper") }
            ?? candidates.first { $0.owningApplication?.bundleIdentifier == "com.apple.dock" }
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
