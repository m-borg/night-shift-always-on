import Cocoa
import Foundation
import os.log

@MainActor
final class NightShiftController {
    enum State: Equatable {
        case alwaysOn
        case manualOff
        case unsupported
    }

    nonisolated static let bundleIdentifier = "com.local.nightshift-always-on"
    private static let userWantsOnKey = "userWantsAlwaysOn"
    private static let refreshIntervalSeconds: TimeInterval = 30 * 60 // Every 30 minutes
    private static let internalEchoSuppressionSeconds: TimeInterval = 0.8
    private static let systemTransitionGraceSeconds: TimeInterval = 6.0

    private let logger = Logger(subsystem: NightShiftController.bundleIdentifier, category: "Controller")
    private let defaults = UserDefaults.standard
    private let client = NSAOBrightnessClient()

    private var refreshTimer: Timer?
    private var ignoreNotificationsUntil: Date = .distantPast
    private var lastSystemTransitionDate: Date = .distantPast
    private var workspaceObservers: [NSObjectProtocol] = []
    private var notificationObservers: [NSObjectProtocol] = []

    private(set) var state: State = .unsupported
    private(set) var lastStatus: NSAOStatus = NSAOStatus()
    private(set) var strength: Float = 0.5

    var onStateChanged: (() -> Void)?

    var userWantsAlwaysOn: Bool {
        get {
            if defaults.object(forKey: Self.userWantsOnKey) == nil {
                return true
            }
            return defaults.bool(forKey: Self.userWantsOnKey)
        }
        set {
            defaults.set(newValue, forKey: Self.userWantsOnKey)
        }
    }

    init() {}

    deinit {
        refreshTimer?.invalidate()
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        for obs in notificationObservers {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func start() {
        guard client.isSupported else {
            state = .unsupported
            logger.error("Night Shift is not supported on this Mac/display.")
            onStateChanged?()
            return
        }

        // First-run initialization: default to Always On.
        if defaults.object(forKey: Self.userWantsOnKey) == nil {
            userWantsAlwaysOn = true
        }

        refreshCurrentStatus()

        if userWantsAlwaysOn {
            enforceAlwaysOn(reason: "startup")
        } else {
            // Respect previously persisted manual-off across restarts unless user already turned it back on.
            if lastStatus.enabled {
                userWantsAlwaysOn = true
                enforceAlwaysOn(reason: "startup-already-enabled")
            } else {
                ensureManualOff(reason: "startup-manual-off")
            }
        }

        client.setStatusChangedHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleExternalStatusChange()
            }
        }

        installSystemObservers()
        startRefreshTimer()
        onStateChanged?()
    }

    // MARK: - User Actions

    func setAlwaysOnFromUser() {
        guard client.isSupported else { return }
        userWantsAlwaysOn = true
        enforceAlwaysOn(reason: "user-menu-on")
        onStateChanged?()
    }

    func setManualOffFromUser() {
        guard client.isSupported else { return }
        userWantsAlwaysOn = false
        ensureManualOff(reason: "user-menu-off")
        onStateChanged?()
    }

    func toggleFromUser() {
        if state == .alwaysOn {
            setManualOffFromUser()
        } else {
            setAlwaysOnFromUser()
        }
    }

    func setWarmth(_ newValue: Float, commit: Bool) {
        let clamped = min(max(newValue, 0.0), 1.0)
        strength = clamped
        suppressSelfNotifications()
        _ = client.setStrength(clamped, commit: commit)
        onStateChanged?()
    }

    // MARK: - Sliding Schedule Core

    /// Computes a 23h59m schedule whose 1-minute off-gap is placed 12 hours in the future.
    /// Because this is refreshed every 30 minutes and on every wake/clock change,
    /// the local clock NEVER reaches `toTime`, so macOS never triggers the 6:59/7:00 flash.
    static func computeSlidingSchedule(now: Date = Date(), calendar: Calendar = .current) -> NSAOSchedule {
        let toDate = calendar.date(byAdding: .hour, value: 12, to: now) ?? now
        let fromDate = calendar.date(byAdding: .minute, value: 1, to: toDate) ?? toDate

        let fromComps = calendar.dateComponents([.hour, .minute], from: fromDate)
        let toComps = calendar.dateComponents([.hour, .minute], from: toDate)

        return NSAOSchedule(
            fromTime: NSAOTime(
                hour: Int32(fromComps.hour ?? 12),
                minute: Int32(fromComps.minute ?? 1)
            ),
            toTime: NSAOTime(
                hour: Int32(toComps.hour ?? 12),
                minute: Int32(toComps.minute ?? 0)
            )
        )
    }

    /// Checks whether `now` falls within ±toleranceMinutes of a scheduled (hour, minute) time-of-day.
    static func isTime(_ now: Date, near target: NSAOTime, toleranceMinutes: Int, calendar: Calendar = .current) -> Bool {
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        guard let nowHour = comps.hour, let nowMinute = comps.minute else { return false }
        let nowTotal = nowHour * 60 + nowMinute
        let targetTotal = Int(target.hour) * 60 + Int(target.minute)
        let rawDiff = abs(nowTotal - targetTotal)
        let wrappedDiff = min(rawDiff, 1440 - rawDiff)
        return wrappedDiff <= toleranceMinutes
    }

