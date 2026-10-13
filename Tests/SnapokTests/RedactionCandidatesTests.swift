import CoreGraphics
import Foundation

/// Checks the review list behind the redaction sheet: grouping, labels, de-duplication, and selection.
@main
struct RedactionCandidatesTests {
    static func main() {
        let phone = CGRect(x: 0.3, y: 0.80, width: 0.2, height: 0.03)
        let nameWithPhone = CGRect(x: 0.25, y: 0.79, width: 0.4, height: 0.05)
        let alice = CGRect(x: 0.12, y: 0.70, width: 0.1, height: 0.03)
        let leftAvatar = CGRect(x: 0.02, y: 0.66, width: 0.08, height: 0.07)
        let rightAvatar = CGRect(x: 0.90, y: 0.50, width: 0.08, height: 0.07)
        let topAvatar = CGRect(x: 0.02, y: 0.85, width: 0.08, height: 0.07)
        let blocks = [
            RecognizedImageText(id: 0, text: "13812345678", box: phone),
            RecognizedImageText(id: 1, text: "Alice", box: alice),
        ]
        let list = RedactionCandidates.make(sensitive: [phone], avatars: [leftAvatar, rightAvatar, topAvatar],
                                            names: [alice, nameWithPhone], blocks: blocks)

        precondition(list.map(\.kind) == [.sensitive, .avatar, .avatar, .avatar, .name], "Grouped in order, got \(list.map(\.kind))")
        precondition(list.allSatisfy(\.isSelected), "Everything starts checked")
        precondition(!list[0].label.contains("12345"), "Sensitive value is not printed in full: \(list[0].label)")
        precondition(list[1].box == topAvatar && list[3].box == rightAvatar, "Avatars listed top to bottom")
        precondition(list[1].label.contains("1") && list[3].label.contains("right"), "Avatar label has number and side: \(list[3].label)")
        precondition(list[4].label == "Alice", "Name shows its text")

        var chosen = list
        chosen[2].isSelected = false
        chosen[4].isSelected = false
        let boxes = RedactionCandidates.selectedBoxes(chosen)
        precondition(boxes == [phone, topAvatar, rightAvatar], "Only checked items are masked")
        precondition(RedactionCandidates.count(chosen, .avatar) == 2 && RedactionCandidates.count(chosen, .name) == 0, "Counts follow the selection")

        var none = list
        for i in none.indices { none[i].isSelected = false }
        precondition(RedactionCandidates.selectedBoxes(none).isEmpty, "Unchecking everything masks nothing")

        precondition(RedactionCandidates.masked("abc") == "•••", "Short values are fully hidden")
        // Toggle behaviour: identity boxes exclude sensitive values; removing one kind leaves the rest untouched.
        precondition(AutoRedaction.identityBoxes(list) == [topAvatar, leftAvatar, rightAvatar, alice], "Identity = avatars + names")
        typealias Item = (name: String, kind: AutoRedactionKind?)
        let canvas: [Item] = [("arrow", nil), ("phone", .sensitive), ("avatar", .chatIdentity), ("hand mosaic", nil), ("name", .chatIdentity)]
        let unchecked = AutoRedaction.replacing(canvas, kind: { $0.kind }, removing: [.chatIdentity], adding: [])
        precondition(unchecked.map(\.name) == ["arrow", "phone", "hand mosaic"], "Unchecking removes only avatar/name masks: \(unchecked.map(\.name))")
        let rechecked = AutoRedaction.replacing(unchecked, kind: { $0.kind }, removing: [.chatIdentity], adding: [("avatar", .chatIdentity), ("name", .chatIdentity)])
        precondition(rechecked.filter { $0.kind == .chatIdentity }.count == 2, "Checking again masks them once")
        let rerun = AutoRedaction.replacing(rechecked, kind: { $0.kind }, removing: [.sensitive, .chatIdentity], adding: [("phone", .sensitive)])
        precondition(rerun.map(\.name) == ["arrow", "hand mosaic", "phone"], "Re-running replaces instead of stacking: \(rerun.map(\.name))")
        let cleared = AutoRedaction.replacing(rerun, kind: { $0.kind }, removing: [.sensitive, .chatIdentity], adding: [])
        precondition(cleared.map(\.name) == ["arrow", "hand mosaic"], "Clearing keeps manual annotations")
        print("RedactionCandidates tests passed")
    }
}
