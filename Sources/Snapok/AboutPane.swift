import AppKit

enum AppLinks {
    static let website = URL(string: "https://snapok.app")!
    static let repository = URL(string: "https://github.com/thinkany-ai/snapok")!
    static let issues = URL(string: "https://github.com/thinkany-ai/snapok/issues/new")!
}

/// App identity, project links, and where Snapok keeps its files.
@MainActor
final class AboutPane: SectionedPageView {
    init() {
        super.init(title: L("About", "关于"))
        add(header())
        addSection(L("Updates", "更新"), rows: [UpdateStatusRow(), UpdateAutomaticRow()])
        addSection(L("Privacy", "隐私"), rows: [TelemetryRow()])
        addSection(L("Links", "链接"), rows: [
            linkRow(L("Website", "官网"), AppLinks.website, symbol: "globe", tint: .systemBlue),
            linkRow(L("Source Code", "源代码"), AppLinks.repository, symbol: "chevron.left.forwardslash.chevron.right", tint: .darkGray),
            linkRow(L("Feedback", "问题反馈"), AppLinks.issues, symbol: "exclamationmark.bubble.fill", tint: .systemOrange,
                    subtitle: L("Report a bug or suggest an idea on GitHub", "在 GitHub 上提交问题或建议"))
        ])
        addSection(L("Folders", "文件夹"), rows: [
            folderRow(L("Screenshot Library", "截图库"), HistoryStore.shared.root, symbol: "photo.stack.fill", tint: Brand.accent),
            folderRow(L("Log", "日志"), AppChannel.logURL, symbol: "doc.text.fill", tint: .systemGray)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func header() -> NSView {
        let icon = NSImageView(image: Brand.appIcon ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let name = NSTextField(labelWithString: AppChannel.displayName)
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let versionLabel = NSTextField(labelWithString: L("Version \(version) (\(build))", "版本 \(version)（\(build)）"))
        versionLabel.font = .systemFont(ofSize: 14)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.isSelectable = true
        let summary = NSTextField(wrappingLabelWithString: L("Screenshots for macOS: capture, annotate, and keep a searchable library.",
                                                             "macOS 截图工具：截图、标注，并保存在可搜索的截图库里。"))
        summary.font = .systemFont(ofSize: 13)
        summary.textColor = .secondaryLabelColor
        let text = NSStackView(views: [name, versionLabel, summary])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        let row = NSStackView(views: [icon, text])
        row.spacing = 18
        row.alignment = .centerY
        return Self.card(row, inset: NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24))
    }

    private func linkRow(_ title: String, _ url: URL, symbol: String, tint: NSColor, subtitle: String? = nil) -> NSView {
        AboutRow(symbol: symbol, tint: tint, title: title,
                 subtitle: subtitle ?? url.absoluteString.replacingOccurrences(of: "https://", with: ""),
                 help: L("Open", "打开")) { NSWorkspace.shared.open(url) }
    }

    private func folderRow(_ title: String, _ url: URL, symbol: String, tint: NSColor) -> NSView {
        AboutRow(symbol: symbol, tint: tint, title: title,
                 subtitle: url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                 help: L("Show in Finder", "在 Finder 中显示")) {
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url.hasDirectoryPath ? url : url.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// A clickable row: colored icon tile, title, gray detail, and an "open" glyph on the right.
@MainActor
final class AboutRow: NSView {
    private let action: () -> Void
    /// Hover and press fill, inset from the card's edges so it never meets the card's corners.
    private let highlight = NSView()
    private let open = NSImageView()
    private var hovering = false { didSet { updateHighlight() } }
    private var pressing = false { didSet { updateHighlight() } }

    convenience init(symbol: String, tint: NSColor, title: String, subtitle: String, help: String, action: @escaping () -> Void) {
        self.init(icon: IconTile(symbol: symbol, tint: tint), title: title, subtitle: subtitle, help: help, action: action)
    }

    /// `icon` sits on the left; a multi-line `subtitle` wraps instead of truncating.
    init(icon tile: NSView, title: String, subtitle: String, help: String, wrapsSubtitle: Bool = false, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        toolTip = help
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 8
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        ])

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        let detail = NSTextField(labelWithString: subtitle)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = wrapsSubtitle ? .byWordWrapping : .byTruncatingMiddle
        if wrapsSubtitle { detail.maximumNumberOfLines = 2 }
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [titleLabel, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        open.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: help)
        open.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        open.contentTintColor = .secondaryLabelColor

        let row = NSStackView(views: [tile, text, NSView(), open])
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18)
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateHighlight() {
        let alpha: CGFloat = pressing ? 0.09 : hovering ? 0.05 : 0
        highlight.layer?.backgroundColor = alpha > 0 ? NSColor.labelColor.withAlphaComponent(alpha).cgColor : nil
        open.contentTintColor = hovering ? .controlAccentColor : .secondaryLabelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHighlight()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressing = false }
    override func mouseDown(with event: NSEvent) { pressing = true }
    override func mouseDragged(with event: NSEvent) { pressing = bounds.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        pressing = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func accessibilityPerformPress() -> Bool { action(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Other apps by the Snapok team, each opening its website. The list comes from `ProductCatalog`.
@MainActor
final class MorePane: SectionedPageView {
    private var list: NSStackView!

    init() {
        super.init(title: L("More from Us", "周边"))
        list = addSection(L("Our Other Apps", "我们的其他产品"), rows: [])
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ProductCatalog.didChange, object: nil)
        ProductCatalog.shared.refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func reload() {
        let catalog = ProductCatalog.shared
        Self.fill(list, with: catalog.products.map { product in
            AboutRow(icon: Self.icon(catalog.icon(for: product), name: product.name), title: product.name,
                     subtitle: product.localizedSummary,
                     help: L("Open \(product.name)", "打开 \(product.name)"), wrapsSubtitle: true) { NSWorkspace.shared.open(product.trackedURL) }
        })
    }

    /// The app icon, or a tile with the name's first letter while it downloads.
    private static func icon(_ image: NSImage?, name: String, size: CGFloat = 34) -> NSView {
        let view: NSView
        if let image {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            view = imageView
        } else {
            let letter = NSTextField(labelWithString: String(name.prefix(1)).uppercased())
            letter.font = .systemFont(ofSize: size * 0.45, weight: .semibold)
            letter.textColor = .white
            letter.alignment = .center
            letter.translatesAutoresizingMaskIntoConstraints = false
            view = NSView()
            view.addSubview(letter)
            NSLayoutConstraint.activate([letter.centerXAnchor.constraint(equalTo: view.centerXAnchor), letter.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        }
        view.wantsLayer = true
        view.layer?.cornerRadius = size * 0.225
        view.layer?.masksToBounds = true
        if !(view is NSImageView) { view.layer?.backgroundColor = NSColor.systemGray.cgColor }
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: size), view.heightAnchor.constraint(equalToConstant: size)])
        return view
    }
}