    private func enforceAlwaysOn(reason: String) {
        let targetSchedule = Self.computeSlidingSchedule()

        suppressSelfNotifications()

        var status = NSAOStatus()
        _ = client.getStatus(&status)

        let scheduleMatches =
            status.schedule.fromTime.hour == targetSchedule.fromTime.hour &&
            status.schedule.fromTime.minute == targetSchedule.fromTime.minute &&
            status.schedule.toTime.hour == targetSchedule.toTime.hour &&
            status.schedule.toTime.minute == targetSchedule.toTime.minute

        if !scheduleMatches {
            _ = client.setSchedule(targetSchedule)
        }
        if status.mode != 2 {
            _ = client.setMode(2)
        }
        if !status.enabled {
            _ = client.setEnabled(true)
        }

        refreshCurrentStatus()
        state = .alwaysOn
        logger.info("Enforced Always On (\(reason, privacy: .public)): sched \(targetSchedule.fromTime.hour):\(targetSchedule.fromTime.minute)->\(targetSchedule.toTime.hour):\(targetSchedule.toTime.minute), enabled=\(self.lastStatus.enabled)")
    }

    private func ensureManualOff(reason: String) {
        suppressSelfNotifications()

        var status = NSAOStatus()
        _ = client.getStatus(&status)

        // Set Schedule to Off (mode 0) so macOS won't auto-enable at any future schedule boundary.
        if status.mode != 0 {
            _ = client.setMode(0)
        }
        if status.enabled {
            _ = client.setEnabled(false)
        }

        refreshCurrentStatus()
        state = .manualOff
        logger.info("Entered Manual Off (\(reason, privacy: .public)): mode=\(self.lastStatus.mode), enabled=\(self.lastStatus.enabled)")
    }

    private func suppressSelfNotifications() {
        ignoreNotificationsUntil = Date().addingTimeInterval(Self.internalEchoSuppressionSeconds)
    }

    func refreshCurrentStatus() {
        var status = NSAOStatus()
        if client.getStatus(&status) {
            lastStatus = status
        }
        var currentStrength: Float = strength
        if client.getStrength(&currentStrength) {
            strength = currentStrength
        }
    }

    // MARK: - External Status Callback (Control Center / System Settings)

    private func handleExternalStatusChange() {
        let now = Date()
        if now < ignoreNotificationsUntil {
            refreshCurrentStatus()
            onStateChanged?()
            return
        }

        refreshCurrentStatus()

        if userWantsAlwaysOn {
            if !lastStatus.enabled {
                // Distinguish system artifacts (wake from sleep, clock jump, 1-in-1440 wake right in the 1m gap,
                // or display reference mode suspension) from a genuine manual user click.
                let recentSystemTransition = now.timeIntervalSince(lastSystemTransitionDate) < Self.systemTransitionGraceSeconds
                let insideScheduleGap = Self.isTime(now, near: lastStatus.schedule.toTime, toleranceMinutes: 2)
                let temporarilyDisabledBySystem = lastStatus.disableFlags != 0

                if temporarilyDisabledBySystem {
                    logger.info("Night Shift temporarily suspended by system (disableFlags=\(self.lastStatus.disableFlags)); keeping Always On intent.")
                    onStateChanged?()
                    return
                }

                if recentSystemTransition || insideScheduleGap {
                    logger.info("Detected non-manual Night Shift drop (wake=\(recentSystemTransition), gap=\(insideScheduleGap)); re-enforcing Always On.")
                    enforceAlwaysOn(reason: "recovered-system-drop")
                    onStateChanged?()
                    return
                }

                // Genuine manual click OFF in Control Center or System Settings!
                logger.info("Detected manual Night Shift OFF from macOS UI.")
                userWantsAlwaysOn = false
                ensureManualOff(reason: "detected-manual-off")
                onStateChanged?()
                return
            }

            // Still enabled, but if schedule mode drifted away from Custom (e.g., mode 0 "Until Tomorrow"
            // or mode 1 "Sunset to Sunrise"), re-lock to our sliding Custom schedule so it won't turn off at 7:00 AM.
            if lastStatus.mode != 2 {
                enforceAlwaysOn(reason: "re-locked-schedule-mode")
            }
            state = .alwaysOn
            onStateChanged?()
        } else {
            // Currently in Manual Off: if user manually clicked Night Shift ON in Control Center / System Settings,
            // immediately resume Always On!
            if lastStatus.enabled {
                logger.info("Detected manual Night Shift ON from macOS UI; resuming Always On.")
                userWantsAlwaysOn = true
                enforceAlwaysOn(reason: "detected-manual-on")
            } else {
                state = .manualOff
            }
            onStateChanged?()
        }
    }

    // MARK: - Timers & System Observers

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: Self.refreshIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.userWantsAlwaysOn {
                    self.enforceAlwaysOn(reason: "periodic-slide")
                    self.onStateChanged?()
                }
            }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func installSystemObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        let wakeNames: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        for name in wakeNames {
            let obs = wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSystemTransition(reason: name.rawValue)
                }
            }
            workspaceObservers.append(obs)
        }

        let center = NotificationCenter.default
        let sysNames: [Notification.Name] = [
            .NSSystemClockDidChange,
            .NSSystemTimeZoneDidChange,
            NSApplication.didChangeScreenParametersNotification
        ]
        for name in sysNames {
            let obs = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSystemTransition(reason: name.rawValue)
                }
            }
            notificationObservers.append(obs)
        }
    }

    private func handleSystemTransition(reason: String) {
        lastSystemTransitionDate = Date()
        guard userWantsAlwaysOn else { return }

        // Give CoreBrightness a short moment to settle after display wake/reconfig, then slide & verify.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.userWantsAlwaysOn else { return }
                self.enforceAlwaysOn(reason: "transition:\(reason)")
                self.onStateChanged?()
            }
        }
    }
}
