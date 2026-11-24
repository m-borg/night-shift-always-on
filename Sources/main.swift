import Cocoa
import Foundation

private func printUsage() {
    let text = """
    NightShiftAlwaysOn — Keeps macOS Night Shift always on (no 6:59/7:00 AM drop),
    unless you manually turn it off.

    Usage:
      NightShiftAlwaysOn              Launch the menu bar app (default)
      NightShiftAlwaysOn --status     Show current Night Shift status
      NightShiftAlwaysOn --on         Turn Night Shift ON (Always On)
      NightShiftAlwaysOn --off        Turn Night Shift OFF (Manual Off)
      NightShiftAlwaysOn --toggle     Toggle between Always On and Manual Off
      NightShiftAlwaysOn --help       Show this help message
    """
    print(text)
}

@MainActor
private func runCLICommand(_ arg: String) -> Int32 {
    let client = NSAOBrightnessClient()
    guard client.isSupported else {
        fputs("Error: Night Shift (CoreBrightness) is not supported on this display.\n", stderr)
        return 1
    }

    let defaults = UserDefaults.standard
    let wantsOnKey = "userWantsAlwaysOn"

    func readStatus() -> NSAOStatus {
        var st = NSAOStatus()
        _ = client.getStatus(&st)
        return st
    }

    func applyOn() {
        let sched = NightShiftController.computeSlidingSchedule()
        defaults.set(true, forKey: wantsOnKey)
        _ = client.setSchedule(sched)
        _ = client.setMode(2)
        _ = client.setEnabled(true)
        print(String(
            format: "Night Shift: ON (Always On, sliding gap at %02d:%02d)",
            sched.toTime.hour, sched.toTime.minute
        ))
    }

    func applyOff() {
        defaults.set(false, forKey: wantsOnKey)
        _ = client.setMode(0)
        _ = client.setEnabled(false)
        print("Night Shift: OFF (Manual Off — will stay off until turned back on)")
    }

    switch arg {
    case "--help", "-h":
        printUsage()
        return 0

    case "--status":
        let st = readStatus()
        var strength: Float = 0
        _ = client.getStrength(&strength)
        let myPID = ProcessInfo.processInfo.processIdentifier
        let running = !NSRunningApplication
            .runningApplications(withBundleIdentifier: NightShiftController.bundleIdentifier)
            .filter { $0.processIdentifier != myPID }
            .isEmpty
        let modeName: String
        switch st.mode {
        case 0: modeName = "Off (0)"
        case 1: modeName = "Sunset-to-Sunrise (1)"
        case 2: modeName = "Custom (2)"
        default: modeName = "Unknown (\(st.mode))"
        }
        print("Enabled:  \(st.enabled)")
        print("Active:   \(st.active)")
        print("Mode:     \(modeName)")
        print(String(
            format: "Schedule: %02d:%02d -> %02d:%02d",
            st.schedule.fromTime.hour, st.schedule.fromTime.minute,
            st.schedule.toTime.hour, st.schedule.toTime.minute
        ))
        print("Warmth:   \(Int(round(strength * 100)))%")
        print("Agent:    \(running ? "Running" : "Not running")")
        return 0

    case "--on":
        applyOn()
        return 0

    case "--off":
        applyOff()
        return 0

    case "--toggle":
        let st = readStatus()
        if st.enabled {
            applyOff()
        } else {
            applyOn()
        }
        return 0

    default:
        fputs("Unknown option: \(arg)\n\n", stderr)
        printUsage()
        return 2
    }
}

// Entry point
let args = CommandLine.arguments.dropFirst()
if let first = args.first, first.hasPrefix("-") {
    let code = MainActor.assumeIsolated {
        runCLICommand(first)
    }
    exit(code)
}

// Prevent duplicate menu bar instances
let currentPID = ProcessInfo.processInfo.processIdentifier
let existing = NSRunningApplication.runningApplications(
    withBundleIdentifier: NightShiftController.bundleIdentifier
).filter { $0.processIdentifier != currentPID }

if !existing.isEmpty {
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
