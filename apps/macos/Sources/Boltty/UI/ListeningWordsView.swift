import AppKit

final class ListeningWordsView: NSView {
  private(set) var text = ""

  private struct Word {
    let string: NSAttributedString
    let width: CGFloat
    let born: CFTimeInterval
    var shown: CGPoint?
  }

  private var words: [Word] = []
  var colors: [NSColor] = [PaletteInk.primary] {
    didSet { needsDisplay = true }
  }
  var wrapWidth: CGFloat = 0 {
    didSet { if wrapWidth != oldValue { needsDisplay = true; startClock() } }
  }
  var isCentred = true
  var headroom: CGFloat = 0 {
    didSet { if headroom != oldValue { needsLayout = true; needsDisplay = true } }
  }
  var wordCount: Int { words.count }
  private var timer: Timer?
  private var lastDraw: CFTimeInterval?
  private let fadeLayer = CAGradientLayer()

  private var font: NSFont {
    roundedAppFont(size: AgentPaletteMetrics.listeningWordsFontSize, weight: .medium)
  }

  private var spaceWidth: CGFloat {
    ceil(NSAttributedString(string: " ", attributes: [.font: font]).size().width)
  }

  var lineHeight: CGFloat {
    ceil(AgentPaletteMetrics.listeningWordsFontSize * AgentPaletteMetrics.listeningWordsLineSpacing)
  }

  private func lines(at width: CGFloat) -> [[Int]] {
    Self.broken(widths: words.map(\.width), space: spaceWidth, at: width)
  }

  private static func broken(widths: [CGFloat], space: CGFloat, at width: CGFloat) -> [[Int]] {
    guard !widths.isEmpty else { return [] }
    var lines: [[Int]] = [[]]
    var used: CGFloat = 0
    for (index, wordWidth) in widths.enumerated() {
      let needed = lines[lines.count - 1].isEmpty ? wordWidth : used + space + wordWidth
      if needed > width, !lines[lines.count - 1].isEmpty {
        lines.append([index])
        used = wordWidth
      } else {
        lines[lines.count - 1].append(index)
        used = needed
      }
    }
    return lines
  }

  func measure(_ text: String, width: CGFloat) -> (lines: Int, widest: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let widths = text.split(whereSeparator: \.isWhitespace).map {
      ceil(NSAttributedString(string: String($0), attributes: attributes).size().width)
    }
    let space = spaceWidth
    let broken = Self.broken(widths: widths, space: space, at: width)
    let widest = broken.map { line in
      line.reduce(0) { $0 + widths[$1] } + space * CGFloat(max(0, line.count - 1))
    }.max() ?? 0
    return (min(broken.count, AgentPaletteMetrics.listeningMaxLines), ceil(widest))
  }

  private func lineWidth(_ line: [Int]) -> CGFloat {
    line.reduce(0) { $0 + words[$1].width } + spaceWidth * CGFloat(max(0, line.count - 1))
  }

  func measure(width: CGFloat) -> (lines: Int, widest: CGFloat) {
    let broken = lines(at: width)
    let shown = min(broken.count, AgentPaletteMetrics.listeningMaxLines)
    return (shown, ceil(broken.map(lineWidth).max() ?? 0))
  }

  private func targets() -> [CGPoint] {
    let broken = lines(at: max(1, wrapWidth))
    let shown = min(broken.count, AgentPaletteMetrics.listeningMaxLines)
    let pad = AgentPaletteMetrics.listeningWordBlur
    var points = [CGPoint](repeating: .zero, count: words.count)
    for (row, line) in broken.enumerated() {
      let fromTop = CGFloat(row - (broken.count - shown) + 1)
      let foot = bounds.height - headroom - pad - fromTop * lineHeight
        + (lineHeight - ceil(font.ascender - font.descender)) / 2
      var x = isCentred ? (bounds.midX - lineWidth(line) / 2).rounded() : pad
      for index in line {
        points[index] = CGPoint(x: x, y: foot.rounded())
        x += words[index].width + spaceWidth
      }
    }
    return points
  }

  var newestWordCentre: CGPoint? {
    guard let last = words.last, let point = targets().last else { return nil }
    return CGPoint(x: point.x + last.width / 2, y: point.y + lineHeight / 2)
  }

