import AppKit

enum PinnedImageResize {
    static func regions(in bounds: CGRect) -> [(SelectionHandle, CGRect)] {
        let x = min(10, bounds.width / 3)
        let y = min(10, bounds.height / 3)
        return [
            (.bottomLeft, CGRect(x: 0, y: 0, width: x, height: y)),
            (.bottomRight, CGRect(x: bounds.width - x, y: 0, width: x, height: y)),
            (.topLeft, CGRect(x: 0, y: bounds.height - y, width: x, height: y)),
            (.topRight, CGRect(x: bounds.width - x, y: bounds.height - y, width: x, height: y)),
            (.left, CGRect(x: 0, y: y, width: x, height: bounds.height - 2 * y)),
            (.right, CGRect(x: bounds.width - x, y: y, width: x, height: bounds.height - 2 * y)),
            (.bottom, CGRect(x: x, y: 0, width: bounds.width - 2 * x, height: y)),
            (.top, CGRect(x: x, y: bounds.height - y, width: bounds.width - 2 * x, height: y))
        ]
    }

    /// The smallest side a free resize leaves.
    static let minimumSide: CGFloat = 24

    /// Keep the opposite corner (or the opposite edge's midpoint) stationary. With `keepAspect` the image scales
    /// evenly; without it each dragged side moves on its own, so an edge changes only the width or the height.
    static func frame(from original: CGRect, handle: SelectionHandle, delta: CGPoint, keepAspect: Bool = true) -> CGRect {
        guard original.width > 0, original.height > 0 else { return original }
        let horizontal = handle.affectsLeft || handle.affectsRight
        let vertical = handle.affectsTop || handle.affectsBottom
        let dx = handle.affectsLeft ? -delta.x : delta.x
        let dy = handle.affectsBottom ? -delta.y : delta.y
        if !keepAspect {
            let width = horizontal ? max(min(minimumSide, original.width), original.width + dx) : original.width
            let height = vertical ? max(min(minimumSide, original.height), original.height + dy) : original.height
            let x = handle.affectsLeft ? original.maxX - width : original.minX
            let y = handle.affectsBottom ? original.maxY - height : original.minY
            return CGRect(x: x, y: y, width: width, height: height)
        }
        let change: CGFloat
        if horizontal && vertical {
            // Project the drag onto the aspect-ratio diagonal for smooth corner resizing.
            change = (dx * original.width + dy * original.height)
                / (original.width * original.width + original.height * original.height)
        } else {
            change = horizontal ? dx / original.width : dy / original.height
        }
        // Small captures must not jump larger when a resize starts.
        let minimumScale = min(1, 48 / min(original.width, original.height))
        let scale = max(minimumScale, 1 + change)
        let size = CGSize(width: original.width * scale, height: original.height * scale)
        let x = handle.affectsLeft ? original.maxX - size.width
            : handle.affectsRight ? original.minX : original.midX - size.width / 2
        let y = handle.affectsBottom ? original.maxY - size.height
            : handle.affectsTop ? original.minY : original.midY - size.height / 2
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
