import AppKit

@MainActor
enum EditorBackground {
    case gradient(Int)
    case customGradient(start: NSColor, end: NSColor, angle: CGFloat)
    case color(NSColor)
    case image(NSImage)

    static let palettes: [[NSColor]] = [
        [NSColor(srgbRed: 0.25, green: 0.12, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.91, green: 0.30, blue: 0.58, alpha: 1), NSColor(srgbRed: 1, green: 0.75, blue: 0.60, alpha: 1)],
        [NSColor(srgbRed: 0.05, green: 0.20, blue: 0.44, alpha: 1), NSColor(srgbRed: 0.16, green: 0.58, blue: 0.77, alpha: 1), NSColor(srgbRed: 0.62, green: 0.88, blue: 0.87, alpha: 1)],
        [NSColor(srgbRed: 0.15, green: 0.12, blue: 0.38, alpha: 1), NSColor(srgbRed: 0.47, green: 0.36, blue: 0.77, alpha: 1), NSColor(srgbRed: 0.91, green: 0.71, blue: 0.86, alpha: 1)],
        [NSColor(srgbRed: 0.98, green: 0.32, blue: 0.36, alpha: 1), NSColor(srgbRed: 1, green: 0.78, blue: 0.38, alpha: 1)],
        [NSColor(srgbRed: 0.04, green: 0.46, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.64, green: 0.91, blue: 0.74, alpha: 1)],
        [NSColor(srgbRed: 0.96, green: 0.56, blue: 0.50, alpha: 1), NSColor(srgbRed: 1, green: 0.90, blue: 0.74, alpha: 1)]
    ]

