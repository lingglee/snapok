import AppKit

enum CaptureBorderStyle: String, Codable, CaseIterable {
    case solid, dashed, dotted

    var title: String {
        switch self {
        case .solid: return L("Solid", "实线")
        case .dashed: return L("Dashed", "虚线")
        case .dotted: return L("Dotted", "点线")
        }
    }
}

/// Capture overlays only; these preferences never become image annotations.
struct CaptureAppearance: Codable, Equatable {
    static let key = "capture.appearance"
    static let borderWidthRange = 1...10
    /// sRGB components with alpha: [r, g, b, a]. Older preferences stored only [r, g, b].
    var color = [236.0 / 255, 72.0 / 255, 153.0 / 255, 1]
    var borderStyle: CaptureBorderStyle = .solid
    var borderWidth = 2

    private enum CodingKeys: String, CodingKey { case color, borderStyle, borderWidth }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        color = try values.decodeIfPresent([Double].self, forKey: .color) ?? color
        borderStyle = try values.decodeIfPresent(CaptureBorderStyle.self, forKey: .borderStyle) ?? borderStyle
        borderWidth = try values.decodeIfPresent(Int.self, forKey: .borderWidth) ?? borderWidth
    }

    var alpha: Double { color.count > 3 ? color[3] : 1 }

    var nsColor: NSColor {
        NSColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: alpha)
    }

    /// Selection handles and the magnifier crosshair must stay usable even when the frame is transparent.
    var handleColor: NSColor {
        alpha < 0.15 ? .white : nsColor.withAlphaComponent(max(alpha, 0.6))
    }

    mutating func setColor(_ value: NSColor) {
        guard let rgb = value.usingColorSpace(.sRGB) else { return }
        color = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
    }

    static func load(in defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key),
              var saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        if saved.color.count == 3 { saved.color.append(1) }
        if saved.color.count != 4 || !saved.color.allSatisfy(\.isFinite) {
            saved.color = Self().color
        }
        saved.color = saved.color.map { min(max($0, 0), 1) }
        saved.borderWidth = min(max(saved.borderWidth, Self.borderWidthRange.lowerBound), Self.borderWidthRange.upperBound)
        return saved
    }

    func save(in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    func stroke(_ rect: CGRect, width: CGFloat) {
        let path = NSBezierPath(rect: rect)
        path.lineWidth = width
        switch borderStyle {
        case .solid: break
        case .dashed: path.setLineDash([8, 5], count: 2, phase: 0)
        case .dotted:
            path.lineCapStyle = .round
            path.setLineDash([0, max(4, width * 2.5)], count: 2, phase: 0)
        }
        nsColor.setStroke()
        path.stroke()
    }
}

@MainActor
final class CaptureAppearancePreview: NSView {
    var appearanceSettings = CaptureAppearance() { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 110, height: 34) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        if appearanceSettings.alpha < 1 {
            // Checkerboard hint so a transparent frame is visibly "transparent", not missing.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).addClip()
            NSColor.gray.withAlphaComponent(0.15).setFill()
            let tile: CGFloat = 5
            var y: CGFloat = 0
            while y < bounds.height {
                var x: CGFloat = (Int(y / tile) % 2 == 0) ? 0 : tile
                while x < bounds.width {
                    CGRect(x: x, y: y, width: tile, height: tile).fill()
                    x += tile * 2
                }
                y += tile
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        let rect = bounds.insetBy(dx: 9, dy: 8)
        appearanceSettings.stroke(rect, width: CGFloat(appearanceSettings.borderWidth) / (window?.backingScaleFactor ?? 1))
        appearanceSettings.handleColor.setFill()
        for point in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4).fill()
        }
    }
}
