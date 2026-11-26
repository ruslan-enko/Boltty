import AppKit

@MainActor
enum DesignFoundations {
  static func colours() -> [DesignSection] {
    [
      DesignSection(title: "Brand", note: "BolttyBrand. Always a fill, under black words.", specimens: [
        swatch("accent", BolttyBrand.accent),
        swatch("accentOnGlass", BolttyBrand.accentOnGlass),
        swatch("accentOnGlassHover", BolttyBrand.accentOnGlassHover),
        swatch("onAccent", BolttyBrand.onAccent),
      ]),
      DesignSection(title: "Ink", note: "PaletteInk, ComposerControlGroup", specimens: [
        words("primary", PaletteInk.primary), words("secondary", PaletteInk.secondary),
        words("tertiary", PaletteInk.tertiary), words("restingInk", ComposerControlGroup.restingInk),
        words("hoverInk", ComposerControlGroup.hoverInk), words("disabledInk", ComposerControlGroup.disabledInk),
      ]),
      DesignSection(title: "Fills", note: "PaletteInk, AgentPaletteMetrics", specimens: [
        swatch("fill", PaletteInk.fill), swatch("secondaryFill", PaletteInk.secondaryFill),
        swatch("tertiaryFill", PaletteInk.tertiaryFill), swatch("selectedFill", PaletteInk.selectedFill),
        swatch("historyRowSelectedFill", AgentPaletteMetrics.historyRowSelectedFill),
        swatch("previewUserBubbleFill", AgentPaletteMetrics.previewUserBubbleFill),
        swatch("failureDetailsFill", AgentPaletteMetrics.failureDetailsFill),
        swatch("helpDensity", AgentPaletteMetrics.helpDensity),
        swatch("sendFill", ComposerControlGroup.sendFill),
      ]),
      DesignSection(title: "Signals", note: "AgentPaletteMetrics", specimens: [
        swatch("resultsUnreadDotFill", AgentPaletteMetrics.resultsUnreadDotFill),
        swatch("failureCardAccent", AgentPaletteMetrics.failureCardAccent),
      ]),
    ]
  }

  static func type() -> [DesignSection] {
    let sizes: [(String, CGFloat)] = [
      ("promptFontSize", AgentPaletteMetrics.promptFontSize),
      ("typePrimary", AgentPaletteMetrics.typePrimary),
      ("typeSecondary", AgentPaletteMetrics.typeSecondary),
      ("typeChat", AgentPaletteMetrics.typeChat),
      ("typeMeta", AgentPaletteMetrics.typeMeta),
      ("typeFootnote", AgentPaletteMetrics.typeFootnote),
    ]
    let headings: [(String, CGFloat)] = [
      ("answerHeading1FontSize", AgentPaletteMetrics.answerHeading1FontSize),
      ("answerHeading2FontSize", AgentPaletteMetrics.answerHeading2FontSize),
      ("answerHeading3FontSize", AgentPaletteMetrics.answerHeading3FontSize),
    ]
    func row(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular) -> DesignSpecimen {
      DesignSpecimen(
        name: name, note: "SF Pro Rounded, \(number(size))",
        view: text("Ask anything · Запитай що завгодно", size: size, weight: weight),
        tile: CGSize(width: 0, height: 64), isWide: true)
    }
    return [
      DesignSection(title: "Sizes", note: "Whole points, no kerning.", specimens: sizes.map { row($0.0, $0.1) }),
      DesignSection(title: "Answer headings", specimens: headings.map { row($0.0, $0.1, .semibold) }),
      DesignSection(title: "Weights", specimens: [
        row("regular", AgentPaletteMetrics.typeSecondary), row("medium", AgentPaletteMetrics.typeSecondary, .medium),
        row("semibold", AgentPaletteMetrics.typeSecondary, .semibold),
      ]),
    ]
  }

