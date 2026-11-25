# PrivacyWatch

A small macOS menu bar app that tells you when something on your Mac starts **listening to your keyboard**, **recording your screen**, or **using your microphone**.

It only observes. It does not block, change, or interfere with any other software, and it needs **no special permissions and no admin rights**.

## What it monitors

| Signal | How | Attribution |
|---|---|---|
| **Keyboard listeners** | Polls the WindowServer's list of event taps (`CGGetEventTapList`) and reports every enabled tap that receives key events. Event taps are the standard mechanism for keystroke capture on macOS, and every tap goes through the WindowServer, so taps created by root daemons show up too. | Exact process |
| **Screen recording** | Asks the WindowServer whether a screen watcher is present (`SLSIsScreenWatcherPresent`, a private SkyLight function, the same signal behind the menu bar recording indicator). | *That* the screen is captured, not *who* |
| **Microphone** | Uses CoreAudio's per-process objects (macOS 14+) to find processes with `kAudioProcessPropertyIsRunningInput` set. Falls back to "app unknown" if the input device runs but no process can be attributed. | App name (helper processes are attributed to their parent `.app`) |

### Who signed it

Every process in the keyboard and microphone lists is classified by verifying the code signature of the **running process** with the Security framework (falling back to the binary on disk):

| Badge | Meaning |
|---|---|
| Apple logo, **Apple** | Satisfies `anchor apple`: a macOS component or one of Apple's own apps. |
| Blue seal, **developer name** | Valid Apple-issued developer certificate (Developer ID or Mac App Store). Shows the name from the certificate, e.g. "Palo Alto Networks". |
| Orange triangle, **Unsigned / Ad-hoc signed** | No verified developer identity. |
| Red octagon, **Invalid signature** | The code does not match its signature. Treat as a red flag. |
| Purple lock, **Can't verify** | The process refuses signature inspection and its binary is unreadable. Tamper-protected security software (EDR agents) commonly does this. It means unverifiable, not malicious. |

For anything not verified as Apple or a named developer, the menu and notifications also show where the binary lives. Hover an entry for the full signer details and path.

State is polled every 2 seconds. Any change triggers a notification and is appended to `~/Library/Logs/PrivacyWatch.log`.

## What it can't see

- **Accessibility API reads.** An app with Accessibility permission can read text from other apps' windows. Those calls go directly from app to app and leave no trace a normal user can observe.
- **Keystroke capture below the event tap level**, such as raw HID access (`IOHIDManager`) or kernel/driver-level capture. Raw HID keyboard access requires the Input Monitoring permission.
- **Very short-lived events** that start and stop between two polls.

## Install

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/mattias800/privacy-watch.git
cd privacy-watch
./scripts/build-app.sh --install
```

This builds `PrivacyWatch.app`, ad-hoc signs it, copies it to `~/Applications` and launches it. On first launch, allow notifications when asked. Enable **Launch at Login** from the menu.

### Command line

```sh
~/Applications/PrivacyWatch.app/Contents/MacOS/PrivacyWatch --status
```

prints a one-off snapshot and exits.

## Menu

- **Keyboard listeners**: each process with an enabled keyboard event tap, marked `macOS` for system processes, and `listen-only` or `can modify input`.
- **Screen recording**: active or not.
- **Microphone**: which apps are capturing audio input.
- **Launch at Login**, **Open Log**, **Send Test Notification**, **Quit**.

The menu bar icon is a plain eye normally, and a filled eye with a warning badge while the screen is being recorded or the microphone is in use.

## License

MIT
