import AppKit
import CoreImage

/// How a mosaic annotation hides what is underneath.
/// `brush` follows the pointer like a marker; the other styles cover a dragged rectangle.
/// `eraseBox` belongs to the Erase tool: it fills the box with the background around it, so the content disappears.
enum MosaicStyle: String, CaseIterable, Codable, Sendable {
    case pixelBox, blurBox, frostedBox, solidBox, brush, eraseBox

    /// The styles offered by the mosaic tool; erasing has its own tool.
    static let mosaicStyles = allCases.filter { $0 != .eraseBox }

    var title: String {
        switch self {
        case .pixelBox: return L("Box · Pixelate", "框选 · 像素马赛克")
        case .blurBox: return L("Box · Blur", "框选 · 高斯模糊")
        case .frostedBox: return L("Box · Frosted Glass", "框选 · 毛玻璃")
        case .solidBox: return L("Box · Solid Color", "框选 · 色块遮挡")
        case .brush: return L("Brush · Pixelate", "涂抹 · 像素马赛克")
        case .eraseBox: return L("Erase", "擦除")
        }
    }

    /// Box styles are drawn by dragging out a rectangle instead of painting a stroke.
    var isBox: Bool { self != .brush }

    /// Pixel block edge, in image points, for each size level.
    nonisolated static func blockSize(level: Int) -> CGFloat {
        [8, 13, 20][min(max(level, 0), 2)]
    }

    /// Gaussian blur radius (sigma), in image points, for each size level.
    nonisolated static func blurRadius(_ style: MosaicStyle, level: Int) -> CGFloat {
        let level = min(max(level, 0), 2)
        return style == .frostedBox ? [10, 16, 24][level] : [5, 9, 15][level]
    }

    /// The style picked last time, so the choice survives between captures.
    static var current: MosaicStyle {
        get {
            let saved = UserDefaults.standard.string(forKey: "editor.mosaicStyle").flatMap(MosaicStyle.init(rawValue:))
            return saved.flatMap { mosaicStyles.contains($0) ? $0 : nil } ?? .pixelBox
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "editor.mosaicStyle") }
    }
}

extension Annotation {
    /// Older annotations (and automatic redaction strokes) carry no style and stay brush strokes.
    var effectiveMosaicStyle: MosaicStyle { mosaicStyle ?? .brush }
    var isBoxMosaic: Bool { kind == .mosaic && effectiveMosaicStyle.isBox }
    /// A mosaic whose style the mosaic tool can change; erase boxes keep theirs.
    var isStylableMosaic: Bool { kind == .mosaic && effectiveMosaicStyle != .eraseBox }

    /// Switches a selected mosaic to another style, keeping the area it covers.
    /// A brush stroke becomes a box over its bounds; a box becomes a zigzag brush stroke over the box.
    @MainActor
    mutating func restyleMosaic(_ style: MosaicStyle) {
        guard kind == .mosaic, style != effectiveMosaicStyle else { return }
        if !style.isBox {
            let stroke = SensitiveDetector.mosaic(covering: rect.insetBy(dx: 3, dy: 3))
            points = stroke.points
            rect = stroke.rect
            sizeLevel = stroke.sizeLevel
        } else if !effectiveMosaicStyle.isBox {
            points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)]
        }
        mosaicStyle = style
    }
}

/// Full-size filtered copies of the screenshot, shared by the capture overlay and the editor.
/// Filtering the whole image once keeps dragging smooth and makes boxes that touch blend seamlessly.
@MainActor
enum MosaicCache {
    private static var sourceID: ObjectIdentifier?
    private static var images: [String: NSImage] = [:]
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// The classic brush mosaic (fixed 10 pt blocks, unchanged from earlier versions).
    static func pixelated(for source: NSImage) -> NSImage? {
        filtered(source, key: "brush") { $0.pixelated(blockSize: 10) }
    }

