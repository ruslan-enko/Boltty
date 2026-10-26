import Foundation

struct AgentRoutingFallback: Equatable, Sendable {
  let preferred: AgentId
  let used: AgentId
  let reason: String

  var sentence: String {
    "\(preferred.displayName) isn't ready — sent to \(used.displayName) instead."
  }

  var tooltip: String {
    "\(preferred.displayName): \(reason.replacingOccurrences(of: "`", with: ""))"
  }
}
