import AppKit

enum HistoryLimitsReading {
  static func bars(_ usage: AgentUsage?) -> [AgentUsageWindow] {
    guard let windows = usage?.windows, !windows.isEmpty else { return [] }
    var groups: [(label: String?, windows: [AgentUsageWindow])] = []
    for window in windows {
      if let index = groups.firstIndex(where: { $0.label == window.label }) {
        groups[index].windows.append(window)
      } else {
        groups.append((window.label, [window]))
      }
    }
    return groups.prefix(AgentPaletteMetrics.historyLimitsMaxBars).compactMap {
      AgentUsage(windows: $0.windows).pressing
    }
  }

  static func detail(_ usage: AgentUsage, agent: AgentId?) -> String {
    let heading = agent.map { String(localized: "\($0.displayName) plan limits") } ?? String(localized: "Plan limits")
    return "\(heading)\n\(UsagePillText.windowDetails(for: usage))"
  }
}

@MainActor
final class HistoryLimitsCapsule: NSView {
  let button = PaletteIconButton()
  private let bars = HistoryLimitsBars()
  private(set) var usage: AgentUsage?
  private var agent: AgentId?
  var hasReading: Bool { !bars.windows.isEmpty }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.masksToBounds = false
    button.translatesAutoresizingMaskIntoConstraints = false
    button.title = ""
    button.imagePosition = .noImage
    button.isBordered = true
    button.bezelStyle = .glass
    button.borderShape = .capsule
    button.controlSize = .extraLarge
    button.restingBackground = .clear
    button.hoverBackground = .clear
    button.pressScale = 1
    button.focusRingType = .none
    button.target = self
    button.action = #selector(showDetail)
    button.setAccessibilityLabel(String(localized: "Plan limits"))
    bars.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    addSubview(bars)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
      bars.leadingAnchor.constraint(equalTo: leadingAnchor),
      bars.trailingAnchor.constraint(equalTo: trailingAnchor),
      bars.topAnchor.constraint(equalTo: topAnchor),
      bars.bottomAnchor.constraint(equalTo: bottomAnchor),
      widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.historyLimitsWidth),
      heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewCloseDiameter),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func apply(_ usage: AgentUsage?, agent: AgentId?) {
    guard self.usage != usage || self.agent != agent else { return }
    self.usage = usage
    self.agent = agent
    bars.windows = HistoryLimitsReading.bars(usage)
    let detail = usage.map { HistoryLimitsReading.detail($0, agent: agent) }
    button.toolTip = detail
    button.setAccessibilityValue(detail)
    if PaletteHelpPresenter.shared.isPinned(for: button) { showDetail() }
  }

  @objc private func showDetail() {
    guard let text = button.toolTip else { return }
    PaletteHelpPresenter.shared.show(for: button, text: text, pinned: true)
  }
}

@MainActor
private final class HistoryLimitsBars: NSView {
  var windows: [AgentUsageWindow] = [] {
    didSet { if windows != oldValue { needsDisplay = true } }
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    guard !windows.isEmpty else { return }
    let width = AgentPaletteMetrics.historyLimitsBarWidth
    let height = AgentPaletteMetrics.historyLimitsBarHeight
    let gap = AgentPaletteMetrics.historyLimitsBarGap
    let whole = CGFloat(windows.count) * height + CGFloat(windows.count - 1) * gap
    let x = AgentPaletteMetrics.onPixelGrid(bounds.midX - width / 2)
    var y = AgentPaletteMetrics.onPixelGrid(bounds.midY - whole / 2)
    let ordered = isFlipped ? windows : windows.reversed()
    for window in ordered {
      let track = NSRect(x: x, y: y, width: width, height: height)
      AgentPaletteMetrics.planRingTrack.setFill()
      NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2).fill()
      let used = CGFloat(min(100, max(0, window.usedPercent))) / 100
      if used > 0 {
        var fill = track
        fill.size.width = max(height, width * used)
        BolttyBrand.accentOnGlass.setFill()
        NSBezierPath(roundedRect: fill, xRadius: height / 2, yRadius: height / 2).fill()
      }
      y += height + gap
    }
  }
}