    /// The filtered image used by a mosaic annotation, or nil for solid boxes (they need no source).
    static func image(for annotation: Annotation, source: NSImage) -> NSImage? {
        let style = annotation.effectiveMosaicStyle
        let level = min(max(annotation.sizeLevel, 0), Style.sizeLevels - 1)
        switch style {
        case .brush:
            return pixelated(for: source)
        case .pixelBox:
            let block = MosaicStyle.blockSize(level: level)
            return filtered(source, key: "pixel-\(level)") { $0.pixelated(blockSize: block) }
        case .blurBox, .frostedBox:
            let radius = MosaicStyle.blurRadius(style, level: level)
            return filtered(source, key: "blur-\(radius)") { blurred($0, radius: radius) }
        case .solidBox, .eraseBox:
            return nil
        }
    }

    static func clear() {
        sourceID = nil
        images = [:]
        eraseColors = [:]
    }

    private static var eraseColors: [String: NSColor] = [:]

    /// The fill for an erase box: the median color of a thin ring just outside it.
    /// `ring` crops the screenshot to the box plus a margin and says how many pixels wide that margin is;
    /// it runs once per box and source.
    static func eraseColor(for rect: CGRect, source: NSImage, ring: () -> (image: CGImage, edge: Int)?) -> NSColor {
        if sourceID != ObjectIdentifier(source) {
            sourceID = ObjectIdentifier(source)
            images = [:]
            eraseColors = [:]
        }
        let key = "\(rect.origin.x),\(rect.origin.y),\(rect.width),\(rect.height)"
        if let color = eraseColors[key] { return color }
        let color = ring().flatMap { borderColor(of: $0.image, edge: max(1, $0.edge)) } ?? .white
        if eraseColors.count > 500 { eraseColors = [:] }
        eraseColors[key] = color
        return color
    }

    /// The median color of the outer `edge` pixels of an image.
    nonisolated static func borderColor(of image: CGImage, edge: Int) -> NSColor? {
        let width = image.width, height = image.height
        guard width > edge * 2, height > edge * 2,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var reds: [UInt8] = [], greens: [UInt8] = [], blues: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width where x < edge || y < edge || x >= width - edge || y >= height - edge {
                let i = (y * width + x) * 4
                reds.append(pixels[i]); greens.append(pixels[i + 1]); blues.append(pixels[i + 2])
            }
        }
        guard !reds.isEmpty else { return nil }
        func median(_ values: [UInt8]) -> CGFloat { CGFloat(values.sorted()[values.count / 2]) / 255 }
        return NSColor(srgbRed: median(reds), green: median(greens), blue: median(blues), alpha: 1)
    }

    private static func filtered(_ source: NSImage, key: String, make: (NSImage) -> NSImage?) -> NSImage? {
        if sourceID != ObjectIdentifier(source) {
            sourceID = ObjectIdentifier(source)
            images = [:]
        }
        if let image = images[key] { return image }
        let image = make(source)
        images[key] = image
        return image
    }

    /// Blurs with clamped edges so the border of the screenshot does not fade to transparent.
    static func blurred(_ source: NSImage, radius: CGFloat) -> NSImage? {
        guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil), source.size.width > 0 else { return nil }
        let scale = CGFloat(cgImage.width) / source.size.width
        let input = CIImage(cgImage: cgImage)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: Double(radius * scale)).cropped(to: input.extent)
        guard let result = context.createCGImage(output, from: input.extent, format: .RGBA8,
                                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return NSImage(cgImage: result, size: source.size)
    }

    /// Corner radius of a box mosaic: crisp for pixel blocks, softly rounded for the others.
    static func cornerRadius(for annotation: Annotation) -> CGFloat {
        // Erasing stays square so no original pixels peek out of the corners.
        [.pixelBox, .eraseBox].contains(annotation.effectiveMosaicStyle) ? 0 : min(6, min(annotation.rect.width, annotation.rect.height) / 4)
    }
}
