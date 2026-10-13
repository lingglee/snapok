import CoreGraphics
import Foundation

/// One thing the redaction tool found, shown in the review sheet so the user can choose what gets masked.
struct RedactionCandidate: Equatable, Sendable {
    enum Kind: Int, CaseIterable, Sendable { case sensitive, avatar, name }

    let kind: Kind
    /// Normalized, bottom-left origin, matching Vision.
    let box: CGRect
    let label: String
    var isSelected: Bool = true
}

enum RedactionCandidates {
    /// Builds the review list: sensitive values first, then avatars top to bottom, then user names.
    /// A name that already overlaps a sensitive value is dropped so it is listed (and masked) once.
    static func make(sensitive: [CGRect], avatars: [CGRect], names: [CGRect], blocks: [RecognizedImageText]) -> [RedactionCandidate] {
        func text(for box: CGRect) -> String? {
            let hit = blocks.first { $0.box == box }
                ?? blocks.filter { $0.box.intersects(box) }
                    .max { $0.box.intersection(box).area < $1.box.intersection(box).area }
            let value = hit?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        var result: [RedactionCandidate] = []
        for box in sensitive {
            let label = text(for: box).map(masked) ?? L("Sensitive value", "敏感信息")
            result.append(RedactionCandidate(kind: .sensitive, box: box, label: label))
        }
        let orderedAvatars = avatars.sorted { $0.maxY == $1.maxY ? $0.minX < $1.minX : $0.maxY > $1.maxY }
        for (index, box) in orderedAvatars.enumerated() {
            let side = box.midX < 0.5 ? L("left", "左侧") : L("right", "右侧")
            result.append(RedactionCandidate(kind: .avatar, box: box,
                                             label: L("Avatar \(index + 1) (\(side))", "头像 \(index + 1)（\(side)）")))
        }
        let filteredNames = names.filter { name in !sensitive.contains { name.contains($0) || $0.contains(name) } }
        for box in filteredNames {
            result.append(RedactionCandidate(kind: .name, box: box, label: text(for: box) ?? L("User name", "用户名")))
        }
        return result
    }

    static func selectedBoxes(_ candidates: [RedactionCandidate]) -> [CGRect] {
        candidates.filter(\.isSelected).map(\.box)
    }

    static func count(_ candidates: [RedactionCandidate], _ kind: RedactionCandidate.Kind) -> Int {
        candidates.filter { $0.isSelected && $0.kind == kind }.count
    }

    /// Keeps the list readable without printing the full secret again.
    static func masked(_ value: String) -> String {
        let chars = Array(value)
        guard chars.count > 4 else { return String(repeating: "•", count: chars.count) }
        let keep = min(3, chars.count / 4)
        return String(chars.prefix(keep)) + String(repeating: "•", count: min(8, chars.count - keep * 2)) + String(chars.suffix(keep))
    }

    static func title(_ kind: RedactionCandidate.Kind) -> String {
        switch kind {
        case .sensitive: L("Sensitive info (phone, email, ID, keys)", "敏感信息（手机号、邮箱、证件号、密钥）")
        case .avatar: L("Avatars", "头像")
        case .name: L("User names", "用户名")
        }
    }
}

/// Which automatic redaction produced a mask, so the editor can swap or remove one group without touching the rest.
enum AutoRedactionKind: Int, Sendable { case sensitive, chatIdentity }

enum AutoRedaction {
    /// Avatars and user names from a candidate list (names already covered by a sensitive value are dropped by `make`).
    static func identityBoxes(_ candidates: [RedactionCandidate]) -> [CGRect] {
        candidates.filter { $0.kind != .sensitive }.map(\.box)
    }

    /// Drops the masks of the given kinds and appends `added`; manual annotations keep their order.
    static func replacing<T>(_ items: [T], kind: (T) -> AutoRedactionKind?, removing: Set<AutoRedactionKind>, adding added: [T]) -> [T] {
        items.filter { item in kind(item).map { !removing.contains($0) } ?? true } + added
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
