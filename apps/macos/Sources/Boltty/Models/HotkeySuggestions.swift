import Carbon

enum HotkeySuggestions {
  struct Suggestion: Identifiable, Equatable, Sendable {
    let binding: HotkeyBinding
    let rationale: String
    var id: String { binding.displayName }
  }

  static let all: [Suggestion] = [
    suggestion(kVK_Space, optionKey, "what Boltty has always used"),
    suggestion(kVK_Space, controlKey | optionKey, "the chord it had before the recorder existed"),
    suggestion(kVK_Space, cmdKey | shiftKey, "the same key with a handier finger"),
    suggestion(kVK_ANSI_E, optionKey, "a single unmodified letter, next to the prompt"),
    suggestion(kVK_ANSI_F, optionKey, "the same, on the other hand"),
    suggestion(kVK_ANSI_E, controlKey | optionKey, "two modifiers, harder to hit by accident"),
  ]

  static let modifierOnly: [Suggestion] = [
    Suggestion(
      binding: .optionCommand,
      rationale: "⌥ and ⌘ pressed together and let go. Needs Input Monitoring."
    ),
  ]

  static let defaultBinding = HotkeyBinding.optionSpace

  static var fallbacks: [HotkeyBinding] {
    all.map(\.binding).filter {
      $0 != defaultBinding && $0.carbonModifiers != UInt32(optionKey)
    }
  }

  static func firstFree(isFree: (HotkeyBinding) -> Bool) -> HotkeyBinding? {
    fallbacks.first { HotkeyValidation.reject($0) == nil && isFree($0) }
  }

  private static func suggestion(_ keyCode: Int, _ modifiers: Int, _ rationale: String) -> Suggestion {
    Suggestion(
      binding: HotkeyBinding(keyCode: UInt32(keyCode), carbonModifiers: UInt32(modifiers)),
      rationale: rationale
    )
  }
}
