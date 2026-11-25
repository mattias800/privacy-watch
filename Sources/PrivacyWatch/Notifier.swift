import Foundation
import UserNotifications

/// Posts user notifications. Falls back to `osascript` if the app has not been
/// granted notification permission (for example when running the bare binary).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var authorized = false
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil

    func requestAuthorization() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            self?.authorized = granted
            if let error {
                Log.write("Notification authorization error: \(error.localizedDescription)")
            }
        }
    }

    func post(title: String, body: String) {
        if authorized, let center {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in
                if let error { Log.write("Notification error: \(error.localizedDescription)") }
            }
        } else {
            postWithAppleScript(title: title, body: body)
        }
    }

    private func postWithAppleScript(title: String, body: String) {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \"\(escape(body))\" with title \"\(escape(title))\""]
        try? process.run()
    }

    // Show banners even though this is a menu bar app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}

/// Appends timestamped lines to ~/Library/Logs/PrivacyWatch.log.
enum Log {
    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/PrivacyWatch.log")

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
