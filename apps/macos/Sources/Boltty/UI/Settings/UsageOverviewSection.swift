import SwiftUI

struct UsageOverviewSection: View {
  @ObservedObject var model: BolttyAISettingsModel
  @State private var tab: Tab = .overview
  @State private var range: AgentStatisticsRange = .all
  @State private var agent: AgentId?

  enum Tab: String, CaseIterable, Identifiable {
    case overview, models
    var id: String { rawValue }
    var title: String { self == .overview ? "Overview" : "Models" }
  }

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 14) {
        controls
        if let statistics = model.statistics {
          content(statistics)
        } else {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Counting every agent’s history…")
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, minHeight: 120)
        }
      }
      .padding(.vertical, 4)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("boltty.settings.usage.overview")
    } header: {
      SettingsSectionHeader("Activity")
    } footer: {
      SettingsNote("Counted from each CLI’s own history on this Mac: what you sent and every reply, and the tokens each CLI wrote down.")
    }
  }

  private var controls: some View {
    HStack(spacing: 12) {
      Picker("View", selection: $tab) {
        ForEach(Tab.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()

      Spacer(minLength: 0)

      Picker("Agent", selection: $agent) {
        Text("All Agents").tag(AgentId?.none)
        Divider()
        ForEach(AgentHistory.tabOrder, id: \.self) { agent in
          Text(agent.displayName).tag(AgentId?.some(agent))
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .fixedSize()

      Picker("Range", selection: $range) {
        ForEach(AgentStatisticsRange.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
    }
  }

  @ViewBuilder
  private func content(_ statistics: AgentStatistics) -> some View {
    let summary = AgentStatisticsSummary(statistics, range: range, agent: agent)
    switch tab {
    case .overview:
      tiles(summary)
      UsageDayGrid(
        days: summary.days,
        firstDay: AgentStatisticsSummary(statistics, range: .all, agent: agent).days.keys.min(),
        rangeStart: range.start(now: Date(), calendar: .current),
        tint: tint
      )
      if let line = AgentStatisticsSummary.bookComparison(tokens: summary.tokens) {
        Text(line)
          .foregroundStyle(.secondary)
      }
    case .models:
      if summary.models.isEmpty {
        Text("No model answered in this range.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 80)
      } else {
        models(summary)
      }
    }
  }

  private var tint: Color {
    agent.map { model.usageTint(for: $0) } ?? Color(nsColor: .systemBlue)
  }

  // MARK: Overview

  private func tiles(_ summary: AgentStatisticsSummary) -> some View {
    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
      GridRow {
        tile("Sessions", Self.decimal(summary.sessions))
        tile("Messages", Self.decimal(summary.messages))
        tile("Total tokens", summary.tokens > 0 ? AgentActivityHistory.compact(Double(summary.tokens)) : "—")
      }
      GridRow {
        tile("Active days", Self.decimal(summary.activeDays))
        tile("Peak hour", summary.peakHour.map(Self.hourName) ?? "—")
        tile("Favorite model", summary.favoriteModel ?? "—", isName: true)
      }
    }
  }

  private func tile(_ title: String, _ value: String, isName: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .foregroundStyle(.secondary)
      Text(value)
        .font(isName ? BolttyInterfaceTypography.body : .system(.title3, design: .rounded, weight: .semibold))
        .monospacedDigit()
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(minHeight: 24, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  // MARK: Models

  private func models(_ summary: AgentStatisticsSummary) -> some View {
    let total = max(summary.tokens, 1)
    return VStack(alignment: .leading, spacing: 12) {
      ForEach(summary.models) { row in
        let ink = row.agent.map { model.usageInk(for: $0) } ?? [.accentColor]
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 10) {
            if let agent = row.agent {
              MascotStill(look: model.mascotLook(for: agent), size: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
              Text(row.id)
              Text(caption(row))
                .font(BolttyInterfaceTypography.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(row.tokens > 0 ? AgentActivityHistory.compact(Double(row.tokens)) : "—")
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          if summary.tokens > 0 {
            UsageMeter(fraction: Double(row.tokens) / Double(total), ink: ink, height: 6)
              .accessibilityLabel("\(row.id) share of tokens")
          }
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  private func caption(_ row: AgentStatisticsSummary.Model) -> String {
    var parts: [String] = []
    if let agent = row.agent { parts.append(agent.displayName) }
    parts.append(row.messages == 1 ? "1 reply" : "\(Self.decimal(row.messages)) replies")
    parts.append(row.sessions == 1 ? "1 session" : "\(Self.decimal(row.sessions)) sessions")
    return parts.joined(separator: " · ")
  }

  // MARK: Formatting

  private static func decimal(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }

  private static func hourName(_ hour: Int) -> String {
    let calendar = Calendar.current
    let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("j")
    let name = formatter.string(from: date)
    return name.allSatisfy(\.isNumber) ? "\(name):00" : name
  }
}

private struct UsageDayGrid: View {
  let days: [Date: AgentStatisticsSummary.Day]
  let firstDay: Date?
  let rangeStart: Date?
  let tint: Color

  private static let minimumWeeks = 26
  private static let maximumWeeks = 53
  private static let spacing: CGFloat = 4

  var body: some View {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let weeks = Self.weeks(firstDay: firstDay, today: today, calendar: calendar)
    let thresholds = Self.thresholds(days.values.map(\.messages))

    HStack(spacing: Self.spacing) {
      ForEach(0..<weeks.count, id: \.self) { column in
        VStack(spacing: Self.spacing) {
          ForEach(0..<7, id: \.self) { row in
            cell(weeks[column][row], today: today, thresholds: thresholds)
          }
        }
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Activity by day")
    .accessibilityValue("\(days.count) active days")
  }

  @ViewBuilder
  private func cell(_ date: Date, today: Date, thresholds: [Int]) -> some View {
    let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
    if date > today {
      Color.clear.aspectRatio(1, contentMode: .fit)
    } else {
      let day = days[date]
      let level = Self.level(day?.messages ?? 0, thresholds: thresholds)
      // Flat: an empty day is the system's fill, a busy one the tint over it.
      shape
        .fill(Color.primary.opacity(0.08))
        .overlay(shape.fill(tint.opacity(Self.opacity[level])))
        .aspectRatio(1, contentMode: .fit)
        .opacity(rangeStart.map { date < $0 } == true ? 0.45 : 1)
        .help(Self.caption(date, day))
    }
  }

  private static let opacity: [Double] = [0, 0.3, 0.5, 0.72, 0.95]

  static func weeks(firstDay: Date?, today: Date, calendar: Calendar) -> [[Date]] {
    let weekday = calendar.component(.weekday, from: today)
    let offset = (weekday - calendar.firstWeekday + 7) % 7
    let thisWeek = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
    var count = minimumWeeks
    if let firstDay {
      let span = calendar.dateComponents([.day], from: calendar.startOfDay(for: firstDay), to: thisWeek).day ?? 0
      count = min(max(span / 7 + 2, minimumWeeks), maximumWeeks)
    }
    return (0..<count).map { column in
      let start = calendar.date(byAdding: .day, value: -7 * (count - 1 - column), to: thisWeek) ?? thisWeek
      return (0..<7).map { calendar.date(byAdding: .day, value: $0, to: start) ?? start }
    }
  }

  static func thresholds(_ counts: [Int]) -> [Int] {
    let busy = counts.filter { $0 > 0 }.sorted()
    guard !busy.isEmpty else { return [] }
    return [0.25, 0.5, 0.75].map { busy[min(Int(Double(busy.count) * $0), busy.count - 1)] }
  }

  static func level(_ count: Int, thresholds: [Int]) -> Int {
    guard count > 0 else { return 0 }
    return 1 + thresholds.filter { count > $0 }.count
  }

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
    return formatter
  }()

  private static func caption(_ date: Date, _ day: AgentStatisticsSummary.Day?) -> String {
    let name = dayFormatter.string(from: date)
    guard let day, day.messages > 0 || day.tokens > 0 else { return "\(name): nothing" }
    var parts = ["\(name): \(day.messages) message\(day.messages == 1 ? "" : "s")"]
    if day.tokens > 0 { parts.append("\(AgentActivityHistory.compact(Double(day.tokens))) tokens") }
    return parts.joined(separator: ", ")
  }
}
