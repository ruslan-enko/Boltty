import Foundation

/// A key Boltty answers that is not a menu command, so it cannot be rebound:
/// the panel's own keys, Ask Boltty's chord, Settings' ‹ ›.
struct BuiltInKey: Identifiable, Equatable {
  let id: String
  let title: String
  let keys: String
  /// One line under the title: where the key works, or where to change it.
  var detail: String?
}

struct BuiltInKeySection: Identifiable, Equatable {
  let title: String
  let keys: [BuiltInKey]

  var id: String { title }
}

/// Every key the product answers besides the menu's (`KeyboardShortcutCatalog`),
/// written down from where the panel handles them
/// (`AgentPaletteView.textView(_:doCommandBy:)`, `PromptTextView`,
/// `ModifierHoldMonitor`, Settings' toolbar). Settings › Shortcuts lists them
/// so a key that exists is a key that can be found; a key added to the panel
/// is added here in the same change.
enum BuiltInKeyCatalog {
  /// `launchChord` is the key that opens Boltty AI from anywhere (`nil`: it is
  /// switched off); `askBolttyChord` the keys held to ask about the screen.
  static func sections(
    launchChord: String?,
    askBolttyChord: String,
    askBolttyIsOn: Bool
  ) -> [BuiltInKeySection] {
    [
      BuiltInKeySection(title: "Boltty AI", keys: [
        BuiltInKey(
          id: "open", title: "Open or hide Boltty AI",
          keys: launchChord ?? "Off",
          detail: launchChord == nil
            ? "Switched off on the General page"
            : "Works from any app — change it on the General page"
        ),
        BuiltInKey(id: "start", title: "Start a chat", keys: "↩", detail: nil),
        BuiltInKey(id: "newline", title: "New line", keys: "⇧↩ or ⌥↩", detail: nil),
        BuiltInKey(id: "agent", title: "Choose the agent", keys: "⇧⇥", detail: nil),
        BuiltInKey(
          id: "controls", title: "Folder, then microphone", keys: "⇥",
          detail: "Space presses the one chosen; a letter goes back to the words"
        ),
        BuiltInKey(id: "list", title: "Open the chat list", keys: "↓", detail: nil),
        BuiltInKey(
          id: "finishDictation", title: "Finish dictating", keys: "↩",
          detail: "While the microphone is listening"
        ),
        BuiltInKey(id: "pastePlain", title: "Paste as plain text", keys: "⇧⌘V", detail: nil),
        BuiltInKey(id: "hide", title: "Hide", keys: "Esc", detail: nil),
      ]),
      BuiltInKeySection(title: "Chat list", keys: [
        BuiltInKey(id: "listMove", title: "Move between chats", keys: "↑ ↓", detail: nil),
        BuiltInKey(
          id: "listEnds", title: "First or last chat", keys: "⌘↑ ⌘↓",
          detail: "Home and End too"
        ),
        BuiltInKey(
          id: "listPage", title: "A page of chats", keys: "⇞ ⇟",
          detail: "Page Up and Page Down — fn↑ and fn↓ on a laptop"
        ),
        BuiltInKey(
          id: "listAgent", title: "Switch agent", keys: "← →",
          detail: "While the search field is empty"
        ),
        BuiltInKey(id: "listOpen", title: "Open the chat", keys: "↩", detail: nil),
        BuiltInKey(
          id: "listNew", title: "New chat", keys: "⌘N",
          detail: "With the chosen tab's agent; All picks one for you"
        ),
        BuiltInKey(id: "listBack", title: "Back", keys: "Esc", detail: nil),
      ]),
      BuiltInKeySection(title: "In a chat", keys: [
        BuiltInKey(
          id: "send", title: "Send", keys: "↩",
          detail: "While the agent works it waits in the queue"
        ),
        BuiltInKey(
          id: "steer", title: "Add to the running turn", keys: "⌘↩",
          detail: "Where the agent takes words mid-turn"
        ),
        BuiltInKey(id: "stop", title: "Stop the running turn", keys: "⌘.", detail: nil),
        BuiltInKey(id: "chatNewline", title: "New line", keys: "⇧↩ or ⌥↩", detail: nil),
        BuiltInKey(id: "chatBack", title: "Back to the chat list", keys: "Esc", detail: nil),
      ]),
      BuiltInKeySection(title: "Questions and approvals", keys: [
        BuiltInKey(id: "answerMove", title: "Move between answers", keys: "↑ ↓", detail: nil),
        BuiltInKey(id: "answerChoose", title: "Choose the answer", keys: "↩", detail: nil),
        BuiltInKey(
          id: "answerNumber", title: "Answer by number", keys: "1 – 9",
          detail: "On a question, with the field empty"
        ),
        BuiltInKey(
          id: "answerTick", title: "Tick an option", keys: "Space",
          detail: "Where several may be chosen"
        ),
      ]),
      BuiltInKeySection(title: "Ask Boltty", keys: [
        BuiltInKey(
          id: "ask", title: "Ask about the screen", keys: "Hold \(askBolttyChord)",
          detail: askBolttyIsOn
            ? "Speak, then let go"
            : "Off — switch it on under Ask Boltty"
        ),
        BuiltInKey(
          id: "askCancel", title: "Cancel", keys: "Any other key",
          detail: "Pressed while the keys are held"
        ),
        BuiltInKey(
          id: "askStop", title: "Stop the answer", keys: "Esc",
          detail: "While it thinks or answers; it also takes its drawings away"
        ),
      ]),
      BuiltInKeySection(title: "Settings", keys: [
        BuiltInKey(id: "settingsBack", title: "Back", keys: "⌘[", detail: nil),
        BuiltInKey(id: "settingsForward", title: "Forward", keys: "⌘]", detail: nil),
      ]),
    ]
  }
}
