import CoreGraphics
import Foundation

/// Finds chat avatars and the user names next to them (WeChat, QQ, DingTalk, Slack, Lark, chat lists)
/// from the screenshot pixels and the OCR boxes. Runs entirely on this Mac.
/// Every box going in or out is normalized (0–1) with a bottom-left origin, matching Vision.
enum ChatRedactor {
    struct Findings: Sendable {
        var avatars: [CGRect] = []
        var names: [CGRect] = []
    }

    /// RGBA pixels, row 0 is the top row.
    struct Pixels: Sendable {
        let width: Int
        let height: Int
        let data: [UInt8]

        func color(_ x: Int, _ y: Int) -> SIMD3<Int> {
            let i = (y * width + x) * 4
            return SIMD3(Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }
    }

    /// A box in downscaled pixel space with a top-left origin.
    private struct Box {
        var minX: Double, minY: Double, maxX: Double, maxY: Double
        var width: Double { maxX - minX }
        var height: Double { maxY - minY }
        var midY: Double { (minY + maxY) / 2 }
        var side: Double { max(width, height) }
    }

    static func detect(image: CGImage, blocks: [RecognizedImageText]) async -> Findings {
        await Task.detached(priority: .userInitiated) {
            guard let pixels = pixels(from: image) else { return Findings() }
            return detect(pixels: pixels, blocks: blocks)
        }.value
    }

    /// Downscales so a full Retina window stays around 1000 px wide; enough to keep avatars apart from bubbles.
    static func pixels(from image: CGImage, maxWidth: Int = 1000, maxPixels: Double = 4_000_000) -> Pixels? {
        let w0 = Double(image.width), h0 = Double(image.height)
        guard w0 > 0, h0 > 0 else { return nil }
        let scale = min(1, Double(maxWidth) / w0, (maxPixels / (w0 * h0)).squareRoot())
        let width = max(1, Int((w0 * scale).rounded())), height = max(1, Int((h0 * scale).rounded()))
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Pixels(width: width, height: height, data: data) : nil
    }

    static func detect(pixels p: Pixels, blocks: [RecognizedImageText]) -> Findings {
        guard !blocks.isEmpty, p.width > 8, p.height > 8 else { return Findings() }
        let w = Double(p.width), h = Double(p.height)
        let texts = blocks.map { Box(minX: $0.box.minX * w, minY: (1 - $0.box.maxY) * h, maxX: $0.box.maxX * w, maxY: (1 - $0.box.minY) * h) }
        let lineHeight = median(texts.map(\.height))
        guard lineHeight >= 3 else { return Findings() }

        let backgrounds = backgroundColors(p, minRun: Int((lineHeight * 5).rounded(.up)))
        let avatars = findAvatars(p, texts: texts, lineHeight: lineHeight, backgrounds: backgrounds)
        var nameIndices: [Int] = []
        for avatar in avatars {
            for (index, text) in texts.enumerated() where !nameIndices.contains(index) {
                if isName(text, beside: avatar, in: p) { nameIndices.append(index) }
            }
        }

        func normalized(_ box: Box) -> CGRect {
            CGRect(x: box.minX / w, y: 1 - box.maxY / h, width: box.width / w, height: box.height / h)
        }
        return Findings(avatars: avatars.map(normalized), names: nameIndices.sorted().map { blocks[$0].box })
    }

    // MARK: Background

    /// Colors laid out in long flat runs: page backgrounds, panes, and most bubbles. Avatars never have runs
    /// longer than an avatar, so a picture repeated many times (one person's messages) still stays foreground.
    private static func backgroundColors(_ p: Pixels, minRun: Int) -> [SIMD3<Int>] {
        var counts = [Int](repeating: 0, count: 4096)
        var longestRun = [Int](repeating: 0, count: 4096)
        var sums = [SIMD3<Int>](repeating: .zero, count: 4096)
        for y in 0..<p.height {
            var runBin = -1, run = 0
            for x in 0..<p.width {
                let c = p.color(x, y)
                let bin = (c.x >> 4) << 8 | (c.y >> 4) << 4 | (c.z >> 4)
                counts[bin] += 1
                sums[bin] &+= c
                if bin == runBin { run += 1 } else { runBin = bin; run = 1 }
                if run > longestRun[bin] { longestRun[bin] = run }
            }
        }
        let total = p.width * p.height
        let minCount = max(1, total / 200)
        let ranked = counts.indices.filter { counts[$0] >= minCount && longestRun[$0] >= minRun }.sorted { counts[$0] > counts[$1] }
        var colors = ranked.prefix(12).map { sums[$0] / counts[$0] }
        if colors.isEmpty, let top = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[top] > 0 {
            colors = [sums[top] / counts[top]]
        }
        return colors
    }

