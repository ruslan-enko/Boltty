import Foundation

struct BolttyWeek: Equatable {
  struct Chat: Equatable, Identifiable {
    let id: UUID
    let agent: AgentId
    let title: String
    let isAskBoltty: Bool
  }

  struct Day: Equatable, Identifiable {
    let date: Date
    var chats: [Chat]
    var id: Date { date }
  }

  let days: [Day]
  let today: Date

  var chats: Int { days.reduce(0) { $0 + $1.chats.count } }
  var askedAboutScreen: Int { days.reduce(0) { $0 + $1.chats.filter(\.isAskBoltty).count } }

  var busiestAgent: AgentId? {
    let counts = Dictionary(grouping: days.flatMap(\.chats), by: \.agent).mapValues(\.count)
    return AgentId.allCases.filter { counts[$0] != nil }.max { counts[$0]! < counts[$1]! }
  }

  init(conversations: [Conversation], now: Date = Date(), calendar: Calendar = .current) {
    let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
    let dates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    let sorted = conversations.sorted { $0.createdAt < $1.createdAt }
    days = dates.map { date in
      Day(date: date, chats: sorted.filter { calendar.isDate($0.createdAt, inSameDayAs: date) }.map {
        Chat(
          id: $0.id,
          agent: AgentId(rawValue: $0.providerID) ?? .opencode,
          title: $0.title,
          isAskBoltty: $0.isAskBoltty)
      })
    }
    today = calendar.startOfDay(for: now)
  }
}
