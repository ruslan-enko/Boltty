import AppKit
import Carbon

struct HotkeyBinding: Hashable, Sendable {
  var keyCode: UInt32
  var carbonModifiers: UInt32

  static let optionSpace = HotkeyBinding(
    keyCode: UInt32(kVK_Space),
    carbonModifiers: UInt32(optionKey)
  )

  static let modifiersOnlyKeyCode: UInt32 = 0xFFFF

  var isModifierOnly: Bool { keyCode == Self.modifiersOnlyKeyCode }

  static let optionCommand = HotkeyBinding(
    keyCode: modifiersOnlyKeyCode,
    carbonModifiers: UInt32(optionKey) | UInt32(cmdKey)
  )

  static let modifierOnlyChoices: Set<HotkeyBinding> = [optionCommand]
}

// MARK: - Display

extension HotkeyBinding {
  var displayName: String {
    if isModifierOnly { return Self.modifierSymbols(carbonModifiers) }
    return Self.modifierSymbols(carbonModifiers) + Self.keyLabel(for: keyCode)
  }

  static func modifierSymbols(_ modifiers: UInt32) -> String {
    KeyChordSymbols.modifiers(
      control: modifiers & UInt32(controlKey) != 0,
      option: modifiers & UInt32(optionKey) != 0,
      shift: modifiers & UInt32(shiftKey) != 0,
      command: modifiers & UInt32(cmdKey) != 0
    )
  }

  private static let namedKeys: [Int: String] = [
    kVK_Space: "Space",
    kVK_Return: "Return",
    kVK_ANSI_KeypadEnter: "Enter",
    kVK_Tab: "Tab",
    kVK_Escape: "Esc",
    kVK_Delete: "Delete",
    kVK_ForwardDelete: "⌦",
    kVK_LeftArrow: "←",
    kVK_RightArrow: "→",
    kVK_UpArrow: "↑",
    kVK_DownArrow: "↓",
    kVK_Home: "Home",
    kVK_End: "End",
    kVK_PageUp: "Page Up",
    kVK_PageDown: "Page Down",
    kVK_Help: "Help",
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
    kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
    kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
    kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
  ]

  static func keyLabel(for keyCode: UInt32) -> String {
    if let named = namedKeys[Int(keyCode)] { return named }
    let latin = KeyboardLayoutCharacter.current(for: keyCode)
    if let latin, !latin.isEmpty, latin.allSatisfy(\.isASCII) {
      return latin.uppercased()
    }
    if let fallback = KeyboardLayoutCharacter.ascii(for: keyCode), !fallback.isEmpty {
      return fallback.uppercased()
    }
    return "Key \(keyCode)"
  }
}

// MARK: - Layout translation

enum KeyboardLayoutCharacter {
  static func current(for keyCode: UInt32) -> String? {
    let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
      ?? asciiCapableSource()
    return translate(keyCode, using: source)
  }

  static func ascii(for keyCode: UInt32) -> String? {
    translate(keyCode, using: asciiCapableSource())
  }

  private static func asciiCapableSource() -> TISInputSource? {
    TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
  }

  private static func translate(_ keyCode: UInt32, using source: TISInputSource?) -> String? {
    guard
      let source,
      let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }

    let layoutData = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue() as Data
    var deadKeyState: UInt32 = 0
    var characters = [UniChar](repeating: 0, count: 8)
    var length = 0

    let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
      guard let base = buffer.baseAddress else { return OSStatus(paramErr) }
      return UCKeyTranslate(
        base.assumingMemoryBound(to: UCKeyboardLayout.self),
        UInt16(keyCode),
        UInt16(kUCKeyActionDisplay),
        0,
        UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit),
        &deadKeyState,
        characters.count,
        &length,
        &characters
      )
    }

    guard status == noErr, length > 0 else { return nil }
    return String(utf16CodeUnits: characters, count: length)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

extension NSEvent {
  var latinCharactersIgnoringModifiers: String? {
    let typed = charactersIgnoringModifiers?.lowercased()
    if let typed, !typed.isEmpty, typed.allSatisfy(\.isASCII) { return typed }
    return KeyboardLayoutCharacter.ascii(for: UInt32(keyCode))?.lowercased() ?? typed
  }
}

// MARK: - Validation

enum HotkeyRejection: Equatable, Sendable {
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

enum HotkeyProblem: Equatable {
  case rejected(HotkeyRejection)
  case unavailable(HotkeyBinding, HotkeyAvailability)

  var attempted: HotkeyBinding? {
    switch self {
    case .rejected: nil
    case let .unavailable(binding, _): binding
    }
  }

  var isConflict: Bool {
    if case .unavailable = self { return true }
    return false
  }

  var message: String {
    switch self {
    case let .rejected(rejection):
      rejection.message
    case let .unavailable(binding, availability):
      availability.takenSentence(for: binding)
    }
  }
}

enum HotkeyValidation {
  private static let modifierFreeKeys: Set<UInt32> = Set(
    [
      kVK_Escape,
      kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
      kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ].map { UInt32($0) }
  )

  private static let reservedBySystem: Set<HotkeyBinding> = [
    binding(kVK_Space, cmdKey),
    binding(kVK_Space, controlKey),
    binding(kVK_Space, controlKey | shiftKey),
    binding(kVK_Space, cmdKey | optionKey),
    binding(kVK_Space, cmdKey | controlKey | shiftKey),
    binding(kVK_Escape, cmdKey | optionKey),
    binding(kVK_Escape, cmdKey | controlKey),
  ]

  private static func binding(_ keyCode: Int, _ modifiers: Int) -> HotkeyBinding {
    HotkeyBinding(keyCode: UInt32(keyCode), carbonModifiers: UInt32(modifiers))
  }

  static func reject(_ binding: HotkeyBinding) -> HotkeyRejection? {
    if binding.isModifierOnly {
      return HotkeyBinding.modifierOnlyChoices.contains(binding) ? nil : .noModifier
    }
    if reservedBySystem.contains(binding) { return .reservedBySystem }
    if isBareCommand(binding), !modifierFreeKeys.contains(binding.keyCode) {
      return .reservedBySystem
    }
    let required = UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
    guard binding.carbonModifiers & required != 0 else {
      return modifierFreeKeys.contains(binding.keyCode) ? nil : .noModifier
    }
    return nil
  }

  static func isBareCommand(_ binding: HotkeyBinding) -> Bool {
    let carbon = binding.carbonModifiers
    guard carbon & UInt32(cmdKey) != 0 else { return false }
    let others = UInt32(controlKey) | UInt32(optionKey) | UInt32(shiftKey)
    return carbon & others == 0
  }
}

// MARK: - AppKit bridge

extension HotkeyBinding {
  static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var carbon: UInt32 = 0
    if flags.contains(.command) { carbon |= UInt32(cmdKey) }
    if flags.contains(.option) { carbon |= UInt32(optionKey) }
    if flags.contains(.control) { carbon |= UInt32(controlKey) }
    if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
    return carbon
  }

  init(event: NSEvent) {
    self.init(
      keyCode: UInt32(event.keyCode),
      carbonModifiers: Self.carbonModifiers(from: event.modifierFlags)
    )
  }
}
