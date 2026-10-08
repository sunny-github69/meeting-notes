import AppKit
import ServiceManagement
import UserNotifications

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// macOS notifications; clicking one opens the file it points to.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    // UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func setUp() {
        center?.delegate = self
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ title: String, _ body: String, open file: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let file { content.userInfo = ["file": file.path] }
        center?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["file"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        done()
    }
}
