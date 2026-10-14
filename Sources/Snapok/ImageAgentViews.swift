import AppKit
import UniformTypeIdentifiers

/// A wrapping label that re-wraps at its laid-out width, so Auto Layout can size multi-line text.
final class WrappingLabel: NSTextField {
    override func layout() {
        super.layout()
        if abs(preferredMaxLayoutWidth - bounds.width) > 0.5 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// A chat image that opens Quick Look on double-click and shows `contextMenu` on right-click.
class AgentImageView: NSImageView {
    var onDoubleClick: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let onDoubleClick { onDoubleClick() } else if event.clickCount == 1 { singleClick() }
    }
    func singleClick() {}
}

/// An image that fits inside `maxSize`, keeps its aspect ratio, and reports clicks.
/// It prefers its full fitted size but shrinks when its container is narrower.
final class AgentThumbnail: AgentImageView {
    private let onClick: () -> Void

    init(image: NSImage, maxSize: CGSize, cornerRadius: CGFloat = 10, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        self.image = image
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        let size = image.size
        let scale = size.width > 0 && size.height > 0 ? min(maxSize.width / size.width, maxSize.height / size.height, 1) : 1
        let width = max(40, size.width * scale)
        let height = max(40, size.height * scale)
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.init(100), for: .horizontal)
        setContentCompressionResistancePriority(.init(100), for: .vertical)
        // Below the split view's holding priorities, so an image never moves the divider.
        let preferred = widthAnchor.constraint(equalToConstant: width)
        preferred.priority = .init(200)
        NSLayoutConstraint.activate([
            preferred,
            widthAnchor.constraint(lessThanOrEqualToConstant: width),
            heightAnchor.constraint(equalTo: widthAnchor, multiplier: height / width)
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(L("View image", "查看图片"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func singleClick() { onClick() }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}

/// The conversation: messages top to bottom, a working indicator, or an empty state with example requests.
@MainActor
final class AgentTranscriptView: NSScrollView {
    var onOpenImage: ((String) -> Void)?
    var onQuickLook: ((String) -> Void)?
    var imageMenu: ((String) -> NSMenu?)?
    var onRetry: (() -> Void)?
    /// Runs the cloud generation the last reply left pending.
    var onResume: (() -> Void)?

    private let stack = NSStackView()
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        // Thin overlay scrollers even when "Show scroll bars" is set to Always.
        scrollerStyle = .overlay
        verticalScroller = ThinScroller()
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        // The scroll view spans the card, so the scroller hugs its edge; this indents the messages.
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 40, bottom: 24, right: 40)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `liveText` is what the cloud agent has written so far; `started` is when the current phase began.
    func show(_ chat: AgentChat?, running: Bool, generating: Bool = false, liveText: String? = nil,
              steps: [SnapokCloud.AgentStep] = [], started: Date? = nil) {
        lastShown = (chat, running, generating, liveText, steps, started)
        timer?.invalidate(); timer = nil
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let chat, !chat.messages.isEmpty else {
            add(emptyState(), fill: true)
            return
        }
        for message in chat.messages {
            add(message.role == .user ? userRow(message, chatID: chat.id) : assistantRow(message, chatID: chat.id, isLast: message == chat.messages.last),
                fill: true)
        }
        if running {
            if let liveText = liveText.map(Self.readable), !liveText.isEmpty {
                let label = WrappingLabel(wrappingLabelWithString: "")
                label.attributedStringValue = MarkdownRenderer.render(liveText)
                label.isSelectable = true
                add(label, fill: true)
            }
            add(workingRow(generating: generating, started: started ?? Date(), steps: steps), fill: false)
            if stepsExpanded, !steps.isEmpty { add(stepsList(steps), fill: false) }
        }
        layoutSubtreeIfNeeded()
        scrollToBottom()
    }

    private func add(_ view: NSView, fill: Bool) {
        stack.addArrangedSubview(view)
        if fill {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -80).isActive = true
        }
    }

    private func scrollToBottom() {
        guard let document = documentView else { return }
        let y = max(0, document.bounds.height - contentView.bounds.height)
        contentView.scroll(to: CGPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
    }

    private func images(_ names: [String], chatID: String, maxSize: CGSize) -> [NSView] {
        names.compactMap { name in
            ImageAgentStore.shared.image(name, in: chatID).map { image -> NSView in
                let thumb = AgentThumbnail(image: image, maxSize: maxSize) { [weak self] in self?.onOpenImage?(name) }
                thumb.onDoubleClick = { [weak self] in self?.onQuickLook?(name) }
                thumb.contextMenu = { [weak self] in self?.imageMenu?(name) }
                return thumb
            }
        }
    }

    private func userRow(_ message: AgentMessage, chatID: String) -> NSView {
        let row = NSView()
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = 8
        let thumbs = images(message.images, chatID: chatID, maxSize: CGSize(width: 200, height: 200))
        var strip: NSStackView?
        if !thumbs.isEmpty {
            let images = NSStackView(views: thumbs)
            images.spacing = 8
            images.alignment = .bottom
            images.setClippingResistancePriority(.defaultLow, for: .horizontal)
            column.addArrangedSubview(images)
            strip = images
        }
        let bubble = NSView()
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 14
        bubble.layer?.backgroundColor = Brand.accent.withAlphaComponent(0.10).cgColor
        let label = WrappingLabel(wrappingLabelWithString: message.text)
        label.font = .systemFont(ofSize: 14)
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14)
        ])
        column.addArrangedSubview(bubble)
        column.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: row.topAnchor),
            column.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            column.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor, constant: 60),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.8)
        ])
        strip?.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.8).isActive = true
        return row
    }

    private func assistantRow(_ message: AgentMessage, chatID: String, isLast: Bool) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        let thumbs = images(message.images, chatID: chatID, maxSize: CGSize(width: 360, height: 360))
        if !thumbs.isEmpty {
            let badge = NSButton(title: L("Edited an image", "已修改图片"),
                                 image: NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)!,
                                 target: nil, action: nil)
            badge.isBordered = false
            badge.imagePosition = .imageLeading
            badge.font = .systemFont(ofSize: 13)
            badge.contentTintColor = .secondaryLabelColor
            badge.refusesFirstResponder = true
            column.addArrangedSubview(badge)
            for thumb in thumbs {
                column.addArrangedSubview(thumb)
                thumb.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor).isActive = true
            }
        }
        if !message.text.isEmpty {
            let label = WrappingLabel(wrappingLabelWithString: "")
            if message.failed {
                label.stringValue = message.text
                label.font = .systemFont(ofSize: 14)
                label.textColor = .systemRed
            } else {
                label.attributedStringValue = MarkdownRenderer.render(message.text)
                label.allowsEditingTextAttributes = true
            }
            label.isSelectable = true
            column.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        if let duration = message.duration {
            let time = NSTextField(labelWithString: L("Took \(Self.durationText(duration))", "用时 \(Self.durationText(duration))"))
            time.font = .systemFont(ofSize: 11)
            time.textColor = .tertiaryLabelColor
            column.addArrangedSubview(time)
        }
        if message.failed && isLast {
            let retry = NSButton(title: L("Try Again", "重试"), target: self, action: #selector(retry))
            retry.bezelStyle = .rounded
            column.addArrangedSubview(retry)
        } else if message.pendingGeneration != nil && isLast {
            let note = WrappingLabel(wrappingLabelWithString: ImageAgentStore.generationBlocked()
                ?? L("The rest needs cloud generation.", "剩下的部分需要云端生成。"))
            note.font = .systemFont(ofSize: 13)
            note.textColor = .secondaryLabelColor
            column.addArrangedSubview(note)
            note.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            let resume = NSButton(title: L("Continue Generating", "继续生成"), target: self, action: #selector(resume))
            resume.bezelStyle = .rounded
            column.addArrangedSubview(resume)
        }
        return column
    }

    /// "8.2 s" under a minute, "1 min 35 s" after.
    static func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return L(String(format: "%.1f s", seconds), String(format: "%.1f 秒", seconds)) }
        let whole = Int(seconds.rounded())
        return L("\(whole / 60) min \(whole % 60) s", "\(whole / 60) 分 \(whole % 60) 秒")
    }

    /// The agent separates interim messages with `<|split|>`; show them as paragraphs.
    private static func readable(_ text: String) -> String {
        text.replacingOccurrences(of: "<|split|>", with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The cloud agent's steps, shown when the progress line is expanded. Runs of the same tool are one line
    /// ("Running a script ×9"); done ones are checked, a running one spins.
    private func stepsList(_ steps: [SnapokCloud.AgentStep]) -> NSView {
        var groups: [(title: String, count: Int, done: Bool)] = []
        for step in steps {
            let title = Self.stepTitle(step.name)
            if let last = groups.last, last.title == title {
                groups[groups.count - 1].count += 1
                groups[groups.count - 1].done = last.done && step.done
            } else {
                groups.append((title, 1, step.done))
            }
        }
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 0, right: 0)
        for group in groups {
            let indicator: NSView
            if group.done {
                let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)!)
                check.contentTintColor = .systemGreen
                check.symbolConfiguration = .init(pointSize: 11, weight: .regular)
                indicator = check
            } else {
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.controlSize = .mini
                spinner.startAnimation(nil)
                indicator = spinner
            }
            indicator.widthAnchor.constraint(equalToConstant: 14).isActive = true
            let count = group.count > 1 ? " ×\(group.count)" : ""
            let label = NSTextField(labelWithString: group.title + count)
            label.font = .systemFont(ofSize: 12)
            label.textColor = group.done ? .tertiaryLabelColor : .secondaryLabelColor
            let row = NSStackView(views: [indicator, label])
            row.spacing = 6
            list.addArrangedSubview(row)
        }
        return list
    }

    /// The agent's tool names in plain words; unknown tools show a generic step.
    static func stepTitle(_ name: String) -> String {
        switch name {
        case "exec", "bash_output": return L("Running a script", "运行脚本")
        case "image_gen": return L("Generating the image", "生成图片")
        case "read_file": return L("Reading a file", "读取文件")
        case "write_file", "edit_file", "apply_patch": return L("Writing a file", "写入文件")
        case "list_dir": return L("Looking at files", "查看文件")
        case "load_skill": return L("Loading a skill", "加载技能")
        case "web_search": return L("Searching the web", "搜索网页")
        case "web_fetch": return L("Opening a web page", "打开网页")
        case "memory_search", "knowledge_search": return L("Looking things up", "查找资料")
        case "spawn_subagent": return L("Starting a helper", "启动子任务")
        default: return L("Working", "处理中")
        }
    }

    /// The progress line. With agent steps it also names the current one ("Running a script · step 13") and gets a
    /// disclosure arrow that lists them all; most people never need to open it.
    private func workingRow(generating: Bool, started: Date, steps: [SnapokCloud.AgentStep]) -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        let current = (steps.last(where: { !$0.done }) ?? steps.last).map {
            L("\(Self.stepTitle($0.name)) · step \(steps.count)", "\(Self.stepTitle($0.name))（第 \(steps.count) 步）")
        }
        let text: @MainActor @Sendable () -> String = { [current] in
            [Self.workingText(since: started, generating: generating), current].compactMap { $0 }.joined(separator: " · ")
        }
        label.stringValue = text()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak label] _ in
            MainActor.assumeIsolated { label?.stringValue = text() }
        }
        let row = NSStackView(views: [spinner, label])
        row.spacing = 8
        if !steps.isEmpty {
            let disclosure = NSButton(image: NSImage(systemSymbolName: stepsExpanded ? "chevron.down" : "chevron.right",
                                                     accessibilityDescription: L("Show steps", "查看步骤"))!,
                                      target: self, action: #selector(toggleSteps))
            disclosure.isBordered = false
            disclosure.contentTintColor = .tertiaryLabelColor
            disclosure.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            disclosure.toolTip = stepsExpanded ? L("Hide steps", "收起步骤") : L("Show steps", "查看步骤")
            row.addArrangedSubview(disclosure)
        }
        return row
    }

    /// Whether the agent's steps are listed under the progress line; kept while the transcript redraws.
    private var stepsExpanded = false
    private var lastShown: (chat: AgentChat?, running: Bool, generating: Bool, liveText: String?, steps: [SnapokCloud.AgentStep], started: Date?)?

    @objc private func toggleSteps() {
        stepsExpanded.toggle()
        guard let shown = lastShown else { return }
        show(shown.chat, running: shown.running, generating: shown.generating, liveText: shown.liveText, steps: shown.steps, started: shown.started)
    }

    private static func workingText(since start: Date, generating: Bool) -> String {
        let seconds = Int(Date().timeIntervalSince(start))
        guard generating else { return L("Working… \(seconds)s", "正在处理… \(seconds) 秒") }
        if seconds >= 180 {
            let limit = Int(ImageAgentStore.generationTimeout / 60)
            return L("Still generating… \(seconds)s · taking longer than usual, stops after \(limit) minutes",
                     "还在生成… \(seconds) 秒 · 比平时久，超过 \(limit) 分钟会自动停止")
        }
        return L("Editing the image… \(seconds)s · usually 1–2 minutes", "正在改图… \(seconds) 秒 · 通常需要 1–2 分钟")
    }

    private func emptyState() -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        icon.contentTintColor = Brand.accent
        let title = NSTextField(labelWithString: L("Ask about an image, edit it, or generate one", "带图提问、改图或生成图片"))
        title.font = .systemFont(ofSize: 22, weight: .bold)
        let subtitle = WrappingLabel(wrappingLabelWithString: L(
            "Attach an image to ask about it or describe a change, or just describe the picture you want. Keep chatting to follow up.",
            "添加图片后可以提问或描述怎么修改，也可以直接描述想要的画面来生成。不满意就接着对话继续调整。"))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        let column = NSStackView(views: [icon, title, subtitle])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 10
        let wrapper = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 120),
            column.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            column.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualTo: wrapper.widthAnchor, constant: -16),
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            subtitle.widthAnchor.constraint(lessThanOrEqualTo: wrapper.widthAnchor, constant: -16)
        ])
        return wrapper
    }

    @objc private func retry() { onRetry?() }
    @objc private func resume() { onResume?() }
}

