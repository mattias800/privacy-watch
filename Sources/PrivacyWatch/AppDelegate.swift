import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let pollInterval: TimeInterval = 2

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let notifier = Notifier()
    private var current = PrivacySnapshot.capture()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifier.requestAuthorization()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        Log.write("Started. \(summary(current))")

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Polling

    private func poll() {
        let next = PrivacySnapshot.capture()
        guard next != current else { return }
        let changes = next.changes(since: current)
        current = next
        updateIcon()

        guard !changes.isEmpty else { return }
        changes.forEach { Log.write($0) }
        let title = changes.count == 1 ? "PrivacyWatch" : "PrivacyWatch: \(changes.count) changes"
        notifier.post(title: title, body: changes.joined(separator: "\n"))
    }

    // MARK: Status icon

    /// Plain eye when quiet; filled eye with a badge while the screen is being
    /// recorded or the microphone is in use.
    private func updateIcon() {
        let alerting = current.screen == .active || current.microphone.inUse
        let symbol = alerting ? "eye.trianglebadge.exclamationmark.fill" : "eye"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "PrivacyWatch")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = summary(current)
    }

    private func summary(_ s: PrivacySnapshot) -> String {
        let screen: String
        switch s.screen {
        case .active: screen = "recording"
        case .inactive: screen = "not recording"
        case .unavailable: screen = "unknown"
        }
        let mic = s.microphone.inUse ? "in use" : "not in use"
        return "Keyboard listeners: \(s.keyboardListeners.count), screen: \(screen), microphone: \(mic)"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        current = PrivacySnapshot.capture()
        updateIcon()
        menu.removeAllItems()

        // Keyboard
        menu.addItem(header("Keyboard listeners"))
        let listeners = current.keyboardListeners.sorted {
            ($0.isAppleSystem ? 1 : 0, $0.name) < ($1.isAppleSystem ? 1 : 0, $1.name)
        }
        if listeners.isEmpty {
            menu.addItem(info("None"))
        }
        for listener in listeners {
            var details: [String] = []
            if listener.isAppleSystem { details.append("macOS") }
            details.append(listener.canModify ? "can modify input" : "listen-only")
            if listener.targetsSingleProcess { details.append("single app") }
            let item = info("\(listener.name)  (\(details.joined(separator: ", ")))")
            item.toolTip = listener.path
            menu.addItem(item)
        }

        // Screen
        menu.addItem(.separator())
        menu.addItem(header("Screen recording"))
        switch current.screen {
        case .active: menu.addItem(info("● Active"))
        case .inactive: menu.addItem(info("Not active"))
        case .unavailable: menu.addItem(info("Unknown (detection unavailable on this macOS)"))
        }

        // Microphone
        menu.addItem(.separator())
        menu.addItem(header("Microphone"))
        if current.microphone.apps.isEmpty && !current.microphone.unattributedUse {
            menu.addItem(info("Not in use"))
        }
        for app in current.microphone.apps.sorted() {
            menu.addItem(info("● \(app)"))
        }
        if current.microphone.unattributedUse {
            menu.addItem(info("● In use (app unknown)"))
        }

        // Actions
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let showLog = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "l")
        showLog.target = self
        menu.addItem(showLog)

        let test = NSMenuItem(title: "Send Test Notification", action: #selector(sendTestNotification), keyEquivalent: "")
        test.target = self
        menu.addItem(test)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PrivacyWatch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// A non-clickable status line that still renders in normal (not greyed-out) text.
    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(noop), keyEquivalent: "")
        item.target = self
        item.indentationLevel = 1
        return item
    }

    @objc private func noop() {}

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: Log.url.path) {
            Log.write("Log created.")
        }
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func sendTestNotification() {
        notifier.post(title: "PrivacyWatch", body: "Notifications are working. \(summary(current))")
    }
}