  static func shape() -> [DesignSection] {
    let corners: [(String, CGFloat)] = [
      ("cornerRadius", AgentPaletteMetrics.cornerRadius),
      ("cardCornerRadius", AgentPaletteMetrics.cardCornerRadius),
      ("listCardCornerRadius", AgentPaletteMetrics.listCardCornerRadius),
      ("chatComposerRestingCornerRadius", AgentPaletteMetrics.chatComposerRestingCornerRadius),
      ("resultsRowCornerRadius", AgentPaletteMetrics.resultsRowCornerRadius),
      ("failureCardCornerRadius", AgentPaletteMetrics.failureCardCornerRadius),
      ("failureDetailsCornerRadius", AgentPaletteMetrics.failureDetailsCornerRadius),
      ("attachmentCardCornerInChat", AgentPaletteMetrics.attachmentCardCornerInChat),
      ("noticeCornerRadius", AgentPaletteMetrics.noticeCornerRadius),
      ("helpCornerRadius", AgentPaletteMetrics.helpCornerRadius),
    ]
    let gaps: [(String, CGFloat)] = [
      ("shellContentInset", AgentPaletteMetrics.shellContentInset),
      ("chatComposerInkInset", AgentPaletteMetrics.chatComposerInkInset),
      ("chatComposerGap", AgentPaletteMetrics.chatComposerGap),
      ("ComposerControlGroup.gap", ComposerControlGroup.gap),
      ("ComposerControlGroup.target", ComposerControlGroup.target),
      ("previewQuestionAnswerSpacing", AgentPaletteMetrics.previewQuestionAnswerSpacing),
      ("previewTurnSpacing", AgentPaletteMetrics.previewTurnSpacing),
      ("resultsRowHeight", AgentPaletteMetrics.resultsRowHeight),
      ("attachmentCardSide", AgentPaletteMetrics.attachmentCardSide),
    ]
    return [
      DesignSection(
        title: "Corners", note: "Continuous. Nested corners are concentric: outer = inner + inset.",
        specimens: corners.map { name, radius in
          let box = DesignBlock(colour: PaletteInk.selectedFill, radius: radius)
          return DesignSpecimen(
            name: name, note: number(radius), view: box, width: 140, height: 80)
        }),
      DesignSection(title: "Spacing", specimens: gaps.map { name, gap in
        DesignSpecimen(
          name: name, note: number(gap), view: DesignBlock(colour: BolttyBrand.accentOnGlass, radius: 0),
          width: gap, height: 40)
      }),
    ]
  }

  static func icons() -> [DesignSection] {
    let side = AgentPaletteMetrics.iconSide(ComposerControlGroup.iconSize(chat: true))
    return [DesignSection(
      title: "Icons", note: "BolttyIcon. Drawn by scripts/render-icons.py; change one there.",
      specimens: BolttyIcon.allCases.map { icon in
        let row = NSStackView(views: [side, side * 2].map { size in
          let view = NSImageView(image: icon.image(size: size) ?? NSImage())
          view.contentTintColor = PaletteInk.primary
          return view
        })
        row.spacing = 16
        return DesignSpecimen(name: icon.rawValue, view: row, tile: CGSize(width: 124, height: 72))
      })]
  }

  static func motion() -> [DesignSection] {
    [DesignSection(
      title: "Motion", note: "Each runs over and over. Open with -boltty.slowMotion 4 to see one slowed.",
      specimens: [
        motion("Motion.quick, standardCurve", .timed(Motion.quick, Motion.standardCurve), seconds(Motion.quick)),
        motion("Motion.standard, standardCurve", .timed(Motion.standard, Motion.standardCurve), seconds(Motion.standard)),
        motion("Motion.standard, emphasizedCurve", .timed(Motion.standard, Motion.emphasizedCurve), seconds(Motion.standard)),
        motion("Motion.pressSpring", .spring(Motion.pressSpring),
               "\(seconds(Motion.pressSpring.duration)), bounce \(number(Motion.pressSpring.bounce))"),
        motion("surfaceResponse",
               .spring(SpringParameters(duration: AgentPaletteMetrics.surfaceResponse)),
               "\(seconds(AgentPaletteMetrics.surfaceResponse)), critically damped: the shell's own spring"),
      ])]
  }

