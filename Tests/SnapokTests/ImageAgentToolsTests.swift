import AppKit
extension Bundle { static var module: Bundle { .main } }

/// Checks how a planner reply becomes Snapok annotations: decoding, target lookup, coordinates, and generation.
@main @MainActor
struct ImageAgentToolsTests {
    static func main() {
        _ = NSApplication.shared
        let plan = AgentPlanner.decode([
            "reply": " 已打码 ",
            "ops": [
                ["op": "mosaic", "targets": [1, 99], "boxes": [], "text": "", "color": "", "style": "blur"],
                ["op": "rect", "targets": [], "boxes": [[0.5, 0.0, 0.25, 0.5], [0.1, 0.1]], "text": "", "color": "blue", "style": ""],
                ["op": "teleport", "targets": [1]],
                ["op": "text", "targets": [1], "boxes": [], "text": "这里", "color": "red", "style": ""],
                ["op": "generate", "targets": [], "boxes": [], "text": "换成渐变背景", "color": "", "style": ""]
            ]
        ])
        precondition(plan.reply == "已打码", "Reply is trimmed")
        precondition(plan.ops.map(\.kind) == [.mosaic, .rect, .text, .generate], "Unknown ops are dropped, got \(plan.ops.map(\.kind))")
        precondition(plan.ops[1].boxes.count == 1, "Malformed boxes are dropped")
        precondition(plan.localOps.count == 3 && plan.generation(fallback: "x") == "换成渐变背景", "Generation is split from the local ops")
        let bare = AgentPlanner.decode(["reply": "正在生成", "ops": [["op": "generate", "targets": [], "boxes": [], "text": " ", "color": "", "style": ""]]])
        precondition(bare.generation(fallback: "继续生成") == "继续生成", "A generate op without text uses the user's message")
        precondition(AgentPlanner.decode(["reply": "正在生成", "ops": []]).generation(fallback: "x") == nil, "No generate op, no generation")
        precondition(ImageAgentStore.isContinue("继续生成。") && ImageAgentStore.isContinue(" Continue ") && !ImageAgentStore.isContinue("继续把手机号打码"),
                     "Only short go-ahead replies count as continue")

        // Target 1 sits in the top-left quarter (Vision boxes are bottom-left).
        let targets = [AgentTarget(id: 1, kind: .sensitive, text: "138•••678", box: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))]
        let size = CGSize(width: 400, height: 200)
        let annotations = AgentToolRunner.annotations(for: plan.ops, size: size, targets: targets)
        precondition(annotations.map(\.kind) == [.mosaic, .rect, .text], "One annotation per resolved target, got \(annotations.map(\.kind))")
        precondition(annotations[0].mosaicStyle == .blurBox && annotations[0].rect.insetBy(dx: 3, dy: 3) == CGRect(x: 0, y: 100, width: 200, height: 100),
                     "Mosaic covers the target in image points: \(annotations[0].rect)")
        // Model boxes are top-left: [0.5, 0, 0.25, 0.5] is the top half of the third quarter.
        precondition(annotations[1].rect.insetBy(dx: 5, dy: 5) == CGRect(x: 200, y: 100, width: 100, height: 100),
                     "Boxes flip to bottom-left: \(annotations[1].rect)")
        precondition(annotations[1].color == Style.colors[3], "Named colors map to the palette")
        precondition(bounds(size).contains(annotations[2].rect) && annotations[2].rect.maxY <= 100,
                     "Label sits below its target, inside the image: \(annotations[2].rect)")

        // Rendering keeps every pixel of a large screenshot.
        let image = solid(width: 3000, height: 1500)
        let rendered = AgentToolRunner.apply(Array(plan.localOps.prefix(1)), to: image, targets: targets)
        let output = rendered?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        precondition(output?.width == 3000 && output?.height == 1500, "Output keeps the source resolution")
        precondition(AgentToolRunner.apply([], to: image, targets: targets) == nil, "No ops, no new image")

