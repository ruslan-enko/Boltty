import Foundation

struct BuiltInKey: Identifiable, Equatable {
  let id: String
  let title: String
  let keys: String
  var detail: String?
}

struct BuiltInKeySection: Identifiable, Equatable {
  let title: String
  let keys: [BuiltInKey]

  var id: String { title }
}

enum BuiltInKeyCatalog {
  static func sections(launchChord: String?, agents: Int = AgentHistory.tabOrder.count) -> [BuiltInKeySection] {
    let choices = agents > 1
    return everySection(launchChord: launchChord).map { section in
      BuiltInKeySection(
        title: section.title,
        keys: section.keys.filter { choices || !["agent", "listAgent"].contains($0.id) })
    }
  }

  private static func everySection(launchChord: String?) -> [BuiltInKeySection] {
    [
      BuiltInKeySection(title: String(localized: "Boltty AI"), keys: [
        BuiltInKey(
          id: "open", title: String(localized: "Open or hide Boltty AI"),
          keys: launchChord ?? String(localized: "Off"),
          detail: launchChord == nil
            ? String(localized: "Switched off on the General page")
            : String(localized: "Works from any app — change it on the General page")
        ),
        BuiltInKey(id: "start", title: String(localized: "Start a chat"), keys: "↩", detail: nil),
        BuiltInKey(id: "newline", title: String(localized: "New line"), keys: String(localized: "⇧↩ or ⌥↩"), detail: nil),
        BuiltInKey(id: "agent", title: String(localized: "Choose the agent"), keys: "⇧⇥", detail: nil),
        BuiltInKey(
          id: "controls", title: String(localized: "Folder, then microphone"), keys: "⇥",
          detail: String(localized: "Space presses the one chosen; a letter goes back to the words")
        ),
        BuiltInKey(id: "list", title: String(localized: "Open the chat list"), keys: "↓", detail: nil),
        BuiltInKey(id: "dictate", title: String(localized: "Dictate"), keys: "⌘D", detail: nil),
        BuiltInKey(id: "folder", title: String(localized: "Choose the folder"), keys: "⌘O", detail: nil),
        BuiltInKey(
          id: "finishDictation", title: String(localized: "Finish dictating"), keys: "↩",
          detail: String(localized: "While the microphone is listening")
        ),
        BuiltInKey(
          id: "mention", title: String(localized: "Add a file"), keys: "@",
          detail: String(localized: "At the start of a word: type its name, ↑ ↓ to choose, ↩ or ⇥ to add it, Esc to let go")
        ),
        BuiltInKey(
          id: "command", title: String(localized: "Use a skill or command"), keys: "/",
          detail: String(localized: "As the first character, where the agent lists them: type its name, ↩ or ⇥ to use it")
        ),
        BuiltInKey(id: "pastePlain", title: String(localized: "Paste as plain text"), keys: "⇧⌘V", detail: nil),
        BuiltInKey(id: "hide", title: String(localized: "Hide"), keys: "Esc", detail: nil),
      ]),
      BuiltInKeySection(title: String(localized: "Chat list"), keys: [
        BuiltInKey(id: "listMove", title: String(localized: "Move between chats"), keys: "↑ ↓", detail: nil),
        BuiltInKey(
          id: "listEnds", title: String(localized: "First or last chat"), keys: "⌘↑ ⌘↓",
          detail: String(localized: "Home and End too")
        ),
        BuiltInKey(
          id: "listPage", title: String(localized: "A page of chats"), keys: "⇞ ⇟",
          detail: String(localized: "Page Up and Page Down — fn↑ and fn↓ on a laptop")
        ),
        BuiltInKey(
          id: "listAgent", title: String(localized: "Switch agent"), keys: "← →",
          detail: String(localized: "While the search field is empty")
        ),
        BuiltInKey(id: "listOpen", title: String(localized: "Open the chat"), keys: "↩", detail: nil),
        BuiltInKey(
          id: "listNew", title: String(localized: "New chat"), keys: "⌘N",
          detail: String(localized: "With the chosen tab's agent; All picks one for you")
        ),
        BuiltInKey(id: "listBack", title: String(localized: "Back"), keys: "Esc", detail: nil),
      ]),
      BuiltInKeySection(title: String(localized: "In a chat"), keys: [
        BuiltInKey(
          id: "send", title: String(localized: "Send"), keys: "↩",
          detail: String(localized: "While the agent works it waits in the queue")
        ),
        BuiltInKey(
          id: "steer", title: String(localized: "Add to the running turn"), keys: "⌘↩",
          detail: String(localized: "Where the agent takes words mid-turn")
        ),
        BuiltInKey(id: "stop", title: String(localized: "Stop the running turn"), keys: "⌘.", detail: nil),
        BuiltInKey(id: "chatNewline", title: String(localized: "New line"), keys: String(localized: "⇧↩ or ⌥↩"), detail: nil),
        BuiltInKey(
          id: "attach", title: String(localized: "Attach a file"), keys: "⇧⌘A",
          detail: String(localized: "Where the agent reads files")
        ),
        BuiltInKey(
          id: "model", title: String(localized: "Choose the model"), keys: "⇧⌘M",
          detail: String(localized: "Applies from the next message")
        ),
        BuiltInKey(id: "chatBack", title: String(localized: "Back to the chat list"), keys: "Esc", detail: nil),
      ]),
      BuiltInKeySection(title: String(localized: "Questions and approvals"), keys: [
        BuiltInKey(id: "answerMove", title: String(localized: "Move between answers"), keys: "↑ ↓", detail: nil),
        BuiltInKey(id: "answerChoose", title: String(localized: "Choose the answer"), keys: "↩", detail: nil),
        BuiltInKey(
          id: "answerNumber", title: String(localized: "Answer by number"), keys: "1 – 9",
          detail: String(localized: "On a question, with the field empty")
        ),
        BuiltInKey(
          id: "answerTick", title: String(localized: "Tick an option"), keys: "Space",
          detail: String(localized: "Where several may be chosen")
        ),
      ]),
      BuiltInKeySection(title: String(localized: "Ask Boltty"), keys: [
        BuiltInKey(
          id: "ask", title: String(localized: "Ask about the screen"), keys: String(localized: "Drag"),
          detail: launchChord.map { String(localized: "Open Boltty AI with \($0), drag across an area, and speak") }
            ?? String(localized: "Open Boltty AI, drag across an area, and speak")
        ),
        BuiltInKey(
          id: "askAgain", title: String(localized: "Ask more"), keys: launchChord ?? String(localized: "Off"),
          detail: String(localized: "While the face is still there. Drag to choose another area")
        ),
        BuiltInKey(
          id: "askSend", title: String(localized: "Send the question"), keys: "↩",
          detail: String(localized: "Or stop speaking")
        ),
        BuiltInKey(
          id: "askCancel", title: String(localized: "Close the question"), keys: "Esc",
          detail: String(localized: "Before the question is sent")
        ),
        BuiltInKey(
          id: "askStop", title: String(localized: "Stop the answer and put the face away"), keys: "Esc",
          detail: String(localized: "Also just after it answers; it takes the drawings too")
        ),
      ]),
      BuiltInKeySection(title: String(localized: "Settings"), keys: [
        BuiltInKey(id: "settingsBack", title: String(localized: "Back"), keys: "⌘[", detail: nil),
        BuiltInKey(id: "settingsForward", title: String(localized: "Forward"), keys: "⌘]", detail: nil),
      ]),
    ]
  }
}
