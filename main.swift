import AppKit
import Carbon
import LocalAuthentication
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

private enum AuthenticationResult { case accepted, rejected }

private enum PinPrompt {
    case hidden, setup, confirm, unlock, disable
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let cornerKey = "bottomRightHotCorner"
    private var corner: HotCorner?
    private var authentication: LAContext?
    private var authenticationID: UUID?
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
    private let pinStore: PinStore
    private var pinEnabled = false
    private var pinPrompt = PinPrompt.hidden
    private var pinInput = ""
    private var pendingPin = ""
    private var pinMessage = ""
    private var pinLabels: [NSTextField] = []

    override init() {
        let directory: URL
        if CommandLine.arguments.contains("--smoke-test") {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("SoftLock-\(UUID())")
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SoftLock")
        }
        pinStore = PinStore(url: directory.appendingPathComponent("pin.json"))
        super.init()
    }
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
               let text = event.characters {
                self.handleCoverKey(text)
            }
            return nil
        }

        NotificationCenter.default.addObserver(self, selector: #selector(refreshScreens), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        registerShortcut()
        if UserDefaults.standard.bool(forKey: Self.cornerKey), !CommandLine.arguments.contains("--smoke-test") {
            enableCorner()
        }
        buildMenu()

        if CommandLine.arguments.contains("--smoke-test") {
            toggleLock()
            let valid = locked && covers.count == NSScreen.screens.count && !covers.isEmpty
            print("Display covers: \(covers.count), valid: \(valid)")
            precondition(valid)
            precondition(countdowns.count == covers.count)
            let testPin = String(Int.random(in: 1000...9999))
            handleCoverKey("p")
            precondition(pinPrompt == .setup && !pinEnabled)
            for digit in testPin { handleCoverKey(String(digit)) }
            handleCoverKey("\r")
            precondition(pinPrompt == .confirm)
            for digit in testPin { handleCoverKey(String(digit)) }
            handleCoverKey("\r")
            precondition(pinEnabled && pinPrompt == .hidden)
            toggleLock()
            precondition(locked && pinPrompt == .unlock)
            let wrongPin = String((Int(testPin)! + 1) % 10000).padding(toLength: 4, withPad: "0", startingAt: 0)
            for digit in wrongPin { handleCoverKey(String(digit)) }
            handleCoverKey("\r")
            precondition(locked && pinPrompt == .unlock)
            handleCoverKey("\u{1b}")
            handleCoverKey("p")
            precondition(pinPrompt == .disable && pinEnabled)
            for digit in testPin { handleCoverKey(String(digit)) }
            handleCoverKey("\r")
            precondition(!pinEnabled && locked && pinPrompt == .hidden)
            handleCoverKey("p")
            toggleLock()
            for digit in testPin { handleCoverKey(String(digit)) }
            handleCoverKey("\r")
            precondition(!locked && covers.isEmpty)
            toggleLock()
            let authenticationTest = UUID()
            authenticationID = authenticationTest
            finishTouchID(.accepted, identifier: UUID())
            precondition(locked, "Stale authentication must not unlock")
            finishTouchID(.rejected, identifier: authenticationTest)
            precondition(locked, "Failed authentication must not unlock")
            authenticationID = authenticationTest
            finishTouchID(.accepted, identifier: authenticationTest)
            precondition(!locked, "Successful authentication must unlock")
            toggleLock()
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

    private func handleCoverKey(_ text: String) {
        if text == " " || (pinPrompt == .hidden && (text == "\r" || text == "\n")) {
            requestTouchID()
            return
        }
        if pinPrompt != .hidden {
            if text == "\u{1b}" {
                showPinPrompt(.hidden)
            } else if text == "\u{7f}" {
                if !pinInput.isEmpty { pinInput.removeLast() }
            } else if text == "\r" || text == "\n" {
                submitPin()
            } else if text.count == 1, "0123456789".contains(text), pinInput.count < 4 {
                pinInput += text
            }
            updatePinLabels()
            return
        }

        if text.lowercased() == "p" {
            showPinPrompt(pinEnabled ? .disable : (pinStore.exists() ? .hidden : .setup))
            if !pinEnabled && pinStore.exists() {
                pinEnabled = true
                updateCountdown()
            }
            return
        }

        if text.count == 1, let hours = Int(text), (0...9).contains(hours) {
            setAwakeHours(hours)
        }
    }

    private func showPinPrompt(_ prompt: PinPrompt) {
        pinPrompt = prompt
        pinInput = ""
        pinMessage = ""
        if prompt != .confirm { pendingPin = "" }
        updatePinLabels()
    }

    private func submitPin() {
        guard pinInput.count == 4 else { return }
        do {
            switch pinPrompt {
            case .setup:
                pendingPin = pinInput
                showPinPrompt(.confirm)
            case .confirm:
                guard pinInput == pendingPin else {
                    showPinPrompt(.setup)
                    pinMessage = "PINs differ. Try again."
                    return
                }
                try pinStore.save(pinInput)
                pinEnabled = true
                showPinPrompt(.hidden)
            case .unlock, .disable:
                guard try pinStore.matches(pinInput) else {
                    pinInput = ""
                    pinMessage = "Incorrect PIN"
                    return
                }
                let action = pinPrompt
                showPinPrompt(.hidden)
                if action == .unlock { unlockScreens() }
                else { pinEnabled = false }
            case .hidden:
                break
            }
        } catch {
            pinInput = ""
            pinMessage = "Could not access local PIN"
        }
        updateCountdown()
    }

    private func updatePinLabels() {
        let title: String
        switch pinPrompt {
        case .hidden: title = ""
        case .setup: title = "Set a 4-digit PIN"
        case .confirm: title = "Confirm PIN"
        case .unlock: title = "Enter PIN to unlock"
        case .disable: title = "Enter PIN to disable protection"
        }
        let text = pinPrompt == .hidden ? pinMessage : "\(title)\n\(String(repeating: "•", count: pinInput.count))\n\(pinMessage.isEmpty ? "Return to confirm · Esc to cancel" : pinMessage)"
        pinLabels.forEach { $0.stringValue = text }
    }

    func applicationWillTerminate(_ notification: Notification) {
        authentication?.invalidate()
        corner?.stop()
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
        countdowns.forEach { $0.stringValue = awake.countdown + (pinEnabled ? " · PIN" : "") }
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
        let cornerItem = NSMenuItem(title: "Bottom-right hot corner", action: #selector(toggleCorner), keyEquivalent: "")
        cornerItem.target = self
        cornerItem.state = corner == nil ? .off : .on
        menu.addItem(cornerItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit SoftLock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func toggleCorner() {
        if let corner {
            corner.stop()
            self.corner = nil
            UserDefaults.standard.set(false, forKey: Self.cornerKey)
        } else {
            enableCorner()
        }
        buildMenu()
    }

    private func enableCorner() {
        let corner = HotCorner { [weak self] in
            guard let self, !self.locked else { return }
            self.toggleLock()
        }
        do {
            try corner.start()
            self.corner = corner
            UserDefaults.standard.set(true, forKey: Self.cornerKey)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not enable the hot corner"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func requestTouchID() {
        guard locked, authentication == nil else { return }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            if pinEnabled { showPinPrompt(.unlock) }
            pinMessage = "Touch ID unavailable. Use your shortcut or PIN."
            updatePinLabels()
            return
        }
        pinMessage = ""
        updatePinLabels()
        let identifier = UUID()
        authenticationID = identifier
        authentication = context
        // Keep covers visible while allowing the system authentication dialog above them.
        covers.forEach { $0.level = .normal }
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                               localizedReason: "Unlock SoftLock") { [weak self] success, _ in
            DispatchQueue.main.async { self?.finishTouchID(success ? .accepted : .rejected, identifier: identifier) }
        }
    }

    private func finishTouchID(_ result: AuthenticationResult, identifier: UUID) {
        guard locked, authenticationID == identifier else { return }
        authentication = nil
        authenticationID = nil
        if result == .accepted {
            unlockScreens()
            return
        }
        pinMessage = "Touch ID did not unlock. Press Return or click Touch ID to try again."
        updatePinLabels()
        covers.forEach { $0.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow))) }
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]
        NSApp.activate(ignoringOtherApps: true)
        covers.first?.makeKeyAndOrderFront(nil)
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
            if pinEnabled {
                showPinPrompt(.unlock)
                return
            }
            unlockScreens()
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
        // Touch ID only listens during an authentication request. Arm it for
        // every cover session, including sessions without PIN protection.
        if !CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.main.async { [weak self] in self?.requestTouchID() }
        }
    }

    private func unlockScreens() {
        authenticationID = nil
        authentication?.invalidate()
        authentication = nil
        locked = false
        pinEnabled = false
        showPinPrompt(.hidden)
        pinLabels.removeAll()
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
    }

    @objc private func refreshScreens() {
        guard locked else { return }
        covers.forEach { $0.orderOut(nil) }
        countdowns.removeAll()
        pinLabels.removeAll()
        covers = NSScreen.screens.map { screen in
            let window = CoverWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.backgroundColor = .black
            window.isOpaque = true
            window.level = authentication == nil ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow))) : .normal
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
            let pinLabel = NSTextField(wrappingLabelWithString: "")
            pinLabel.alignment = .center
            pinLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            pinLabel.textColor = .gray
            pinLabel.translatesAutoresizingMaskIntoConstraints = false
            window.contentView?.addSubview(pinLabel)
            pinLabels.append(pinLabel)
            if let content = window.contentView {
                NSLayoutConstraint.activate([
                    label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                    label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                    countdown.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                    countdown.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
                    pinLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                    pinLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 24),
                    pinLabel.widthAnchor.constraint(equalToConstant: 320)
                ])
            }
            let touch = NSButton(title: "Touch ID", target: self, action: #selector(requestTouchID))
            touch.bezelStyle = .rounded
            touch.translatesAutoresizingMaskIntoConstraints = false
            window.contentView?.addSubview(touch)
            if let content = window.contentView {
                NSLayoutConstraint.activate([
                    touch.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                    touch.topAnchor.constraint(equalTo: pinLabel.bottomAnchor, constant: 16)
                ])
            }
            window.orderFrontRegardless()
            return window
        }
        covers.first?.makeKeyAndOrderFront(nil)
        updatePinLabels()
        updateCountdown()
    }
}

if HotCorner.runRecovery() { exit(EXIT_SUCCESS) }

let app = NSApplication.shared
private let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
