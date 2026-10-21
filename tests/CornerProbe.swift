import AppKit
@main struct CornerProbe {
    static func main() throws {
        if HotCorner.runRecovery() { return }
        let corner = HotCorner {}
        try corner.start()
        if CommandLine.arguments.contains("--stop") { corner.stop(); return }
        print("ready")
        fflush(stdout)
        RunLoop.main.run()
    }
}
