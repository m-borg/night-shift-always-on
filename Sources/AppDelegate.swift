import Cocoa
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = NightShiftController()
    private var statusItem: NSStatusItem!

    private var statusTitleItem: NSMenuItem!
    private var statusSubtitleItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var warmthLabel: NSTextField!
    private var warmthSlider: NSSlider!
    private var launchAtLoginItem: NSMenuItem!

    private static let launchAgentLabel = "com.local.nightshift-always-on"
    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        controller.onStateChanged = { [weak self] in
            self?.updateUI()
        }
        controller.start()
        updateUI()
    }

    // MARK: - Menu Bar Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.delegate = self

        statusTitleItem = NSMenuItem(title: "Night Shift: Always On", action: nil, keyEquivalent: "")
        statusTitleItem.isEnabled = false
        menu.addItem(statusTitleItem)

        statusSubtitleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusSubtitleItem.isEnabled = false
        menu.addItem(statusSubtitleItem)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(title: "Turn Night Shift Off", action: #selector(toggleNightShift), keyEquivalent: "t")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let sliderItem = NSMenuItem()
        sliderItem.view = makeWarmthSliderView()
        menu.addItem(sliderItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Open Display Settings…",
            action: #selector(openDisplaySettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        launchAtLoginItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit NightShiftAlwaysOn",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func makeWarmthSliderView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 48))

        let label = NSTextField(labelWithString: "Color Temperature: 50%")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 16, y: 26, width: 208, height: 16)
        container.addSubview(label)
        self.warmthLabel = label

        let slider = NSSlider(value: 0.5, minValue: 0.0, maxValue: 1.0, target: self, action: #selector(warmthSliderChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 16, y: 4, width: 208, height: 20)
        container.addSubview(slider)
        self.warmthSlider = slider

        return container
    }

    // MARK: - UI Sync

    func menuWillOpen(_ menu: NSMenu) {
        controller.refreshCurrentStatus()
        updateUI()
    }

    private func updateUI() {
        let button = statusItem.button

        switch controller.state {
        case .alwaysOn:
            setStatusIcon(symbolName: "moon.stars.fill", fallback: "NS", description: "Night Shift Always On")
            button?.appearsDisabled = false
            statusTitleItem.title = "Night Shift: Always On"
            let toTime = controller.lastStatus.schedule.toTime
            statusSubtitleItem.title = String(
                format: "Protected (sliding gap stays at %02d:%02d)",
                toTime.hour, toTime.minute
            )
            toggleItem.title = "Turn Night Shift Off"
            toggleItem.isEnabled = true

        case .manualOff:
            setStatusIcon(symbolName: "moon", fallback: "ns", description: "Night Shift Off (Manual)")
            button?.appearsDisabled = true
            statusTitleItem.title = "Night Shift: Off (Manual)"
            statusSubtitleItem.title = "Won't turn on until you click it back on"
            toggleItem.title = "Turn Night Shift On (Always On)"
            toggleItem.isEnabled = true

        case .unsupported:
            setStatusIcon(symbolName: "exclamationmark.triangle", fallback: "!", description: "Night Shift Unsupported")
            button?.appearsDisabled = true
            statusTitleItem.title = "Night Shift: Unavailable"
            statusSubtitleItem.title = "Not supported on current display"
            toggleItem.title = "Unavailable"
            toggleItem.isEnabled = false
        }

        let pct = Int(round(controller.strength * 100))
        warmthLabel.stringValue = "Warmth: \(pct)%"
        warmthSlider.doubleValue = Double(controller.strength)
        launchAtLoginItem.state = FileManager.default.fileExists(atPath: Self.launchAgentURL.path) ? .on : .off
    }

    private func setStatusIcon(symbolName: String, fallback: String, description: String) {
        guard let button = statusItem.button else { return }
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let configured = image.withSymbolConfiguration(config) ?? image
            configured.isTemplate = true
            button.image = configured
            button.title = ""
        } else {
            button.image = nil
            button.title = fallback
        }
    }

    // MARK: - Actions

    @objc private func toggleNightShift() {
        controller.toggleFromUser()
    }

    @objc private func warmthSliderChanged(_ sender: NSSlider) {
        let value = Float(sender.doubleValue)
        let isCommit = NSApp.currentEvent?.type == .leftMouseUp
        controller.setWarmth(value, commit: isCommit)
    }

    @objc private func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let fm = FileManager.default
        let plistURL = Self.launchAgentURL
        if fm.fileExists(atPath: plistURL.path) {
            try? fm.removeItem(at: plistURL)
        } else {
            let execPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let plist: [String: Any] = [
                "Label": Self.launchAgentLabel,
                "ProgramArguments": [execPath],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "ProcessType": "Interactive"
            ]
            try? fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: plistURL, options: .atomic)
            }
        }
        updateUI()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
