import AppKit
import CoreAudio
import CoreGraphics
import Foundation

// MARK: - Process naming

/// Resolves a pid to its executable path.
func executablePath(for pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

/// A human-readable name for a process. Helper processes inside an app bundle
/// (e.g. "Google Chrome Helper") are attributed to the outermost .app.
func displayName(pid: pid_t, path: String?) -> String {
    if let path {
        let components = path.split(separator: "/")
        if let app = components.first(where: { $0.hasSuffix(".app") }) {
            return String(app.dropLast(4))
        }
        if let last = components.last { return String(last) }
    }
    if let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
        return name
    }
    return "pid \(pid)"
}

// MARK: - Keyboard event taps

/// A process that has an enabled event tap receiving keyboard events.
struct KeyboardListener: Hashable {
    let path: String
    let name: String
    let signer: CodeSigner
    /// false = listen-only tap; true = active tap that can also modify or drop events.
    let canModify: Bool
    /// true when the tap only watches a single target process rather than the whole session.
    let targetsSingleProcess: Bool
}

/// Lists every enabled event tap that receives key events. All event taps are
/// registered with the WindowServer, so this includes taps created by root daemons.
/// It needs no special permission.
enum KeyboardTapMonitor {
    private static let keyMask: UInt64 =
        (1 << UInt64(CGEventType.keyDown.rawValue)) |
        (1 << UInt64(CGEventType.keyUp.rawValue)) |
        (1 << UInt64(CGEventType.flagsChanged.rawValue))

    static func snapshot() -> Set<KeyboardListener> {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return [] }

        var result = Set<KeyboardListener>()
        for tap in taps.prefix(Int(count)) where tap.enabled && (tap.eventsOfInterest & keyMask) != 0 {
            let pid = pid_t(tap.tappingProcess)
            let path = executablePath(for: pid) ?? "pid \(pid)"
            result.insert(KeyboardListener(
                path: path,
                name: displayName(pid: pid, path: path),
                signer: CodeSignatureInspector.signer(pid: pid, path: path),
                canModify: tap.options != .listenOnly,
                targetsSingleProcess: tap.processBeingTapped != 0
            ))
        }
        return result
    }
}

// MARK: - Screen recording

enum ScreenRecordingState: Equatable {
    case active
    case inactive
    case unavailable
}

/// Asks the WindowServer whether anything is currently capturing the screen.
/// Uses a private SkyLight function (the same signal behind the menu bar's
/// recording indicator). It reports *that* the screen is captured, not *who* is capturing.
enum ScreenRecordingMonitor {
    private typealias WatcherFn = @convention(c) () -> Bool

    private static let watcherPresent: WatcherFn? = {
        let libraries = [
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        ]
        for library in libraries {
            guard let handle = dlopen(library, RTLD_LAZY) else { continue }
            for symbol in ["SLSIsScreenWatcherPresent", "CGSIsScreenWatcherPresent"] {
                if let pointer = dlsym(handle, symbol) {
                    return unsafeBitCast(pointer, to: WatcherFn.self)
                }
            }
        }
        return nil
    }()

    static func snapshot() -> ScreenRecordingState {
        guard let watcherPresent else { return .unavailable }
        return watcherPresent() ? .active : .inactive
    }
}

// MARK: - Microphone

/// An app capturing audio input. Helper processes of the same app collapse into one entry.
struct AudioClient: Hashable {
    let name: String
    let signer: CodeSigner
}

struct MicrophoneState: Equatable {
    /// Apps whose processes are currently capturing audio input.
    var apps: Set<AudioClient>
    /// The default input device is running, but no specific process could be identified.
    var unattributedUse: Bool

    var inUse: Bool { !apps.isEmpty || unattributedUse }
}

/// Uses CoreAudio's per-process objects (macOS 14+) to see which processes are
/// currently running audio input. Needs no microphone permission.
enum MicrophoneMonitor {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func snapshot() -> MicrophoneState {
        var apps = Set<AudioClient>()
        for process in processObjects() where isRunningInput(process) {
            let pid = processPID(process)
            if pid == getpid() { continue }
            let path = pid > 0 ? executablePath(for: pid) : nil
            apps.insert(AudioClient(
                name: displayName(pid: pid, path: path),
                signer: CodeSignatureInspector.signer(pid: pid, path: path)
            ))
        }
        let deviceRunning = defaultInputDeviceIsRunning()
        return MicrophoneState(apps: apps, unattributedUse: apps.isEmpty && deviceRunning)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var addr = address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func processPID(_ process: AudioObjectID) -> pid_t {
        var addr = address(kAudioProcessPropertyPID)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &pid)
        return pid
    }

    private static func defaultInputDeviceIsRunning() -> Bool {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &device) == noErr, device != 0 else {
            return false
        }
        var runningAddr = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &runningAddr, 0, nil, &size, &running) == noErr && running != 0
    }
}

// MARK: - Combined snapshot

struct PrivacySnapshot: Equatable {
    var keyboardListeners: Set<KeyboardListener>
    var screen: ScreenRecordingState
    var microphone: MicrophoneState

    static func capture() -> PrivacySnapshot {
        PrivacySnapshot(
            keyboardListeners: KeyboardTapMonitor.snapshot(),
            screen: ScreenRecordingMonitor.snapshot(),
            microphone: MicrophoneMonitor.snapshot()
        )
    }

    /// Human-readable descriptions of what changed from `old` to `self`.
    func changes(since old: PrivacySnapshot) -> [String] {
        var changes: [String] = []

        for listener in keyboardListeners.subtracting(old.keyboardListeners).sorted(by: { $0.name < $1.name }) {
            let verified = listener.signer.kind == .apple || listener.signer.kind == .thirdParty
            let location = verified ? "" : " [\(listener.path)]"
            changes.append("⌨️ \(listener.name) (\(listener.signer.notificationTag)) started listening to the keyboard\(location)")
        }
        for listener in old.keyboardListeners.subtracting(keyboardListeners).sorted(by: { $0.name < $1.name }) {
            changes.append("⌨️ \(listener.name) (\(listener.signer.notificationTag)) stopped listening to the keyboard")
        }

        if screen != old.screen {
            switch screen {
            case .active: changes.append("🖥️ Screen recording started")
            case .inactive: changes.append("🖥️ Screen recording stopped")
            case .unavailable: break
            }
        }

        for app in microphone.apps.subtracting(old.microphone.apps).sorted(by: { $0.name < $1.name }) {
            changes.append("🎙️ \(app.name) (\(app.signer.notificationTag)) started using the microphone")
        }
        for app in old.microphone.apps.subtracting(microphone.apps).sorted(by: { $0.name < $1.name }) {
            changes.append("🎙️ \(app.name) (\(app.signer.notificationTag)) stopped using the microphone")
        }
        if microphone.unattributedUse != old.microphone.unattributedUse {
            changes.append(microphone.unattributedUse
                ? "🎙️ Microphone in use (app unknown)"
                : "🎙️ Microphone no longer in use")
        }

        return changes
    }
}
