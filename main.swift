import AppKit
import Carbon
import IOKit.pwr_mgt

private enum AwakeSettings {
    static let defaultHoursKey = "defaultAwakeHours"
    static let initialHours = 1
    static let secondsPerHour: TimeInterval = 3_600
    static let secondsPerMinute: TimeInterval = 60
}

private final class AwakeSession {
    private var assertion: IOPMAssertionID = 0
    private var deadline: Date?
    private var active = false

    var countdown: String {
        guard active else { return "sleeping" }
        guard let deadline else { return "∞" }
        let minutes = max(0, Int(ceil(deadline.timeIntervalSinceNow / AwakeSettings.secondsPerMinute)))
        return "\(minutes)m"
    }

    func start(hours: Int) throws {
        if !active {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "SoftLock background work" as CFString,
                &assertion
            )
            guard result == kIOReturnSuccess else {
                throw NSError(domain: "SoftLock.Power", code: Int(result))
            }
        }
        active = true
        deadline = hours == 0 ? nil : Date().addingTimeInterval(Double(hours) * AwakeSettings.secondsPerHour)
    }

    func hasExpired(at now: Date = Date()) -> Bool {
        guard active, let deadline else { return false }
        return now >= deadline
    }

    func stop() {
        if active { IOPMAssertionRelease(assertion) }
        active = false
        deadline = nil
    }

    deinit { stop() }
}

private enum Shortcut: UInt32 {
    case commandShiftL
    case commandL

    var modifiers: UInt32 {
        self == .commandShiftL ? UInt32(cmdKey | shiftKey) : UInt32(cmdKey)
    }

    var label: String {
        self == .commandShiftL ? "Cmd+Shift+L" : "Cmd+L"
    }
}

