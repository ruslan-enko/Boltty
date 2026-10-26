import XCTest
@testable import Boltty

final class AgentHistoryTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }()

  private var now: Date {
    calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12))!
  }

  private func at(_ daysAgo: Int, hour: Int = 9) -> Date {
    let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
    return calendar.date(
      bySettingHour: hour, minute: 0, second: 0, of: day
    )!
  }

  private func row(
    _ agent: AgentId,
    _ title: String,
    updated: Date
  ) -> BolttyAISessionItem {
    BolttyAISessionItem(
      id: UUID(),
      title: title,
      subtitle: "",
      agent: agent,
      isCurrent: false,
      updatedAt: updated
    )
  }

  private func sections(
    _ items: [BolttyAISessionItem],
    agent: AgentId? = nil
  ) -> [AgentHistory.Section] {
    AgentHistory.sections(items, agent: agent, now: now, calendar: calendar)
  }

  // MARK: - Tabs

  func testEveryAdapterKeepsATabEvenWithNothingBehindIt() {
    let tabs = AgentHistory.tabs([
      row(.claude, "One", updated: at(0))
    ])

    XCTAssertEqual(tabs.map(\.agent), AgentHistory.tabOrder)
    XCTAssertEqual(tabs.first { $0.agent == .claude }?.count, 1)
    XCTAssertEqual(tabs.filter(\.isEmpty).count, AgentId.adapterCases.count - 1)
  }

  func testATabCountsEveryConversationOfItsAgentNotWhatTheFilterShows() {
    let tabs = AgentHistory.tabs([
      row(.codex, "A", updated: at(0)),
      row(.codex, "B", updated: at(40)),
      row(.grok, "C", updated: at(0))
    ])

    XCTAssertEqual(tabs.first { $0.agent == .codex }?.count, 2)
    XCTAssertEqual(tabs.first { $0.agent == .grok }?.count, 1)
  }

  // MARK: - Filtering by tab

  func testNoActiveTabMeansEveryAgent() {
    let all = sections([
      row(.claude, "Claude", updated: at(0, hour: 11)),
      row(.codex, "Codex", updated: at(0, hour: 10))
    ])

    XCTAssertEqual(all.flatMap(\.items).map(\.title), ["Claude", "Codex"])
  }

  func testAnActiveTabKeepsOnlyThatAgent() {
    let codexOnly = sections(
      [
        row(.claude, "Claude", updated: at(0, hour: 11)),
        row(.codex, "Codex", updated: at(0, hour: 10))
      ],
      agent: .codex
    )

    XCTAssertEqual(codexOnly.flatMap(\.items).map(\.title), ["Codex"])
  }

  func testAConversationWithNoTabOfItsOwnStillAppearsWithNoTabActive() {
    let orphan = row(.custom, "From an adapter we dropped", updated: at(0))

    XCTAssertEqual(sections([orphan]).flatMap(\.items).map(\.title), ["From an adapter we dropped"])
    XCTAssertTrue(AgentHistory.tabOrder.allSatisfy { sections([orphan], agent: $0).isEmpty })
  }

  // MARK: - Days

  func testRowsFallIntoTheDayTheyWereLastTouched() {
    let result = sections([
      row(.claude, "An hour ago", updated: at(0, hour: 11)),
      row(.claude, "This morning", updated: at(0, hour: 9)),
      row(.claude, "Yesterday", updated: at(1))
    ])

    XCTAssertEqual(result.map(\.title), ["Today", "Yesterday"])
    XCTAssertEqual(result[0].items.map(\.title), ["An hour ago", "This morning"])
    XCTAssertEqual(result[1].items.map(\.title), ["Yesterday"])
  }

  func testTheCallersOrderIsKept() {
    let result = sections([
      row(.claude, "Older", updated: at(0, hour: 9)),
      row(.claude, "Newer", updated: at(0, hour: 11))
    ])

    XCTAssertEqual(result[0].items.map(\.title), ["Older", "Newer"])
  }

  func testARowOutOfOrderJoinsItsDayRatherThanOpeningASecondHeading() {
    let result = sections([
      row(.claude, "Today A", updated: at(0, hour: 11)),
      row(.claude, "Yesterday", updated: at(1)),
      row(.claude, "Today B", updated: at(0, hour: 9))
    ])

    XCTAssertEqual(result.map(\.title), ["Today", "Yesterday"])
    XCTAssertEqual(result[0].items.map(\.title), ["Today A", "Today B"])
  }

  func testTheDayIsWhenItWasLastTouchedNotWhenItStarted() {
    let longRunning = Conversation(
      providerID: AgentId.claude.rawValue,
      title: "Long-running",
      workingDirectory: "/tmp",
      createdAt: at(30),
      updatedAt: at(0)
    )
    let rows = BolttyAISessionList.items(conversations: [longRunning], selectedID: nil)

    XCTAssertEqual(sections(rows).map(\.title), ["Today"])
  }

  func testAHeadingNamesTheWeekdayWhileThatIsStillHowYouWouldSayIt() {
    XCTAssertEqual(
      AgentHistory.title(for: at(3), now: now, calendar: calendar), "Thursday"
    )
  }

  func testPastAWeekTheHeadingBecomesADateAndTheYearOnlyShowsWhenItDiffers() {
    let thisYear = AgentHistory.title(for: at(30), now: now, calendar: calendar)
    let lastYear = AgentHistory.title(for: at(400), now: now, calendar: calendar)

    XCTAssertTrue(thisYear.contains("August"), thisYear)
    XCTAssertFalse(thisYear.contains("2026"), thisYear)
    XCTAssertTrue(lastYear.contains("2025"), lastYear)
  }

  func testASectionIsIdentifiedByItsDayRatherThanByItsHeading() {
    let today = sections([row(.claude, "A", updated: at(0))])[0]

    XCTAssertEqual(today.id, "2026-09-20")
    XCTAssertEqual(today.title, "Today")
  }

  func testNothingAtAllIsNoSectionsRatherThanAnEmptyOne() {
    XCTAssertTrue(sections([]).isEmpty)
    XCTAssertTrue(sections([row(.claude, "A", updated: at(0))], agent: .grok).isEmpty)
  }
}

extension AgentHistoryTests {
  func testTheTabsAreEveryAdapterInTheReferencesOrder() {
    XCTAssertEqual(AgentHistory.tabOrder, [.claude, .codex, .opencode, .grok, .antigravity])
    XCTAssertEqual(Set(AgentHistory.tabOrder), Set(AgentId.adapterCases))
    XCTAssertEqual(AgentHistory.tabOrder.count, AgentId.adapterCases.count)
  }

  func testAdjacentTabTreatsEveryAgentAsTheStopBeforeTheFirst() {
    let order = AgentHistory.tabOrder
    XCTAssertEqual(AgentHistory.adjacentTab(to: nil, by: 1), order.first)
    XCTAssertNil(AgentHistory.adjacentTab(to: order.first, by: -1))
    XCTAssertNil(AgentHistory.adjacentTab(to: nil, by: -1), "stops, never wraps")
    XCTAssertEqual(AgentHistory.adjacentTab(to: order.last, by: 1), order.last)
    XCTAssertEqual(AgentHistory.adjacentTab(to: order[0], by: 1), order[1])
  }
}
