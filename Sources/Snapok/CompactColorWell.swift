import AppKit

extension NSColorWell {
    /// Preserve the native anchored color popover while keeping the entry point a small swatch.
    @MainActor
    func useCompactSwatch() {
        colorWellStyle = .minimal
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
}

/// A compact color well whose popover includes a clickable "Transparent" swatch.
/// The system popover's slashed "no color" cell can't be enabled by apps, so this well shows its own popover.
@MainActor
final class ClearableColorWell: NSColorWell {
    static let swatchColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue,
        .systemPink, .systemPurple, .systemBrown, .white, .systemGray, .black
    ]
    static let grayColors: [NSColor] = (0...11).map { NSColor(white: 1 - CGFloat($0) / 11, alpha: 1) }

    private var popover: NSPopover?

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        showSwatchPopover()
    }

    func showSwatchPopover() {
        popover?.close()
        let content = ColorSwatchGridController(current: color) { [weak self] picked in
            self?.pick(picked)
        } onMore: { [weak self] in
            self?.popover?.close()
            NSColorPanel.shared.showsAlpha = true
            self?.activate(true)
            NSColorPanel.shared.orderFront(nil)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        self.popover = popover
    }

    /// Transparent keeps the current hue with 0 alpha, so raising opacity later restores the color.
    func pick(_ picked: NSColor?) {
        if let picked {
            color = picked
        } else {
            let base = color.usingColorSpace(.sRGB) ?? .black
            color = base.withAlphaComponent(0)
        }
        popover?.close()
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }
}

@MainActor
private final class ColorSwatchGridController: NSViewController {
    private let current: NSColor
    private let onPick: (NSColor?) -> Void
    private let onMore: () -> Void

    init(current: NSColor, onPick: @escaping (NSColor?) -> Void, onMore: @escaping () -> Void) {
        self.current = current
        self.onPick = onPick
        self.onMore = onMore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let currentRGB = current.usingColorSpace(.sRGB)
        let isClear = (currentRGB?.alphaComponent ?? 1) < 0.005
        func matches(_ color: NSColor) -> Bool {
            guard !isClear, let a = currentRGB, let b = color.usingColorSpace(.sRGB) else { return false }
            return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
                && abs(a.blueComponent - b.blueComponent) < 0.01
        }

        let clear = SwatchButton(color: nil, selected: isClear) { [weak self] in self?.onPick(nil) }
        clear.toolTip = L("Transparent", "透明")
        clear.setAccessibilityLabel(L("Transparent", "透明"))
        let clearLabel = NSTextField(labelWithString: L("Transparent", "透明"))
        clearLabel.font = .systemFont(ofSize: 12)
        let clearRow = NSStackView(views: [clear, clearLabel])
        clearRow.spacing = 6

        func row(_ colors: [NSColor]) -> NSStackView {
            let views = colors.map { color in
                SwatchButton(color: color, selected: matches(color)) { [weak self] in self?.onPick(color) }
            }
            let stack = NSStackView(views: views)
            stack.spacing = 4
            return stack
        }

        let more = NSButton(title: L("More Colors…", "更多颜色…"), target: self, action: #selector(showMore))
        more.bezelStyle = .rounded
        more.controlSize = .small

        let stack = NSStackView(views: [clearRow, row(ClearableColorWell.swatchColors), row(ClearableColorWell.grayColors), more])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        view = stack
    }

    @objc private func showMore() { onMore() }
}

/// A clickable swatch; `color == nil` draws the transparent (checkerboard + red slash) swatch.
@MainActor
final class SwatchButton: NSButton {
    let swatchColor: NSColor?
    private let isCurrent: Bool
    private let handler: () -> Void

    init(color: NSColor?, selected: Bool, handler: @escaping () -> Void) {
        swatchColor = color
        isCurrent = selected
        self.handler = handler
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func clicked() { handler() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        if let swatchColor {
            swatchColor.setFill()
            path.fill()
        } else {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSColor.white.setFill()
            rect.fill()
            NSColor(white: 0.82, alpha: 1).setFill()
            let cell: CGFloat = 4
            var y = rect.minY
            var rowIndex = 0
            while y < rect.maxY {
                var x = rect.minX + (rowIndex % 2 == 0 ? 0 : cell)
                while x < rect.maxX {
                    NSRect(x: x, y: y, width: cell, height: cell).fill()
                    x += cell * 2
                }
                y += cell
                rowIndex += 1
            }
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX, y: rect.minY))
            slash.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            slash.lineWidth = 2
            NSColor.systemRed.setStroke()
            slash.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        if isCurrent {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4)
            ring.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }
}
