import AppKit
import UniformTypeIdentifiers

/// Resolve the semantic background in the view's current appearance, including live theme changes.
@MainActor
private final class EditorChromeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class EditorControlsDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class BackgroundEditorController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    var onClose: (() -> Void)?
    var onPin: ((NSImage) -> Void)?
    /// Called with the exported image after "Copy Image", so the pin shortcut can pin it.
    var onCopy: ((NSImage) -> Void)?
    /// The library entry this editor writes its annotations back to on close.
    var historyID: UUID?
    var annotations: [Annotation] { preview.commitTextEditing(restoreFocus: false); return preview.annotations }
    var captureStyle: CaptureStyle { CaptureStyle(preferences: preferences, background: preview.background) }
    private var toolButtons: [NSButton] = []
    private let strokePicker = NSPopUpButton()
    private let stepStylePicker = NSPopUpButton()
    private let mosaicStylePicker = NSPopUpButton()
    private let numberRect = NSButton(checkboxWithTitle: L("Number boxes", "画框自动编号"), target: nil, action: nil)
    private let textControls = AnnotationTextControls()
    private let strokeControls = NSStackView()
    private var toolbarHeight: NSLayoutConstraint?
    private let annotationColor = NSColorWell()
    private let quickActions: [ToolbarAction] = ToolKind.allCases.map { .tool($0) } + [.undo, .pin, .save, .cancel, .done]
    private let preview: BackgroundPreview
    private var revertButton: NSButton!
    /// 「还原原图」: this image shows and exports as captured; the default style is left alone.
    private var showsOriginal = false
    private let originalNote = NSTextField(wrappingLabelWithString: L(
        "Showing the screenshot as captured, without background, padding, or corners. Click Restore Style at the top to frame it again.",
        "当前是原始截图，没有背景、留白和圆角。点顶部的「恢复样式」可重新套用。"))
    private let backgroundPicker = NSPopUpButton()
    private let colorWell = NSColorWell()
    private let borderColorWell = NSColorWell()
    private let gradientStart = NSColorWell()
    private let gradientEnd = NSColorWell()
    private let gradientAngle = NSSlider(value: 35, minValue: 0, maxValue: 360, target: nil, action: nil)
    private let gradientAngleLabel = NSTextField(labelWithString: "35°")
    /// The sidebar's settings column.
    private let controls = NSStackView()
    private let customGradientControls = NSStackView()
    private let gradientSwatches = NSStackView()
    private let backgroundColorRow = NSStackView()
    private var backgroundImageButton: NSButton!
    private let photoSwatches = NSStackView()
    private var photoButtons: [NSButton] = []
    /// The bundled photo shown as the image background; nil while it's an imported image.
    private var selectedPhoto: String?
    private var gradientButtons: [NSButton] = []
    private var preferences = BackgroundPreferences.load()
    private let dimensions = NSTextField(labelWithString: "")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let operationFeedback = WindowFeedback()
    private let zoomLabel = NSTextField(labelWithString: "")
    private var sliders: [NSSlider] = []
    private var values: [NSTextField] = []
    private let shadowButton = NSButton(checkboxWithTitle: L("Soft shadow", "柔和阴影"), target: nil, action: nil)
    private let adaptToImage = NSButton(checkboxWithTitle: L("Fit to screenshot size", "按截图大小自动调整"), target: nil, action: nil)
    private var wallpaper: NSImage?
    /// The screen the capture came from, whose wallpaper the "Desktop Wallpaper" background uses.
    private let screen: NSScreen?
    private var customImage: NSImage?
    private var selectedBackground = 0
    private var usesCustomGradient = false
    private var selectedGradient = 0
    private let watermarkEnabled = NSButton(checkboxWithTitle: L("Add watermark", "添加水印"), target: nil, action: nil)
    private let watermarkText = NSTextField(string: "")
    private let watermarkPosition = NSPopUpButton()
    /// Where the watermark was last dragged, kept so switching back to「自定义」restores it.
    private var watermarkCenter: CGPoint?
    /// The single-watermark placement behind「自定义」: a saved corner preset (0–8) until it is first dragged, then custom.
    private var watermarkSinglePosition = 8
    private let watermarkFont = NSPopUpButton()
    private let watermarkBold = NSButton(checkboxWithTitle: L("Bold", "粗体"), target: nil, action: nil)
    private let watermarkSize = NSSlider(value: 32, minValue: Double(BackgroundPreferences.Watermark.fontSizeRange.lowerBound),
                                         maxValue: 200, target: nil, action: nil)
    private let watermarkSizeField = NSTextField(string: "32")
    private let watermarkColor = NSColorWell()
    private let watermarkOpacity = NSSlider(value: 60, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let watermarkOpacityLabel = NSTextField(labelWithString: "60%")
    private let watermarkDetails = NSStackView()
    private let fontFamilies = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    init(image: NSImage, screen: NSScreen?, annotations: [Annotation] = [], style: BackgroundPreferences? = nil) {
        // A library item keeps its own style; a new screenshot gets the last style fitted to its size.
        if let style {
            preferences = style
        } else if let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            preferences = preferences.adapted(toPixels: CGSize(width: pixels.width, height: pixels.height))
        }
        preview = BackgroundPreview(image: image, annotations: annotations)
        self.screen = screen ?? NSScreen.main
        wallpaper = DesktopWallpaper.cached(for: self.screen)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1060, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = AppChannel.displayName + L(" · Edit Image", " · 编辑图片")
        window.minSize = CGSize(width: 880, height: 640)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        [annotationColor, colorWell, borderColorWell, gradientStart, gradientEnd, watermarkColor].forEach { $0.useCompactSwatch() }
        window.delegate = self
        buildInterface()
        // Read before `restorePreferences` falls back from a wallpaper it can't show yet.
        let wantsWallpaper = preferences.backgroundType == 1
        restorePreferences()
        syncOriginalMode()
        refreshWallpaper(select: wantsWallpaper)
        preview.onChange = { [weak self] in self?.syncTools() }
        preview.onCommand = { [weak self] action in self?.performQuickAction(action) }
        preview.onViewportChange = { [weak self] in self?.updateZoomLabel() }
        preview.onWatermarkMove = { [weak self] center in
            guard let self else { return }
            self.watermarkCenter = center
            self.watermarkSinglePosition = BackgroundPreferences.Watermark.customPosition
            self.watermarkPosition.selectItem(withTag: BackgroundPreferences.Watermark.customPosition)
            self.updateComposition()
        }
        syncTools()
        updateZoomLabel()
        window.makeFirstResponder(preview)
        window.center()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        return button
    }

    private func buildInterface() {
        guard let root = window?.contentView else { return }
        let header = EditorChromeView()
        let toolbar = makeQuickToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        let sidebar = EditorChromeView()
        [header, sidebar, preview].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        let title = label(L("Edit Image", "编辑图片"), size: 19, weight: .semibold)
        let subtitle = label(L("Annotate your image and adjust the background and padding.", "标注图片，调整背景与留白。"), size: 12)
        subtitle.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [title, subtitle])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 5
        let copy = button(L("Copy Image", "复制图片"), action: #selector(copyOutput))
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = .command
        let save = button(L("Save PNG", "保存 PNG"), action: #selector(saveOutput))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        save.bezelColor = Brand.accent
        revertButton = button(L("Revert to Original", "还原原图"), action: #selector(revertToOriginal))
        revertButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        revertButton.imagePosition = .imageLeading
        let actions = NSStackView(views: [revertButton, makeAIMenu(), copy, save])
        actions.spacing = 10
        [titleStack, actions].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; header.addSubview($0) }
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 16
        controls.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = EditorControlsDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(controls)
        scroll.documentView = document
        sidebar.addSubview(scroll)
        toolbarHeight = toolbar.heightAnchor.constraint(equalToConstant: 126)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor), header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 82),
            titleStack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24), titleStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20), actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            sidebar.topAnchor.constraint(equalTo: header.bottomAnchor), sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.trailingAnchor.constraint(equalTo: root.trailingAnchor), sidebar.widthAnchor.constraint(equalToConstant: 280),
            preview.topAnchor.constraint(equalTo: header.bottomAnchor), preview.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor), preview.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: root.bottomAnchor), toolbarHeight!,
            scroll.topAnchor.constraint(equalTo: sidebar.topAnchor), scroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            controls.topAnchor.constraint(equalTo: document.topAnchor, constant: 24), controls.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            controls.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            controls.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        func add(_ view: NSView) {
            controls.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        }
        originalNote.font = .systemFont(ofSize: 13)
        originalNote.textColor = .secondaryLabelColor
        originalNote.isHidden = true
        add(originalNote)
        add(label(L("Background", "背景"), size: 14, weight: .semibold))
        // Tags are the saved background types, so the menu order can differ from them.
        for (title, type) in [(L("Gradient", "渐变"), 0), (L("Solid Color", "纯色"), 2),
                              (L("Desktop Wallpaper", "当前桌面壁纸"), 1), (L("Custom Image", "自定义图片"), 3)] {
            backgroundPicker.addItem(withTitle: title)
            backgroundPicker.lastItem?.tag = type
        }
        backgroundPicker.target = self
        backgroundPicker.action = #selector(changeBackground)
        add(backgroundPicker)
        let swatches = gradientSwatches
        swatches.orientation = .vertical
        swatches.spacing = 8
        let presetNames = [L("Berry Pink", "莓粉"), L("Coastal Blue", "海岸蓝"), L("Twilight Purple", "暮光紫"), L("Sunrise", "日出"), L("Mint", "薄荷"), L("Peach", "蜜桃")]
        for rowIndex in 0..<2 {
            let row = NSStackView()
            row.spacing = 8
            row.distribution = .fillEqually
            for index in (rowIndex * 3)..<(rowIndex * 3 + 3) {
                let swatch = NSButton(image: NSImage(size: CGSize(width: 72, height: 36), flipped: false) { rect in
                    EditorBackground.gradient(index).draw(in: rect)
                    return true
                }, target: self, action: #selector(selectPreset(_:)))
                swatch.tag = index
                swatch.isBordered = false
                swatch.imageScaling = .scaleAxesIndependently
                swatch.toolTip = presetNames[index]
                swatch.setAccessibilityLabel(presetNames[index])
                swatch.heightAnchor.constraint(equalToConstant: 36).isActive = true
                swatch.wantsLayer = true
                swatch.layer?.cornerRadius = 6
                swatch.layer?.masksToBounds = true
                gradientButtons.append(swatch)
                row.addArrangedSubview(swatch)
            }
            swatches.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: swatches.widthAnchor).isActive = true
        }
        add(swatches)
        customGradientControls.orientation = .vertical
        customGradientControls.alignment = .leading
        customGradientControls.spacing = 10
        [gradientStart, gradientEnd].forEach {
            $0.target = self
            $0.action = #selector(changeCustomGradient)
        }
        gradientStart.setAccessibilityLabel(L("Gradient start color", "渐变起始颜色"))
        gradientEnd.setAccessibilityLabel(L("Gradient end color", "渐变结束颜色"))
        let gradientColors = NSStackView(views: [label(L("Start", "起始"), size: 12), gradientStart, label(L("End", "结束"), size: 12), gradientEnd])
        gradientColors.spacing = 10
        customGradientControls.addArrangedSubview(gradientColors)
        gradientAngle.target = self
        gradientAngle.action = #selector(changeCustomGradient)
        gradientAngle.isContinuous = true
        gradientAngle.setAccessibilityLabel(L("Gradient angle", "渐变角度"))
        gradientAngleLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        gradientAngleLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        let gradientDirection = NSStackView(views: [label(L("Angle", "方向"), size: 12), gradientAngle, gradientAngleLabel])
        gradientDirection.spacing = 8
        customGradientControls.addArrangedSubview(gradientDirection)
        gradientDirection.widthAnchor.constraint(equalTo: customGradientControls.widthAnchor).isActive = true
        add(customGradientControls)
        photoSwatches.orientation = .vertical
        photoSwatches.spacing = 8
        let photos = BackgroundPhotos.all
        for rowStart in stride(from: 0, to: photos.count, by: 3) {
            let row = NSStackView()
            row.spacing = 8
            row.distribution = .fillEqually
            for (index, photo) in photos.enumerated() where index >= rowStart && index < rowStart + 3 {
                let swatch = NSButton(image: BackgroundPhotos.thumbnail(photo.name) ?? NSImage(), target: self, action: #selector(selectPhoto(_:)))
                swatch.tag = index
                swatch.isBordered = false
                swatch.imageScaling = .scaleAxesIndependently
                swatch.toolTip = photo.title
                swatch.setAccessibilityLabel(photo.title)
                swatch.heightAnchor.constraint(equalTo: swatch.widthAnchor, multiplier: 2.0 / 3.0).isActive = true
                swatch.wantsLayer = true
                swatch.layer?.cornerRadius = 6
                swatch.layer?.masksToBounds = true
                photoButtons.append(swatch)
                row.addArrangedSubview(swatch)
            }
            photoSwatches.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: photoSwatches.widthAnchor).isActive = true
        }
        add(photoSwatches)
        backgroundImageButton = button(L("Choose Background Image…", "选择背景图片…"), action: #selector(importBackground))
        add(backgroundImageButton)
        colorWell.color = NSColor(srgbRed: 0.96, green: 0.90, blue: 0.94, alpha: 1)
        colorWell.target = self
        colorWell.action = #selector(changeColor)
        colorWell.setAccessibilityLabel(L("Custom background color", "自定义背景颜色"))
        let colorRow = backgroundColorRow
        colorRow.setViews([label(L("Custom color", "自选颜色"), size: 12), colorWell], in: .leading)
        colorRow.spacing = 12
        add(colorRow)
        add(label(L("Padding", "留白"), size: 14, weight: .semibold))
        add(controlRow(L("Horizontal", "左右"), value: 120, maximum: 600, tag: 0))
        add(controlRow(L("Vertical", "上下"), value: 120, maximum: 600, tag: 1))
        adaptToImage.target = self
        adaptToImage.action = #selector(updateComposition)
        adaptToImage.toolTip = L("Padding, corners, and the watermark keep their proportions on screenshots of other sizes.",
                                 "换一张大小不同的截图时，留白、圆角和水印按比例缩放，保持同样的观感。")
        add(adaptToImage)
        add(label(L("Appearance", "截图外观"), size: 14, weight: .semibold))
        add(controlRow(L("Border", "描边"), value: 0, maximum: 20, tag: 2))
        borderColorWell.color = .white
        borderColorWell.target = self
        borderColorWell.action = #selector(updateComposition)
        borderColorWell.setAccessibilityLabel(L("Border color", "描边颜色"))
        let borderColorRow = NSStackView(views: [label(L("Border color", "描边颜色"), size: 12), borderColorWell])
        borderColorRow.spacing = 12
        add(borderColorRow)
        add(controlRow(L("Corner radius", "圆角"), value: 16, maximum: 80, tag: 3))
        shadowButton.state = .on
        shadowButton.target = self
        shadowButton.action = #selector(updateComposition)
        add(shadowButton)
        controls.setCustomSpacing(24, after: shadowButton)
        add(label(L("Watermark", "水印"), size: 14, weight: .semibold))
        add(makeWatermarkControls())
        dimensions.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        dimensions.textColor = .secondaryLabelColor
        add(dimensions)
        feedback.font = .systemFont(ofSize: 11)
        feedback.textColor = .secondaryLabelColor
        add(feedback)
    }

    // MARK: Watermark

    private func makeWatermarkControls() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 10
        watermarkEnabled.target = self
        watermarkEnabled.action = #selector(changeWatermark)
        container.addArrangedSubview(watermarkEnabled)

        watermarkDetails.orientation = .vertical
        watermarkDetails.alignment = .leading
        watermarkDetails.spacing = 10
        func row(_ title: String, _ views: [NSView]) -> NSStackView {
            let caption = label(title, size: 12)
            caption.widthAnchor.constraint(equalToConstant: 44).isActive = true
            let row = NSStackView(views: [caption] + views)
            row.spacing = 8
            watermarkDetails.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: watermarkDetails.widthAnchor).isActive = true
            return row
        }
        watermarkText.placeholderString = L("e.g. © Your Name", "例如：© 你的名字")
        watermarkText.delegate = self
        watermarkText.target = self
        watermarkText.action = #selector(changeWatermark)
        watermarkText.setAccessibilityLabel(L("Watermark text", "水印文字"))
        _ = row(L("Text", "文字"), [watermarkText])

        // Tags are saved positions; corner presets from older settings still render and show as「自定义」.
        for (title, position) in [(L("Custom (drag in preview)", "自定义（在预览中拖动）"), BackgroundPreferences.Watermark.customPosition),
                                  (L("Tiled", "平铺满图"), BackgroundWatermark.Position.tiled.rawValue)] {
            watermarkPosition.addItem(withTitle: title)
            watermarkPosition.lastItem?.tag = position
        }
        watermarkPosition.target = self
        watermarkPosition.action = #selector(changeWatermark)
        watermarkPosition.setAccessibilityLabel(L("Watermark position", "水印位置"))
        _ = row(L("Position", "位置"), [watermarkPosition])

        watermarkFont.addItem(withTitle: L("System Font", "系统字体"))
        watermarkFont.menu?.addItem(.separator())
        for family in fontFamilies {
            watermarkFont.addItem(withTitle: family)
            if let font = NSFont(name: family, size: 13) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13) {
                watermarkFont.lastItem?.attributedTitle = NSAttributedString(string: family, attributes: [.font: font])
            }
        }
        watermarkFont.target = self
        watermarkFont.action = #selector(changeWatermark)
        watermarkFont.setAccessibilityLabel(L("Watermark font", "水印字体"))
        _ = row(L("Font", "字体"), [watermarkFont])

        watermarkSize.target = self
        watermarkSize.action = #selector(changeWatermarkSize)
        watermarkSize.isContinuous = true
        watermarkSize.setAccessibilityLabel(L("Watermark size (pixels)", "水印字号（像素）"))
        watermarkSizeField.alignment = .right
        watermarkSizeField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        watermarkSizeField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        watermarkSizeField.target = self
        watermarkSizeField.action = #selector(changeWatermarkSizeField)
        watermarkSizeField.delegate = self
        watermarkSizeField.setAccessibilityLabel(L("Watermark size (pixels)", "水印字号（像素）"))
        _ = row(L("Size", "字号"), [watermarkSize, watermarkSizeField, label("px", size: 11)])

        watermarkBold.target = self
        watermarkBold.action = #selector(changeWatermark)
        watermarkColor.target = self
        watermarkColor.action = #selector(changeWatermark)
        watermarkColor.setAccessibilityLabel(L("Watermark color", "水印颜色"))
        _ = row(L("Color", "颜色"), [watermarkColor, watermarkBold])

        watermarkOpacity.target = self
        watermarkOpacity.action = #selector(changeWatermark)
        watermarkOpacity.isContinuous = true
        watermarkOpacity.setAccessibilityLabel(L("Watermark opacity", "水印不透明度"))
        watermarkOpacityLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        watermarkOpacityLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        _ = row(L("Opacity", "透明度"), [watermarkOpacity, watermarkOpacityLabel])

        let hint = NSTextField(wrappingLabelWithString: L("Saved as your default and added automatically to future exports.",
                                                          "会记住设置，之后导出的图片都会自动加上。"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        watermarkDetails.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: watermarkDetails.widthAnchor).isActive = true

        container.addArrangedSubview(watermarkDetails)
        watermarkDetails.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        return container
    }

    private var watermarkSettings: BackgroundPreferences.Watermark {
        let fontIndex = watermarkFont.indexOfSelectedItem
        return BackgroundPreferences.Watermark(
            enabled: watermarkEnabled.state == .on,
            text: watermarkText.stringValue,
            fontFamily: fontIndex >= 2 ? fontFamilies[fontIndex - 2] : nil,
            bold: watermarkBold.state == .on,
            fontSize: watermarkSize.integerValue,
            color: Self.components(watermarkColor.color),
            opacity: watermarkOpacity.doubleValue / 100,
            position: watermarkPosition.selectedTag() == BackgroundWatermark.Position.tiled.rawValue
                ? BackgroundWatermark.Position.tiled.rawValue : watermarkSinglePosition,
            center: watermarkCenter.map { [$0.x, $0.y] }
        ).normalized()
    }

    private func restoreWatermark() {
        let value = (preferences.watermark ?? .init()).normalized()
        watermarkEnabled.state = value.enabled ? .on : .off
        watermarkText.stringValue = value.text
        let tiled = BackgroundWatermark.Position.tiled.rawValue
        watermarkSinglePosition = value.position != tiled ? value.position
            : value.center != nil ? BackgroundPreferences.Watermark.customPosition : 8
        watermarkPosition.selectItem(withTag: value.position == tiled ? tiled : BackgroundPreferences.Watermark.customPosition)
        watermarkCenter = value.center.map { CGPoint(x: $0[0], y: $0[1]) }
        if let family = value.fontFamily, let index = fontFamilies.firstIndex(of: family) {
            watermarkFont.selectItem(at: index + 2)
        } else { watermarkFont.selectItem(at: 0) }
        watermarkBold.state = value.bold ? .on : .off
        watermarkSize.maxValue = max(watermarkSize.maxValue, Double(value.fontSize))
        watermarkSize.integerValue = value.fontSize
        watermarkSizeField.integerValue = value.fontSize
        watermarkColor.color = Self.color(value.color)
        watermarkOpacity.doubleValue = (value.opacity * 100).rounded()
        syncWatermarkControls()
    }

    private func syncWatermarkControls() {
        watermarkDetails.isHidden = watermarkEnabled.state != .on
        watermarkOpacityLabel.stringValue = "\(watermarkOpacity.integerValue)%"
    }

    @objc private func changeWatermark() {
        watermarkOpacity.doubleValue = watermarkOpacity.doubleValue.rounded()
        syncWatermarkControls()
        updateComposition()
    }

    @objc private func changeWatermarkSize() {
        watermarkSize.doubleValue = watermarkSize.doubleValue.rounded()
        watermarkSizeField.integerValue = watermarkSize.integerValue
        changeWatermark()
    }

    @objc private func changeWatermarkSizeField() {
        let range = BackgroundPreferences.Watermark.fontSizeRange
        let entered = Double(watermarkSizeField.stringValue) ?? watermarkSize.doubleValue
        let size = entered.isFinite ? min(max(Int(entered.rounded()), range.lowerBound), range.upperBound) : watermarkSize.integerValue
        // Typed sizes may exceed the slider's comfortable range.
        watermarkSize.maxValue = max(200, Double(size))
        watermarkSize.integerValue = size
        watermarkSizeField.integerValue = size
        changeWatermark()
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === watermarkText { changeWatermark() }
    }

    private func makeQuickToolbar() -> NSView {
        let bar = EditorChromeView()
        let tools = NSStackView()
        tools.spacing = 6
        let select = NSButton(image: NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: L("Select and move annotations", "选择和移动标注"))!, target: self, action: #selector(selectAnnotation))
        let selectKey = ToolShortcuts.hotKey(for: ToolShortcuts.select).key
        select.toolTip = L("Select and move (\(selectKey)) · Double-click to edit text · Delete to remove", "选择和移动标注（\(selectKey)）· 双击编辑文字 · Delete 删除")
        select.bezelStyle = .rounded
        select.widthAnchor.constraint(equalToConstant: 32).isActive = true
        tools.addArrangedSubview(select)
        for (index, action) in quickActions.enumerated() {
            let title = action == .cancel ? L("Close Editor (⌘W)", "关闭编辑（⌘W）") : action == .done ? L("Copy Image (⌘C)", "复制图片（⌘C）") : action.title ?? ""
            let item = NSButton(image: NSImage(systemSymbolName: action.symbol!, accessibilityDescription: title)!, target: self, action: #selector(quickAction(_:)))
            item.tag = index
            item.toolTip = title
            item.bezelStyle = .rounded
            item.widthAnchor.constraint(equalToConstant: 32).isActive = true
            if action == .cancel { item.keyEquivalent = "w"; item.keyEquivalentModifierMask = .command }
            tools.addArrangedSubview(item)
            toolButtons.append(item)
        }
        strokePicker.addItems(withTitles: [L("Thin / Small", "细 / 小"), L("Medium", "中"), L("Thick / Large", "粗 / 大")])
        strokePicker.selectItem(at: 1)
        strokePicker.target = self
        strokePicker.action = #selector(changeAnnotationStyle)
        strokePicker.setAccessibilityLabel(L("Annotation stroke or text size", "标注线宽或文字大小"))
        strokePicker.toolTip = L("1 / 2 / 3: small / medium / large · [ / ]: decrease / increase", "1 / 2 / 3：小 / 中 / 大 · [ / ]：减小 / 增大")
        annotationColor.color = preview.selectedColor
        annotationColor.target = self
        annotationColor.action = #selector(changeAnnotationStyle)
        annotationColor.setAccessibilityLabel(L("Annotation color", "标注颜色"))
        strokeControls.addArrangedSubview(label(L("Size", "大小"), size: 11))
        strokeControls.addArrangedSubview(strokePicker)
        strokeControls.spacing = 10
        textControls.onChange = { [weak self] style in
            guard let self else { return }
            self.preview.textStyle = style
            self.preview.applyStyle()
        }
        textControls.widthAnchor.constraint(equalToConstant: 288).isActive = true
        stepStylePicker.addItems(withTitles: StepMarkerStyle.allCases.map(\.title))
        stepStylePicker.target = self
        stepStylePicker.action = #selector(changeStepStyle)
        stepStylePicker.setAccessibilityLabel(L("Number style", "编号样式"))
        numberRect.target = self
        numberRect.action = #selector(changeNumberRect)
        mosaicStylePicker.addItems(withTitles: MosaicStyle.mosaicStyles.map(\.title))
        mosaicStylePicker.target = self
        mosaicStylePicker.action = #selector(changeMosaicStyle)
        mosaicStylePicker.setAccessibilityLabel(L("Mosaic style", "马赛克样式"))
        mosaicStylePicker.toolTip = L("Box styles: drag out a rectangle · Brush: paint freely", "框选样式：拖出一个矩形 · 涂抹：按住随意涂")
        let numberOptions = NSStackView(views: [mosaicStylePicker, numberRect, stepStylePicker])
        numberOptions.spacing = 10
        let options = NSStackView(views: [strokeControls, textControls, label(L("Color", "颜色"), size: 11), annotationColor])
        options.spacing = 10
        for (index, color) in Style.colors.enumerated() {
            let image = NSImage(size: CGSize(width: 22, height: 22), flipped: false) { rect in
                let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
                color.setFill()
                circle.fill()
                NSColor.gray.withAlphaComponent(0.45).setStroke()
                circle.lineWidth = 0.7
                circle.stroke()
                return true
            }
            let swatch = NSButton(image: image, target: self, action: #selector(selectAnnotationColor(_:)))
            swatch.tag = index
            swatch.isBordered = false
            swatch.widthAnchor.constraint(equalToConstant: 22).isActive = true
            swatch.setAccessibilityLabel([L("Red", "红色"), L("Yellow", "黄色"), L("Green", "绿色"), L("Blue", "蓝色"), L("Black", "黑色"), L("White", "白色")][index])
            options.addArrangedSubview(swatch)
        }
        let zoomOut = NSButton(title: "−", target: self, action: #selector(zoomOut))
        let zoomIn = NSButton(title: "+", target: self, action: #selector(zoomIn))
        let actualSize = NSButton(title: "100%", target: self, action: #selector(actualSize))
        let fit = NSButton(title: L("Fit", "适应窗口"), target: self, action: #selector(fitPreview))
        for item in [zoomOut, zoomIn, actualSize, fit] { item.bezelStyle = .rounded }
        zoomOut.toolTip = L("Zoom out (⌘−)", "缩小（⌘−）")
        zoomIn.toolTip = L("Zoom in (⌘+)", "放大（⌘+）")
        fit.toolTip = L("Fit image to window (⌘0)", "适应窗口（⌘0）")
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.alignment = .center
        zoomLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let hint = label(L("Scroll to pan · Pinch to zoom", "滚动移动 · 双指捏合缩放"), size: 11)
        hint.textColor = .secondaryLabelColor
        let zoomControls = NSStackView(views: [zoomOut, zoomLabel, zoomIn, actualSize, fit, hint])
        zoomControls.spacing = 6
        [tools, options, numberOptions, zoomControls].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview($0) }
        NSLayoutConstraint.activate([
            tools.centerXAnchor.constraint(equalTo: bar.centerXAnchor), tools.topAnchor.constraint(equalTo: bar.topAnchor, constant: 12),
            options.centerXAnchor.constraint(equalTo: bar.centerXAnchor), options.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 10),
            numberOptions.centerXAnchor.constraint(equalTo: bar.centerXAnchor), numberOptions.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 6),
            zoomControls.centerXAnchor.constraint(equalTo: bar.centerXAnchor), zoomControls.topAnchor.constraint(equalTo: numberOptions.bottomAnchor, constant: 8)
        ])
        return bar
    }

    @objc private func selectAnnotation() { preview.chooseTool(nil) }
    private func updateZoomLabel() { zoomLabel.stringValue = "\(Int((preview.zoom * 100).rounded()))%" }
    @objc private func zoomOut() { preview.zoomBy(0.8) }
    @objc private func zoomIn() { preview.zoomBy(1.25) }
    @objc private func actualSize() { preview.setZoom(1) }
    @objc private func fitPreview() { preview.fitToWindow() }
    @objc private func quickAction(_ sender: NSButton) { performQuickAction(quickActions[sender.tag]) }
    /// Esc with the focus outside the canvas (a slider, a picker): close, as the toolbar's ✕ does. The canvas and
    /// text fields handle Esc themselves first.
    override func cancelOperation(_ sender: Any?) {
        window?.close()
    }

    private func performQuickAction(_ action: ToolbarAction) {
        switch action {
        case .tool(let tool): preview.chooseTool(preview.selectedTool == tool ? nil : tool)
        case .undo: preview.undoEdit()
        case .pin: if let image = output() { onPin?(image) }
        case .save: saveOutput()
        case .done: copyOutput()
        case .cancel: window?.close()
        default: break
        }
    }
    @objc private func changeAnnotationStyle() {
        preview.sizeLevel = strokePicker.indexOfSelectedItem
        preview.selectedColor = annotationColor.color
        preview.applyStyle()
    }
    @objc private func changeStepStyle() {
        preview.stepStyle = StepMarkerStyle.allCases[stepStylePicker.indexOfSelectedItem]
        preview.applyStyle()
    }
    @objc private func changeMosaicStyle() {
        let style = MosaicStyle.mosaicStyles[max(0, mosaicStylePicker.indexOfSelectedItem)]
        preview.mosaicStyle = style
        MosaicStyle.current = style
        preview.applyStyle()
    }
    @objc private func changeNumberRect() {
        preview.setNumberRect(numberRect.state == .on)
    }
    @objc private func selectAnnotationColor(_ sender: NSButton) {
        annotationColor.color = Style.colors[sender.tag]
        changeAnnotationStyle()
    }
    private func syncTools() {
        textControls.isHidden = !preview.usesTextStyle
        strokeControls.isHidden = preview.usesTextStyle
        stepStylePicker.isHidden = !preview.usesStepStyle
        numberRect.isHidden = !preview.usesRectStyle
        numberRect.state = preview.autoNumberRect ? .on : .off
        mosaicStylePicker.isHidden = !preview.usesMosaicStyle
        mosaicStylePicker.selectItem(at: MosaicStyle.mosaicStyles.firstIndex(of: preview.mosaicStyle) ?? 0)
        toolbarHeight?.constant = preview.usesStepStyle || preview.usesRectStyle || preview.usesMosaicStyle ? 154 : 126
        stepStylePicker.selectItem(at: StepMarkerStyle.allCases.firstIndex(of: preview.stepStyle) ?? 0)
        textControls.update(preview.textStyle, pixelScale: preview.pixelScale)
        for (index, button) in toolButtons.enumerated() {
            if case .tool(let tool) = quickActions[index] {
                button.contentTintColor = preview.selectedTool == tool ? Brand.accent : .labelColor
                button.state = preview.selectedTool == tool ? .on : .off
            }
        }
        strokePicker.selectItem(at: preview.sizeLevel)
        annotationColor.color = preview.selectedColor
    }

    private func controlRow(_ title: String, value: Double, maximum: Double, tag: Int) -> NSView {
        let slider = NSSlider(value: value, minValue: 0, maxValue: maximum, target: self, action: #selector(sliderChanged(_:)))
        slider.tag = tag
        slider.isContinuous = true
        slider.setAccessibilityLabel(title + L(" (pixels)", "（像素）"))
        let field = NSTextField(string: String(Int(value)))
        field.tag = tag
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.widthAnchor.constraint(equalToConstant: 44).isActive = true
        field.target = self
        field.action = #selector(valueChanged(_:))
        field.delegate = self
        field.setAccessibilityLabel(title + L(" (pixels)", "（像素）"))
        let row = NSStackView(views: [label(title, size: 12), slider, field, label("px", size: 11)])
        row.spacing = 7
        sliders.append(slider)
        values.append(field)
        return row
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        sender.doubleValue = sender.doubleValue.rounded()
        values[sender.tag].integerValue = sender.integerValue
        updateComposition()
    }

    @objc private func valueChanged(_ sender: NSTextField) {
        let slider = sliders[sender.tag]
        let entered = Double(sender.stringValue) ?? slider.doubleValue
        slider.doubleValue = entered.isFinite ? min(max(entered.rounded(), 0), slider.maxValue) : slider.doubleValue
        sender.integerValue = slider.integerValue
        updateComposition()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField, values.contains(field) { valueChanged(field) }
        if (obj.object as? NSTextField) === watermarkSizeField { changeWatermarkSizeField() }
    }

    @objc private func updateComposition() {
        guard !showsOriginal else {
            preview.composition = .plain
            savePreferences()
            refresh()
            return
        }
        preview.composition = BackgroundLayout(horizontalPadding: CGFloat(sliders[0].integerValue),
                                               verticalPadding: CGFloat(sliders[1].integerValue),
                                               cornerRadius: CGFloat(sliders[3].integerValue), shadow: shadowButton.state == .on,
                                               borderWidth: CGFloat(sliders[2].integerValue), borderColor: borderColorWell.color,
                                               watermark: BackgroundWatermark(preferences: watermarkSettings))
        savePreferences()
        refresh()
    }

    @objc private func selectPhoto(_ sender: NSButton) {
        let name = BackgroundPhotos.all[sender.tag].name
        guard let photo = BackgroundPhotos.image(name) else { return }
        customImage = photo
        selectedPhoto = name
        backgroundPicker.selectItem(withTag: 3)
        changeBackground()
    }

    @objc private func selectPreset(_ sender: NSButton) {
        selectedGradient = sender.tag
        usesCustomGradient = false
        restorePresetControls()
        backgroundPicker.selectItem(withTag: 0)
        changeBackground()
    }

    /// Captures the wallpaper as the desktop shows it (the file is a placeholder for dynamic and Aerial wallpapers),
    /// then shows it if the wallpaper background is chosen, or `select` asks for it.
    private func refreshWallpaper(select: Bool, onFailure: (() -> Void)? = nil) {
        Task { [weak self] in
            guard let self else { return }
            guard let fresh = await DesktopWallpaper.capture(for: screen) else {
                if wallpaper == nil { onFailure?() }
                return
            }
            wallpaper = fresh
            guard select || backgroundPicker.selectedTag() == 1 else { return }
            selectedBackground = 1
            backgroundPicker.selectItem(withTag: 1)
            preview.background = .image(fresh)
        }
    }

    @objc private func changeBackground() {
        let index = backgroundPicker.selectedTag()
        switch index {
        case 0: preview.background = usesCustomGradient ? customGradientBackground() : .gradient(selectedGradient)
        case 1:
            guard let wallpaper else {
                // Not captured yet: try now, and only explain if that fails too.
                let previous = selectedBackground == 4 ? 0 : selectedBackground
                refreshWallpaper(select: true) { [weak self] in
                    guard let self else { return }
                    backgroundPicker.selectItem(withTag: previous)
                    operationFeedback.showError(L("Unable to read the desktop wallpaper. Allow Screen Recording in System Settings, or choose a background image.",
                                                  "无法读取当前壁纸。请在系统设置里允许屏幕录制，或选择背景图片。"), in: window)
                }
                return
            }
            preview.background = .image(wallpaper)
        case 2: preview.background = .color(colorWell.color)
        case 3:
            if customImage == nil, let first = BackgroundPhotos.all.first, let photo = BackgroundPhotos.image(first.name) {
                customImage = photo
                selectedPhoto = first.name
            }
            guard let customImage else { importBackground(); return }
            preview.background = .image(customImage)
        default: preview.background = customGradientBackground()
        }
        selectedBackground = index == 0 && usesCustomGradient ? 4 : index
        syncGradientControls()
        savePreferences()
        refresh()
    }

    private func customGradientBackground() -> EditorBackground {
        .customGradient(start: gradientStart.color, end: gradientEnd.color, angle: CGFloat(gradientAngle.doubleValue))
    }

    @objc private func changeCustomGradient() {
        gradientAngle.integerValue = Int(gradientAngle.doubleValue.rounded())
        usesCustomGradient = true
        backgroundPicker.selectItem(withTag: 0)
        changeBackground()
    }

    private func restorePresetControls() {
        let palette = EditorBackground.palettes[selectedGradient]
        gradientStart.color = palette.first!
        gradientEnd.color = palette.last!
        gradientAngle.doubleValue = 35
    }

    private func syncGradientControls() {
        // Show only the options for the chosen background type.
        let isGradient = selectedBackground == 0 || selectedBackground == 4
        let options: [(NSView, Bool)] = [
            (gradientSwatches, isGradient), (customGradientControls, isGradient),
            (photoSwatches, selectedBackground == 3), (backgroundImageButton, selectedBackground == 3),
            (backgroundColorRow, selectedBackground == 2)
        ]
        for (view, visible) in options {
            view.isHidden = !visible
            controls.setCustomSpacing(NSStackView.useDefaultSpacing, after: view)
        }
        controls.setCustomSpacing(NSStackView.useDefaultSpacing, after: backgroundPicker)
        let lastOption = options.last(where: { $0.1 })?.0 ?? backgroundPicker
        controls.setCustomSpacing(24, after: lastOption)
        gradientAngleLabel.stringValue = "\(gradientAngle.integerValue)°"
        for button in gradientButtons {
            button.layer?.borderWidth = selectedBackground == 0 && button.tag == selectedGradient ? 2 : 0
            button.layer?.borderColor = Brand.accent.cgColor
        }
        for button in photoButtons {
            let selected = selectedBackground == 3 && selectedPhoto == BackgroundPhotos.all[button.tag].name
            button.layer?.borderWidth = selected ? 2 : 0
            button.layer?.borderColor = Brand.accent.cgColor
        }
    }

    @objc private func changeColor() {
        backgroundPicker.selectItem(withTag: 2)
        changeBackground()
    }

    @objc private func importBackground() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L("Choose a background image. It will be centered and fill the canvas.", "选择一张背景图片，图片会居中铺满画布。")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                self.backgroundPicker.selectItem(withTag: self.selectedBackground == 4 ? 0 : self.selectedBackground)
                return
            }
            guard let image = NSImage(contentsOf: url), image.isValid,
                  image.size.width > 0, image.size.height > 0 else {
                self.backgroundPicker.selectItem(withTag: self.selectedBackground == 4 ? 0 : self.selectedBackground)
                self.operationFeedback.showError(L("Unable to read this image. Choose a PNG, JPEG, or HEIC file.", "无法读取这张图片，请选择 PNG、JPEG 或 HEIC。"), in: window)
                return
            }
            self.customImage = image
            self.selectedPhoto = nil
            self.preferences.customImagePath = url.path
            // Keep a local copy so the preference survives moving the imported file.
            if let data = image.tiffRepresentation {
                let folder = AppChannel.supportDirectory
                let savedURL = folder.appendingPathComponent("EditorBackground.tiff")
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: savedURL, options: .atomic)
                    self.preferences.customImagePath = savedURL.path
                } catch {
                    log("editor background persistence failed", error: error)
                }
            }
            self.backgroundPicker.selectItem(withTag: 3)
            self.changeBackground()
        }
    }

    private func restorePreferences() {
        showsOriginal = preferences.plain == true
        selectedGradient = min(max(preferences.gradient, 0), EditorBackground.palettes.count - 1)
        selectedBackground = preferences.backgroundType
        usesCustomGradient = preferences.backgroundType == 4 || preferences.usesCustomGradient == true
        if let name = preferences.backgroundPhoto, let photo = BackgroundPhotos.image(name) {
            customImage = photo
            selectedPhoto = name
        } else if let path = preferences.customImagePath {
            customImage = NSImage(contentsOfFile: path)
        }
        // Keep last-used image defaults independent of the lifetime of a library item.
        if selectedPhoto == nil, let customImage, let data = customImage.tiffRepresentation {
            let url = AppChannel.supportDirectory.appendingPathComponent("EditorBackground.tiff")
            if preferences.customImagePath != url.path {
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    preferences.customImagePath = url.path
                } catch { log("editor background defaults write failed", error: error) }
            }
        }
        if (selectedBackground == 1 && wallpaper == nil) || (selectedBackground == 3 && customImage == nil) {
            selectedBackground = 0
        }
        colorWell.color = Self.color(preferences.backgroundColor)
        borderColorWell.color = Self.color(preferences.borderColor)
        let gradient = preferences.customGradient ?? .init()
        gradientStart.color = Self.color(gradient.start)
        gradientEnd.color = Self.color(gradient.end)
        gradientAngle.doubleValue = gradient.angle
        if !usesCustomGradient { restorePresetControls() }
        let restored = [preferences.horizontalPadding, preferences.verticalPadding, preferences.borderWidth, preferences.cornerRadius]
        for (index, value) in restored.enumerated() {
            sliders[index].integerValue = value
            values[index].integerValue = value
        }
        shadowButton.state = preferences.shadow ? .on : .off
        adaptToImage.state = preferences.adaptsToImage == false ? .off : .on
        restoreWatermark()
        backgroundPicker.selectItem(withTag: selectedBackground == 4 ? 0 : selectedBackground)
        switch selectedBackground {
        case 1: preview.background = .image(wallpaper!)
        case 2: preview.background = .color(colorWell.color)
        case 3: preview.background = .image(customImage!)
        case 4: preview.background = customGradientBackground()
        default: preview.background = .gradient(selectedGradient)
        }
        syncGradientControls()
        updateComposition()
    }

    private func savePreferences() {
        preferences.backgroundType = selectedBackground
        preferences.gradient = selectedGradient
        preferences.usesCustomGradient = usesCustomGradient
        preferences.backgroundPhoto = selectedPhoto
        preferences.customGradient = .init(start: Self.components(gradientStart.color), end: Self.components(gradientEnd.color), angle: gradientAngle.doubleValue)
        preferences.horizontalPadding = sliders[0].integerValue
        preferences.verticalPadding = sliders[1].integerValue
        preferences.borderWidth = sliders[2].integerValue
        preferences.cornerRadius = sliders[3].integerValue
        preferences.shadow = shadowButton.state == .on
        preferences.backgroundColor = Self.components(colorWell.color)
        preferences.borderColor = Self.components(borderColorWell.color)
        preferences.watermark = watermarkSettings
        preferences.plain = showsOriginal ? true : nil
        preferences.adaptsToImage = adaptToImage.state == .on
        preferences.referenceSize = [Double(preview.source.width), Double(preview.source.height)]
        preferences.save()
    }

    private static func color(_ components: [Double]) -> NSColor {
        NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: components[3])
    }

    private static func components(_ color: NSColor) -> [Double] {
        let color = color.usingColorSpace(.sRGB) ?? .white
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
    }

    private func refresh() {
        preview.needsDisplay = true
        let size = preview.composition.canvasSize(for: CGSize(width: preview.source.width, height: preview.source.height))
        dimensions.stringValue = L("Export size  \(Int(size.width)) × \(Int(size.height)) px", "导出尺寸  \(Int(size.width)) × \(Int(size.height)) px")
        feedback.stringValue = L("Exports at the original resolution. Padding is measured in pixels.", "按原始截图分辨率导出，留白以像素计算。")
    }

    private func output() -> NSImage? {
        preview.commitTextEditing(restoreFocus: false)
        window?.makeFirstResponder(nil)
        let image = BackgroundRenderer.render(source: preview.source, background: preview.background, layout: preview.composition) { context in
            self.preview.drawAnnotations(in: context)
        }
        if image == nil { operationFeedback.showError(L("Image too large or insufficient memory. Reduce padding and try again.", "图片尺寸过大或内存不足，请减小留白后重试。"), in: window) }
        return image
    }

    @objc private func copyOutput() {
        guard let image = output() else { return }
        ImageExport.copy(image)
        onCopy?(image)
        operationFeedback.show(L("Copied to clipboard.", "已复制到剪贴板。"), in: window)
    }

    @objc private func saveOutput() {
        guard let image = output() else { return }
        switch ImageExport.save(image) {
        case .saved: operationFeedback.show(L("Image saved.", "图片已保存。"), in: window)
        case .cancelled: break
        case .failed: operationFeedback.showError(L("Could not save. Choose another location and try again.", "保存失败，请选择其他位置后重试。"), in: window)
        }
    }

    func windowWillClose(_ notification: Notification) { preview.commitTextEditing(restoreFocus: false); operationFeedback.dismiss(); onClose?() }

    // MARK: AI tools

    /// Toggles 「还原原图」: back to the screenshot as captured (annotations cleared, ⌘Z restores them, and no frame for
    /// this image only), or framed again in the style panel's settings.
    @objc private func revertToOriginal() {
        if !showsOriginal { preview.removeAllAnnotations() }
        showsOriginal.toggle()
        syncOriginalMode()
        updateComposition()
        window?.makeFirstResponder(preview)
    }

    private func syncOriginalMode() {
        revertButton.title = showsOriginal ? L("Restore Style", "恢复样式") : L("Revert to Original", "还原原图")
        revertButton.image = NSImage(systemSymbolName: showsOriginal ? "paintpalette" : "arrow.counterclockwise", accessibilityDescription: nil)
        revertButton.toolTip = showsOriginal
            ? L("Frame this image again with the background and padding on the right.", "用右侧的背景、留白等样式重新装饰这张图。")
            : L("Remove all annotations and the background, back to the screenshot as captured. ⌘Z brings the annotations back; your default style doesn't change.",
                "清除所有标注和背景，回到截图时的样子；标注可用 ⌘Z 撤回，默认样式不受影响。")
        // The style controls don't apply to the plain screenshot, so they step aside for a note.
        for view in controls.arrangedSubviews where view !== dimensions && view !== feedback {
            view.isHidden = showsOriginal && view !== originalNote
        }
        originalNote.isHidden = !showsOriginal
        if !showsOriginal { syncGradientControls() }
    }

    private func makeAIMenu() -> NSPopUpButton {
        let menu = NSPopUpButton(frame: .zero, pullsDown: true)
        menu.controlSize = .large
        menu.addItem(withTitle: L("AI Tools", "AI 工具"))
        menu.item(at: 0)?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        func add(_ title: String, _ symbol: String?, _ action: Selector, indent: Int = 0) -> NSMenuItem {
            menu.addItem(withTitle: title)
            let item = menu.lastItem!
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            item.target = self
            item.action = action
            item.indentationLevel = indent
            return item
        }
        _ = add(L("Recognize Text", "识别文字"), "text.viewfinder", #selector(recognizeText))
        _ = add(L("Redact Sensitive Info", "打码敏感信息"), "eye.slash", #selector(redactSensitive))
            .toolTip = L("Phone numbers, emails, ID numbers, and keys", "手机号、邮箱、证件号、密钥")
        _ = add(L("Redact Avatars & Names", "打码头像和昵称"), "person.crop.circle.badge.xmark", #selector(redactIdentity))
            .toolTip = L("For chat screenshots", "适用于聊天截图")
        menu.menu?.addItem(.separator())
        // One click per language, no dialog; on-device translation works without a model or account.
        menu.addItem(withTitle: L("Translate Image", "翻译图片"))
        let translate = menu.lastItem!
        translate.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: nil)
        let languages = NSMenu()
        for target in TranslationTargets.all.map(\.name) {
            let item = languages.addItem(withTitle: target, action: #selector(translateText(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target
            item.state = target == AppSettings.lastTranslationTarget ? .on : .off
        }
        translate.submenu = languages
        _ = add(L("Ask Snapok Agent…", "问 Snapok Agent…"), "sparkles", #selector(askAgent))
        menu.toolTip = L("Recognition and redaction run on this Mac. Translating and Snapok Agent send the screenshot to your model or Snapok Cloud.",
                         "文字识别和打码在本机完成；翻译和 Snapok Agent 会把截图发送给你配置的模型或 Snapok 云端")
        return menu
    }

    /// What AI features see: the screenshot with the current annotations, so anything already masked stays masked.
    private var annotatedSource: CGImage? {
        preview.commitTextEditing(restoreFocus: false)
        return HistoryRenderer.render(original: preview.sourceImage, annotations: preview.annotations)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    @objc private func recognizeText() {
        Telemetry.capture("ai_used", ["feature": "ocr"])
        guard let image = annotatedSource else { return }
        AIResultWindowController.show(title: L("Recognized Text", "识别出的文字"), markdown: false, autoCopy: true,
                                      emptyText: L("No text recognized.", "没有识别到文字。"), near: window) {
            await TextScanner.scan(image).text
        }
    }

    /// Masks (normalized boxes) in image points, tagged so they can be removed as a group later.
    private func masks(_ boxes: [CGRect], _ kind: AutoRedactionKind) -> [Annotation] {
        let size = preview.sourceImage.size
        return boxes.map { box in
            var mask = SensitiveDetector.mosaic(covering: CGRect(
                x: box.minX * size.width, y: box.minY * size.height,
                width: box.width * size.width, height: box.height * size.height
            ))
            mask.autoRedaction = kind
            return mask
        }
    }

    /// Masks phone numbers, emails, ID numbers and keys. Running it again replaces its previous masks.
    @objc private func redactSensitive() {
        Telemetry.capture("ai_used", ["feature": "redact"])
        operationFeedback.show(L("Finding sensitive information…", "正在查找敏感信息…"), in: window, success: false)
        let source = preview.source
        Task { @MainActor in
            let boxes = await TextScanner.scan(source).sensitiveBoxes
            preview.replaceAutoRedaction(removing: [.sensitive], adding: masks(boxes, .sensitive))
            operationFeedback.show(boxes.isEmpty
                ? L("No phone numbers, emails, ID numbers, or keys found.", "没有发现手机号、邮箱、证件号或密钥。")
                : Self.redactionSummary(values: boxes.count, avatars: 0, names: 0), in: window)
        }
    }

    /// Masks chat avatars and the user names beside them. Running it again replaces its previous masks.
    @objc private func redactIdentity() {
        Telemetry.capture("ai_used", ["feature": "redact_identity"])
        operationFeedback.show(L("Finding avatars and user names…", "正在查找头像和昵称…"), in: window, success: false)
        let source = preview.source
        Task { @MainActor in
            let scan = await TextScanner.scan(source)
            let chat = await ChatRedactor.detect(image: source, blocks: scan.blocks)
            let candidates = RedactionCandidates.make(sensitive: scan.sensitiveBoxes, avatars: chat.avatars,
                                                      names: chat.names, blocks: scan.blocks)
            let boxes = AutoRedaction.identityBoxes(candidates)
            preview.replaceAutoRedaction(removing: [.chatIdentity], adding: masks(boxes, .chatIdentity))
            operationFeedback.show(boxes.isEmpty
                ? L("No chat avatars or user names found.", "没有识别到聊天头像或昵称。")
                : Self.redactionSummary(values: 0, avatars: RedactionCandidates.count(candidates, .avatar),
                                        names: RedactionCandidates.count(candidates, .name)), in: window)
        }
    }

    static func redactionSummary(values: Int, avatars: Int, names: Int) -> String {
        var english: [String] = [], chinese: [String] = []
        if values > 0 { english.append("\(values) sensitive values"); chinese.append("\(values) 处敏感信息") }
        if avatars > 0 { english.append("\(avatars) avatars"); chinese.append("\(avatars) 个头像") }
        if names > 0 { english.append("\(names) user names"); chinese.append("\(names) 个用户名") }
        return L("Redacted \(english.joined(separator: ", ")).",
                 "已打码：\(chinese.joined(separator: "、"))。")
    }

    /// Opens the translation panel for the picked language, where each block can be adjusted.
    @objc private func translateText(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? String, let image = annotatedSource else { return }
        sender.menu?.items.forEach { $0.state = $0 == sender ? .on : .off }
        AppSettings.lastTranslationTarget = target
        Telemetry.capture("ai_used", ["feature": "translate"])
        ImageTranslationWindowController.show(image: image, target: target, useVision: false, near: window)
    }

    /// Opens Snapok Agent with this screenshot (and its annotations) attached.
    private func openAgent(_ request: AgentRequest, feature: String) {
        Telemetry.capture("ai_used", ["feature": feature])
        guard let image = annotatedSource else { return }
        ImageAgentEntry.open?(NSImage(cgImage: image, size: preview.sourceImage.size), request)
    }

    @objc private func askAgent() { openAgent(.edit, feature: "agent_ask") }
}
