import SwiftUI

struct UsageOverviewSection: View {
  @ObservedObject var store: ConversationStore

  static let faceSize: CGFloat = 26
  static let faceStep: CGFloat = 17
  static let facesShown = 5

  var body: some View {
    let week = BolttyWeek(conversations: store.conversations)
    Section {
      VStack(alignment: .leading, spacing: 10) {
        Text(week.chats == 0 ? String(localized: "No chats this week yet") : String(localized: "\(week.chats) chats this week"))
          .font(BolttyInterfaceTypography.headline)
          .monospacedDigit()
        days(week)
      }
      .padding(.vertical, 4)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("boltty.settings.usage.week")
    } header: {
      SettingsSectionHeader(String(localized: "Activity"))
    }
  }

  private func days(_ week: BolttyWeek) -> some View {
    let tallest = min(week.days.map(\.chats.count).max() ?? 0, Self.facesShown + 1)
    return HStack(alignment: .bottom, spacing: 8) {
      ForEach(week.days) { day in
        VStack(spacing: 4) {
          WeekDayFaces(chats: day.chats, slots: max(tallest, 1))
          Text(Self.weekday(day.date))
            .font(BolttyInterfaceTypography.callout)
            .fontWeight(day.date == week.today ? .semibold : .regular)
            .foregroundStyle(day.date > week.today ? .tertiary : day.date == week.today ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.weekdayName(day.date))
        .accessibilityValue(String(localized: "\(day.chats.count) chats"))
      }
    }
  }

  private static let shortWeekday: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEEEE")
    return formatter
  }()

  private static let fullWeekday: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEEE")
    return formatter
  }()

  private static func weekday(_ date: Date) -> String { shortWeekday.string(from: date) }
  private static func weekdayName(_ date: Date) -> String { fullWeekday.string(from: date) }
}

private struct WeekDayFaces: View {
  let chats: [BolttyWeek.Chat]
  let slots: Int

  private var overflows: Bool { chats.count > UsageOverviewSection.facesShown + 1 }
  private var shown: [BolttyWeek.Chat] {
    Array(chats.suffix(overflows ? UsageOverviewSection.facesShown : chats.count))
  }

  var body: some View {
    let side = UsageOverviewSection.faceSize
    let step = UsageOverviewSection.faceStep
    let height = side + CGFloat(max(slots - 1, 0)) * step
    ZStack(alignment: .bottom) {
      if chats.isEmpty {
        Circle()
          .fill(.quaternary)
          .frame(width: 5, height: 5)
          .padding(.bottom, (side - 5) / 2)
      }
      ForEach(Array(shown.enumerated()), id: \.element.id) { index, chat in
        WeekFace(chat: chat)
          .offset(y: -CGFloat(index) * step)
          .zIndex(Double(index))
      }
      if overflows {
        Text(verbatim: "+\(chats.count - shown.count)")
          .font(BolttyInterfaceTypography.fixed(size: 11, weight: .semibold))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(height: side)
          .offset(y: -CGFloat(shown.count) * step)
      }
    }
    .frame(height: height, alignment: .bottom)
  }
}

private struct WeekFace: View {
  let chat: BolttyWeek.Chat
  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let side = UsageOverviewSection.faceSize
    Group {
      if let image = MascotSnapshotCache.image(MascotLook.face(for: chat.agent), size: side, scale: 2) {
        Image(decorative: image, scale: 2)
          .resizable()
      } else {
        Circle().fill(.quaternary)
      }
    }
    .frame(width: side, height: side)
    .scaleEffect(hovering && !reduceMotion ? 1.25 : 1)
    .animation(.spring(duration: 0.3, bounce: 0.45), value: hovering)
    .onHover { hovering = $0 }
    .help(chat.title)
  }
}