/// The message box: attached images above a one-line field with "+" and send buttons.
/// Images can also be dropped on it or pasted with ⌘V.
@MainActor
final class AgentComposer: NSView, NSTextFieldDelegate {
    static let maxAttachments = 4
    var onSend: ((String, [NSImage]) -> Void)?
    /// While busy, the send button becomes a stop button.
    var onStop: (() -> Void)?
    private(set) var attachments: [NSImage] = []
    var isBusy = false { didSet { refresh() } }
    var isAvailable = true { didSet { refresh() } }
    var placeholder: String {
        get { field.placeholderString ?? "" }
        set { field.placeholderString = newValue }
    }
    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue; refresh() }
    }

    private let field = NSTextField()
    private let strip = NSStackView()
    private let plus = CircleIconButton(symbol: "plus", style: .subtle)
    private let send = CircleIconButton(symbol: "arrow.up", style: .primary)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 25
        layer?.borderWidth = 1
        registerForDraggedTypes([.fileURL, .png, .tiff])

        plus.setAccessibilityLabel(L("Add images", "添加图片"))
        plus.target = self
        plus.action = #selector(showAddMenu)
        plus.toolTip = L("Add images", "添加图片")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        send.setAccessibilityLabel(L("Send", "发送"))
        send.target = self
        send.action = #selector(sendClicked)
        send.toolTip = L("Send", "发送")
        strip.spacing = 8
        strip.isHidden = true
        // Fixed sizes, centred on one line: bezel insets would otherwise shift the buttons.
        let row = NSView()
        for view in [plus, field, send] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 34),
            plus.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 2),
            plus.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 32),
            plus.heightAnchor.constraint(equalToConstant: 32),
            field.leadingAnchor.constraint(equalTo: plus.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            send.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -2),
            send.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        let column = NSStackView(views: [strip, row])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.distribution = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            row.widthAnchor.constraint(equalTo: column.widthAnchor),
            send.widthAnchor.constraint(equalToConstant: 32),
            send.heightAnchor.constraint(equalToConstant: 32)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor(white: 0.21, alpha: 1) : .white).cgColor
        layer?.borderColor = NSColor(white: dark ? 1 : 0, alpha: 0.12).cgColor
    }

    func focus(selectingAll: Bool = false) {
        window?.makeFirstResponder(field)
        if selectingAll { field.currentEditor()?.selectAll(nil) }
    }

    func attach(_ images: [NSImage]) {
        attachments.append(contentsOf: images.prefix(Self.maxAttachments - attachments.count))
        rebuildStrip()
        refresh()
    }

    func clear() {
        field.stringValue = ""
        attachments.removeAll()
        rebuildStrip()
        refresh()
    }

    private func refresh() {
        let hasText = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSend = isAvailable && !isBusy && hasText
        field.isEnabled = isAvailable
        plus.isEnabled = isAvailable && attachments.count < Self.maxAttachments
        send.isEnabled = canSend || isBusy
        send.image = NSImage(systemSymbolName: isBusy ? "stop.fill" : "arrow.up", accessibilityDescription: nil)
        let title = isBusy ? L("Stop", "停止") : L("Send", "发送")
        send.toolTip = title
        send.setAccessibilityLabel(title)
    }

    private func rebuildStrip() {
        strip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, image) in attachments.enumerated() {
            let thumb = AgentThumbnail(image: image, maxSize: CGSize(width: 64, height: 64), cornerRadius: 8) {}
            let remove = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("Remove image", "移除图片"))!,
                                  target: self, action: #selector(removeAttachment(_:)))
            remove.isBordered = false
            remove.tag = index
            remove.contentTintColor = .secondaryLabelColor
            remove.translatesAutoresizingMaskIntoConstraints = false
            thumb.addSubview(remove)
            NSLayoutConstraint.activate([
                remove.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 2),
                remove.trailingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: -2)
            ])
            strip.addArrangedSubview(thumb)
        }
        strip.isHidden = attachments.isEmpty
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    @objc private func submit() {
        if isBusy { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, !isBusy, !text.isEmpty else { return }
        onSend?(text, attachments)
    }

    @objc private func sendClicked() {
        isBusy ? onStop?() : submit()
    }

    /// Esc in the message box stops a turn in flight.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard isBusy, commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onStop?()
        return true
    }

    @objc private func removeAttachment(_ sender: NSButton) {
        guard attachments.indices.contains(sender.tag) else { return }
        attachments.remove(at: sender.tag)
        rebuildStrip()
        refresh()
    }

    @objc private func showAddMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: L("Choose Images…", "选择图片…"), action: #selector(chooseImages), keyEquivalent: "").target = self
        let paste = menu.addItem(withTitle: L("Paste Image", "粘贴图片"), action: #selector(pasteImage), keyEquivalent: "")
        paste.target = self
        paste.isEnabled = NSImage.canInit(with: .general)
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: plus.bounds.height + 4), in: plus)
    }

    @objc private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.attach(panel.urls.compactMap(NSImage.init(contentsOf:)))
        }
    }

    @objc private func pasteImage() {
        attach((NSPasteboard.general.readObjects(forClasses: [NSImage.self]) as? [NSImage]) ?? [])
    }

    /// ⌘V with an image (and no text) on the pasteboard attaches it instead of pasting into the field.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let pasteboard = NSPasteboard.general
        if isAvailable, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "v",
           pasteboard.string(forType: .string) == nil, NSImage.canInit(with: pasteboard) {
            pasteImage()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isAvailable && NSImage.canInit(with: sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = (sender.draggingPasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage]) ?? []
        attach(images)
        return !images.isEmpty
    }
}

