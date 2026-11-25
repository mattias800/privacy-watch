import AppKit

// `PrivacyWatch --status` prints a one-off snapshot to the terminal and exits.
if CommandLine.arguments.contains("--status") {
    let s = PrivacySnapshot.capture()
    print("Keyboard listeners:")
    for l in s.keyboardListeners.sorted(by: { $0.name < $1.name }) {
        print("  \(l.name)  [\(l.canModify ? "can modify" : "listen-only")\(l.targetsSingleProcess ? ", single app" : "")]  \(l.path)")
    }
    print("Screen recording: \(s.screen)")
    print("Microphone: \(s.microphone.inUse ? "in use by \(s.microphone.apps.sorted().joined(separator: ", "))\(s.microphone.unattributedUse ? "unknown app" : "")" : "not in use")")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
