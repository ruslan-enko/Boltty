import Foundation

/// One agent's line in the limits window under the menu-bar mark.
struct UsageGlanceRow: Equatable {
  enum Content: Equatable {
    case limits(AgentUsage)
    case signedOut(command: String)
    /// Declares no plan limit (OpenCode): said, not left blank.
    case noPlanLimit
    /// Reports limits, but none has come yet.
    case waiting
  }

  let agent: AgentId
  let content: Content
}

enum UsageGlanceText {
  static func used(_ window: AgentUsageWindow) -> String {
    "\(min(100, max(0, window.usedPercent)))% used"
  }

  static func reset(_ window: AgentUsageWindow, now: Date = Date()) -> String? {
    guard let date = window.resetsAt, date > now else { return nil }
    if window.severity == .exhausted {
      return "Back \(AgentUsageWindow.resetPhrase(date, now: now))"
    }
    return "Resets in \(AgentUsageWindow.countdown(to: date, now: now))"
  }

  static func waiting(isReading: Bool) -> String {
    isReading ? "Reading…" : "No limits reported yet"
  }

  static let noPlanLimit = "Reports no plan limit"
}
