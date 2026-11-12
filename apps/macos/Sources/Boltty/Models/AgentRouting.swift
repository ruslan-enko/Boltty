import Foundation

/// Who a new chat goes to when nobody was chosen: the agent with the most of
/// its plan left. Plans are in different units, so only the percentage used and
/// the time it comes back are ever compared.
enum AgentRouting {
  static let closeCall = 15
  static let soonReset: TimeInterval = 60 * 60

  struct Standing: Equatable, Sendable {
    var providerID: String
    /// `nil` when the agent reports no percentage.
    var used: Int?
    var isSpent: Bool
    var comesBack: Date?
  }

  /// The candidates in the order they are tried. `candidates` come in tab
  /// order; `sticky` is who answered last and `preferred` the person's own
  /// agent, each winning a close call so the choice does not jump about.
  static func ranked(
    candidates: [String],
    usage: [String: AgentUsage],
    spentUntil: [String: Date] = [:],
    sticky: String? = nil,
    preferred: String? = nil,
    now: Date = Date()
  ) -> [String] {
    let standings = candidates.map {
      standing(of: $0, usage: usage[$0], spentUntil: spentUntil[$0], now: now)
    }
    let place = Dictionary(
      candidates.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    func inTabOrder(_ lhs: Standing, _ rhs: Standing) -> Bool {
      (place[lhs.providerID] ?? 0) < (place[rhs.providerID] ?? 0)
    }

    var measured = standings.filter { !$0.isSpent && $0.used != nil }.sorted {
      $0.used == $1.used ? inTabOrder($0, $1) : ($0.used ?? 0) < ($1.used ?? 0)
    }
    let unmeasured = standings.filter { !$0.isSpent && $0.used == nil }
    let spent = standings.filter(\.isSpent).sorted {
      switch ($0.comesBack, $1.comesBack) {
      case let (lhs?, rhs?) where lhs != rhs: lhs < rhs
      case (_?, nil): true
      case (nil, _?): false
      default: inTabOrder($0, $1)
      }
    }

    if let best = measured.first?.used {
      let close = measured.filter { ($0.used ?? 0) - best < closeCall }.map(\.providerID)
      if let favourite = [sticky, preferred].compactMap({ $0 }).first(where: close.contains),
         let index = measured.firstIndex(where: { $0.providerID == favourite }) {
        measured.insert(measured.remove(at: index), at: 0)
      }
      return (measured + unmeasured + spent).map(\.providerID)
    }
    var open = unmeasured.map(\.providerID)
    if let favourite = [sticky, preferred].compactMap({ $0 }).first(where: open.contains),
       let index = open.firstIndex(of: favourite) {
      open.insert(open.remove(at: index), at: 0)
    }
    return open + spent.map(\.providerID)
  }

  static func standing(
    of providerID: String, usage: AgentUsage?, spentUntil: Date? = nil, now: Date = Date()
  ) -> Standing {
    let live = (usage?.windows ?? []).filter { window in
      window.resetsAt.map { $0 > now } ?? true
    }
    let exhausted = live.filter { $0.severity == .exhausted }
    let heldBack = spentUntil.flatMap { $0 > now ? $0 : nil }
    if !exhausted.isEmpty || heldBack != nil {
      let returns = exhausted.compactMap(\.resetsAt) + [heldBack].compactMap { $0 }
      return Standing(providerID: providerID, used: 100, isSpent: true, comesBack: returns.max())
    }
    let used = live.map { window -> Int in
      let soon = window.resetsAt.map { $0.timeIntervalSince(now) < soonReset } ?? false
      return soon ? window.usedPercent / 2 : window.usedPercent
    }.max()
    return Standing(providerID: providerID, used: used, isSpent: false, comesBack: nil)
  }

  static func isSpent(_ usage: AgentUsage?, now: Date) -> Bool {
    standing(of: "", usage: usage, now: now).isSpent
  }
}

/// A turn that failed before any word, given to the next agent.
struct AgentHandOver: Equatable, Sendable {
  enum Reason: Equatable, Sendable { case spent, modelGone, failed }

  let from: AgentId
  let to: AgentId
  let reason: Reason

  var sentence: String { Self.sentence(skipped: from.displayName, why: reason, next: to.displayName) }

  static func sentence(skipped: String, why: Reason, next: String) -> String {
    switch why {
    case .spent: "\(skipped)'s limit is used up · \(next) answers"
    case .modelGone: "\(skipped)'s model is gone · \(next) answers"
    case .failed: "\(skipped) could not answer · \(next) answers"
    }
  }
}
