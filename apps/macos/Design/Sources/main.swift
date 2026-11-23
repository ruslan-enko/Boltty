import AppKit

// The product's main.swift is left out, and this with it.
enum LaunchTrace {
  static func mark(_ label: String) {}
}

let app = NSApplication.shared
// The person's own faces and settings, read and never written.
UserDefaults.standard.addSuite(named: "com.boltty.app")
let design = DesignWindowController()
app.delegate = design
app.run()
