import AppKit
import Carbon

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
            return nil
        }

        NotificationCenter.default.addObserver(self, selector: #selector(refreshScreens), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        registerShortcut()
        buildMenu()

        if CommandLine.arguments.contains("--smoke-test") {
            toggleLock()
            let valid = locked && covers.count == NSScreen.screens.count && !covers.isEmpty
            print("Display covers: \(covers.count), valid: \(valid)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                toggleLock()
                print("Unlocked: \(!locked && covers.isEmpty)")
                NSApp.terminate(nil)
            }
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
        let quitItem = NSMenuItem(title: "Quit SoftLock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quitItem)
        statusItem.menu = menu
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
            covers.forEach { $0.orderOut(nil) }
            covers.removeAll()
            NSApp.presentationOptions = []
            priorApp?.activate(options: [])
            return
        }

        guard hotKey != nil else { return }
        priorApp = NSWorkspace.shared.frontmostApplication
        locked = true
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]
        refreshScreens()
        NSApp.activate(ignoringOtherApps: true)
        covers.first?.makeKeyAndOrderFront(nil)
    }

    @objc private func refreshScreens() {
        guard locked else { return }
        covers.forEach { $0.orderOut(nil) }
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
            if let content = window.contentView {
                NSLayoutConstraint.activate([
                    label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                    label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
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
