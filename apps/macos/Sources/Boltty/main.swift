import AppKit

enum LaunchTrace {
  static let enabled = ProcessInfo.processInfo.environment["BOLTTY_LAUNCH_TRACE"] == "1"
  nonisolated(unsafe) static var start = ProcessInfo.processInfo.systemUptime
  nonisolated(unsafe) static var last = ProcessInfo.processInfo.systemUptime

  static func mark(_ label: String) {
    guard enabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let line = String(
      format: "[launch] %7.1f ms   step %6.1f ms   %@\n",
      (now - start) * 1000,
      (now - last) * 1000,
      label
    )
    FileHandle.standardError.write(Data(line.utf8))
    last = now
  }
}

_ = LaunchTrace.start

// Not NSApplicationMain: it can ignore a delegate assigned in code. Made first: it checks in with
// LaunchServices, which 0.2.5 and older wait for.
let app = NSApplication.shared

UpdateInstaller.waitForReplacedCopy()

// Ignore SIGPIPE: a write to a CLI that has just exited must not kill Boltty.
signal(SIGPIPE, SIG_IGN)

let delegate = AppDelegate()
app.setActivationPolicy(AppDelegate.isHostingUnitTests ? .accessory : .regular)
app.delegate = delegate
LaunchTrace.mark("NSApplication.shared + delegate")
app.run()
