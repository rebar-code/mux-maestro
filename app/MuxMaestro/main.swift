import Cocoa
import GhosttyKit

// Before anything reads settings: carry them over from the old bundle ID.
DefaultsMigration.migrate()

// libghostty must be initialized once, before any other ghostty_* call.
// Reused from Ghostty's macos/Sources/App/macOS/main.swift.
if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    NSLog("MuxMaestro: ghostty_init failed")
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
