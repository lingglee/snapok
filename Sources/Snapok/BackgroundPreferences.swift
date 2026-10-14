import Foundation

/// Last-used editor defaults, independent of an individual screenshot.
struct BackgroundPreferences: Codable, Equatable {
    static let gradientPresetCount = 6
    struct CustomGradient: Codable, Equatable {
        var start = [0.91, 0.30, 0.58, 1.0]
        var end = [0.16, 0.58, 0.77, 1.0]
        var angle = 35.0
    }
    static let key = "editor.background.preferences"
    var backgroundType = 0
    var gradient = 0
    var horizontalPadding = 120
    var verticalPadding = 120
    var cornerRadius = 16
    var shadow = true
    var borderWidth = 0
    var borderColor = [1.0, 1.0, 1.0, 1.0]
    var backgroundColor = [0.96, 0.90, 0.94, 1.0]
    var customImagePath: String?
    /// A bundled photo (`BackgroundPhotos`) used as the image background; nil means the imported image.
    var backgroundPhoto: String?
    var customGradient: CustomGradient?
    var usesCustomGradient: Bool?
    /// Optional so settings saved before watermarks existed still decode.
    var watermark: Watermark?
    /// For one library item: shown and exported as captured, without the frame (「还原原图」).
    /// Kept with the item only; `save` never makes it the default style.
    var plain: Bool?

    /// User-defined text stamped onto exported images.
    struct Watermark: Codable, Equatable {
        static let positionCount = 11
        static let customPosition = 10
        static let fontSizeRange = 8...400
        static let maxTextLength = 200
        var enabled = false
        var text = ""
        /// Font family name; nil means the system font.
        var fontFamily: String?
        var bold = false
        var fontSize = 32
        var color = [1.0, 1.0, 1.0, 1.0]
        var opacity = 0.6
        /// 0–8: a 3×3 grid read left to right, top to bottom; 9: tiled across the canvas; 10: dragged to `center`.
        var position = 8
        /// For a dragged watermark: its centre as fractions of the canvas, measured from the bottom left.
        var center: [Double]?

        var isVisible: Bool { enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && opacity > 0 }

        func normalized() -> Self {
            var value = self
            value.text = String(text.prefix(Self.maxTextLength))
            if let family = fontFamily, family.isEmpty { value.fontFamily = nil }
            value.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
            value.color = BackgroundPreferences.normalized(color, fallback: Self().color)
            value.opacity = opacity.isFinite ? min(max(opacity, 0), 1) : Self().opacity
            value.position = min(max(position, 0), Self.positionCount - 1)
            value.center = center.flatMap { $0.count == 2 && $0.allSatisfy(\.isFinite) ? $0.map { min(max($0, 0), 1) } : nil }
            return value
        }
    }

    static func load(in defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key),
              var saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        saved.backgroundType = min(max(saved.backgroundType, 0), 4)
        saved.gradient = min(max(saved.gradient, 0), gradientPresetCount - 1)
        saved.horizontalPadding = min(max(saved.horizontalPadding, 0), 600)
        saved.verticalPadding = min(max(saved.verticalPadding, 0), 600)
        saved.cornerRadius = min(max(saved.cornerRadius, 0), 80)
        saved.borderWidth = min(max(saved.borderWidth, 0), 20)
        let fallback = Self()
        saved.backgroundColor = normalized(saved.backgroundColor, fallback: fallback.backgroundColor)
        saved.borderColor = normalized(saved.borderColor, fallback: fallback.borderColor)
        if var gradient = saved.customGradient {
            let fallback = CustomGradient()
            gradient.start = normalized(gradient.start, fallback: fallback.start)
            gradient.end = normalized(gradient.end, fallback: fallback.end)
            gradient.angle = gradient.angle.isFinite ? min(max(gradient.angle, 0), 360) : fallback.angle
            saved.customGradient = gradient
        }
        saved.watermark = saved.watermark?.normalized()
        return saved
    }

    func save(in defaults: UserDefaults = .standard) {
        var value = self
        value.plain = nil
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.key) }
    }

    fileprivate static func normalized(_ color: [Double], fallback: [Double]) -> [Double] {
        guard color.count == 4, color.allSatisfy(\.isFinite) else { return fallback }
        return color.map { min(max($0, 0), 1) }
    }
}