  override var isFlipped: Bool { false }
  override var isOpaque: Bool { false }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    fadeLayer.startPoint = CGPoint(x: 0.5, y: 1)
    fadeLayer.endPoint = CGPoint(x: 0.5, y: 0)
    fadeLayer.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func setText(_ newText: String, animated: Bool) {
    guard newText != text else { return }
    text = newText
    let incoming = newText.split(whereSeparator: \.isWhitespace).map(String.init)
    let now = Motion.now
    let arrives = animated && !MotionPreferences.reduceMotion
    let stagger = AgentPaletteMetrics.listeningWordStagger
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: PaletteInk.primary
    ]
    let held = min(incoming.count, words.count)
    var revised = Array(words.prefix(held))
    for index in revised.indices where revised[index].string.string != incoming[index] {
      let string = NSAttributedString(string: incoming[index], attributes: attributes)
      revised[index] = Word(
        string: string,
        width: ceil(string.size().width),
        born: revised[index].born,
        shown: revised[index].shown
      )
    }
    words = revised + incoming.dropFirst(held).enumerated().map { index, word in
      let string = NSAttributedString(string: word, attributes: attributes)
      return Word(
        string: string,
        width: ceil(string.size().width),
        born: arrives ? now + Double(index) * stagger : -.infinity
      )
    }
    if !arrives {
      for index in words.indices { words[index].shown = nil }
    }
    needsDisplay = true
    startClock()
  }

  private func startClock() {
    guard timer == nil, window != nil, !MotionPreferences.reduceMotion else { return }
    lastDraw = nil
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func tick() {
    needsDisplay = true
    let settled = Motion.now - AgentPaletteMetrics.listeningWordArrival
    let targets = targets()
    let still = zip(words, targets).allSatisfy { word, target in
      guard let shown = word.shown else { return true }
      return abs(shown.x - target.x) < 0.25 && abs(shown.y - target.y) < 0.25
    }
    if still, words.allSatisfy({ $0.born <= settled }) {
      timer?.invalidate()
      timer = nil
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      timer?.invalidate()
      timer = nil
    }
  }

  override func layout() {
    super.layout()
    updateFade()
  }

  private func updateFade() {
    guard bounds.height > 0 else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fadeLayer.frame = bounds
    let whole = min(1, (headroom + AgentPaletteMetrics.listeningWordBlur) / bounds.height)
    let clear = whole * 0.25
    fadeLayer.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor,
                        NSColor.black.cgColor, NSColor.black.cgColor]
    fadeLayer.locations = [0, NSNumber(value: Double(clear)), NSNumber(value: Double(whole)), 1]
    CATransaction.commit()
    if layer?.mask !== fadeLayer { layer?.mask = fadeLayer }
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext, !words.isEmpty else { return }
    updateFade()
    let now = Motion.now
    let dt = lastDraw.map { min(0.1, max(0, now - $0)) } ?? 0
    lastDraw = now
    let glide = 1 - exp(-dt / AgentPaletteMetrics.listeningWordGlide)
    let arrival = AgentPaletteMetrics.listeningWordArrival
    let targets = targets()

    for index in words.indices {
      let target = targets[index]
      let at: CGPoint
      if let shown = words[index].shown, !MotionPreferences.reduceMotion {
        at = CGPoint(x: shown.x + (target.x - shown.x) * glide, y: shown.y + (target.y - shown.y) * glide)
      } else {
        at = target
      }
      words[index].shown = at
      let word = words[index]
      guard at.y + lineHeight > 0, at.y < bounds.height else { continue }
      let firstFoot = bounds.height - headroom - AgentPaletteMetrics.listeningWordBlur - lineHeight
        + (lineHeight - ceil(font.ascender - font.descender)) / 2
      let leaving = max(0, min(1, 1 - (at.y - firstFoot.rounded()) / lineHeight))
      guard leaving > 0.01 else { continue }
      let progress = word.born == -.infinity ? 1 : max(0, min(1, (now - word.born) / arrival))
      guard progress > 0 else { continue }
      let eased = 1 - pow(1 - progress, 3)
      let rise = AgentPaletteMetrics.listeningWordRise * (1 - eased)
      let origin = CGPoint(x: at.x, y: at.y - rise)

      let sharp = max(0, min(1, (eased - 0.45) / 0.55))
      let radius = AgentPaletteMetrics.listeningWordBlur * (1 - eased)
      let haze = min(1, progress * 2.5) * (1 - sharp * sharp)
      if haze > 0.01, radius > 0.25 {
        let tinted = NSMutableAttributedString(attributedString: word.string)
        tinted.addAttribute(.foregroundColor, value: hazeColor(at: at.x + word.width / 2),
                            range: NSRange(location: 0, length: tinted.length))
        context.saveGState()
        context.setAlpha(haze * 0.11 * leaving)
        let rings: [(CGFloat, Int)] = [(radius, 16), (radius * 0.66, 12), (radius * 0.33, 8)]
        for (ring, samples) in rings {
          for index in 0..<samples {
            let angle = (CGFloat(index) + ring / max(radius, 1)) / CGFloat(samples) * 2 * .pi
            tinted.draw(at: CGPoint(x: origin.x + cos(angle) * ring, y: origin.y + sin(angle) * ring * 0.7))
          }
        }
        context.restoreGState()
      }
      if sharp > 0 {
        context.saveGState()
        context.setAlpha(sharp * leaving)
        context.setShadow(
          offset: CGSize(width: 0, height: -1),
          blur: 6,
          color: NSColor.black.withAlphaComponent(0.5).cgColor
        )
        word.string.draw(at: origin)
        context.restoreGState()
      }
    }
  }

  private func hazeColor(at x: CGFloat) -> NSColor {
    guard colors.count > 1, bounds.width > 0 else { return colors.first ?? PaletteInk.primary }
    let t = max(0, min(1, x / bounds.width)) * CGFloat(colors.count - 1)
    let index = min(Int(t), colors.count - 2)
    let from = colors[index].usingColorSpace(.sRGB) ?? colors[index]
    let to = colors[index + 1].usingColorSpace(.sRGB) ?? colors[index + 1]
    return from.blended(withFraction: t - CGFloat(index), of: to) ?? from
  }
}