    func draw(in rect: CGRect) {
        switch self {
        case .gradient(let index):
            NSGradient(colors: Self.palettes[min(max(index, 0), Self.palettes.count - 1)])?.draw(in: rect, angle: 35)
        case .customGradient(let start, let end, let angle):
            NSGradient(starting: start, ending: end)?.draw(in: rect, angle: angle)
        case .color(let color):
            color.setFill()
            rect.fill()
        case .image(let image):
            guard image.size.width > 0, image.size.height > 0 else { return }
            let scale = max(rect.width / image.size.width, rect.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

struct BackgroundLayout {
    var horizontalPadding: CGFloat = 120
    var verticalPadding: CGFloat = 120
    var cornerRadius: CGFloat = 16
    var shadow = true
    var borderWidth: CGFloat = 0
    var borderColor: NSColor = .white
    var watermark: BackgroundWatermark?

    /// The screenshot as captured: no padding, corners, shadow, border, or watermark.
    static let plain = BackgroundLayout(horizontalPadding: 0, verticalPadding: 0, cornerRadius: 0, shadow: false, borderWidth: 0)

    func canvasSize(for source: CGSize) -> CGSize {
        CGSize(width: source.width + horizontalPadding * 2, height: source.height + verticalPadding * 2)
    }
}

/// One renderer serves both the scaled live preview and the full-resolution PNG.
@MainActor
enum BackgroundRenderer {
    static func draw(source: CGImage, background: EditorBackground, layout: BackgroundLayout, overlay: ((CGContext) -> Void)? = nil) {
        let sourceSize = CGSize(width: source.width, height: source.height)
        let canvas = CGRect(origin: .zero, size: layout.canvasSize(for: sourceSize))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: canvas).addClip()
        background.draw(in: canvas)
        let photo = CGRect(x: layout.horizontalPadding, y: layout.verticalPadding, width: sourceSize.width, height: sourceSize.height)
        let radius = min(layout.cornerRadius, min(photo.width, photo.height) / 2)
        let outline = NSBezierPath(roundedRect: photo, xRadius: radius, yRadius: radius)
        if layout.shadow {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            // Sized for a ~1000 px screenshot and scaled with its shorter side, so a small crop isn't swamped and a
            // full Retina screen still shows it.
            let scale = min(max(min(sourceSize.width, sourceSize.height) / 1000, 0.5), 3)
            shadow.shadowBlurRadius = 32 * scale
            shadow.shadowOffset = CGSize(width: 0, height: -12 * scale)
            shadow.set()
            NSColor.black.setFill()
            outline.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        if let context = NSGraphicsContext.current?.cgContext {
            context.draw(source, in: photo)
            context.saveGState()
            context.translateBy(x: photo.minX, y: photo.minY)
            overlay?(context)
            context.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        // Draw inside the image bounds so even a zero-padding export keeps the
        // entire border. The same renderer serves preview and full-size output.
        let width = min(max(layout.borderWidth, 0), min(photo.width, photo.height) / 2)
        if width > 0 {
            let inset = width / 2
            let border = NSBezierPath(roundedRect: photo.insetBy(dx: inset, dy: inset),
                                      xRadius: max(radius - inset, 0), yRadius: max(radius - inset, 0))
            border.lineWidth = width
            layout.borderColor.setStroke()
            border.stroke()
        }
        layout.watermark?.draw(in: canvas, photo: photo)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func render(source: CGImage, background: EditorBackground, layout: BackgroundLayout, overlay: ((CGContext) -> Void)? = nil) -> NSImage? {
        let size = layout.canvasSize(for: CGSize(width: source.width, height: source.height))
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 16384, size.height <= 16384, size.width * size.height <= 80_000_000,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(source: source, background: background, layout: layout, overlay: overlay)
        NSGraphicsContext.restoreGraphicsState()
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: size)
    }
}

/// Text stamped on the finished canvas. Sizes are in canvas (source) pixels, so the
/// zoomed preview and the full-resolution export always match.
@MainActor
struct BackgroundWatermark {
    enum Position: Int, CaseIterable {
        case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight, tiled, custom
    }

    var text: String
    var fontFamily: String?
    var bold = false
    var fontSize: CGFloat = 32
    var color: NSColor = .white
    var opacity: CGFloat = 0.6
    var position: Position = .bottomRight
    /// Where a `.custom` watermark is centred, as fractions of the canvas from the bottom left.
    var center: CGPoint?

    /// nil when the watermark is off or has nothing to draw.
    init?(preferences: BackgroundPreferences.Watermark?) {
        guard let value = preferences?.normalized(), value.isVisible else { return nil }
        text = value.text
        fontFamily = value.fontFamily
        bold = value.bold
        fontSize = CGFloat(value.fontSize)
        color = NSColor(srgbRed: value.color[0], green: value.color[1], blue: value.color[2], alpha: value.color[3])
        opacity = CGFloat(value.opacity)
        position = Position(rawValue: value.position) ?? .bottomRight
        center = value.center.map { CGPoint(x: $0[0], y: $0[1]) }
    }

    init(text: String, fontFamily: String? = nil, bold: Bool = false, fontSize: CGFloat = 32,
         color: NSColor = .white, opacity: CGFloat = 0.6, position: Position = .bottomRight) {
        self.text = text
        self.fontFamily = fontFamily
        self.bold = bold
        self.fontSize = fontSize
        self.color = color
        self.opacity = opacity
        self.position = position
    }

    static func font(family: String?, bold: Bool, size: CGFloat) -> NSFont {
        if let family, !family.isEmpty,
           let font = NSFontManager.shared.font(withFamily: family, traits: bold ? .boldFontMask : [], weight: bold ? 9 : 5, size: size) {
            return font
        }
        return .systemFont(ofSize: size, weight: bold ? .bold : .medium)
    }

    var attributes: [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = max(fontSize / 12, 1)
        shadow.shadowOffset = CGSize(width: 0, height: -max(fontSize / 24, 0.5))
        return [.font: Self.font(family: fontFamily, bold: bold, size: fontSize),
                .foregroundColor: color.withAlphaComponent(color.alphaComponent * opacity),
                .shadow: shadow]
    }

    /// Where the text box lands. Edge positions sit centred in the padding band when it is
    /// tall enough, otherwise inset from the canvas edge.
    func frame(textSize: CGSize, canvas: CGRect, photo: CGRect) -> CGRect {
        if position == .custom {
            // Kept whole on the canvas whatever the padding becomes.
            let center = center ?? CGPoint(x: 0.5, y: 0.5)
            let x = min(max(canvas.minX + center.x * canvas.width - textSize.width / 2, canvas.minX), canvas.maxX - textSize.width)
            let y = min(max(canvas.minY + center.y * canvas.height - textSize.height / 2, canvas.minY), canvas.maxY - textSize.height)
            return CGRect(origin: CGPoint(x: x, y: y), size: textSize)
        }
        let margin = max(fontSize * 0.6, 8)
        let column = position.rawValue % 3, row = position.rawValue / 3
        let x: CGFloat
        switch column {
        case 0: x = canvas.minX + margin
        case 2: x = canvas.maxX - margin - textSize.width
        default: x = canvas.midX - textSize.width / 2
        }
        let topBand = canvas.maxY - photo.maxY, bottomBand = photo.minY - canvas.minY
        let y: CGFloat
        switch row {
        case 0:
            y = topBand >= textSize.height + 8 ? photo.maxY + (topBand - textSize.height) / 2 : canvas.maxY - margin - textSize.height
        case 2:
            y = bottomBand >= textSize.height + 8 ? canvas.minY + (bottomBand - textSize.height) / 2 : canvas.minY + margin
        default: y = canvas.midY - textSize.height / 2
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: textSize)
    }

    private var string: NSAttributedString? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, opacity > 0, fontSize > 0 else { return nil }
        let string = NSAttributedString(string: trimmed, attributes: attributes)
        return string.size().width > 0 && string.size().height > 0 ? string : nil
    }

    /// The single text box on the canvas; nil when tiled or empty.
    func textFrame(canvas: CGRect, photo: CGRect) -> CGRect? {
        guard position != .tiled, let string else { return nil }
        return frame(textSize: string.size(), canvas: canvas, photo: photo)
    }

    func draw(in canvas: CGRect, photo: CGRect) {
        guard let string else { return }
        let size = string.size()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: canvas).addClip()
        if position == .tiled {
            drawTiled(string, size: size, canvas: canvas)
        } else {
            string.draw(at: frame(textSize: size, canvas: canvas, photo: photo).origin)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawTiled(_ string: NSAttributedString, size: CGSize, canvas: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let stepX = size.width + max(fontSize * 3, 40), stepY = size.height + max(fontSize * 3, 40)
        let diagonal = hypot(canvas.width, canvas.height)
        // Cap the work for tiny fonts on huge canvases.
        guard (diagonal / stepX) * (diagonal / stepY) < 20_000 else { return }
        context.saveGState()
        context.translateBy(x: canvas.midX, y: canvas.midY)
        context.rotate(by: .pi / 6)
        var row = 0
        var y = -diagonal / 2
        while y < diagonal / 2 {
            // Stagger alternate rows for an even pattern.
            var x = -diagonal / 2 - (row.isMultiple(of: 2) ? 0 : stepX / 2)
            while x < diagonal / 2 {
                string.draw(at: CGPoint(x: x, y: y))
                x += stepX
            }
            y += stepY
            row += 1
        }
        context.restoreGState()
    }
}
