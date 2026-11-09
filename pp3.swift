// pp3.swift: a horizontal PP3 battery readout in the menu bar. IOKit pushes updates.
//
//   run:   swift pp3.swift (or: swiftc -O pp3.swift -o pp3)

import AppKit
import IOKit.ps

/// Hide rules for the menu bar.
///
/// `hideAbove` is a percentage, and a value of 100 means "never".
typealias Settings = (hideWhenCharging: Bool, hideAbove: Int)

/// One reading of the system battery.
struct Battery {
    var present = false
    var percentage = 0
    var charging = false
}

/// The canvas for the status icon, in points.
let batteryGlyphSize = CGSize(width: 30, height: 16)

/// The menu bar icon, inlined.
let iconTemplate = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- Menu bar icon.
         pp3.swift substitutes the text of #reading and drops #charging when the
         battery is not charging, so keep both ids. Coordinates are 60 x 32 units;
         the reading baseline is y 22.3, which centers the cap box on y 16. -->
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 32">
      <g fill="none" stroke="#000" stroke-width="1.8">
        <rect x="4" y="3" width="46" height="26" rx="2.5"/>
        <path d="M44 3 V29"/>
        <path d="M50 7 H52.3 A1.2 1.2 0 0 1 53.5 8.2 V12.3 A1.2 1.2 0 0 1 52.3 13.5 H50"/>
        <path d="M50 18.5 H53.3 A1.2 1.2 0 0 1 54.5 19.7 V23.8 A1.2 1.2 0 0 1 53.3 25 H50"/>
      </g>
      <path id="charging" fill="#000" fill-rule="evenodd" d="M44 3 H47.5 A2.5 2.5 0 0 1 50 5.5 V26.5
              A2.5 2.5 0 0 1 47.5 29 H44 Z M 45.100,16.350 Q 45.100,16.307 45.118,16.269 Q
              45.136,16.232 45.167,16.191 L 47.669,13.060 Q 47.729,12.983 47.800,12.966 Q
              47.871,12.949 47.928,12.978 Q 47.984,13.007 48.006,13.074 Q 48.027,13.142
              47.993,13.236 L 47.159,15.492 L 48.733,15.492 Q 48.808,15.492 48.854,15.538 Q
              48.900,15.584 48.900,15.651 Q 48.900,15.692 48.883,15.730 Q 48.866,15.769
              48.836,15.809 L 46.333,18.940 Q 46.273,19.015 46.202,19.034 Q 46.132,19.052
              46.075,19.022 Q 46.018,18.992 45.995,18.925 Q 45.973,18.859 46.009,18.765 L
              46.841,16.506 L 45.269,16.506 Q 45.192,16.506 45.146,16.461 Q 45.100,16.416
              45.100,16.350 Z"/>
      <text id="reading" x="24" y="22.3" text-anchor="middle" font-size="18" fill="#000"
            font-family="SF Pro Display, Helvetica, Arial, sans-serif" font-weight="700">88</text>
    </svg>
    """

/// The icon SVG for one reading.
///
/// Parameters
/// ----------
/// battery : The reading to show. A missing battery draws a dash.
///
/// returns: The SVG text with the reading and the charging state applied.
func iconSVG(for battery: Battery) -> String {
    let reading = battery.present ? "\(battery.percentage)" : "—"
    var svg = iconTemplate.replacingOccurrences(
        of: #"(<text id="reading"[^>]*>)([^<]*)(</text>)"#,
        with: "$1\(reading)$3",
        options: .regularExpression)
    if !battery.charging {
        svg = svg.replacingOccurrences(
            of: #"\s*<path id="charging"[\s\S]*?/>"#,
            with: "",
            options: .regularExpression)
    }
    return svg
}

let powerSourceChanged = Notification.Name("pp3.powerSourceChanged")
let revealRequested = Notification.Name("pp3.reveal")

/// The absolute path of this binary, used by the app to exex itself and write LaunchAgents.
///
/// returns: The executable URL.
func currentExecutable() -> URL {
    let argument = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    guard argument.pathExtension != "swift", let path = processPath(getpid()) else {
        return argument
    }
    // The kernel reports the path as absolute and real. Standardizing the path would
    // change /private/tmp to /tmp and break the lock-owner check.
    return URL(fileURLWithPath: path)
}

/// Take a single-instance lock for an unbundled binary and record the pid of the owner.
///
/// Parameters
/// ----------
/// path : The lock file. This func creates and holds it for the lifetime of the process
///
/// returns: True when this process holds the lock.
func acquireLock(_ path: String) -> Bool {
    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        if fd >= 0 { close(fd) }
        return false
    }
    let pid = "\(getpid())\n"
    ftruncate(fd, 0)
    _ = pid.withCString { write(fd, $0, strlen($0)) }
    return true
}

/// The pid in the lock file, if it still names a live copy of this binary.
///
/// A crash leaves the file behind, and the system can reuse pids. This function checks
/// the executable of the owner before it sends a signal.
///
/// Parameters
/// ----------
/// path : The lock file to read.
///
/// returns: The pid, or nil when the file is missing, malformed, or stale.
func lockOwner(_ path: String) -> pid_t? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
        let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
        pid > 1, processPath(pid) == currentExecutable().path
    else { return nil }
    return pid
}

/// The executable that a live process runs.
///
/// Parameters
/// ----------
/// pid : The process to query.
///
/// returns: The absolute path of the executable, or nil when the process is gone.
func processPath(_ pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: 4096)
    let length = buffer.withUnsafeMutableBytes {
        proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
    }
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
}

/// Re-exec the app in detached mode and terminate. Do nothing when the app is already
/// detached.
///
/// A direct terminal launch returns immediately. The child gets its own session
/// (`POSIX_SPAWN_SETSID`) and /dev/null stdio. The function skips this step when the app
/// is already detached, when launchd is the parent, and under `swift pp3.swift`.
///
/// returns: Nothing on the detached path. On the other paths, the process exits with
/// code 0 and does not return.
func detachIfInteractive() {
    if getenv("PP3_DETACHED") != nil { return }
    if getppid() == 1 { return }  // launchd is the parent. This is LaunchAgent behavior.
    let argv0 = currentExecutable()
    guard argv0.pathExtension != "swift" else { return }
    setenv("PP3_DETACHED", "1", 1)
    var pid: pid_t = 0
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDWR, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_RDWR, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_RDWR, 0)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(argv0.path), nil]
    defer { argv.forEach { free($0) } }
    if posix_spawn(&pid, argv0.path, &actions, &attr, &argv, environ) == 0 {
        exit(0)
    }
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
    // The spawn failed. Continue and run in the foreground.
}

/// The IOKit power source push callback.
///
/// The callback runs on the main run loop, where the app installs the source. So the
/// notification arrives on the main thread. (C function pointers cannot capture state,
/// so the callback has no state.)
func powerSourcePushed(_: UnsafeMutableRawPointer?) {
    NotificationCenter.default.post(name: powerSourceChanged, object: nil)
}

/// Read the internal battery from IOKit. IOKit is the only public source for this reading.
///
/// returns: The current reading. `present` is false on a machine without a battery.
func readBattery() -> Battery {
    var battery = Battery()
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return battery }
    let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
    for source in sources {
        guard let raw = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue(),
            let info = raw as? [String: Any],
            info[kIOPSIsPresentKey] as? Bool ?? true
        else { continue }
        if let type = info[kIOPSTypeKey] as? String, type != kIOPSInternalBatteryType {
            continue  // A UPS or a peripheral. This is not the cell of the Mac.
        }
        let current = info[kIOPSCurrentCapacityKey] as? Int ?? 0
        let full = info[kIOPSMaxCapacityKey] as? Int ?? 100
        battery.present = true
        battery.percentage = full > 0 ? min(100, current * 100 / full) : 0
        // "Charging" here means "on external power". macOS holds a full or optimized
        // battery without charging it. Those are the plugged-in hours that the hide rule
        // is meant to cover.
        battery.charging = info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        return battery
    }
    return battery
}

/// Own the status item and re-read the battery when IOKit pushes a change.
///
/// There is no polling timer. `IOPSNotificationCreateRunLoopSource` fires on any power
/// source change, such as a percentage change, a charging state change, or a power
/// connection change. A wake also refreshes the reading after sleep.
final class PP3: NSObject, NSApplicationDelegate {
    /// The hide rules. The app remembers them across launches. The LaunchAgent can start
    /// the app at login.
    private var settings: Settings = (
        hideWhenCharging: UserDefaults.standard.bool(forKey: "hideWhenCharging"),
        hideAbove: UserDefaults.standard.object(forKey: "hideAbove") as? Int ?? 100
    )
    private var battery = Battery()
    private var statusItem: NSStatusItem?
    private var activity: NSObjectProtocol?  // App Nap opt-out. Keep this object retained.
    private var revealed = false  // A second launch asked to show the icon.
    private let agentPlist =
        NSHomeDirectory()
        + "/Library/LaunchAgents/local.pp3.plist"

    /// Install the icon. Subscribe to the IOKit push source. Draw the first image.
    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: powerSourceChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reveal), name: revealRequested, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
        let push = IOPSNotificationCreateRunLoopSource(powerSourcePushed, nil)?
            .takeRetainedValue()
        if let push {
            CFRunLoopAddSource(CFRunLoopGetMain(), push, .commonModes)  // The loop retains it.
        }
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "battery readout")
        refresh()
    }

    /// Build the template image for one reading. The image includes the number.
    ///
    /// returns: The icon from the inlined SVG, at the menu bar size.
    private func statusImage(_ battery: Battery) -> NSImage {
        guard let data = iconSVG(for: battery).data(using: .utf8),
            let image = NSImage(data: data)
        else { return NSImage(size: batteryGlyphSize) }
        image.size = batteryGlyphSize
        image.isTemplate = true
        return image
    }

    /// Re-read the battery. Apply the hide rules. Redraw the icon.
    @MainActor @objc private func refresh() {
        battery = readBattery()
        let allowed = hideRulesAllow
        if allowed { revealed = false }  // A reveal lasts until the hide rules allow the icon.
        statusItem?.button?.image = statusImage(battery)
        statusItem?.button?.setAccessibilityLabel(statusText)
        statusItem?.isVisible = revealed || allowed
        rebuildMenu()
    }

    /// Whether the hide rules alone keep the icon in the menu bar.
    @MainActor private var hideRulesAllow: Bool {
        guard battery.present else { return true }  // No battery. Always show the icon.
        if settings.hideWhenCharging && battery.charging { return false }
        return battery.percentage <= settings.hideAbove
    }

    /// Bring the icon back after a second launch. This action ignores the hide rules.
    @MainActor @objc private func reveal() {
        revealed = true
        refresh()
    }

    /// The top line of the menu. It shows the current reading as words.
    private var statusText: String {
        guard battery.present else { return "No battery" }
        return "Battery: \(battery.percentage)%" + (battery.charging ? ", charging" : "")
    }

    /// Change the charging rule. Save the new value. Apply the hide rules again.
    @MainActor @objc private func toggleHideWhenCharging() {
        settings.hideWhenCharging.toggle()
        saveSettings()
        refresh()
    }

    /// Set the threshold. A tag is a percentage. A tag of 100 means "Never".
    @MainActor @objc private func pickHideAbove(_ sender: NSMenuItem) {
        settings.hideAbove = sender.tag
        saveSettings()
        refresh()
    }

    /// Write the hide rules to the defaults domain of the app. The domain name is the
    /// binary name.
    @MainActor private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(settings.hideWhenCharging, forKey: "hideWhenCharging")
        defaults.set(settings.hideAbove, forKey: "hideAbove")
    }

    /// Report whether the per-user LaunchAgent exists. The app uses this LaunchAgent to
    /// launch at login for an unbundled binary.
    //
    /// (NOTE: SMAppService is the modern method, but it needs an .app bundle.)
    ///
    /// returns: True when the agent plist exists on disk.
    private func launchAtLoginEnabled() -> Bool {
        FileManager.default.fileExists(atPath: agentPlist)
    }

    /// Install or remove the per-user LaunchAgent.
    ///
    /// returns: Nothing. This function writes or deletes the plist and redraws the menu.
    @MainActor @objc private func toggleLaunchAtLogin() {
        let fm = FileManager.default
        if launchAtLoginEnabled() {
            try? fm.removeItem(atPath: agentPlist)
        } else {
            let plist: [String: Any] = [
                "Label": "local.pp3",
                "ProgramArguments": [currentExecutable().path],
                "RunAtLoad": true,
            ]
            try? fm.createDirectory(
                atPath: (agentPlist as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            {
                try? data.write(to: URL(fileURLWithPath: agentPlist))
            }
        }
        rebuildMenu()
    }

    /// Add a checkmark to a menu item in the shared image column.
    ///
    /// This function uses the image column, not `state`. macOS 26 gives Quit an
    /// image-column glyph automatically. Both toggles use the same column and stay aligned
    /// with Quit.
    @MainActor private func checkmark(_ item: NSMenuItem, on: Bool) {
        item.image =
            on ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) : nil
    }

    /// Build the threshold picker in 10% steps. The first item is Never (100).
    @MainActor private func thresholdMenu() -> NSMenu {
        let menu = NSMenu()
        menu.items = [100, 10, 20, 30, 40, 50, 60, 70, 80, 90].map { value in
            let item = NSMenuItem(
                title: value == 100 ? "Never" : "\(value)%",
                action: #selector(pickHideAbove(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            item.state = value == settings.hideAbove ? .on : .off
            return item
        }
        return menu
    }

    /// Rebuild the full menu from the current state.
    @MainActor private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: statusText, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let hide = menu.addItem(
            withTitle: "Hide when Charging", action: #selector(toggleHideWhenCharging),
            keyEquivalent: "")
        hide.target = self
        checkmark(hide, on: settings.hideWhenCharging)
        menu.addItem(withTitle: "Hide when Above…", action: nil, keyEquivalent: "")
            .submenu = thresholdMenu()
        menu.addItem(.separator())
        let login = menu.addItem(
            withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin),
            keyEquivalent: "")
        login.target = self
        checkmark(login, on: launchAtLoginEnabled())
        menu.addItem(
            withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
    }
}

detachIfInteractive()
signal(SIGUSR1, SIG_IGN)  // A reveal request. The default action would terminate the process.
let lockFile = NSHomeDirectory() + "/Library/Caches/pp3.lock"
if !acquireLock(lockFile) {
    // A second launch cannot own the menu bar. It asks the live instance to show itself
    // instead. That is the only way back from an auto-hidden icon.
    if let owner = lockOwner(lockFile) { kill(owner, SIGUSR1) }
    exit(0)
}

let reveal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
reveal.setEventHandler {
    NotificationCenter.default.post(name: revealRequested, object: nil)
}
reveal.resume()

let app = NSApplication.shared
let controller = PP3()  // run() never returns. This reference keeps the controller alive.
app.delegate = controller
app.setActivationPolicy(.accessory)  // Menu bar only. No Dock icon.
app.run()
