import AppKit
import Darwin

// Own the Dock preference only while SoftLock is running. A sleeping helper
// watches process exit and restores the original corner even after a crash.
final class HotCorner {
    private struct Recovery: Codable {
        let owner: Int32
        let token: UUID
        let action: Int
        let modifiers: Int
    }
    private static let recoveryFlag = "--restore-corner"
    private static let dockDomain = "com.apple.dock" as CFString
    private static let actionKey = "wvous-br-corner" as CFString
    private static let modifierKey = "wvous-br-modifier" as CFString
    private static let disabled = 0
    private static let dwellSeconds = 0.35
    private static let cornerSize: CGFloat = 3
    private static let recoveryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SoftLock/hot-corner.json")
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pending: Timer?
    private var inside = false
    private var recovery: Recovery?
    private var helper: Process?
    private let entered: () -> Void

    init(entered: @escaping () -> Void) { self.entered = entered }

    static func runRecovery() -> Bool {
        guard CommandLine.arguments.count == 4, CommandLine.arguments[1] == recoveryFlag,
              let owner = Int32(CommandLine.arguments[2]), let token = UUID(uuidString: CommandLine.arguments[3]) else { return false }
        let source = DispatchSource.makeProcessSource(identifier: owner, eventMask: .exit, queue: .main)
        source.setEventHandler {
            restore(token: token)
            exit(EXIT_SUCCESS)
        }
        source.resume()
        if kill(owner, 0) != 0 && errno == ESRCH {
            restore(token: token)
            return true
        }
        withExtendedLifetime(source) { dispatchMain() }
    }

    func start() throws {
        guard recovery == nil else { return }
        let saved = Recovery(owner: getpid(), token: UUID(), action: Self.read(Self.actionKey), modifiers: Self.read(Self.modifierKey))
        let directory = Self.recoveryURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(saved).write(to: Self.recoveryURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.recoveryURL.path)
        let helper = Process()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = [Self.recoveryFlag, String(saved.owner), saved.token.uuidString]
        try helper.run()
        self.helper = helper
        recovery = saved
        Self.write(action: Self.disabled, modifiers: Self.disabled)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in self?.checkPointer() }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.checkPointer()
            return event
        }
        guard globalMonitor != nil, localMonitor != nil else {
            stop()
            throw NSError(domain: "SoftLock.HotCorner", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not observe pointer movement."])
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        pending?.invalidate(); pending = nil; inside = false
        if let recovery { Self.restore(token: recovery.token) }
        recovery = nil
        if let helper, helper.isRunning { helper.terminate() }
        helper = nil
    }

    private func checkPointer() {
        let point = NSEvent.mouseLocation
        let atCorner = NSScreen.screens.contains {
            point.x >= $0.frame.maxX - Self.cornerSize && point.x < $0.frame.maxX
                && point.y >= $0.frame.minY && point.y <= $0.frame.minY + Self.cornerSize
        }
        guard atCorner != inside else { return }
        inside = atCorner
        pending?.invalidate(); pending = nil
        guard atCorner else { return }
        pending = Timer.scheduledTimer(withTimeInterval: Self.dwellSeconds, repeats: false) { [weak self] _ in self?.entered() }
    }

    private static func read(_ key: CFString) -> Int {
        CFPreferencesAppSynchronize(dockDomain)
        return (CFPreferencesCopyAppValue(key, dockDomain) as? NSNumber)?.intValue ?? disabled
    }

    private static func write(action: Int, modifiers: Int) {
        CFPreferencesSetAppValue(actionKey, NSNumber(value: action), dockDomain)
        CFPreferencesSetAppValue(modifierKey, NSNumber(value: modifiers), dockDomain)
        CFPreferencesAppSynchronize(dockDomain)
        let dock = Process()
        dock.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        dock.arguments = ["Dock"]
        dock.standardError = FileHandle.nullDevice
        try? dock.run()
    }

    private static func restore(token: UUID) {
        guard let data = try? Data(contentsOf: recoveryURL),
              let saved = try? JSONDecoder().decode(Recovery.self, from: data), saved.token == token else { return }
        if read(actionKey) == disabled && read(modifierKey) == disabled {
            write(action: saved.action, modifiers: saved.modifiers)
        }
        try? FileManager.default.removeItem(at: recoveryURL)
    }
}