private final class CoverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var covers: [NSWindow] = []
    private var hotKey: EventHotKeyRef?
    private var shortcut = Shortcut.commandShiftL
    private var locked = false
    private var keyMonitor: Any?
    private var priorApp: NSRunningApplication?
    private let awake = AwakeSession()
    private var countdowns: [NSTextField] = []
    private var countdownTimer: Timer?
    private var sleepTimer: Timer?
    private var defaultHours: Int {
        let stored = UserDefaults.standard.object(forKey: AwakeSettings.defaultHoursKey) as? Int
        guard let stored, (0...9).contains(stored) else { return AwakeSettings.initialHours }
        return stored
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "SoftLock")

        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue()
            app.toggleLock()
            return noErr
        }, 1, [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))], Unmanaged.passUnretained(self).toOpaque(), nil)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.locked else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.type == .keyDown, !event.isARepeat, modifiers.isEmpty,
               let text = event.characters, text.count == 1,
               let hours = Int(text), (0...9).contains(hours) {
                self.setAwakeHours(hours)
            }
            return nil
        }

        NotificationCenter.default.addObserver(self, selector: #selector(refreshScreens), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        registerShortcut()
        buildMenu()

        if CommandLine.arguments.contains("--smoke-test") {
            toggleLock()
            let valid = locked && covers.count == NSScreen.screens.count && !covers.isEmpty
            print("Display covers: \(covers.count), valid: \(valid)")
            precondition(valid)
            precondition(countdowns.count == covers.count)
            setAwakeHours(9)
            precondition(awake.countdown == "540m")
            precondition(awake.hasExpired(at: Date().addingTimeInterval(10 * AwakeSettings.secondsPerHour)))
            setAwakeHours(0)
            precondition(awake.countdown == "∞")
            precondition(!awake.hasExpired(at: .distantFuture))
            setAwakeHours(1)
            precondition(awake.countdown == "60m")
            checkSleepTimer(at: .distantFuture)
            precondition(awake.countdown == "sleeping")
            precondition(countdownTimer == nil && sleepTimer == nil)
            setAwakeHours(1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                toggleLock()
                precondition(awake.countdown == "sleeping")
                precondition(countdownTimer == nil)
                print("Unlocked: \(!locked && covers.isEmpty)")
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        awake.stop()
        NSApp.presentationOptions = []
    }

    private func setAwakeHours(_ hours: Int) {
        do {
            try awake.start(hours: hours)
            sleepTimer?.invalidate()
            sleepTimer = nil
            if hours > 0 {
                sleepTimer = Timer.scheduledTimer(withTimeInterval: Double(hours) * AwakeSettings.secondsPerHour, repeats: false) { [weak self] _ in
                    self?.checkSleepTimer()
                }
            }
            updateCountdown()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not keep the Mac awake"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func updateCountdown() {
        countdowns.forEach { $0.stringValue = awake.countdown }
    }

    private func checkSleepTimer(at now: Date = Date()) {
        guard awake.hasExpired(at: now) else {
            updateCountdown()
            return
        }
        awake.stop()
        countdownTimer?.invalidate()
        countdownTimer = nil
        sleepTimer?.invalidate()
        sleepTimer = nil
        updateCountdown()

        guard !CommandLine.arguments.contains("--smoke-test") else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        do {
            try process.run()
        } catch {
            countdowns.forEach { $0.stringValue = "sleep failed" }
        }
    }

    private func registerShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        let identifier = EventHotKeyID(signature: 0x534C4F43, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_L), shortcut.modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
        guard result != noErr else { return }
        let alert = NSAlert()
        alert.messageText = "Shortcut unavailable"
        alert.informativeText = "Another app may own \(shortcut.label). Choose another shortcut from the SoftLock menu."
        alert.runModal()
    }

    private func buildMenu() {
        let menu = NSMenu()
        let lockItem = NSMenuItem(title: "Cover all screens (\(shortcut.label))", action: #selector(toggleLock), keyEquivalent: "")
        lockItem.target = self
        lockItem.isEnabled = hotKey != nil
        menu.addItem(lockItem)
        menu.addItem(.separator())

        for option in [Shortcut.commandShiftL, .commandL] {
            let item = NSMenuItem(title: option.label, action: #selector(changeShortcut(_:)), keyEquivalent: "")
            item.tag = Int(option.rawValue)
            item.state = option == shortcut ? .on : .off
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let defaultsItem = NSMenuItem(title: "Keep awake by default", action: nil, keyEquivalent: "")
        let defaultsMenu = NSMenu()
        for hours in 0...9 {
            let title = hours == 0 ? "Indefinitely" : "\(hours) hour\(hours == 1 ? "" : "s")"
            let item = NSMenuItem(title: title, action: #selector(changeDefault(_:)), keyEquivalent: "")
            item.tag = hours
            item.target = self
            item.state = hours == defaultHours ? .on : .off
            defaultsMenu.addItem(item)
        }
        defaultsItem.submenu = defaultsMenu
        menu.addItem(defaultsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit SoftLock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func changeDefault(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: AwakeSettings.defaultHoursKey)
        buildMenu()
    }

    @objc private func changeShortcut(_ sender: NSMenuItem) {
        guard let selection = Shortcut(rawValue: UInt32(sender.tag)) else { return }
        shortcut = selection
        registerShortcut()
        buildMenu()
    }

    @objc private func toggleLock() {
        if locked {
            locked = false
            awake.stop()
            countdownTimer?.invalidate()
            countdownTimer = nil
            sleepTimer?.invalidate()
            sleepTimer = nil
            countdowns.removeAll()
            covers.forEach { $0.orderOut(nil) }
            covers.removeAll()
            NSApp.presentationOptions = []
            priorApp?.activate(options: [])
            return
        }

        guard hotKey != nil else { return }
        priorApp = NSWorkspace.shared.frontmostApplication
        locked = true
        setAwakeHours(defaultHours)
        countdownTimer = Timer.scheduledTimer(withTimeInterval: AwakeSettings.secondsPerMinute, repeats: true) { [weak self] _ in
            self?.checkSleepTimer()
        }
        countdownTimer?.tolerance = 1
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]
        refreshScreens()
        NSApp.activate(ignoringOtherApps: true)
        covers.first?.makeKeyAndOrderFront(nil)
    }

    @objc private func refreshScreens() {
        guard locked else { return }
        covers.forEach { $0.orderOut(nil) }
        countdowns.removeAll()
        covers = NSScreen.screens.map { screen in
            let window = CoverWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.backgroundColor = .black
            window.isOpaque = true
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.setFrame(screen.frame, display: true)

            let label = NSTextField(labelWithString: "Away for a moment")
            label.font = .systemFont(ofSize: 22, weight: .medium)
            label.textColor = .darkGray
            label.translatesAutoresizingMaskIntoConstraints = false
            window.contentView?.addSubview(label)
            let countdown = NSTextField(labelWithString: awake.countdown)
            countdown.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            countdown.textColor = NSColor(white: 0.16, alpha: 1)
            countdown.translatesAutoresizingMaskIntoConstraints = false
            window.contentView?.addSubview(countdown)
            countdowns.append(countdown)
            if let content = window.contentView {
                NSLayoutConstraint.activate([
                    label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                    label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                    countdown.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                    countdown.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
                ])
            }
            window.orderFrontRegardless()
            return window
        }
        covers.first?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
