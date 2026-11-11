import Foundation
import UserNotifications

/// Optional macOS notification when a note's reminder is due (Settings; off by default). Delivered by
/// this Mac's Notification Center; nothing leaves the Mac.
enum ReminderNotifications {
    static func requestPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]) { _,_ in }
    }

    static func post(_ note: SilkNote) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Silk Note"
        content.body = String(note.text.prefix(180))
        content.sound = .default
        let request = UNNotificationRequest(identifier:"note-\(note.id.uuidString)",content:content,trigger:nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