  static func glass(clear: Bool) -> [DesignSection] {
    func host(_ style: PaletteSurfaceStyle, radius: CGFloat) -> NSView {
      PaletteGlassHost(content: NSView(), cornerRadius: radius, style: style)
    }
    func specimen(_ name: String, _ note: String, _ style: PaletteSurfaceStyle) -> DesignSpecimen {
      DesignSpecimen(
        name: name, note: note, view: host(style, radius: AgentPaletteMetrics.cardCornerRadius),
        width: 260, height: 150, tile: CGSize(width: 330, height: 220))
    }
    return [
      DesignSection(title: "Surfaces", note: "PaletteGlassHost. Density goes over the glass, never into its tint.", specimens: [
        specimen("Shell, as chosen above", "bolttyAIPrompt(clearGlass:)", .bolttyAIPrompt(clearGlass: clear)),
        specimen("Control and composer", "bolttyAI", .bolttyAI),
        specimen("Plain", "plain", .plain),
      ]),
    ]
  }

  static func faces() -> [DesignSection] {
    func live(_ look: MascotLook, _ name: String, _ note: String = "", emotion: MascotEmotion = .curious)
      -> DesignSpecimen {
      let face = MascotNSView(conversationID: UUID(), look: look)
      face.reduceMotion = MotionPreferences.reduceMotion
      face.emotion = emotion
      return DesignSpecimen(name: name, note: note, view: face, width: 84, height: 84, tile: CGSize(width: 140, height: 120))
    }
    let standard = MascotPalette.standard
    let emotions: [(String, MascotEmotion)] = [
      ("curious", .curious), ("listening", .listening), ("thinking", .thinking), ("focused", .focused),
      ("concerned", .concerned), ("sad", .sad), ("sleeping", .sleeping),
    ]
    return [
      DesignSection(title: "Agents", note: "As chosen in Settings › Agents. Press one.", specimens: AgentHistory.tabOrder.map {
        live(.face(for: $0), $0.shortDisplayName, MascotLook.face(for: $0).displayName)
      }),
      DesignSection(title: "Shapes", note: "MascotShape", specimens: MascotShape.allCases.map {
        live(MascotLook(shape: $0, palette: standard), $0.displayName)
      }),
      DesignSection(title: "Gradients", note: "MascotPalette: the face, its stops, and the light its words arrive in.",
                    specimens: MascotPalette.catalog.flatMap { palette in
        [
          live(MascotLook(shape: .hex, palette: palette), palette.displayName),
          DesignSpecimen(
            name: "stops", note: "\(palette.displayName)", view: DesignStops(colours: palette.colors),
            width: 150, height: 40, tile: CGSize(width: 180, height: 120)),
          DesignSpecimen(
            name: "arrivalLight", note: "\(palette.displayName)", view: DesignStops(colours: palette.arrivalLight),
            width: 150, height: 40, tile: CGSize(width: 180, height: 120)),
        ]
      }),
      DesignSection(title: "Finishes", note: "MascotFinish", specimens: MascotFinish.allCases.map {
        live(MascotLook(shape: .hex, palette: standard, finish: $0), $0.displayName)
      }),
      DesignSection(title: "Moods", note: "MascotEmotion", specimens: emotions.map {
        live(MascotLook(shape: .hex, palette: standard), $0.0, emotion: $0.1)
      }),
    ]
  }

  static func backdrops() -> [DesignSection] {
    AgentHistory.tabOrder.map { agent in
      let palette = MascotPalette.face(for: agent)
      return DesignSection(title: agent.shortDisplayName, note: palette.displayName, specimens:
        [ChatBackdrop.sky, .space, .black].map { backdrop in
          let view = NSView()
          view.wantsLayer = true
          view.layer?.contentsGravity = .resizeAspectFill
          view.layer?.contents = AgentBackdropRenderer.still(
            of: backdrop, palette: palette, scene: AgentPaletteMetrics.chatSurfaceSize, scale: 1)
          return DesignSpecimen(
            name: backdrop.title, view: view, tile: CGSize(width: 292, height: 340), fills: false)
            .filling()
        })
    }
  }

  static func number(_ value: CGFloat) -> String {
    String(format: "%g", (Double(value) * 100).rounded() / 100)
  }

  private static func seconds(_ value: TimeInterval) -> String { "\(number(CGFloat(value))) s" }

