import XCTest
@testable import Boltty

final class AgentRoutingTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func usage(_ percent: Int, resetsIn seconds: TimeInterval? = 5 * 3600) -> AgentUsage {
    AgentUsage(windows: [
      AgentUsageWindow(kind: .session, usedPercent: percent, resetsAt: seconds.map { now + $0 }),
    ])
  }

  private func ranked(
    _ usage: [String: AgentUsage], candidates: [String] = ["claude", "codex", "grok"],
    spentUntil: [String: Date] = [:], sticky: String? = nil, preferred: String? = nil
  ) -> [String] {
    AgentRouting.ranked(
      candidates: candidates, usage: usage, spentUntil: spentUntil, sticky: sticky,
      preferred: preferred, now: now)
  }

  func testTheAgentWithTheMostLeftGoesFirst() {
    XCTAssertEqual(
      ranked(["claude": usage(70), "codex": usage(20), "grok": usage(45)]),
      ["codex", "grok", "claude"])
  }

  func testASpentAgentIsTriedLastAndTheSoonestBackFirstAmongThem() {
    XCTAssertEqual(
      ranked(["claude": usage(100, resetsIn: 7200), "codex": usage(100, resetsIn: 600), "grok": usage(90)]),
      ["grok", "codex", "claude"])
  }

  func testACloseCallStaysWithWhoAnsweredLast() {
    let plans = ["claude": usage(30), "codex": usage(20), "grok": usage(80)]
    XCTAssertEqual(ranked(plans, sticky: "claude").first, "claude")
    XCTAssertEqual(ranked(plans, sticky: "grok").first, "codex")
  }

  func testACloseCallGoesToThePreferredAgentWhenNobodyAnsweredYet() {
    let plans = ["claude": usage(30), "codex": usage(20)]
    XCTAssertEqual(ranked(plans, preferred: "claude").first, "claude")
    XCTAssertEqual(ranked(plans, sticky: "codex", preferred: "claude").first, "codex")
  }

  func testAGapWiderThanACloseCallIsNotOverruled() {
    let plans = ["claude": usage(20 + AgentRouting.closeCall), "codex": usage(20)]
    XCTAssertEqual(ranked(plans, sticky: "claude", preferred: "claude").first, "codex")
  }

  func testAnAgentThatReportsNoPercentageComesAfterThoseThatDo() {
    XCTAssertEqual(
      ranked(["claude": usage(95), "grok": usage(100)], candidates: ["opencode", "claude", "grok"]),
      ["claude", "opencode", "grok"])
  }

  func testWithNothingMeasuredThePreferredAgentLeadsInTabOrder() {
    XCTAssertEqual(ranked([:], preferred: "codex"), ["codex", "claude", "grok"])
    XCTAssertEqual(ranked([:]), ["claude", "codex", "grok"])
  }

  func testALimitHitHereCountsUntilItComesBack() {
    let plans = ["claude": usage(10), "codex": usage(40)]
    XCTAssertEqual(ranked(plans, spentUntil: ["claude": now + 60]), ["codex", "claude"])
    XCTAssertEqual(ranked(plans, spentUntil: ["claude": now - 60]), ["claude", "codex"])
  }

  func testAWindowAlreadyBackCountsForNothing() {
    let standing = AgentRouting.standing(of: "claude", usage: usage(100, resetsIn: -60), now: now)
    XCTAssertFalse(standing.isSpent)
    XCTAssertNil(standing.used)
  }

  func testAWindowAboutToComeBackWeighsHalf() {
    let standing = AgentRouting.standing(of: "claude", usage: usage(80, resetsIn: 600), now: now)
    XCTAssertEqual(standing.used, 40)
  }

  func testTheHandOverSaysWhoAndWhy() {
    let handOver = AgentHandOver(from: .claude, to: .codex, reason: .spent)
    XCTAssertEqual(
      handOver.sentence,
      "\(AgentId.claude.displayName)'s limit is used up · \(AgentId.codex.displayName) answers")
  }
}
