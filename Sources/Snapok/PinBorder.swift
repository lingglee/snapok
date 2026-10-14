import AppKit

/// The outline drawn around pinned images; a clear color or zero width means none.
struct PinBorder: Codable, Equatable {
    static let key = "pin.border"
    static let didChange = Notification.Name("PinBorder.didChange")
    static let widthRange = 0...8

    /// sRGB components with alpha: [r, g, b, a].
    var color = [236.0 / 255, 72.0 / 255, 153.0 / 255, 0.8]
    var width = 1

    var nsColor: NSColor {
        guard color.count == 4 else { return .clear }
        return NSColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: color[3])
    }

    var isVisible: Bool { width > 0 && color.count == 4 && color[3] > 0 }

    mutating func setColor(_ value: NSColor) {
        let srgb = value.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        color = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
    }

    static func load(in defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key), var saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        if saved.color.count != 4 || !saved.color.allSatisfy(\.isFinite) { saved.color = Self().color }
        saved.color = saved.color.map { min(max($0, 0), 1) }
        saved.width = min(max(saved.width, widthRange.lowerBound), widthRange.upperBound)
        return saved
    }

    func save(in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
