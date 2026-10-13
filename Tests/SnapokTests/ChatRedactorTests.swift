import AppKit
import Vision

/// Builds WeChat-like screenshots and checks which avatars and names get masked.
@main
@MainActor
struct ChatRedactorTests {
    static let width = 600, height = 700

    static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        syntheticGroupChat()
        repeatedAvatars()
        noTextMeansNoAvatars()
        try await endToEndWithOCR()
        print("ChatRedactor tests passed")
    }

    /// Top-left pixel rect → normalized Vision box.
    static func vision(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(x: x / Double(width), y: 1 - (y + h) / Double(height), width: w / Double(width), height: h / Double(height))
    }

    static func makeContext() -> CGContext {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draw with a top-left origin to match the layout numbers below.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    static func fill(_ c: CGContext, _ rect: CGRect, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
        c.setFillColor(red: r, green: g, blue: b, alpha: 1)
        c.fill(rect)
    }

    /// A photo-like avatar: several colored bands.
    static func avatar(_ c: CGContext, x: CGFloat, y: CGFloat, size: CGFloat = 40) {
        fill(c, CGRect(x: x, y: y, width: size, height: size), 0.85, 0.55, 0.35)
        fill(c, CGRect(x: x + 8, y: y + 6, width: size - 16, height: size / 2), 0.35, 0.45, 0.75)
        fill(c, CGRect(x: x, y: y + size * 0.7, width: size, height: size * 0.3), 0.3, 0.6, 0.35)
    }

    static func syntheticGroupChat() {
        let c = makeContext()
        var blocks: [RecognizedImageText] = []
        func block(_ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) {
            blocks.append(RecognizedImageText(id: blocks.count, text: text, box: vision(x, y, w, h)))
        }
        // Someone else, with a nickname above a white bubble.
        avatar(c, x: 20, y: 40)
        fill(c, CGRect(x: 72, y: 42, width: 60, height: 10), 0.55, 0.55, 0.55); block("张三", 72, 42, 60, 10)
        fill(c, CGRect(x: 72, y: 58, width: 220, height: 36), 1, 1, 1)
        fill(c, CGRect(x: 84, y: 69, width: 180, height: 13), 0.1, 0.1, 0.1); block("今天下午开会", 84, 69, 180, 13)
        // Private-chat style: no nickname, the bubble starts at the avatar's top.
        avatar(c, x: 20, y: 130)
        fill(c, CGRect(x: 72, y: 130, width: 180, height: 40), 1, 1, 1)
        fill(c, CGRect(x: 84, y: 143, width: 140, height: 13), 0.1, 0.1, 0.1); block("好的收到", 84, 143, 140, 13)
        // Me on the right with a green bubble.
        avatar(c, x: 540, y: 210)
        fill(c, CGRect(x: 330, y: 210, width: 198, height: 40), 0.58, 0.92, 0.41)
        fill(c, CGRect(x: 342, y: 223, width: 170, height: 13), 0.1, 0.1, 0.1); block("我马上到", 342, 223, 170, 13)
        // Someone sends a photo: the avatar has no text beside it but sits in the same column.
        avatar(c, x: 20, y: 290)
        fill(c, CGRect(x: 72, y: 290, width: 150, height: 110), 0.2, 0.3, 0.5)
        // A one-character reply in a square bubble is not an avatar.
        fill(c, CGRect(x: 300, y: 130, width: 40, height: 40), 1, 1, 1)
        fill(c, CGRect(x: 312, y: 143, width: 16, height: 14), 0.1, 0.1, 0.1); block("好", 312, 143, 16, 14)
        // A sticker (large square) and a toolbar icon (small square) are not avatars.
        fill(c, CGRect(x: 380, y: 300, width: 120, height: 120), 0.9, 0.3, 0.6)
        fill(c, CGRect(x: 30, y: 640, width: 18, height: 18), 0.3, 0.3, 0.3)
        fill(c, CGRect(x: 60, y: 644, width: 50, height: 11), 0.4, 0.4, 0.4); block("表情", 60, 644, 50, 11)
        // A desktop-style icon with its label below, not beside it.
        fill(c, CGRect(x: 300, y: 480, width: 44, height: 44), 0.2, 0.6, 0.9)
        fill(c, CGRect(x: 297, y: 530, width: 50, height: 11), 0.2, 0.2, 0.2); block("访达", 297, 530, 50, 11)

        let pixels = ChatRedactor.pixels(from: c.makeImage()!)!
        let found = ChatRedactor.detect(pixels: pixels, blocks: blocks)
        let avatarCenters = found.avatars.map { CGPoint(x: $0.midX * Double(width), y: (1 - $0.midY) * Double(height)) }
        print("avatars:", avatarCenters.map { "(\(Int($0.x)),\(Int($0.y)))" }, "names:", found.names.count)
        func hasAvatar(_ x: Double, _ y: Double) -> Bool { avatarCenters.contains { abs($0.x - x) < 4 && abs($0.y - y) < 4 } }
        precondition(hasAvatar(40, 60), "Left avatar with nickname must be found")
        precondition(hasAvatar(40, 150), "Left avatar in a private chat must be found")
        precondition(hasAvatar(560, 230), "My avatar on the right must be found")
        precondition(hasAvatar(40, 310), "Avatar next to a photo must be found by column")
        precondition(found.avatars.count == 4, "Stickers, toolbar and desktop icons are not avatars, got \(found.avatars.count)")
        precondition(found.names == [blocks[0].box], "Only the nickname is a name, not bubble text: \(found.names)")
    }

    /// One person sending many messages: the same picture repeats, which must not turn it into "background".
    static func repeatedAvatars() {
        let c = makeContext()
        var blocks: [RecognizedImageText] = []
        for row in 0..<12 {
            let y = CGFloat(10 + row * 56)
            avatar(c, x: 20, y: y)
            fill(c, CGRect(x: 72, y: y, width: 260, height: 40), 1, 1, 1)
            fill(c, CGRect(x: 84, y: y + 13, width: 200, height: 13), 0.1, 0.1, 0.1)
            blocks.append(RecognizedImageText(id: row, text: "消息 \(row)", box: vision(84, Double(y) + 13, 200, 13)))
        }
        let found = ChatRedactor.detect(pixels: ChatRedactor.pixels(from: c.makeImage()!)!, blocks: blocks)
        precondition(found.avatars.count == 12, "Every repeated avatar must be found, got \(found.avatars.count)")
        precondition(found.names.isEmpty, "Bubble text is never a name")
    }

    static func noTextMeansNoAvatars() {
        let c = makeContext()
        avatar(c, x: 20, y: 40)
        let pixels = ChatRedactor.pixels(from: c.makeImage()!)!
        precondition(ChatRedactor.detect(pixels: pixels, blocks: []).avatars.isEmpty, "Without any text the image is not a chat")
    }

    /// Real text, real Vision OCR, at Retina scale.
    static func endToEndWithOCR() async throws {
        let scale: CGFloat = 2
        let size = NSSize(width: 520, height: 260)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: size.height); flip.scaleX(by: 1, yBy: -1); flip.concat()
        NSColor(white: 0.93, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
        func draw(_ text: String, _ x: CGFloat, _ y: CGFloat, _ font: CGFloat, _ color: NSColor) {
            let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: font), .foregroundColor: color])
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform(); t.translateX(by: x, yBy: y + font * 1.2); t.scaleX(by: 1, yBy: -1); t.concat()
            attributed.draw(at: .zero)
            NSGraphicsContext.restoreGraphicsState()
        }
        func photo(_ x: CGFloat, _ y: CGFloat) {
            NSColor(calibratedRed: 0.85, green: 0.55, blue: 0.35, alpha: 1).setFill(); NSRect(x: x, y: y, width: 40, height: 40).fill()
            NSColor(calibratedRed: 0.35, green: 0.45, blue: 0.75, alpha: 1).setFill(); NSRect(x: x + 8, y: y + 6, width: 24, height: 20).fill()
        }
        photo(16, 20)
        draw("Alice Wang", 66, 18, 12, .gray)
        NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: 66, y: 38, width: 300, height: 38), xRadius: 4, yRadius: 4).fill()
        draw("Meeting moved to 3 pm today", 78, 46, 15, .black)
        photo(16, 120)
        draw("Bob Li", 66, 118, 12, .gray)
        NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: 66, y: 138, width: 220, height: 38), xRadius: 4, yRadius: 4).fill()
        draw("Sounds good to me", 78, 146, 15, .black)
        NSGraphicsContext.restoreGraphicsState()

        let image = rep.cgImage!
        if let path = ProcessInfo.processInfo.environment["CHAT_TEST_IMAGE"] { try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path)) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let blocks = (request.results ?? []).enumerated().compactMap { index, observation in
            observation.topCandidates(1).first.map { RecognizedImageText(id: index, text: $0.string, box: observation.boundingBox) }
        }
        let scan = (blocks: blocks, ())
        let found = await ChatRedactor.detect(image: image, blocks: scan.blocks)
        let names = scan.blocks.filter { block in found.names.contains(block.box) }.map(\.text)
        print("OCR:", scan.blocks.map(\.text), "avatars:", found.avatars.count, "names:", names)
        precondition(found.avatars.count == 2, "Both avatars must be found with real OCR")
        precondition(names.count == 2 && names.allSatisfy { $0.contains("Alice") || $0.contains("Bob") }, "Only the two names: \(names)")
    }
}


func L(_ english: String, _ chinese: String) -> String { english }
