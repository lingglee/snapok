import AppKit
import CoreImage

/// How a mosaic annotation hides what is underneath.
/// `brush` follows the pointer like a marker; the other styles cover a dragged rectangle.
enum MosaicStyle: String, CaseIterable, Codable, Sendable {
    case pixelBox, blurBox, frostedBox, solidBox, brush

    var title: String {
        switch self {
        case .pixelBox: return L("Box · Pixelate", "框选 · 像素马赛克")
        case .blurBox: return L("Box · Blur", "框选 · 高斯模糊")
        case .frostedBox: return L("Box · Frosted Glass", "框选 · 毛玻璃")
        case .solidBox: return L("Box · Solid Color", "框选 · 色块遮挡")
        case .brush: return L("Brush · Pixelate", "涂抹 · 像素马赛克")
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
        get { UserDefaults.standard.string(forKey: "editor.mosaicStyle").flatMap(MosaicStyle.init(rawValue:)) ?? .pixelBox }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "editor.mosaicStyle") }
    }
}

extension Annotation {
    /// Older annotations (and automatic redaction strokes) carry no style and stay brush strokes.
    var effectiveMosaicStyle: MosaicStyle { mosaicStyle ?? .brush }
    var isBoxMosaic: Bool { kind == .mosaic && effectiveMosaicStyle.isBox }

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
        case .solidBox:
            return nil
        }
    }

    static func clear() {
        sourceID = nil
        images = [:]
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
        annotation.effectiveMosaicStyle == .pixelBox ? 0 : min(6, min(annotation.rect.width, annotation.rect.height) / 4)
    }
}
