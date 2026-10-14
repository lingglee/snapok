import AppKit
import Carbon
extension Bundle { static var module: Bundle { .main } }

/// Box mosaics (pixelate / blur / frosted / solid / erase) and the classic brush, rendered on a striped image.
@main @MainActor
struct MosaicStyleTests {
    static let size = CGSize(width: 200, height: 120)   // points; rendered at 2x like a Retina capture
    static let box = CGRect(x: 40, y: 30, width: 80, height: 50)

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        UserDefaults.standard.removeObject(forKey: "editor.mosaicStyle")
        let source = stripes()
        let plain = render(source, [])

        // 1. Each box style changes only the inside of the box, and every style looks different.
        var insides: [MosaicStyle: [UInt8]] = [:]
        for style in MosaicStyle.allCases where style.isBox {
            var mark = Annotation(kind: .mosaic, rect: box, points: [box.origin, CGPoint(x: box.maxX, y: box.maxY)],
                                  color: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1), sizeLevel: 1)
            mark.mosaicStyle = style
            let out = render(source, [mark])
            precondition(region(out, box.insetBy(dx: -4, dy: -4), outside: true) == region(plain, box.insetBy(dx: -4, dy: -4), outside: true),
                         "\(style) must not touch pixels outside the box")
            let inside = region(out, box.insetBy(dx: 7, dy: 7), outside: false)
            precondition(inside != region(plain, box.insetBy(dx: 7, dy: 7), outside: false), "\(style) must hide the box contents")
            insides[style] = inside
        }
        precondition(Set(insides.values).count == 5, "Pixelate, blur, frosted, solid and erase must render differently")
        // Erase fills flat with the background around the box, whatever the annotation color.
        let erased = insides[.eraseBox]!
        precondition(stride(from: 0, to: erased.count, by: 4).allSatisfy { erased[$0..<$0 + 3] == erased[0..<3] }, "Erase fills with one color")
        precondition(abs(Int(erased[2]) - 230) > 10, "Erase ignores the annotation color")
        precondition(!MosaicStyle.mosaicStyles.contains(.eraseBox), "The mosaic tool does not offer erasing")

        // 2. Solid fills with the annotation color; pixel blocks are flat; frosted is lighter than plain blur.
        let solid = insides[.solidBox]!
        precondition(stride(from: 0, to: solid.count, by: 4).allSatisfy { abs(Int(solid[$0 + 2]) - 230) <= 10 },
                     "Solid boxes must use the chosen color")
        precondition(mean(insides[.frostedBox]!) > mean(insides[.blurBox]!) + 20, "Frosted glass must add a milky veil")
        precondition(contrast(insides[.blurBox]!) < contrast(region(plain, box.insetBy(dx: 7, dy: 7), outside: false)) / 3,
                     "Blur must wash out the stripes")
        let pixel = render(source, [{ var a = Annotation(kind: .mosaic, rect: box, points: [], color: .black, sizeLevel: 2); a.mosaicStyle = .pixelBox; return a }()])
        let block = Int(MosaicStyle.blockSize(level: 2) * 2)
        precondition(pixelAt(pixel, 82, 82) == pixelAt(pixel, 83, 83), "Neighbouring pixels in one block must match")
        precondition(block == 40)
        // Larger levels give coarser blocks.
        precondition(MosaicStyle.blockSize(level: 0) < MosaicStyle.blockSize(level: 2))
        precondition(MosaicStyle.blurRadius(.blurBox, level: 0) < MosaicStyle.blurRadius(.blurBox, level: 2))

        // 3. Brush (and annotations without a style, e.g. from older history) still paints only along the stroke.
        let brush = Annotation(kind: .mosaic, rect: CGRect(x: 20, y: 50, width: 160, height: 24),
                               points: [CGPoint(x: 32, y: 62), CGPoint(x: 168, y: 62)], color: .black, sizeLevel: 1)
        precondition(brush.effectiveMosaicStyle == .brush && !brush.isBoxMosaic)
        let brushed = render(source, [brush])
        precondition(region(brushed, CGRect(x: 0, y: 0, width: 200, height: 40), outside: false)
                     == region(plain, CGRect(x: 0, y: 0, width: 200, height: 40), outside: false), "Brush must stay on its stroke")
        precondition(region(brushed, CGRect(x: 60, y: 58, width: 80, height: 8), outside: false)
                     != region(plain, CGRect(x: 60, y: 58, width: 80, height: 8), outside: false))

        // 4. Style survives history save/load; old items without the key decode as brush.
        var saved = Annotation(kind: .mosaic, rect: box, points: [], color: .black, sizeLevel: 0)
        saved.mosaicStyle = .frostedBox
        let decoded = try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(saved))
        precondition(decoded.mosaicStyle == .frostedBox && decoded.rect == box)
        let legacy = #"{"kind":"mosaic","rect":[[1,2],[3,4]],"points":[],"color":[0,0,0,1],"sizeLevel":1}"#
        let legacyItem = try JSONDecoder().decode(Annotation.self, from: Data(legacy.utf8))
        precondition(legacyItem.effectiveMosaicStyle == .brush)
        let future = #"{"kind":"mosaic","rect":[[1,2],[3,4]],"points":[],"color":[0,0,0,1],"sizeLevel":1,"mosaicStyle":"hologram"}"#
        let futureItem = try JSONDecoder().decode(Annotation.self, from: Data(future.utf8))
        precondition(futureItem.effectiveMosaicStyle == .brush,
                     "An unknown style must not break loading the history item")

        // 5. Switching a selected mosaic between box and brush keeps the covered area.
        var restyled = saved
        restyled.restyleMosaic(.brush)
        precondition(restyled.effectiveMosaicStyle == .brush && restyled.points.count >= 2
                     && restyled.rect.insetBy(dx: -1, dy: -1).contains(box), "Box → brush must still cover the box")
        restyled.restyleMosaic(.solidBox)
        precondition(restyled.isBoxMosaic && restyled.rect.contains(box))

        // 6. In the editor, dragging with a box style makes one rectangle (not a stroke) and is undoable.
        let editor = BackgroundPreview(image: source)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        editor.frame = window.contentView!.bounds
        window.contentView = editor
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        precondition(editor.mosaicStyle == .pixelBox, "New installs default to the box pixel mosaic")
        editor.chooseTool(.mosaic)
        editor.mosaicStyle = .blurBox
        editor.mouseDown(with: event(.leftMouseDown, CGPoint(x: 250, y: 180)))
        for x in stride(from: 260, through: 340, by: 20) { editor.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: x, y: 180 + (x - 250) / 2))) }
        editor.mouseUp(with: event(.leftMouseUp, CGPoint(x: 340, y: 225)))
        precondition(editor.annotations.count == 1, "One drag must make one mosaic")
        let dragged = editor.annotations[0]
        let a = editor.imagePoint(from: CGPoint(x: 250, y: 180)), b = editor.imagePoint(from: CGPoint(x: 340, y: 225))
        precondition(dragged.mosaicStyle == .blurBox && dragged.points.count == 2, "Box mosaics keep only their two corners")
        precondition(abs(dragged.rect.minX - min(a.x, b.x)) < 0.5 && abs(dragged.rect.maxY - max(a.y, b.y)) < 0.5,
                     "The box must match the dragged rectangle exactly (no brush padding)")
        // A tiny click must not leave a sliver behind.
        editor.mouseDown(with: event(.leftMouseDown, CGPoint(x: 400, y: 300)))
        editor.mouseUp(with: event(.leftMouseUp, CGPoint(x: 401, y: 300)))
        precondition(editor.annotations.count == 1)
        // Brush style in the editor still paints a stroke.
        editor.mosaicStyle = .brush
        editor.mouseDown(with: event(.leftMouseDown, CGPoint(x: 200, y: 160)))
        for x in stride(from: 210, through: 260, by: 10) { editor.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: x, y: 160))) }
        editor.mouseUp(with: event(.leftMouseUp, CGPoint(x: 260, y: 160)))
        precondition(editor.annotations.count == 2 && editor.annotations[1].points.count > 2 && !editor.annotations[1].isBoxMosaic)
        editor.undoEdit()
        precondition(editor.annotations.count == 1, "Undo must remove the last mosaic")

        if CommandLine.arguments.count > 1 {
            var row: [Annotation] = []
            for (index, style) in MosaicStyle.allCases.filter(\.isBox).enumerated() {
                var mark = Annotation(kind: .mosaic, rect: CGRect(x: 6 + CGFloat(index) * 48, y: 30, width: 42, height: 60), points: [],
                                      color: NSColor(white: 0.15, alpha: 1), sizeLevel: 1)
                mark.mosaicStyle = style
                row.append(mark)
            }
            try bitmap(source, row).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("Passed mosaic checks: box styles stay inside the box, look distinct, solid color, frosted veil, blur, brush stroke, history coding, restyle, editor drag/undo")
    }

    /// Black and white vertical stripes with colored text, so every filter has visible detail to remove.
    static func stripes() -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for x in stride(from: 0, to: Int(size.width), by: 4) {
            (x % 8 == 0 ? NSColor.black : NSColor.white).setFill()
            CGRect(x: CGFloat(x), y: 0, width: 4, height: size.height).fill()
        }
        ("13800138000" as NSString).draw(at: CGPoint(x: 48, y: 50), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.systemRed])
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    static func bitmap(_ source: NSImage, _ annotations: [Annotation]) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        source.draw(in: CGRect(origin: .zero, size: size))
        for annotation in annotations {
            AnnotationRenderer.draw(annotation, in: context.cgContext, sourceImage: source, origin: .zero, localImage: true)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func render(_ source: NSImage, _ annotations: [Annotation]) -> NSBitmapImageRep { bitmap(source, annotations) }

    /// Raw RGBA bytes inside (or outside) `rect` (points, bottom-left origin).
    static func region(_ rep: NSBitmapImageRep, _ rect: CGRect, outside: Bool) -> [UInt8] {
        var bytes: [UInt8] = []
        let data = rep.bitmapData!
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let point = CGPoint(x: (CGFloat(x) + 0.5) / 2, y: size.height - (CGFloat(y) + 0.5) / 2)
                guard rect.contains(point) != outside else { continue }
                let i = y * rep.bytesPerRow + x * 4
                bytes += [data[i], data[i + 1], data[i + 2], data[i + 3]]
            }
        }
        return bytes
    }

    static func pixelAt(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> [UInt8] {
        let i = y * rep.bytesPerRow + x * 4
        return (0..<4).map { rep.bitmapData![i + $0] }
    }

    static func mean(_ bytes: [UInt8]) -> Double {
        let rgb = bytes.enumerated().filter { $0.offset % 4 != 3 }.map { Double($0.element) }
        return rgb.reduce(0, +) / Double(max(1, rgb.count))
    }

    /// Standard deviation of brightness: high for crisp stripes, low after blurring.
    static func contrast(_ bytes: [UInt8]) -> Double {
        let lum = stride(from: 0, to: bytes.count, by: 4).map { (Double(bytes[$0]) + Double(bytes[$0 + 1]) + Double(bytes[$0 + 2])) / 3 }
        let avg = lum.reduce(0, +) / Double(max(1, lum.count))
        return (lum.map { ($0 - avg) * ($0 - avg) }.reduce(0, +) / Double(max(1, lum.count))).squareRoot()
    }
}
