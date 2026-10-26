import AppKit

struct ShortcutBinding: Equatable, Hashable, Sendable {
  var keyEquivalent: String
  var modifiers: NSEvent.ModifierFlags

  var isUnbound: Bool { keyEquivalent.isEmpty }

  static let unbound = ShortcutBinding(keyEquivalent: "", modifiers: [])

  init(keyEquivalent: String, modifiers: NSEvent.ModifierFlags) {
    self.keyEquivalent = keyEquivalent
    self.modifiers = modifiers
  }

  init(event: NSEvent) {
    let raw = event.charactersIgnoringModifiers ?? ""
    self.keyEquivalent = raw.lowercased()
    self.modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .intersection([.command, .option, .control, .shift])
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(keyEquivalent)
    hasher.combine(modifiers.rawValue)
  }
}

// MARK: - Display

extension ShortcutBinding {
  var displayName: String {
    guard !isUnbound else { return "None" }
    return Self.modifierSymbols(modifiers) + Self.keyLabel(keyEquivalent)
  }

  static func modifierSymbols(_ modifiers: NSEvent.ModifierFlags) -> String {
    KeyChordSymbols.modifiers(
      control: modifiers.contains(.control),
      option: modifiers.contains(.option),
      shift: modifiers.contains(.shift),
      command: modifiers.contains(.command)
    )
  }

  private static let namedKeys: [String: String] = [
    " ": "Space",
    "\r": "↩",
    "\t": "⇥",
    "\u{1b}": "⎋",
    "\u{8}": "⌫",
    "\u{7f}": "⌫",
    "\u{f700}": "↑",
    "\u{f701}": "↓",
    "\u{f702}": "←",
    "\u{f703}": "→",
    "\u{f729}": "↖",
    "\u{f72b}": "↘",
    "\u{f72c}": "⇞",
    "\u{f72d}": "⇟",
  ]

  static func keyLabel(_ keyEquivalent: String) -> String {
    if let named = namedKeys[keyEquivalent] { return named }
    return keyEquivalent.uppercased()
  }
}

// MARK: - Validation

enum ShortcutBindingRejection: Equatable, Sendable {
  case noModifier
  case reservedBySystem

  var message: String {
    switch self {
    case .noModifier:
      KeyChordSymbols.noModifierMessage
    case .reservedBySystem:
      "macOS reserves that shortcut."
    }
  }
}

enum ShortcutBindingValidation {
  private static let reserved: Set<ShortcutBinding> = [
    ShortcutBinding(keyEquivalent: "\t", modifiers: .command),
    ShortcutBinding(keyEquivalent: " ", modifiers: .command),
    ShortcutBinding(keyEquivalent: "\u{1b}", modifiers: [.command, .option]),
  ]

  static func reject(_ binding: ShortcutBinding) -> ShortcutBindingRejection? {
    guard !binding.isUnbound else { return nil }
    guard binding.modifiers.intersection([.command, .option, .control]).isEmpty == false else {
      return .noModifier
    }
    if reserved.contains(binding) { return .reservedBySystem }
    return nil
  }
}

enum KeyChordSymbols {
  static func modifiers(
    control: Bool,
    option: Bool,
    shift: Bool,
    command: Bool
  ) -> String {
    var out = ""
    if control { out += "⌃" }
    if option { out += "⌥" }
    if shift { out += "⇧" }
    if command { out += "⌘" }
    return out
  }

  static let noModifierMessage = "Use ⌘, ⌥, or ⌃ with another key."
}