  static func oklch(_ colour: NSColor) -> String {
    let resolved = colour.usingColorSpace(.extendedSRGB) ?? colour
    let value = Oklab(resolved).oklch
    var said = "OKLCH " + [value.l, value.c].map { String(format: "%.3f", $0) }.joined(separator: " ")
    if value.c > 0.002 { said += String(format: " %.0f°", value.h) }
    if resolved.alphaComponent < 1 { said += String(format: ", %.0f%%", resolved.alphaComponent * 100) }
    return said
  }

  private static func swatch(_ name: String, _ colour: NSColor) -> DesignSpecimen {
    DesignSpecimen(
      name: name, note: oklch(colour), view: DesignBlock(colour: colour, radius: 10), width: 120, height: 60)
  }

  private static func words(_ name: String, _ colour: NSColor) -> DesignSpecimen {
    DesignSpecimen(name: name, view: text("Boltty", size: AgentPaletteMetrics.typePrimary, ink: colour))
  }

  static func text(
    _ words: String, size: CGFloat, weight: NSFont.Weight = .regular, ink: NSColor = PaletteInk.primary
  ) -> NSTextField {
    let field = NSTextField(labelWithString: words)
    field.font = roundedAppFont(size: size, weight: weight)
    field.textColor = ink
    return field
  }

  private static func motion(_ name: String, _ kind: DesignMotionView.Kind, _ note: String) -> DesignSpecimen {
    DesignSpecimen(
      name: name, note: note, view: DesignMotionView(kind), width: 220, height: 40,
      tile: CGSize(width: 280, height: 90))
  }
}

extension DesignSpecimen {
  func filling() -> DesignSpecimen {
    var copy = self
    copy.width = tile.width
    copy.height = tile.height
    return copy
  }
}

final class DesignBlock: NSView {
  private let colour: NSColor
  private let radius: CGFloat

  init(colour: NSColor, radius: CGFloat) {
    self.colour = colour
    self.radius = radius
    super.init(frame: .zero)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() { layer?.backgroundColor = colour.cgColor }

  override func layout() {
    super.layout()
    layer?.applyPaletteCorner(radius: min(radius, bounds.width / 2, bounds.height / 2))
  }
}

final class DesignStops: NSView {
  init(colours: [NSColor]) {
    super.init(frame: .zero)
    let row = NSStackView(views: colours.map { DesignBlock(colour: $0, radius: 0) })
    row.distribution = .fillEqually
    row.spacing = 0
    row.frame = bounds
    row.autoresizingMask = [.width, .height]
    addSubview(row)
    for view in row.arrangedSubviews { view.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class DesignMotionView: NSView {
  enum Kind {
    case timed(TimeInterval, CAMediaTimingFunction)
    case spring(SpringParameters)
  }

  private static let side: CGFloat = 32
  private let kind: Kind
  private let dot = CALayer()
  private var timer: Timer?
  private var isFar = false

  init(_ kind: Kind) {
    self.kind = kind
    super.init(frame: .zero)
    wantsLayer = true
    dot.backgroundColor = BolttyBrand.accentOnGlass.cgColor
    dot.bounds = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
    dot.applyPaletteCorner(radius: Self.side / 2)
    layer?.addSublayer(dot)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    timer?.invalidate()
    timer = nil
    guard window != nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.run() }
    }
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    dot.position = CGPoint(x: place, y: bounds.midY)
    CATransaction.commit()
  }

  private var place: CGFloat { isFar ? bounds.maxX - Self.side / 2 : Self.side / 2 }

  private func run() {
    let from = place
    isFar.toggle()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    dot.position.x = place
    CATransaction.commit()
    switch kind {
    case .timed(let duration, let curve):
      let move = CABasicAnimation(keyPath: "position.x")
      move.fromValue = from
      move.toValue = place
      move.duration = Motion.scaled(duration)
      move.timingFunction = curve
      move.preferringHighFrameRate()
      dot.add(move, forKey: "position.x")
    case .spring(var spring):
      spring.duration = Motion.scaled(spring.duration)
      MotionPreferences.animateSpring(on: dot, keyPath: "position.x", from: from, to: place, spring: spring)
    }
  }
}
