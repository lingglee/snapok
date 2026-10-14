import AppKit

/// Our other apps, shown on the「周边」settings page. The list comes from https://cdn.snapok.app/products.json
/// (published by `scripts/publish-products.sh`); the last copy is cached, and a built-in list covers the first run and offline use.
@MainActor
final class ProductCatalog {
    struct Product: Codable, Equatable {
        struct Text: Codable, Equatable {
            var en: String
            var zh: String
        }
        var id: String
        var name: String
        var url: URL
        var icon: URL?
        var summary: Text

        var localizedSummary: String { L(summary.en, summary.zh) }

        /// The link with `utm_source=snapok_desktop`, keeping any query it already has.
        var trackedURL: URL {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            var items = (components.queryItems ?? []).filter { $0.name != "utm_source" }
            items.append(URLQueryItem(name: "utm_source", value: "snapok_desktop"))
            components.queryItems = items
            return components.url ?? url
        }
    }

    private struct Feed: Codable {
        var products: [Product]
    }

    static let shared = ProductCatalog()
    static let didChange = Notification.Name("ProductCatalog.didChange")
    static let feedURL = URL(string: "https://cdn.snapok.app/products.json")!

    static let builtIn: [Product] = [
        Product(id: "spotcat", name: "Spotcat", url: URL(string: "https://spotcat.ai")!, icon: nil,
                summary: .init(en: "A fast, native macOS launcher for apps, files, the web, extensions, and AI.",
                               zh: "快速的原生 macOS 启动器：⌥Space 打开应用、文件、网页、扩展和 AI。")),
        Product(id: "douchat", name: "Douchat", url: URL(string: "https://douchat.ai")!, icon: nil,
                summary: .init(en: "A desktop workspace where AI agents work alone or together in group chats.",
                               zh: "让 AI 智能体单独工作、也能在群聊里协作的桌面工作区。")),
        Product(id: "termany", name: "Termany", url: URL(string: "https://termany.sh")!, icon: nil,
                summary: .init(en: "The agent-native terminal: run many coding agents in one window.",
                               zh: "为智能体打造的终端：一个窗口同时运行多个编程智能体。"))
    ]

    private(set) var products: [Product]
    private var icons: [String: NSImage] = [:]
    private var refreshing = false
    private var downloading: Set<String> = []

    private static var folder: URL { AppChannel.supportDirectory.appendingPathComponent("Products", isDirectory: true) }
    private static var cacheURL: URL { folder.appendingPathComponent("products.json") }

    private init() {
        products = (try? Data(contentsOf: Self.cacheURL)).flatMap(Self.decode) ?? Self.builtIn
    }

    /// Only well-formed http(s) entries count; an empty or broken feed keeps what we have.
    static func decode(_ data: Data) -> [Product]? {
        guard let feed = try? JSONDecoder().decode(Feed.self, from: data) else { return nil }
        let valid = feed.products.filter { ["http", "https"].contains($0.url.scheme) && !$0.name.isEmpty && !$0.id.isEmpty }
        return valid.isEmpty ? nil : valid
    }

    /// Fetches the latest list in the background and posts `didChange` when it differs.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            var request = URLRequest(url: Self.feedURL, timeoutInterval: 15)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, let fresh = Self.decode(data) else { return }
                try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                try? data.write(to: Self.cacheURL, options: .atomic)
                guard fresh != products else { return }
                products = fresh
                NotificationCenter.default.post(name: Self.didChange, object: nil)
            } catch {
                log("loading the product list failed", error: error)
            }
        }
    }

    /// The bundled icon when the app ships one, else a downloaded copy; nil until a download finishes (then `didChange`).
    func icon(for product: Product) -> NSImage? {
        if let cached = icons[product.id] { return cached }
        if let url = Bundle.snapokResources.url(forResource: product.id, withExtension: "png", subdirectory: "Products"),
           let image = NSImage(contentsOf: url).map(Self.trimmed) {
            icons[product.id] = image
            return image
        }
        let file = Self.folder.appendingPathComponent("\(product.id).png")
        if let image = NSImage(contentsOf: file).map(Self.trimmed) {
            icons[product.id] = image
            return image
        }
        if let remote = product.icon, ["http", "https"].contains(remote.scheme) { download(remote, to: file, id: product.id) }
        return nil
    }

    private func download(_ remote: URL, to file: URL, id: String) {
        guard downloading.insert(id).inserted else { return }
        Task {
            defer { downloading.remove(id) }
            guard let (data, response) = try? await URLSession.shared.data(from: remote),
                  (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else { return }
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            icons[id] = Self.trimmed(image)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    /// Crops away transparent margins, so icons drawn with padding show at the same size as edge-to-edge ones.
    static func trimmed(_ image: NSImage) -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY, maxX - minX + 1 < width || maxY - minY + 1 < height else { return image }
        // Keep it square so the icon is not stretched.
        let side = max(maxX - minX + 1, maxY - minY + 1)
        let crop = CGRect(x: (minX + maxX + 1 - side) / 2, y: (minY + maxY + 1 - side) / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cropped = context.makeImage()?.cropping(to: crop) else { return image }
        return NSImage(cgImage: cropped, size: CGSize(width: crop.width, height: crop.height))
    }
}
