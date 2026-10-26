import AppKit

struct KeyboardShortcut: Identifiable {
  let id: String
  let title: String
  let display: String
  let keyEquivalent: String?
  let modifiers: NSEvent.ModifierFlags
}

struct KeyboardShortcutSection: Identifiable {
  let title: String
  let shortcuts: [KeyboardShortcut]

  var id: String { title }
}

enum KeyboardShortcutCatalog {
  static let sections: [KeyboardShortcutSection] = [
    KeyboardShortcutSection(title: "Boltty", shortcuts: [
      shortcut("settings", "Settings", "⌘,", ",", .command),
      shortcut("closeBoltty", "Close Boltty", "⌘Q", "q", .command)
    ]),
    KeyboardShortcutSection(title: "Edit", shortcuts: [
      shortcut("copy", "Copy", "⌘C", "c", .command),
      shortcut("paste", "Paste", "⌘V", "v", .command),
      shortcut("selectAll", "Select All", "⌘A", "a", .command)
    ]),
    KeyboardShortcutSection(title: "Window", shortcuts: [
      shortcut("minimize", "Minimize", "⌘M", "m", .command)
    ])
  ]

  static func shortcut(for id: String) -> KeyboardShortcut {
    guard let entry = entry(for: id) else {
      preconditionFailure("Missing shortcut catalog entry: \(id)")
    }
    return entry
  }

  static func entry(for id: String) -> KeyboardShortcut? {
    for section in sections {
      if let shortcut = section.shortcuts.first(where: { $0.id == id }) {
        return shortcut
      }
    }
    return nil
  }

  static let allShortcuts: [KeyboardShortcut] = sections.flatMap(\.shortcuts)

  static let customizableIDs: [String] = allShortcuts.map(\.id)

  private static func shortcut(
    _ id: String,
    _ title: String,
    _ display: String,
    _ keyEquivalent: String?,
    _ modifiers: NSEvent.ModifierFlags
  ) -> KeyboardShortcut {
    KeyboardShortcut(
      id: id,
      title: title,
      display: display,
      keyEquivalent: keyEquivalent,
      modifiers: modifiers
    )
  }
}
