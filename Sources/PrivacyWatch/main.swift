import AppKit

// `PrivacyWatch --status` prints a one-off snapshot to the terminal and exits.
if CommandLine.arguments.contains("--status") {
    let s = PrivacySnapshot.capture()
    print("Keyboard listeners:")
    for l in s.keyboardListeners.sorted(by: { $0.name < $1.name }) {
        print("  \(l.name)  [\(l.signer.notificationTag); \(l.canModify ? "can modify" : "listen-only")\(l.targetsSingleProcess ? ", single app" : "")]")
        print("      \(l.signer.detail)")
        print("      \(l.path)")
    }
    print("Screen recording: \(s.screen)")
    if s.microphone.inUse {
        print("Microphone: in use")
        for app in s.microphone.apps.sorted(by: { $0.name < $1.name }) {
            print("  \(app.name)  [\(app.signer.notificationTag)]")
        }
        if s.microphone.unattributedUse { print("  (app unknown)") }
    } else {
        print("Microphone: not in use")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