    private static func distance(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> Int {
        let d = a &- b
        return max(abs(d.x), abs(d.y), abs(d.z))
    }

    // MARK: Avatars

    private static func findAvatars(_ p: Pixels, texts: [Box], lineHeight: Double, backgrounds: [SIMD3<Int>]) -> [Box] {
        let width = p.width, height = p.height, n = width * height
        var foreground = [Bool](repeating: false, count: n)
        for y in 0..<height {
            for x in 0..<width {
                let c = p.color(x, y)
                foreground[y * width + x] = backgrounds.allSatisfy { distance(c, $0) > 18 }
            }
        }
        // Close 1 px gaps (anti-aliasing, thin light lines inside a photo) without joining an avatar to its bubble.
        var row = [Bool](repeating: false, count: n)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                row[i] = foreground[i] || (x > 0 && foreground[i - 1]) || (x + 1 < width && foreground[i + 1])
            }
        }
        var mask = [Bool](repeating: false, count: n)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                mask[i] = row[i] || (y > 0 && row[i - width]) || (y + 1 < height && row[i + width])
            }
        }

        let components = connectedComponents(mask, width: width, height: height)
        let minSide = lineHeight * 1.6, maxSide = lineHeight * 4.8
        var candidates: [Box] = []
        for component in components {
            let box = component.box
            let short = min(box.width, box.height), long = max(box.width, box.height)
            guard short >= minSide, long <= maxSide, long / short <= 1.25,
                  Double(component.count) / (box.width * box.height) >= 0.6 else { continue }
            // Bubbles hold text; a short one ("OK") is as square as an avatar.
            let holdsText = texts.contains { text in
                let midX = (text.minX + text.maxX) / 2
                return midX > box.minX && midX < box.maxX && text.midY > box.minY && text.midY < box.maxY
            }
            let covered = texts.reduce(0.0) { $0 + overlap(box, $1) }
            guard !holdsText, covered / (box.width * box.height) <= 0.2 else { continue }
            candidates.append(box)
        }

        // A chat avatar has a bubble or a name right beside it; app or desktop icons have their labels below.
        func hasTextBeside(_ box: Box) -> Bool {
            texts.contains { text in
                let verticallyAligned = text.midY >= box.minY - box.side * 0.2 && text.midY <= box.maxY + box.side * 0.2
                guard verticallyAligned else { return false }
                let right = text.minX - box.maxX, left = box.minX - text.maxX
                return (right >= -box.side * 0.1 && right <= box.side * 1.5) || (left >= -box.side * 0.1 && left <= box.side * 1.5)
            }
        }
        var accepted = candidates.filter(hasTextBeside)
        // Avatars next to image or sticker messages: same column and size as an avatar already found.
        for box in candidates where !accepted.contains(where: { same($0, box) }) {
            let aligned = accepted.contains { other in
                let tolerance = other.side * 0.12
                return abs(other.side - box.side) <= other.side * 0.15
                    && (abs(other.minX - box.minX) <= tolerance || abs(other.maxX - box.maxX) <= tolerance)
            }
            if aligned { accepted.append(box) }
        }
        return accepted.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
    }

    private static func same(_ a: Box, _ b: Box) -> Bool {
        a.minX == b.minX && a.minY == b.minY && a.maxX == b.maxX && a.maxY == b.maxY
    }

    private static func overlap(_ a: Box, _ b: Box) -> Double {
        let w = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let h = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return w > 0 && h > 0 ? w * h : 0
    }

    private struct Component {
        var box: Box
        var count: Int
    }

    /// 8-connected components with union-find.
    private static func connectedComponents(_ mask: [Bool], width: Int, height: Int) -> [Component] {
        var labels = [Int32](repeating: -1, count: mask.count)
        var parent: [Int32] = []
        func find(_ value: Int32) -> Int32 {
            var x = value
            while parent[Int(x)] != x {
                parent[Int(x)] = parent[Int(parent[Int(x)])]
                x = parent[Int(x)]
            }
            return x
        }
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                var root: Int32 = -1
                let neighbors = [(x - 1, y), (x - 1, y - 1), (x, y - 1), (x + 1, y - 1)]
                for (nx, ny) in neighbors where nx >= 0 && ny >= 0 && nx < width {
                    let label = labels[ny * width + nx]
                    guard label >= 0 else { continue }
                    let other = find(label)
                    if root < 0 { root = other } else if other != root {
                        let (low, high) = root < other ? (root, other) : (other, root)
                        parent[Int(high)] = low
                        root = low
                    }
                }
                if root < 0 {
                    root = Int32(parent.count)
                    parent.append(root)
                }
                labels[y * width + x] = root
            }
        }
        var stats: [Int32: Component] = [:]
        for y in 0..<height {
            for x in 0..<width {
                let label = labels[y * width + x]
                guard label >= 0 else { continue }
                let root = find(label)
                let fx = Double(x), fy = Double(y)
                if var component = stats[root] {
                    component.box.minX = min(component.box.minX, fx)
                    component.box.minY = min(component.box.minY, fy)
                    component.box.maxX = max(component.box.maxX, fx + 1)
                    component.box.maxY = max(component.box.maxY, fy + 1)
                    component.count += 1
                    stats[root] = component
                } else {
                    stats[root] = Component(box: Box(minX: fx, minY: fy, maxX: fx + 1, maxY: fy + 1), count: 1)
                }
            }
        }
        return Array(stats.values)
    }

    // MARK: Names

    /// A user name sits right beside the avatar, level with its upper half, directly on the page background;
    /// message text instead sits inside a bubble whose color differs from the gap next to the avatar.
    private static func isName(_ text: Box, beside avatar: Box, in p: Pixels) -> Bool {
        let side = avatar.side
        guard text.height <= side * 0.6,
              text.midY >= avatar.minY - side * 0.15, text.midY <= avatar.minY + side * 0.45 else { return false }
        let right = text.minX - avatar.maxX, left = avatar.minX - text.maxX
        let onRight = right >= -side * 0.1 && right <= side * 0.9
        let onLeft = left >= -side * 0.1 && left <= side * 0.9
        guard onRight || onLeft else { return false }

        // The page background: the gap between avatar and text, or just above the avatar when they touch.
        var gap: [SIMD3<Int>] = []
        let gapMin = onRight ? avatar.maxX + 1 : text.maxX + 1
        let gapMax = onRight ? text.minX - 1 : avatar.minX - 1
        if gapMax - gapMin >= 1 {
            gap = samples(p, minX: gapMin, maxX: gapMax, minY: text.minY, maxY: text.maxY)
        }
        if gap.isEmpty {
            gap = samples(p, minX: avatar.minX, maxX: avatar.maxX, minY: avatar.minY - 3, maxY: avatar.minY - 1)
        }
        // What surrounds the text: the strip just above it and just to its far side.
        let margin = max(2, text.height * 0.35)
        var ring = samples(p, minX: text.minX, maxX: text.maxX, minY: text.minY - margin, maxY: text.minY - 1)
        ring += onRight
            ? samples(p, minX: text.maxX + 1, maxX: text.maxX + margin, minY: text.minY, maxY: text.maxY)
            : samples(p, minX: text.minX - margin, maxX: text.minX - 1, minY: text.minY, maxY: text.maxY)
        guard !gap.isEmpty, !ring.isEmpty else { return false }
        return distance(medianColor(gap), medianColor(ring)) <= 16
    }

    private static func samples(_ p: Pixels, minX: Double, maxX: Double, minY: Double, maxY: Double) -> [SIMD3<Int>] {
        let x0 = max(0, Int(minX.rounded(.down))), x1 = min(p.width - 1, Int(maxX.rounded(.up)))
        let y0 = max(0, Int(minY.rounded(.down))), y1 = min(p.height - 1, Int(maxY.rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return [] }
        let stepX = max(1, (x1 - x0) / 40), stepY = max(1, (y1 - y0) / 20)
        var result: [SIMD3<Int>] = []
        for y in stride(from: y0, through: y1, by: stepY) {
            for x in stride(from: x0, through: x1, by: stepX) { result.append(p.color(x, y)) }
        }
        return result
    }

    private static func medianColor(_ colors: [SIMD3<Int>]) -> SIMD3<Int> {
        func channel(_ value: (SIMD3<Int>) -> Int) -> Int { colors.map(value).sorted()[colors.count / 2] }
        return SIMD3(channel { $0.x }, channel { $0.y }, channel { $0.z })
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }
}