        // Erase uses the Erase tool's style; solid uses the named color.
        let erase = AgentOp(kind: .mosaic, targets: [1], boxes: [], text: "", color: "white", style: "erase")
        let solid = AgentOp(kind: .mosaic, targets: [1], boxes: [], text: "", color: "white", style: "solid")
        let masks = AgentToolRunner.annotations(for: [erase, solid], size: size, targets: targets)
        precondition(masks[0].mosaicStyle == .eraseBox && masks[1].mosaicStyle == .solidBox, "Styles map to the editor's")
        precondition(masks[1].color == Style.colors[5], "Solid covers in the named color")

        // Erasing a dark mark on a blue background leaves blue where the mark was.
        let marked = Self.solid(width: 400, height: 200, mark: CGRect(x: 40, y: 120, width: 80, height: 40))
        let erased = AgentToolRunner.apply([erase], to: marked, targets: targets)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let center = MosaicCache.borderColor(of: erased.cropping(to: CGRect(x: 70, y: 50, width: 20, height: 20))!, edge: 5)!.usingColorSpace(.sRGB)!
        precondition(abs(center.redComponent - 0.2) < 0.03 && abs(center.blueComponent - 0.8) < 0.03, "Erased area takes the background: \(center)")

        // Recognized text keeps rows, joins blocks on one row, tabs wide gaps, and leaves a blank line between paragraphs.
        func block(_ id: Int, _ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat) -> RecognizedImageText {
            RecognizedImageText(id: id, text: text, box: CGRect(x: x, y: y, width: width, height: 0.04))
        }
        let layout = TextScanner.layout([
            block(0, "18:40", 0.85, 0.900, 0.08), block(1, "1024 全栈开发社群", 0.10, 0.901, 0.30),
            block(2, "YUFAN YANG：是..", 0.10, 0.855, 0.30),
            block(3, "京东汽车", 0.10, 0.700, 0.15), block(4, "5 折起", 0.26, 0.700, 0.10)
        ], size: CGSize(width: 1000, height: 1000))
        precondition(layout == "1024 全栈开发社群\t18:40\nYUFAN YANG：是..\n\n京东汽车 5 折起", "OCR layout: \(layout.debugDescription)")
        // Translation targets: menu names and the names a planner may write map to languages.
        precondition(TranslationTargets.language(for: "简体中文")?.minimalIdentifier == "zh", "简体中文 → zh-Hans")
        precondition(TranslationTargets.language(for: "繁體中文")?.maximalIdentifier.contains("Hant") == true, "繁體中文 → zh-Hant")
        precondition(TranslationTargets.language(for: " english ")?.languageCode?.identifier == "en", "Case and spaces are ignored")
        precondition(TranslationTargets.language(for: "日语")?.languageCode?.identifier == "ja", "Chinese names of languages work")
        precondition(TranslationTargets.language(for: "Klingon") == nil, "Unknown names have no language")
        // Naming without a model: app name plus the first line that reads as words.
        let chatList = "18:40\n(473)\n1024 全栈开发社群\t18:40\nYUFAN YANG：是.."
        precondition(LocalNaming.titleAndTags(appName: "微信", ocrText: chatList)! == ("微信 · 1024 全栈开发社群 18:40", ["微信"]),
                     "App and first meaningful line: \(LocalNaming.titleAndTags(appName: "微信", ocrText: chatList)!)")
        precondition(LocalNaming.titleAndTags(appName: nil, ocrText: "OK\nLaunch your AI product in one hour today with ShipAny")!.title
                     == "Launch your AI product in one…", "Long lines are cut")
        precondition(LocalNaming.titleAndTags(appName: " ", ocrText: "12:30\n42") == nil, "Nothing to name with gives nil")
        print("ImageAgentToolsTests passed")
    }

    static func bounds(_ size: CGSize) -> CGRect { CGRect(origin: .zero, size: size) }

    /// A blue image, optionally with a black mark (a rect in bottom-left pixel coordinates).
    static func solid(width: Int, height: Int, mark: CGRect? = nil) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let mark {
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(mark)
        }
        return context.makeImage()!
    }
}