/// A round icon button with hover and pressed states. `.primary` is the brand-colored send button;
/// `.subtle` is a soft tinted circle for secondary actions. The circle is drawn as an exact square
/// centered in the bounds, and alignment insets are zero, so the frame is exactly what constraints say.
final class CircleIconButton: NSButton {
    enum Style { case primary, subtle }
    private let style: Style
    private var hovering = false { didSet { needsDisplay = true } }

    init(symbol: String, style: Style) {
        self.style = style
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        symbolConfiguration = .init(pointSize: 14, weight: style == .primary ? .bold : .semibold)
        isBordered = false
        imagePosition = .imageOnly
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height)
        let circle = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        let pressed = isHighlighted
        let fill: NSColor
        let tint: NSColor
        switch style {
        case .primary where isEnabled:
            let shade: CGFloat = pressed ? 0.2 : hovering ? 0.1 : 0
            fill = Brand.accent.blended(withFraction: shade, of: .black) ?? Brand.accent
            tint = .white
        case .primary:
            fill = NSColor.labelColor.withAlphaComponent(0.07)
            tint = .tertiaryLabelColor
        case .subtle:
            fill = NSColor.labelColor.withAlphaComponent(!isEnabled ? 0.03 : pressed ? 0.14 : hovering ? 0.1 : 0.05)
            tint = isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
        }
        fill.setFill()
        NSBezierPath(ovalIn: circle).fill()
        guard let image = image?.withSymbolConfiguration(symbolConfiguration ?? .init(pointSize: 14, weight: .semibold)) else { return }
        let symbol = image.tinted(tint)
        let size = symbol.size
        symbol.draw(in: NSRect(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2, width: size.width, height: size.height))
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

private extension NSImage {
    /// A copy of a template symbol filled with `color`.
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            // sourceIn replaces the symbol's color (keeping its shape and the color's alpha);
            // sourceAtop would blend a translucent gray over black and stay dark.
            rect.fill(using: .sourceIn)
            return true
        }
    }
}

/// A slim overlay scroller: no track, a 4pt rounded knob that widens to 6pt under the pointer.
final class ThinScroller: NSScroller {
    private var hovering = false { didSet { needsDisplay = true } }

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 10 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let thickness: CGFloat = hovering ? 6 : 4
        let vertical = bounds.height >= bounds.width
        let rect = vertical
            ? NSRect(x: bounds.maxX - thickness - 2, y: knob.minY + 2, width: thickness, height: knob.height - 4)
            : NSRect(x: knob.minX + 2, y: bounds.maxY - thickness - 2, width: knob.width - 4, height: thickness)
        NSColor.labelColor.withAlphaComponent(hovering ? 0.35 : 0.22).setFill()
        NSBezierPath(roundedRect: rect, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}
