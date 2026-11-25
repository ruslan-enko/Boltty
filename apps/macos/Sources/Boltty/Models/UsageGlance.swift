import Foundation

struct UsageGlanceRow: Equatable {
  enum Content: Equatable {
    case limits(AgentUsage)
    case signedOut(command: String)
    case noPlanLimit
    case waiting
  }

  let agent: AgentId
  let content: Content
  var takesNextChat = false
}

enum UsageGlanceText {
  static let takesNextChat = String(localized: "Next chat")

  static func used(_ window: AgentUsageWindow) -> String {
    String(localized: "\(min(100, max(0, window.usedPercent)))% used")
  }

  static func reset(_ window: AgentUsageWindow, now: Date = Date()) -> String? {
    guard let date = window.resetsAt, date > now else { return nil }
    if window.severity == .exhausted {
      return String(localized: "back \(AgentUsageWindow.resetPhrase(date, now: now))")
    }
    return String(localized: "resets in \(AgentUsageWindow.countdown(to: date, now: now))")
  }

  static func waiting(isReading: Bool) -> String {
    isReading ? String(localized: "Reading limits…") : String(localized: "No limits reported yet")
  }

  static let noPlanLimit = String(localized: "Reports no plan limit")
}
