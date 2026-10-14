import AppKit
import UserNotifications

/// Tells the user a Snapok Agent task finished while they were in another app; clicking opens the chat.
@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotifier()
    /// Shorter turns finish before anyone switches away.
    static let minimumDuration: TimeInterval = 8

    /// Installs the click handler; call once at launch.
    func start() { UNUserNotificationCenter.current().delegate = self }

    func taskFinished(chatID: String, title: String, reply: AgentMessage) {
        guard !NSApp.isActive, (reply.duration ?? 0) >= Self.minimumDuration else { return }
        let content = UNMutableNotificationContent()
        content.title = reply.failed
            ? L("Snapok Agent couldn't finish", "Snapok Agent 任务没有完成")
            : reply.images.isEmpty ? L("Snapok Agent replied", "Snapok Agent 已回复") : L("Your image is ready", "图片已生成")
        let firstLine = reply.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        content.body = firstLine.isEmpty ? title : String(firstLine.prefix(120))
        content.sound = .default
        content.userInfo = ["chatID": chatID]
        let request = UNNotificationRequest(identifier: "agent-\(chatID)", content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        Task {
            // Asks the first time; afterwards macOS remembers the answer.
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            do { try await center.add(request) } catch { log("agent notification failed", error: error) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let chatID = response.notification.request.content.userInfo["chatID"] as? String else { return }
        await MainActor.run { ImageAgentEntry.openChat?(chatID) }
    }
}
