import AppKit
import Foundation

enum AgentPaletteMetrics {
  /// Shared-shell motion: critically damped, retargeted with its current velocity.
  ///
  /// **0.3, not the 0.4 it was.** A critically damped spring covers 95% of its
  /// travel in about 0.75 × its response, so 0.4 took ~0.30s to arrive where
  /// the macOS 27 recording this motion is copied from travels in ~0.13s — the
  /// shell read as catching up with its own content, which resolves at 0.2.
  /// At 0.3 geometry lands at ~0.22s, with the content rather than after it.
  /// Not lower: below ~0.25 a morph between two very different sizes (pill to
  /// a full transcript) stops reading as one object changing shape.
  static let surfaceResponse: CGFloat = 0.3
  static let surfaceContentDuration: TimeInterval = Motion.standard

  /// What the shared shell *is* right now, which is not a number.
  ///
  /// Initial and compact states are pills. Chat and history are cards
  /// with corners sized for the content and inset each one carries.
  ///
  /// They were one constant for a long time (`resultsCornerRadius`), which
  /// worked by accident: at 52 or 74.5 it clamped to half the height and looked
  /// like a capsule, and only past ~149 did the stated number show. So one
  /// number was describing both roles, could only be right for one of them, and
  /// every correction that fixed the card un-fixed the pill or the reverse.
  /// That is the whole of why this corner was rewritten 23 times.
  enum SurfaceShape {
    /// The listening orb. A capsule at the height it is drawn at, and
    /// no rounder once it grows past that — see `surfaceCornerRadius`.
    case pill
    /// Initial prompt capsule, with the same corner as the compact input.
    case initial
    /// Transcript + composer. The mock's 44.
    case chat
    /// Session switcher. Its rows sit closer to the wall than the composer
    /// does, so the same corner reads rounder here — see `listCardCornerRadius`.
    case list
  }

  /// The open chat's corner: the composer's at rest, plus the inset it stands
  /// in — **concentric**, so the gap between the composer and the shell is
  /// one number round the corner as well as along the walls. The back disc
  /// is placed to the same rule (`previewCloseInset`).
  static let cardCornerRadius: CGFloat = chatComposerRestingCornerRadius + shellContentInset

  /// The gap between the shell's rim and everything nested against it.
  ///
  /// One number feeds both the composer and the transcript, so whatever
  /// fraction Auto Layout lands on, it lands on the same one for both and their
  /// side walls cannot part company. The composer to the shell's floor and
  /// corners and the back disc to the corner's arc are this same gap, which is
  /// why the corner is derived from it (`cardCornerRadius`). The open chat's
  /// reserved height (`chatSurfaceSize`) does not count it, so a smaller inset
  /// gives its points to the transcript rather than shrinking the card.
  static let shellContentInset: CGFloat = 12

  /// The composer's corner: the mock's `rounded-[100px]`, i.e. a capsule.
  ///
  /// Over-large on purpose — `PaletteGlassHost` clamps to half the shorter side,
  /// so "more than can be drawn" is how a capsule is written at any height.
  static let chatComposerCornerRadius: CGFloat = fromMock(100)

  /// The open chat composer's corner, **the same at every height**: the
  /// corner the one-line box can carry as a squircle on its own walls, which
  /// the shell's corner is concentric with (`cardCornerRadius`). A corner that
  /// grew with the draft would leave that concentric arc; a taller box holds
  /// this one as easily as the shortest.
  static let chatComposerRestingCornerRadius: CGFloat =
    (chatComposerBoxHeight / (2 * continuousCornerWallReach)).rounded(.down)


  /// The switcher card's corner: the pill inside it, plus the gap it keeps.
  ///
  /// **A card's corner is not independent of what it holds.** Two rounded
  /// rectangles with a uniform gap only read as one object while their arcs stay
  /// parallel, which is exactly `inner + inset` — the rule the open chat
  /// follows too (`cardCornerRadius`). The list's rows sit 16 in, so the
  /// chat's old 58.67 left 12.67 of daylight the eye read as the card being
  /// rounder than the thing inside it.
  static let listCardCornerRadius: CGFloat =
    resultsRowCornerRadius + resultsRowHorizontalInset

  static func surfaceCornerRadius(
    forHeight height: CGFloat, shape: SurfaceShape
  ) -> CGFloat {
    let radius: CGFloat
    switch shape {
    // **The capsule's corner, not half of whatever height it reaches.**
    //
    // `.greatestFiniteMagnitude` here used to mean "always a stadium", which is
    // right for the two heights a pill is normally drawn at — the resting
    // prompt (74.5, so 37.25) — and wrong the
    // moment a draft wraps. At six lines the prompt is ~340 tall, so half of it
    // is ~170: the ends become arcs deep enough to crowd the mascot and the mic
    // that are pinned inside them, and the field reads as a lozenge with text
    // stuffed through the middle.
    //
    // `cornerRadius` is half the resting capsule's height, so this is still
    // exactly a capsule at rest and stops growing after that — a grown text
    // field is a rounded rectangle, which is what every multi-line input does.
    case .pill: radius = cornerRadius
    case .initial: radius = cornerRadius
    case .chat: radius = cardCornerRadius
    case .list: radius = listCardCornerRadius
    }
    return min(radius, max(0, height) / 2)
  }

  /// Gap between the transcript and the composer standing under it — mock 20.
  static let surfaceStackSpacing: CGFloat = fromMock(20)

  /// The agent's face beside what it is doing, on the card's working line.
  static let workingFaceDiameter: CGFloat = fromMock(24)

  /// The composer's height at one line, the design frame's 64. The text and
  /// the control group are centred in it.
  static let chatComposerHeight: CGFloat = 64
  /// The open chat's composer is a box at least this tall, whatever the
  /// draft holds: the words from its top left, the icon row along its foot.
  /// **Room for one line** — padding, a line, the gap, the icon row and the
  /// padding again — and it grows with the draft and scrolls past the cap
  /// like any field. A taller empty box would stand over a well deeper than
  /// anything in it. `chatComposerHeight` stays the one-line height of the
  /// prompt's bar, what a draft collapses back to outside a chat.
  static let chatComposerBoxHeight: CGFloat = chatComposerPadding + chatComposerControlsPadding
    + chatComposerGap
    + ComposerControlGroup.glyph + {
      // `PromptTextView.textOnlyLineHeight(for: chatComposerFont)`, which is
      // the main actor's; the same sum, read off the same face.
      let font = roundedAppFont(size: previewBodyFontSize)
      return ceil(font.ascender - font.descender + font.leading)
    }()
  /// **One inset holds the box's whole content**: the words' ink, the + at
  /// the foot's left, Return's ink at its right and the icons' ink above the
  /// foot all stand this far from the rim. It is measured to the *ink* —
  /// the first letter's left edge and the capitals' tops — because that is
  /// what the eye measures, so the line is placed a point further out for
  /// the letter's side bearing and 3.5 higher for the space over SF Pro
  /// Rounded 15's capitals (`testTheChatComposersInkStandsTwentyIn` measures
  /// both off the laid-out text).
  static let chatComposerInkInset: CGFloat = 16
  static let chatComposerLeadingPadding: CGFloat = chatComposerInkInset - 1
  /// Above the words' line.
  static let chatComposerPadding: CGFloat = chatComposerInkInset - 3.5
  /// After Return's ink and under the icons' ink.
  static let chatComposerControlsPadding: CGFloat = chatComposerInkInset
  /// Between the words' line and the icon row. 10, not less: the folder
  /// pill is 26 tall, taller than the 16 glyph the box is stacked from, and
  /// a smaller gap put the descenders over it. Sizes the box and the grown
  /// controls band only — the words' own top and inset below stay at a gap
  /// of 5, which is what keeps their ink where the test pins it.
  static let chatComposerGap: CGFloat = 10
  /// A grown draft's scroll document carries half the gap above and below
  /// its lines, so a line scrolled up still travels to the fading edge; the
  /// scroll view stands the rest of the padding in from the top.
  ///
  /// **Half of a gap of 5, not of `chatComposerGap`**: following the gap
  /// moves the words' ink off its pinned inset. `chatComposerGrownTextTop`
  /// below holds for the same reason.
  static let chatComposerGrownTextInset: CGFloat = 2.5
  /// `chatComposerPadding` less the inset above. See
  /// `chatComposerGrownTextInset`.
  static let chatComposerGrownTextTop: CGFloat = chatComposerPadding - chatComposerGrownTextInset
  /// Under a grown draft's scroll view: the rest of the gap, the icon row,
  /// and the padding — 24 + lines + 15 + row + 24 in all, as the frame
  /// stacks them.
  static let chatComposerGrownControlsBand: CGFloat =
    chatComposerGap - chatComposerGrownTextInset + ComposerControlGroup.glyph + chatComposerControlsPadding
  /// The composer's placeholder ink, *Do anything*: white at 50%, the
  /// control group's resting ink.
  static let chatComposerPlaceholderInk = ComposerControlGroup.restingInk
  /// A composer glyph's hit target — folder, ring, clip, microphone, send —
  /// on the initial prompt and in a chat alike. See `ComposerControlGroup`.
  static let chatComposerControlDiameter: CGFloat = ComposerControlGroup.target
  /// Where the caret sits in from the composer's left rim.
  ///
  /// Much tighter than `promptTextLeading`, and it has to be — that one leaves
  /// room for the agent mark, which the composer drops once the shell is a
  /// chat.
  static let chatComposerTextLeading: CGFloat = chatComposerLeadingPadding
  /// The last glyph's hit target, in from the composer's right rim, so that
  /// Return's ink stands at the box's padding.
  static let chatComposerControlsTrailingInset: CGFloat =
    chatComposerControlsPadding - (ComposerControlGroup.target - ComposerControlGroup.glyph) / 2
  /// Text to the first glyph's hit target. The frame leaves 10 units of air
  /// between the last letter and the ink, and the target already holds some of
  /// it — a glyph at `restingAttachGlyphPointSize` is ~18pt of ink across — so
  /// what remains is this.
  static let chatComposerTextControlsGap = onPixelGrid(
    fromMock(10) - (chatComposerControlDiameter - 18) / 2
  )
  /// The gap between the clip and the microphone while a draft is expanded —
  /// dictating, or after it — where the recording cluster needs the room.
  /// At rest the glyphs' hit targets touch (`restingControlsSpacing`).
  static let chatComposerMicSpacing: CGFloat = fromMock(10)
  /// The stop square's inset from the composer's right rim, while a turn runs.
  static let chatComposerTrailingInset: CGFloat = fromMock(6)
  /// How big a composer glyph draws. See `ComposerControlGroup.glyph`.
  static let chatComposerGlyphSize: CGFloat = ComposerControlGroup.glyph
  /// The stop square in Send's slot: the outlined SF Symbol `stop`, at the
  /// same size as the outlines beside it.
  static let chatComposerStopGlyphPointSize: CGFloat = restingAttachGlyphPointSize


  /// The scale every Boltty AI mock is exported at.
  ///
  /// Pinned by the palette frame's own width — 388.45 against the 520pt capsule
  /// below — and agreed with by three numbers in the same frame that were never
  /// asked to agree: its 72.08pt capsule is `promptSize.height` and its 32pt
  /// voice control is `voiceOrbDiameter`. It used to be agreed with by a third,
  /// the frame's 45.735 corner — that one is gone, because no corner in this
  /// file comes off the mock any more. See `cardCornerRadius`.
  ///
  /// **This supersedes the 2.76 the switcher block below used to divide by.**
  /// That divisor came from an older export at a different scale, and it is the
  /// single reason the list read tighter than the design in every direction at
  /// once: dividing by a number ~10% too large shrinks every padding in the
  /// card, and the errors compound rather than cancel. Anything transcribed
  /// from a mock now goes through `fromMock`, so the scale is stated in one
  /// place and a future re-read cannot disagree with this one silently.
  static let mockScale: CGFloat = 0.75
  /// **Snapped to the half-point grid**, which on a Retina display is one
  /// device pixel. The 0.75 scale turns most of the mock's numbers into
  /// thirds — 22 into 29.33, 20 into 26.67, 44 into 58.67 — and a third of a
  /// point is a place no edge can be drawn: the glass rim, the composer's wall
  /// and the gap between them landed between pixels and were anti-aliased
  /// soft. `promptSize.height` was snapped by hand for exactly this reason;
  /// now every number read off the mock is, and none is more than a quarter
  /// of a point from the design.
  static func fromMock(_ value: CGFloat) -> CGFloat { onPixelGrid(value / mockScale) }
  static func onPixelGrid(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }

  /// Compact search capsule (Figma Boltty AI reference).
  ///
  /// **Height is the mock's 56, not the 98 this carried for a long time.** The
  /// width was always transcribed (388.45 → 520) but the height never was, and
  /// at 98 the capsule had roughly 30pt of air above and below a 38pt face
  /// where the mock has 15 — the face floated in the middle of a bar instead of
  /// filling it, which is what "the top and bottom padding is wrong" looks like
  /// from the outside.
  ///
  /// Two numbers in the same frame agree with 56 independently, which is why
  /// this is a transcription rather than a taste call. The face: the mock paints
  /// 26.2 units of hexagon inside 56, and `promptMascotSize` is 38.3 inside
  /// 74.67 — the same fraction. The voice disc: the mock's 32 against 56 is
  /// 0.571, and `voiceOrbDiameter` (44) against 74.67 is 0.589.
  ///
  /// Everything shaped by this follows it rather than being re-stated:
  /// `cornerRadius` is half of it, the vertical air is what a line of type
  /// leaves of it, and `panelSize` is built from it.
  /// The height is snapped to the retina half-point grid, the same way
  /// `voiceOrbDiameter` is. `fromMock(56)` is 74.666…, and a capsule whose
  /// centre lands a twelfth of a point off the grid draws its stadium corners
  /// and its hairline edge soft — Auto Layout aligns the laid-out capsule to
  /// the backing store while `bounds.midY` keeps the fraction, so the two stop
  /// agreeing about where the middle is.
  ///
  /// **The air round the face is 15% more than the mock's.** The face keeps
  /// its size, so the capsule grows by the air alone. The mock's own height
  /// stays `promptMockHeight`, which is what its other numbers are read
  /// against.
  ///
  /// **85 tall, Spotlight's proportion** — macOS 27's Spotlight field at
  /// the same width. Only the height: the walls keep `promptPaddingGrowth`.
  static let promptSize = CGSize(width: 540, height: 85)
  /// The capsule the mock draws, `fromMock(56)` on the half-point grid.
  static let promptMockHeight: CGFloat = (fromMock(56) * 2).rounded() / 2
  /// How much more air the first screen has than the mock: above and below
  /// the face, beside the face and beside the last glyph.
  static let promptPaddingGrowth: CGFloat = 1.15
  /// An open chat's **default** size, with the composer a box
  /// (`chatComposerBoxHeight`) at its foot. A person who wants other room
  /// drags it out — `BolttyAISurfaceSizes` keeps what they chose. Content
  /// scrolls inside; the screen may cap it.
  static let chatSurfaceSize = CGSize(width: 584, height: 680)
  /// The smallest open chat a drag can leave: a composer with its five
  /// glyphs and a few words beside them, and a transcript with room for a
  /// question and the start of its answer.
  static let chatSurfaceMinimumSize = CGSize(width: 420, height: 360)
  /// The chat list's default: the tab strip over five rows. As wide as the
  /// prompt, so ↓ does not change the width.
  static var historySurfaceHeight: CGFloat {
    historyTabStripHeight + resultsListHeight(itemCount: historyDefaultVisibleRows)
  }
  static let historyDefaultVisibleRows = 5
  /// The smallest chat list a drag can leave: five tabs that still carry
  /// their names, and two rows under them.
  static var historySurfaceMinimumSize: CGSize {
    CGSize(width: 440, height: historyTabStripHeight + resultsListHeight(itemCount: 2))
  }
  /// Where a resizable shell's edge is found: this far inside it, this far
  /// outside it (where the shell's shadow still takes the press), and a lower
  /// corner this far in along both edges — most of the 58pt corner, where the
  /// grabber stands. The sides stop this short of the top, which is the move
  /// handle. Five points either side was the first try, and nobody found it.
  static let surfaceResizeInnerGrip: CGFloat = 6
  static let surfaceResizeOuterGrip: CGFloat = 8
  static let surfaceResizeCornerReach: CGFloat = 30
  static let surfaceResizeTopClearance: CGFloat = 28
  /// The scroll indicator that follows the shell round its right corners
  /// (`PaletteCornerScrollIndicator`): its
  /// centre line this far in from the rim, this thick — an overlay knob's
  /// width — half a corner's quarter circle long, never under this, and still this long after the scrolling
  /// rests, as an overlay scroller lingers.
  static let scrollIndicatorInset: CGFloat = 7
  static let scrollIndicatorWidth: CGFloat = 5
  static let scrollIndicatorMinimumLength: CGFloat = 14
  static let scrollIndicatorLinger: TimeInterval = 0.9
  static let scrollIndicatorInk = NSColor.white.withAlphaComponent(0.45)
  /// The corner's grabber (`PaletteResizeGrabberView`): an arc this far
  /// *outside* the rim, as iPadOS 26 hangs it off a window's corner, this
  /// thick, spanning
  /// this much either side of the diagonal. Not drawn at rest: it shows
  /// only while the pointer is on a grip or a drag is under way.
  static let resizeGrabberOutset: CGFloat = 6
  static let resizeGrabberLineWidth: CGFloat = 4
  static let resizeGrabberHalfAngle: CGFloat = .pi / 12
  static let resizeGrabberRestingInk = NSColor.clear
  static let resizeGrabberLitInk = NSColor.white.withAlphaComponent(0.75)
  /// WORK PAGE 1091:4731 uses a 112-high capsule, twice the older mock's 56.
  /// Adapt just its initial controls to the mock's capsule height — not the
  /// grown one, so the extra air does not scale them too.
  static func fromInitialPromptMock(_ value: CGFloat) -> CGFloat {
    onPixelGrid(value * promptMockHeight / 112)
  }

  static let restingWaveformGlyphSize = CGSize(
    width: fromInitialPromptMock(30.75), height: fromInitialPromptMock(32.8)
  )
  /// The group's targets touch; the 10pt between glyphs is inside them.
  static let restingControlsSpacing: CGFloat = 0
  /// The mock leaves 40 units between the last glyph's ink and the capsule
  /// rim, and the first screen 15% more (`promptPaddingGrowth`) — 30.5 of
  /// ink. Subtract the target's transparent padding so the visible inset agrees.
  static let restingControlsTrailingInset = onPixelGrid(
    restingControlsInkInset - ComposerControlGroup.gap(chat: false) / 2
  )
  /// From the rim to the last glyph's ink — and to the face's, on the other
  /// end (`promptLeadingInset`).
  static let restingControlsInkInset = onPixelGrid(fromInitialPromptMock(40) * promptPaddingGrowth)
  /// The agent mark beside the prompt.
  ///
  /// The mock draws a 25pt box, which is 33.3 here. The box is not the mark:
  /// the brand SVGs carry ~40% transparent padding inside their viewBox, so
  /// this box paints a ~20pt mark — which is what the mock's own 14.5pt
  /// glyph (19.3 here) asks for.
  static let iconSize: CGFloat = fromMock(25)

  /// The mascot is drawn 15% larger than the icon box it sits in.
  ///
  /// **Each face multiplies its own box.**
  ///
  /// The boxes themselves are no longer load-bearing for type: `promptTextLeading`
  /// and `resultsRowTextLeading` state where text starts, so a box can be sized
  /// for the face and the pointer without moving a single letter.
  static let mascotOversize: CGFloat = 1.15
  /// The face beside the prompt: `mascotOversize` of its box, and then a
  /// quarter more — at the box's own size it read small beside the prompt's
  /// type and controls.
  static let promptMascotScale: CGFloat = 1.15 * 1.10
  static let promptMascotSize: CGFloat = iconSize * mascotOversize * promptMascotScale
  /// The prompt mark's click target.
  ///
  /// Bigger than both the box and the face: clicking the mark opens the agent
  /// switcher, and the face had grown past the view that carries that gesture,
  /// so its top and bottom edges looked clickable and were not. 44 is the size
  /// Apple's own guidance puts on a pointer target, and it costs nothing now
  /// that the box no longer positions the text beside it.
  /// How far the prompt's face reaches past its box, on one side — the number
  /// the gap beside it has to give back: text measured from the box sits this
  /// much nearer the ink than the box implies.
  static var promptMascotOverhang: CGFloat { (promptMascotSize - iconSize) / 2 }
  static let promptMarkHitSize: CGFloat = max(44, promptMascotSize.rounded(.up))
  static let cornerRadius: CGFloat = promptSize.height / 2
  /// Transparent bleed that keeps the capsule shadow inside the borderless panel.
  static let safeAreaX: CGFloat = 50
  static let safeAreaY: CGFloat = 50

  // MARK: - Type ramp

  /// **The palette's type sizes.** Every label takes one of these; the
  /// exceptions inside an answer (`answerHeading1FontSize`,
  /// `answerHeading3FontSize`) say why they step off it.
  ///
  /// Whole points: 18 / 15 / 13 / 11 — `typeChat` is on the 15. Fractions
  /// put glyph stems between pixels, and two sizes less than a point apart
  /// read as one size set slightly wrong rather than as two levels.
  /// Primary: the initial prompt, a row's title.
  static let typePrimary: CGFloat = 18
  /// Secondary: a row's second line, a day's heading, the folder chip.
  static let typeSecondary: CGFloat = 15
  /// The chat: its transcript and the composer under it, on
  /// `typeSecondary`'s step.
  static let typeChat: CGFloat = 15
  /// Meta: what sits beside an answer rather than in it — files, tool calls,
  /// an error under the prompt.
  static let typeMeta: CGFloat = 13
  /// Footnote: legends, sizes, raw output. The system's own small-control
  /// size, so a `.small` button in the same row sets at the same size.
  static let typeFootnote: CGFloat = NSFont.systemFontSize(for: .small)

  /// The first screen's typed words and placeholder.
  ///
  /// **A decided on-screen size, not a transcription**: the design frames
  /// never agreed about it. 20, a step over the transcript's headings and
  /// off the ramp on purpose — the first screen is one line of type, and it
  /// should read as the thing to look at.
  static let promptFontSize: CGFloat = 20

  // MARK: The caret (`PromptCaretView`)
  //
  // macOS 27's Spotlight caret, measured off a screenshot and held to the
  // type size, so the first screen's 20 and a
  // chat's 15 draw one caret at two sizes: a bar 2 wide at 22 points,
  // reaching 5 past the capitals and 5 under the baseline, in a light whose
  // falloff was matched to within a twentieth, pixel row by pixel row.

  /// The bar's width, in half points — 2 on the first screen, 1.5 in a chat.
  static let caretWidthPerPoint: CGFloat = 0.09
  /// How far the bar reaches past the capitals, and under the baseline.
  static let caretReachPerPoint: CGFloat = 0.227
  /// The light: the room it is drawn in round the bar, how far its shape
  /// stands out from the bar, its blur, and its strength.
  static let caretGlowMarginPerPoint: CGFloat = 0.7
  static let caretGlowSpreadPerPoint: CGFloat = 0.075
  static let caretGlowBlurPerPoint: CGFloat = 0.175
  static let caretGlowAlpha: CGFloat = 0.68
  /// Solid while typing; blinking once the caret has rested this long, on
  /// this period — AppKit's own half a second on, half off.
  static let caretBlinkDelay: TimeInterval = 0.5
  static let caretBlinkPeriod: TimeInterval = 1.0
  /// WORK PAGE (14): a long draft becomes a scrolling card, at the same size as
  /// a short one — see `PromptTextView.setExpandedStyle`. The recording controls
  /// stay on the original row and float above its text.
  ///
  /// This is where the draft stops growing the panel and starts scrolling
  /// inside it, which at full-size type is a little under five lines.
  static let expandedPromptMaximumHeight: CGFloat = fromMock(148)
  /// The capsule's side walls (mock 12 → 16) and the gap from the mark to the
  /// placeholder beside it (mock 5 → 6.7).
  ///
  /// Only the horizontal walls are stated here. The capsule's vertical air is
  /// what `promptSize.height` has left over once a line of prompt type is in
  /// it — so it follows the font rather than this number.
  ///
  /// **The face stands as far in as the microphone does**: its ink
  /// `restingControlsInkInset` from the rim. The face paints past its box,
  /// and its ink stands `promptMascotInkOutset` before it, so the box is
  /// that much further in.
  ///
  /// **Less `promptMascotOpticalInset`**: at the same distance a full face
  /// sitting in the capsule's round end reads further in than a thin glyph
  /// by a straight wall, so its ink stands 24.5 from the rim to look 30.5.
  static let promptLeadingInset =
    restingControlsInkInset + promptMascotInkOutset - promptMascotOpticalInset
  static let promptMascotOpticalInset: CGFloat = 6
  /// How far the prompt face's ink stands before its box: the overhang, less
  /// the room the outline leaves inside its own frame. Measured on screen: a
  /// box 18 in put the ink at 14.
  static let promptMascotInkOutset: CGFloat = 4
  static let promptTrailingInset = fromMock(12)
  /// The mark-to-text gap: the mock's 5 (6.7 here), plus what the face takes back.
  ///
  /// Stated from the box, while the mascot paints past the box — so the gap the
  /// *eye* gets is `promptMascotOverhang` narrower than the number says. Giving that
  /// back is not a taste decision, it is the difference between the mock's gap
  /// and the mock's gap minus the overhang, which is why it is derived rather
  /// than typed.
  static let promptIconTextSpacing =
    fromMock(5) + promptMascotOverhang + mascotOpticalTextGap
  /// Air beyond what the overhang costs, added by eye.
  ///
  /// The only part of the gap that is a judgement rather than arithmetic, which
  /// is why it is separate and named: a hexagon's widest point is its middle, so
  /// the corner nearest the text sits back from the frame edge and the geometric
  /// gap reads a little tight. At 5.5 the caret stands 15 from the face's
  /// ink.
  static let mascotOpticalTextGap: CGFloat = 5.5
  /// Where the prompt's text starts, measured from the capsule's leading edge.
  ///
  /// The row's `resultsRowTextLeading`, for the same reason: while the field
  /// began at the mark's trailing edge, the mark's box was a typographic
  /// measurement and could not be resized without moving the sentence. See
  /// that metric for the full account.
  static let promptTextLeading: CGFloat =
    promptLeadingInset + iconSize + promptIconTextSpacing
  static let promptMicTextSpacing: CGFloat = 10

  /// Pasted attachments, drawn inline as capsules: a glyph and a name in the
  /// kind's colour, on that colour at a fifth, a capsule taller than the
  /// type round them.
  ///
  /// **Ratios of the sentence's point size, not points**, because the chip
  /// stands in two sentences — the first screen's 20 and a chat's 15. The
  /// name is the sentence's own size: a word in the sentence.
  static let chipHeightPerPoint: CGFloat = 1.46
  static let chipPaddingPerPoint: CGFloat = 0.44
  static let chipSymbolPerPoint: CGFloat = 0.68
  static let chipSymbolGapPerPoint: CGFloat = 0.31

  /// What a chip shows under the pointer (`PromptChipPreview`), in a system
  /// popover: a picture fitted inside a square this big, or a few lines of
  /// what it carries at most this wide.
  static let chipPreviewImageMaxSide: CGFloat = 240
  /// A region dragged across the screen (`ScreenSelectionOverlay`): a press
  /// outside the shell that moves this far is a drag, not "go away"; a drag
  /// smaller than the minimum on either side is neither, and selects nothing.
  static let screenSelectionDragThreshold: CGFloat = 4
  static let screenSelectionMinimumSide: CGFloat = 12
  static let screenSelectionLineWidth: CGFloat = 2.5
  static let screenSelectionCornerRadius: CGFloat = 8
  /// The faint wider stroke of the same gradient round the border, where
  /// there is no Metal to draw the glow (`ScreenSelectionGlowView`).
  static let screenSelectionGlowWidth: CGFloat = 10
  /// The border's light: it runs into the region about this far from the
  /// line — a Gaussian off each edge, its width 0.45 of this — strongest at
  /// the line, and as a faint halo this far outside it.
  static let screenSelectionInnerGlowDepth: CGFloat = 36
  static let screenSelectionInnerGlowStrength: CGFloat = 0.3
  static let screenSelectionHaloReach: CGFloat = 10
  static let screenSelectionHaloStrength: CGFloat = 0.3
  /// How far the mascot's colours slosh along the region's height — a
  /// fraction of it — the two waves across its width and the slow drift, as
  /// the body's gradient does (`gradientCoordinate`). Larger than the body's
  /// share, because a line shows far less of the run than a filled face.
  static let screenSelectionWaveAmplitude: CGFloat = 0.26
  static let screenSelectionDriftAmplitude: CGFloat = 0.2
  /// The Oklab lightness the mascot's stops are lifted to for the border —
  /// under a word's 0.8, which draws Lilac and Citrus as pastels on the
  /// dim.
  static let screenSelectionLightness: Double = 0.72
  /// The handles a region is moved and resized by, and how far from one a
  /// press still takes hold of it.
  static let screenSelectionHandleDiameter: CGFloat = 9
  static let screenSelectionHandleReach: CGFloat = 12
  /// The screen outside the region, while it is asked about.
  static let screenSelectionDim: CGFloat = 0.4
  /// Between the region and the shell that stands beside it, and between the
  /// shell and the screen's edge.
  static let screenSelectionShellGap: CGFloat = 16
  static let chipPreviewImageCornerRadius: CGFloat = 8
  static let chipPreviewImageInset: CGFloat = 8
  static let chipPreviewTextInset: CGFloat = 12
  static let chipPreviewTextMaxWidth: CGFloat = 320
  static let chipPreviewTextMaxLines = 12
  static let chipPreviewFileIconSize: CGFloat = 48

  /// How long the typing has to rest before the keys are said: words
  /// arriving while a sentence is still being written are
  /// a second thing moving at the end of the line. A keystroke puts them away
  /// at once; they come back over `Motion.standard`.
  static let keyHintDelay: TimeInterval = 1

  /// The pill's corner: the mock's 50 against a 21pt chip, i.e. a stadium.
  /// `PromptChipCell` clamps it to half the height, which is what actually
  /// draws it — the number only has to be big enough to reach that clamp.
  static let chipCornerRadius: CGFloat = fromMock(50)

  /// Chip fill, as a fraction of its own ink colour — the label's colour at
  /// a fifth, as the reference draws all four.
  static let chipFillAlpha: CGFloat = 0.22

  /// Chip entrance. Tight and short by design: a chip is the result of a
  /// keystroke, not an event, so it should settle dryly rather than spring —
  /// see `MotionPreferences.controlPressSpring`, which is what drives it.
  ///
  /// The duration is also a budget. `NSTextAttachmentCell` is *drawn*, not
  /// layered, so this animation is redraws of one small rect rather than a
  /// `CABasicAnimation`; 0.16s is ~19 frames at 120Hz, and a longer one would
  /// be paid for in CPU rather than in polish.
  static let chipAppearDuration: TimeInterval = 0.16
  static let chipAppearStartScale: CGFloat = 0.94

  /// Shared resting hit target for the clip and waveform, including when the
  /// initial prompt draws them without a backing disc (WORK PAGE 1091:4731).
  static let voiceOrbDiameter: CGFloat = 44

  /// The waveform is drawn, not a symbol.
  ///
  /// `waveform` as an SF Symbol is one fixed picture of sound. The bars have
  /// to answer the voice individually, so they are five layers whose heights
  /// are driven by the microphone — a glyph cannot do that.
  /// Six bars, not five, and the numbers below are measured off the vector the
  /// mock actually exports rather than estimated from a picture of it.
  ///
  /// The mock's glyph is `waveform` at 15×16 inside the 32pt disc: six stadium
  /// bars 1.46 wide on a 2.71 pitch, the tallest spanning the full 16. Through
  /// `fromMock` that is 1.95 wide, 1.66 apart, 21.3 tall — thinner, further
  /// apart and half again as tall as the five 2.5×17 bars this drew before,
  /// which is most of why our control read as a chunkier, stubbier waveform
  /// than the design's.
  static let voiceOrbBarCount = 6
  static let voiceOrbBarWidth: CGFloat = fromMock(1.4613)
  static let voiceOrbBarSpacing: CGFloat = fromMock(1.2449)
  static let restingWaveformBarSpacing =
    (restingWaveformGlyphSize.width - CGFloat(voiceOrbBarCount) * voiceOrbBarWidth)
      / CGFloat(voiceOrbBarCount - 1)
  /// Height of the tallest voice bar at rest inside the 44pt circle.
  static let voiceOrbBarHeight: CGFloat = 22
  /// Resting profile — **asymmetric**, because `waveform` is.
  ///
  /// The old [0.34, 0.62, 1, 0.62, 0.34] was a symmetric idea of the symbol;
  /// the symbol itself peaks left of centre and has a secondary swell on the
  /// right. Each entry is that bar's height over the tallest one, straight off
  /// the export: 4.18, 10.41, 16, 8.41, 12.76, 5.59.
  static let voiceOrbBarProfile: [CGFloat] = [0.26, 0.65, 1.0, 0.53, 0.80, 0.35]
  /// How far a bar may swing from its resting height at full level.
  static let voiceOrbBarSwing: CGFloat = 0.5
  /// Radians the travelling wave advances per microphone reading.
  ///
  /// Readings arrive ~47×/second, so this *is* the clock — no display link is
  /// needed, and the bars stop dead when the audio stops rather than idling.
  static let voiceOrbBarPhaseStep: CGFloat = 0.38
  /// Phase offset between neighbouring bars, so the crest travels across the
  /// group instead of every bar pumping in unison.
  static let voiceOrbBarPhaseSpread: CGFloat = 1.1

  /// The recording cluster that hover-reveals over the microphone disc.
  ///
  /// While speaking, only the disc stays on the card so the draft remains
  /// fully readable. Pointing near it expands this pill: cancel, elapsed time,
  /// level meter, confirm — on the glass every control wears
  /// (`PaletteSurfaceStyle.bolttyAIControl`, the shell's own), 2pt of
  /// padding and 10pt between the four parts.
  ///
  /// The pill's meter is "how loud", and it only appears under the pointer.
  /// The shell's rim (`VoiceEdgeGlowView`) is a different question — that the
  /// capsule is live — in the mascot's colours, and it stays up while this
  /// cluster is tucked away. Two indicators, two jobs.
  static let voiceControlsPadding: CGFloat = fromMock(2)
  static let voiceControlsSpacing: CGFloat = fromMock(10)
  static let voiceControlsCornerRadius: CGFloat = fromMock(50)
  /// The pill's own height — the mock's 36, and the only place it is stated.
  ///
  /// Two paddings around a disc, which is what the constraints already build;
  /// naming it keeps layout and hit-target tests on the same measurement.
  static var voiceControlsHeight: CGFloat { voiceOrbDiameter + voiceControlsPadding * 2 }

  /// Both discs are `voiceOrbDiameter` — the same button, two roles.
  ///
  /// Confirm is white with a black glyph, cancel is transparent with a white
  /// one: the vocabulary the idle microphone already established, where solid
  /// means the primary action and transparent means the secondary.
  static let voiceControlsGlyphPointSize: CGFloat = fromMock(12)
  static let voiceControlsTimerFontSize: CGFloat = fromMock(12)
  static let voiceControlsCancelGlyphColor = PaletteInk.primary
  /// Flat white, and opaque on purpose: with the frost showing through, it
  /// reads grey over the dark pill, and Send is the one control here that
  /// should look solid.
  static let voiceControlsConfirmFillColor = NSColor.white
  static let voiceControlsConfirmGlyphColor = NSColor.black
  /// Hover leaves the white disc alone. A white disc cannot brighten, and on
  /// a dark pill a dimmed one reads as grey — as if the button went inactive
  /// at the moment it is aimed at — so Send takes its feedback from the press
  /// instead.
  ///
  /// Kept as its own constant rather than folded into the resting colour: the
  /// two are separate states that happen to agree.
  static let voiceControlsConfirmHoverFillColor = NSColor.white
  /// Hover on the transparent disc, which has the opposite problem: nothing to
  /// dim, so the feedback has to appear.
  static let voiceControlsCancelHoverFillColor = PaletteInk.fill
  /// Cancel's hover also frosts what is behind it, rather than only tinting.
  ///
  /// The disc has no fill of its own to dim or brighten, so the hover has to
  /// arrive out of nothing — and a bare 12% white wash arriving over the pill
  /// reads as a painted dot. A small backdrop blur underneath makes the same
  /// wash read as a piece of glass appearing, which is the pill's own language.
  ///
  /// Small on purpose: the pill is already frosted, and the two blurs compound
  /// as `sqrt(s1^2 + s2^2)`, so anything larger erases the wave behind it.
  static let voiceControlsCancelHoverBlurRadius: CGFloat = 3

  /// The live meter inside the pill (mock: 35.77 × 16).
  static let voiceMeterSize = CGSize(width: fromMock(35.77), height: fromMock(16))
  /// Thin and many, unlike the orb's five: this is an oscillogram read at a
  /// glance, not a control that has to look pressable.
  static let voiceMeterBarCount = 14
  static let voiceMeterBarWidth: CGFloat = 1.6
  /// Shortest a bar gets, so silence still draws a line rather than nothing.
  static let voiceMeterMinimumBarFraction: CGFloat = 0.18

  /// **The first screen's capsule grows with the draft.** The first line
  /// stays where a one-line draft
  /// stands, centred in the resting capsule, beside the face and the icons;
  /// each line after it adds its height below, and the same slack closes it.
  @MainActor
  static var promptGrownInset: CGFloat {
    max(0, (promptSize.height - PromptTextView.textOnlyLineHeight) / 2)
  }

  /// How far it grows before the draft scrolls inside it: five lines.
  @MainActor
  static var promptGrownMaximumHeight: CGFloat {
    promptGrownInset * 2
      + CGFloat(PromptTextView.maxVisibleLines) * PromptTextView.textOnlyLineHeight
  }

  /// How long after the last word Boltty waits for the polished final
  /// transcript before submitting anyway.
  ///
  /// Apple's engine delivers its best text *after* the audio stops — it
  /// finalizes its ranges, and with a second language the two recognizers'
  /// phrases are only compared once both have. Submitting the moment ✓ is
  /// pressed would send the partial, which is the version with the mistakes
  /// in it.
  static let voiceConfirmGraceInterval: TimeInterval = 2.0

  /// The composer's glyphs — folder, clip, microphone, Return, stop — at 15,
  /// a little under the 17 at which the medium `paperclip` fills the mock's
  /// 31 × 32 frame, so the icons stay quieter than the words.
  static let restingAttachGlyphPointSize: CGFloat = 15

  /// The back control, top-left of the card: **macOS 27's standard glass
  /// button**, as the Siri app's toolbar draws its row of glass circles:
  /// each 36 points across, its symbol 16 points of ink, the size
  /// `magnifyingglass` and `square.and.pencil` draw at 16 regular. The
  /// control is the system's own (`GlassCircleButton`: an `NSButton`,
  /// `bezelStyle = .glass`, `borderShape = .circle`).
  static let previewCloseDiameter: CGFloat = 36
  /// `chevron.backward` at the toolbar's symbol size and weight.
  static let previewCloseGlyphPointSize: CGFloat = 16
  static let previewCloseGlyphWeight: NSFont.Weight = .regular
  /// The close disc's inset from the card's top **and** leading edges.
  ///
  /// One number for both, so the disc sits *in* the corner rather than near
  /// it.
  ///
  /// **It keeps the disc `shellContentInset` from the corner's arc**, the
  /// gap the composer keeps. A disc in a corner rounder than itself comes nearest
  /// the arc on the diagonal, so it stands that far from the arc there and a
  /// little further from the walls: the arc's centre is `cardCornerRadius` in
  /// along both walls, and the disc's is on the line from it to the corner.
  static let previewCloseInset: CGFloat = {
    let radius = previewCloseDiameter / 2
    let fromArcCentre = cardCornerRadius - shellContentInset - radius
    return onPixelGrid(cardCornerRadius - fromArcCentre / 2.squareRoot() - radius)
  }()
  /// The chat list's foot discs — Settings in the lower left, New Chat in
  /// the lower right — inset this far from the foot and from their side.
  ///
  /// Chosen by eye. It stands inside the lower corners' resize grips
  /// (`surfaceResizeCornerReach`), so the grips give way on a disc
  /// (`AgentPaletteView.resizeEdges`); clearing them took 25, which sat the
  /// discs too far from the corner.
  static let historyFootDiscInset: CGFloat = 18
  /// The band across the list's foot the discs own; the rows dissolve
  /// across it as the chat's transcript does under its back disc.
  static let historyFootHeight: CGFloat =
    historyFootDiscInset + previewCloseDiameter + previewContentVerticalPadding

  /// The band across the top of the card the close disc owns.
  ///
  /// **A scroll content inset, not a frame offset, and the difference is what
  /// the mock draws.** In the reference's right-hand card the answer is
  /// plainly visible running underneath the disc: the control is glass, the
  /// text reads through it, and a line passing behind it is the design rather
  /// than a defect. A frame offset cannot express that — it puts the viewport
  /// below the disc at every scroll position — so the band is spent where it
  /// can scroll away.
  ///
  /// The gap under the disc is `previewContentVerticalPadding` rather than a
  /// number of its own: the card's padding is one constant on the top, the
  /// bottom and both sides.
  static let previewHeaderHeight: CGFloat =
    previewCloseInset + previewCloseDiameter + previewContentVerticalPadding

  /// The waveform on the mic button.
  ///
  /// White, because the control stands on the system's glass, which is dark
  /// over this panel. One appearance through every state, with the waveform
  /// carrying whether anything is being heard.
  static let voiceOrbGlyphColor = PaletteInk.primary

  /// Smoothing applied to the microphone level before it drives anything.
  ///
  /// Raw RMS off a 1024-frame buffer arrives ~47×/second and is far too jumpy
  /// to drive a visual directly — unsmoothed it strobes. Rises are followed
  /// quickly and falls slowly, the standard asymmetry for a level meter: a
  /// consonant should light it immediately, and the gap between two words
  /// should not put it out.
  static let voiceOrbLevelAttack: CGFloat = 0.5
  static let voiceOrbLevelRelease: CGFloat = 0.12

  /// The voice glow: rays of the mascot's colours fanning out of one point
  /// under the shell's glass, and quickening with the voice. Drawn *beneath*
  /// the glass so the glass bends and frosts what moves, and with no hard
  /// edges anywhere: at this size any line reads as a wire lying on the
  /// glass. See `VoiceEdgeGlowLayout`.
  static let voiceGlowIdle: CGFloat = 0.26
  static let voiceGlowBreatheDuration: CGFloat = 3.4
  static let voiceGlowAttack: CGFloat = 0.325
  static let voiceGlowRelease: CGFloat = 0.86
  /// The orb's wave follows the voice on a quicker envelope than the light
  /// does: it rises on a syllable and falls in the gap after it, which is what
  /// makes it read as the voice and not as a lamp turned up.
  static let voiceGlowWaveAttack: CGFloat = 0.05
  static let voiceGlowWaveRelease: CGFloat = 0.22

  /// How fast the rays travel, in the shader's units a second: silence, what a
  /// full voice adds to it, and processing, which holds one pace.
  ///
  /// The voice is what moves it — a quiet room drifts and a word sets it
  /// running — and it is an *integral* of this (`flow`), so a change of
  /// speed quickens the picture rather than jumping it.
  static let voiceGlowFlowRest: CGFloat = 0.55
  static let voiceGlowFlowVoice: CGFloat = 3.4
  static let voiceGlowFlowProcessing: CGFloat = 1.7
  /// Radians a second of the origin's sway across the shell.
  static let voiceGlowSwayRate: CGFloat = 0.9
  /// The palette's stops are lifted to this Oklab lightness before they light
  /// the rays: a dark stop (Lilac's violet) is mud once the glass has dimmed
  /// it. The screen selection's border does the same (`screenSelectionLightness`).
  static let voiceGlowLightness: Double = 0.62
  static let voiceGlowFadeDuration: TimeInterval = 0.4

  /// Leaving, once the transcript has landed.
  ///
  /// Longer than it arrived, and longer than a cancel. The words appear in the
  /// prompt at the same moment, and the two should read as one event finishing
  /// rather than as a light being switched off beside some text appearing.
  static let voiceGlowCompletedFadeDuration: TimeInterval = 0.55
  /// Leaving because the take was discarded, or because dictation failed.
  ///
  /// Short, but deliberately not zero: a light that vanishes between two frames
  /// reads as a glitch, and on the failure path an error message is arriving in
  /// the same instant and should not have to compete with a glow.
  static let voiceGlowAbortFadeDuration: TimeInterval = 0.18

  /// Second noise gate, applied to the normalised level rather than the raw
  /// amplitude. `VoiceDictationService.loudness` already drops anything under
  /// −50 dB; this drops what survives that and still is not speech — a steady
  /// fan sits around 0.04 and should not light the shell.
  static let voiceGlowGate: CGFloat = 0.055
  /// Width of the gate's knee. A hard threshold chatters: a reading resting on
  /// it crosses several times a second and the glow strobes at the rate of the
  /// room instead of the rate of the voice.
  static let voiceGlowGateKnee: CGFloat = 0.11
  /// The level processing runs at. It has no microphone to answer, so it holds
  /// a steady value rather than decaying to the idle floor — the point of the
  /// state is that something *is* happening.
  static let voiceGlowBeamLevel: CGFloat = 0.74
  /// How long processing takes to wind the rays into a spiral, and to let them
  /// out again.
  static let voiceGlowBeamGatherDuration: CGFloat = 0.32

  /// How long a silence has to last before a dictated prompt sends itself.
  ///
  /// Long enough to be a decision rather than a pause for breath. Apple's own
  /// dictation endpoints around 1.5s; this is longer because the thing on the
  /// other side of it is not punctuation, it is an agent starting work.
  static let voiceSilenceSubmitDelay: TimeInterval = 2.4

  /// Listening is an orb: the shell collapses to a ball this wide, with the
  /// voice's light in it. A little taller than the prompt capsule, so the
  /// collapse reads as a change of shape and not as a shrink.
  static let listeningOrbDiameter: CGFloat = 84
  /// **And it grows round the words as they are said**: a capsule as tall as the orb, the
  /// words this far in from each round end, as long as the prompt at most —
  /// the words land there when the take ends.
  static let listeningWordsInset: CGFloat = 30
  static let listeningWordsFontSize: CGFloat = typePrimary
  static let listeningMaxWidth: CGFloat = promptSize.width

  /// How far a glyph button sinks while held.
  ///
  /// 0.95, not 0.90. A tenth of a 44pt disc is 4.4pt of travel — the depth of
  /// an iOS tap, where a finger hides the control and the motion has to be
  /// seen round it. Under a pointer the control is in plain view, and a
  /// Liquid Glass button on the Mac gives way by a few percent.
  static let controlPressedScale: CGFloat = 0.95
  /// Rows are much wider than glyph buttons, so they need far less travel to
  /// read as pressed.
  static let rowPressedScale: CGFloat = 0.985
  /// Hover in/out crossfade for buttons and rows.
  static let hoverFadeDuration: TimeInterval = Motion.quick
  /// How long the pointer rests on a control before its help tag shows.
  static let helpTagDelay: TimeInterval = 0.45
  /// How long after a tag goes that the next one shows at once, with no
  /// wait: the pointer moving from one control to the next.
  static let helpTagWarmWindow: TimeInterval = 0.5

  /// **The panel arrives at once**: ⌥Space is pressed dozens of times a day,
  /// and at that frequency an entrance stops reading as polish and starts
  /// reading as latency — the palette must feel like it was already there.
  ///
  /// Leaving keeps a short fade, with no hold before it. Nobody waits on a
  /// panel going away, and one cut out of existence reads as a crash rather
  /// than as a dismissal.
  static let panelFadeOutDuration: TimeInterval = 0.10
  /// How far under the menu bar the shell stands: it is locked there, under
  /// the notch it drips out of, as Siri's field stands under the status bar.
  static let lockedTopGap: CGFloat = 30

  /// The drip (`PaletteDrip`): the shell running out of the notch — or the
  /// top edge — as a drop, letting go and spreading into its shape, as
  /// iPadOS 26's Siri field arrives. Leaving is the same drop backwards and
  /// quicker: nobody waits on a panel going away.
  ///
  /// **On the shell's own spring, retargeted** — it is the shell's glass
  /// that drips, not a separate drop, and a retargeted spring keeps its
  /// speed, so letting go never stops it dead. The shell falls at
  /// `dripFallResponse`; `dripSpreadAfter` into the fall it is retargeted
  /// into its frame at `dripSpreadResponse`, keeping its speed. Leaving, it
  /// shrinks to its fallen size and then rises into the source. What stands
  /// on the shell fades in from `dripContentInAfter`.
  ///
  /// **Arriving is scaled by `dripInPace`**: every number of the way in is
  /// that share of its base, so the fall, the spread and the content keep
  /// their proportions as the whole is tuned faster or slower.
  static let dripInPace: CGFloat = 0.65
  static let dripInDuration = TimeInterval(0.6 * dripInPace)
  static let dripOutDuration: TimeInterval = 0.38
  static let dripFallResponse: CGFloat = 0.26 * dripInPace
  static let dripSpreadAfter = TimeInterval(0.11 * dripInPace)
  static let dripSpreadResponse: CGFloat = 0.3 * dripInPace
  static let dripShrinkResponse: CGFloat = 0.18
  static let dripRiseAfter: TimeInterval = 0.08
  static let dripRiseResponse: CGFloat = 0.2
  static let dripContentInAfter = TimeInterval(0.12 * dripInPace)
  static let dripContentInDuration = TimeInterval(0.24 * dripInPace)
  /// Where a screen has no notch, the drop comes from a sliver this tall at
  /// the top edge. Nothing is drawn there.
  static let dripEdgeSliver: CGFloat = 8
  /// Sizes as shares of the prompt's height (or a shorter shell's): the seed
  /// it starts from inside the notch, and the drop as it falls — a little
  /// taller than wide.
  static let dripSeed: CGFloat = 0.5
  static let dripFallWidth: CGFloat = 0.8
  static let dripFallHeight: CGFloat = 0.92

  /// Session switcher list under the capsule (↓) — visual sibling of the prompt glass.
  ///
  /// Everything from here to `resultsRowIconTextSpacing` is the switcher mock
  /// through `fromMock` — see there for what it replaced and why the card used
  /// to come out uniformly tight.
  static let resultsTopSpacing = fromMock(6)
  /// The history frame's `h-16` row, row to row — see `fromHistoryMock`.
  static let resultsRowHeight: CGFloat = fromHistoryMock(64)
  static let resultsMaxVisibleRows = 6
  /// How far a `.continuous` corner actually runs along the wall, as a multiple
  /// of its radius.
  ///
  /// **Measured, not assumed.** A circular corner meets the straight wall at
  /// exactly `radius` from the end; a squircle's curvature is spread out, so it
  /// is still bending well past that point. Rendering a continuous layer at
  /// three radii and walking the first solid pixel along the top edge gives
  /// 54/40, 43/32 and 28/21 — 1.34 every time.
  ///
  /// This is the number the corner rule was missing, and the whole reason a
  /// card that satisfied "radius ≤ 0.4 × height" still came out looking bent:
  /// at 0.4 the two corners on an 80pt wall claim 2 × 1.34 × 32 = 86pt of it.
  /// They do not merely touch, they *overlap*, and where two squircle arcs are
  /// forced to meet past their tangent point the shape kinks — which is exactly
  /// "crooked and sharp".
  static let continuousCornerWallReach: CGFloat = 1.34

  /// Which curve a corner of `radius` can be drawn with on a shape whose
  /// shorter side is `shorterSide`.
  ///
  /// `CALayer.applyPaletteCorner(radius:)` is the way to reach this from a layer
  /// that sets its own corner.
  ///
  /// One rule, used by every rounded surface in the palette — the glass host
  /// applies it to itself, and the floating shadow asks for it so the silhouette
  /// behind a card matches the card.
  ///
  /// A squircle keeps bending past its radius, so two of them need
  /// `2 × reach × radius` of wall. Where that does not fit they are forced
  /// together past their tangent point and the outline kinks — flat, angular
  /// ends where round ones were wanted. A circular corner costs exactly its
  /// radius and `CALayer` caps the radius at half the shorter side, so the worst
  /// it can draw is an honest stadium.
  static func cornerCurve(radius: CGFloat, shorterSide: CGFloat) -> CALayerCornerCurve {
    guard shorterSide > 0 else { return .continuous }
    let capped = min(radius, shorterSide / 2)
    return 2 * continuousCornerWallReach * capped <= shorterSide ? .continuous : .circular
  }

  /// The face in a session row: its box exactly, with no overhang.
  ///
  /// Beside the prompt a face paints past its box, and should — there is nothing
  /// but flat capsule wall next to it. A row is the opposite: the face sits at
  /// the rounded end of the selection pill, and the pill's wall curves away
  /// precisely where the face is widest. At 1.15× the box the two met — the
  /// overhang put the face's corner 0.3pt from the arc, which is why it read as
  /// leaning on the wall.
  ///
  /// Measured against the mock the face was also simply too big for the pill:
  /// 0.61 of its height where the mock draws 0.48. Its box is 0.53, which is
  /// the nearer of the two and needs no new number to say it.
  static let resultsMascotSize: CGFloat = resultsIconFrameSize
  /// The box the glyph is centred in (mock 25 → 33.3).
  ///
  /// Wider than the glyph on purpose. Agent marks are not a consistent width —
  /// a fixed box is what keeps every row's title starting on the same vertical
  /// line. With the padding either side of it, text starts 59.3pt into the pill,
  /// which is where the mock starts it.
  static let resultsIconFrameSize: CGFloat = 32
  /// The empty card is a hero, not a row.
  ///
  /// A list with nothing in it is the one state where the card has no rows to
  /// line up against, so lining up against them anyway — a face in the row's
  /// icon box, a sentence on the row's title line — spent the whole card on one
  /// short phrase clinging to its top-left corner. Centred, at a size the card
  /// is actually built around, it reads as Boltty answering rather than as a
  /// list that failed to draw.
  ///
  /// Transcribed from the empty-state frame: a 48.4 face over its sentence,
  /// which is `fromMock` 64.5 here — nearly twice the 33.3 a row's face gets,
  /// and the whole point of the layout.
  static let resultsEmptyMascotSize: CGFloat = fromMock(48.4)
  /// Air between the face and the sentence under it.
  static let resultsEmptyMascotTextSpacing: CGFloat = fromMock(15)
  /// Padding above the face and below the sentence, as the card sees it.
  ///
  /// What the hero view lays out is `resultsEmptyOwnVerticalPadding` — this
  /// minus what the results stack already contributes — because the stack
  /// carries `resultsVerticalInset` on every side of whatever it holds. Stating
  /// the total here and the remainder there keeps the number that can be
  /// checked against the mock separate from the number that has to be typed
  /// into a constraint, which is where the two were quietly added together:
  /// the card came out ~200 tall against the mock's 173.
  static let resultsEmptyVerticalPadding: CGFloat = fromMock(24)
  static var resultsEmptyOwnVerticalPadding: CGFloat {
    max(0, resultsEmptyVerticalPadding - resultsVerticalInset)
  }

  /// Padding above the first row and below the last — the mock's 12, which is
  /// the same wall the prompt capsule wears (`promptLeadingInset`).
  static let resultsVerticalInset: CGFloat = fromMock(12)
  /// Selected-row pill: a capsule, stated as one.
  ///
  /// This was 50 — a number that never reached the screen. `CALayer` caps a
  /// corner at half the shorter side and silently did so on every frame, so the
  /// pill drew 30 while the constant claimed 50. A value that cannot be drawn
  /// looks like a setting and is not one; worse, it hid *why* the ends were
  /// wrong, because the radius always appeared to be someone else's problem.
  ///
  /// Half the pill's own height draws the same pixels and says the true thing:
  /// this shape is a capsule.
  /// The selected row is a capsule, and it fits: the card's corner is 58.67 and
  /// its walls are `resultsRowHorizontalInset` away, leaving 42.67 — more than
  /// the 30 a 60pt row's stadium asks for, so the pill stays inside the card's
  /// curve instead of crossing it.
  static var resultsRowCornerRadius: CGFloat {
    (resultsRowHeight - resultsRowInset * 2) / 2
  }

  /// A row's title and the line of reply under it: Primary over Secondary.
  ///
  /// 15 medium over 13 regular (`typeMeta`), in primary over secondary ink,
  /// as Mail and Messages set a row — at one size and weight the reply
  /// competes with the name it belongs to.
  static let resultsTitleFontSize: CGFloat = typeSecondary
  static let resultsSubtitleFontSize: CGFloat = typeMeta
  /// Rows stack flush; the 7.5 inner padding is the air between faces.
  static let resultsRowInset: CGFloat = 0
  /// The mock's selected row is a flat 8% fill, no edge.
  static let resultsRowSelectedBorderWidth: CGFloat = 0
  /// A working chat's row: the hairline round its pill, one lap of the lit
  /// window round the outline, the window's share of it, how far each row's
  /// pace may drift from the lap, the brief hurry a fresh reply brings and
  /// how long it lasts — and the subtitle's breath, down to `BreathFloor`
  /// and back over twice `BreathDuration`.
  static let resultsWorkingEdgeWidth: CGFloat = 1
  static let resultsWorkingOrbitDuration: CFTimeInterval = 3.2
  static let resultsWorkingOrbitShare: CGFloat = 0.32
  static let resultsWorkingOrbitVariance: Double = 0.15
  static let resultsWorkingBoostSpeed: Float = 3
  static let resultsWorkingBoostDuration: TimeInterval = 1
  static let resultsWorkingStillOpacity: CGFloat = 0.5
  static let resultsWorkingBreathFloor: Float = 0.35
  static let resultsWorkingBreathDuration: CFTimeInterval = 1.1

  /// Inset of the highlight pill from the card's side walls.
  ///
  /// The mock's 12, i.e. the card's padding is square: 12 on all four sides,
  /// which is why this and `resultsVerticalInset` are one number written
  /// twice.
  static let resultsRowHorizontalInset: CGFloat = fromMock(12)
  /// Icon → text gap inside a row. A row's face does not paint past its box
  /// — see `resultsMascotSize` — so the gap is the mock's number and only
  /// that.
  static let resultsRowIconTextSpacing: CGFloat = 10.5
  /// Where a row's title starts, measured from the pill's own leading edge.
  ///
  /// **A row has no face** — a title and a line of the reply and nothing
  /// else, so the text starts at the pill's own padding: the history frame's
  /// `pl-5`.
  static let resultsRowTextLeading: CGFloat = fromHistoryMock(20)
  /// The frame's `pr-3`: a truncated line stops nearer the pill's end than it
  /// starts from the other.
  static let resultsRowTextTrailing: CGFloat = fromHistoryMock(12)
  /// An unread chat's dot: 8 across, in Mail's blue, standing on the row's
  /// trailing edge with the pill's own trailing padding past it. Trailing so
  /// it reads on every tab alike — Latest's face owns the leading edge —
  /// the way iOS carries its unread counts.
  static let resultsUnreadDotDiameter: CGFloat = 8
  /// Between the truncated text and the dot.
  static let resultsUnreadDotGap: CGFloat = 8
  static let resultsUnreadDotFill = HexColor.nsColor("#0A84FF")
  /// **Except in Latest**: that tab mixes every agent,
  /// so there a row leads with its agent's face — a still picture of it, in the
  /// row's own box — and the title moves over by the face and the gap.
  static var resultsRowFacedTextLeading: CGFloat {
    resultsRowTextLeading + resultsMascotSize + resultsRowIconTextSpacing
  }

  // MARK: - History

  /// The history design frame: the card is `582.67` units wide there — the
  /// 388.45-unit WORK PAGE card at 1.5×. Every number of the history card
  /// goes through this one: the tab track, the date headings, the rows. Do
  /// not put them through `fromMock`. Type sizes are the exception: they
  /// are the ramp's.
  static let historyMockCardWidth: CGFloat = 582.67
  /// The card's width the frame is read against. The prompt is wider now;
  /// the list's rows and tabs keep this scale.
  static let historyMockScaleWidth: CGFloat = 520
  static func fromHistoryMock(_ value: CGFloat) -> CGFloat {
    onPixelGrid(value * historyMockScaleWidth / historyMockCardWidth)
  }

  /// The date heading over a day's rows.
  ///
  /// **A section heading, not a row**: 13 semibold in secondary ink, on the
  /// rows' leading edge, standing at the foot of its box — more air above it
  /// than under it, because it belongs to the day below. Set like a title,
  /// it reads as one more chat. A heading is never a step in the ↑↓ walk.
  static let historyHeaderHeight: CGFloat = fromHistoryMock(50)
  static let historyHeaderFontSize: CGFloat = typeMeta
  static let historyHeaderTextColor = PaletteInk.secondary
  /// The heading's baseline to the foot of its box. Rows stand flush, and a
  /// lit row's pill fills its whole height, so this is also the heading's
  /// distance from that pill: 10 keeps a descender ("Yesterday") clear of
  /// a hovered row.
  static let historyHeaderBottomInset: CGFloat = 10
  /// More air over a heading that follows a day's rows. With the box alone
  /// the heading stands about as far from its first title as the rows stand
  /// apart, so it belongs to neither day; with this the air above it is
  /// about twice the air below. The first heading, under the tabs, has
  /// nothing above it to stand apart from.
  static let historyHeaderSeparation: CGFloat = 8
  /// A heading's box: the separation over every day but the first.
  static func historyHeaderHeight(followsRows: Bool) -> CGFloat {
    historyHeaderHeight + (followsRows ? historyHeaderSeparation : 0)
  }
  /// The wall a heading keeps from either side of the card before it would
  /// truncate — the row pill's own inset plus its text padding.
  static var historyHeaderLeading: CGFloat {
    resultsRowHorizontalInset + resultsRowTextLeading
  }

  /// The agent tabs above the list: segments, each a face over a name.
  /// Latest wears the faces of every agent that is on; each agent's tab its
  /// own.
  ///
  /// The card's padding: the chosen tab stands this far off the card's top
  /// and sides — the open chat's inset (`shellContentInset`).
  static let historyTabTopInset: CGFloat = shellContentInset
  /// The track's wall to the segments inside it. Nothing draws a track.
  static let historyTabTrackPadding: CGFloat = 0
  /// A segment's own padding, so the face and the name stand with air round
  /// them.
  static let historyTabPadding: CGFloat = 10
  /// An agent's face in its tab, and the gap to the name under it. 40 is as
  /// far as one grows inside the height Latest's group already sets — past
  /// that the strip grows and the list pays for it.
  static let historyTabMascotSize: CGFloat = fromHistoryMock(40)
  static let historyTabMascotTextSpacing: CGFloat = fromHistoryMock(4)
  /// One face of Latest's group, and the gap under the group, which is
  /// wider than an agent's (`gap-1.5`).
  static let historyTabLatestMascotSize: CGFloat = fromHistoryMock(20)
  static let historyTabLatestTextSpacing: CGFloat = fromHistoryMock(6)
  /// The square Latest's faces stand on, two faces tall: every agent that
  /// can take a prompt, from one to five,
  /// packed on it like the pips of a die (`AgentHistoryTabView.faceFrames`).
  static var historyTabClusterSide: CGFloat { 2 * historyTabLatestMascotSize }
  /// What a segment keeps clear of its name on either side. The segments are
  /// equal while every name fits in its share; a name that does not takes
  /// what it needs and the rest give it up (`segmentWidths`).
  static let historyTabSegmentInset: CGFloat = 6
  static let historyTabFontSize: CGFloat = typeSecondary
  /// A line of the tab's type, measured rather than assumed.
  static var historyTabLabelHeight: CGFloat {
    let font = roundedAppFont(size: historyTabFontSize)
    return ceil(font.ascender - font.descender + font.leading)
  }
  /// Every segment is as tall as the tallest, which is Latest's: the faces of
  /// the agents' tabs centre in the same height (`self-stretch`,
  /// `justify-center`), which is why their names stand higher than Latest's.
  static var historyTabHeight: CGFloat {
    let latest = 2 * historyTabLatestMascotSize + historyTabLatestTextSpacing
    let agent = historyTabMascotSize + historyTabMascotTextSpacing
    return onPixelGrid(2 * historyTabPadding + max(latest, agent) + historyTabLabelHeight)
  }
  /// Fixed height, because the strip is always there and a card that changed
  /// height when a tab's label wrapped would resize the panel for nothing.
  static var historyTabTrackHeight: CGFloat { historyTabHeight + 2 * historyTabTrackPadding }
  /// The chosen segment and the hover: a rounded rectangle **concentric
  /// with the card** — the card's corner less the inset the tab stands in
  /// from it, as the open chat's composer is.
  static var historyTabCornerRadius: CGFloat { listCardCornerRadius - historyTabTopInset }
  /// Between the track and the first heading (`gap-3.5`).
  static let historyTabListSpacing: CGFloat = fromHistoryMock(14)
  /// What the strip occupies above the list. The list carries
  /// `resultsVerticalInset` over its first heading already, so the strip
  /// takes only what the frame's gap asks for beyond it.
  static var historyTabStripHeight: CGFloat {
    historyTabTopInset + historyTabTrackHeight + historyTabListSpacing - resultsVerticalInset
  }
  /// The spring the tab glass travels on — critically damped, so it covers
  /// 95% of the way in ~0.15s. Quicker than the shell's (`surfaceResponse`):
  /// ←/→ held down has to read as steps.
  static let historyTabSlideResponse = CGFloat(Motion.standard)
  static let historyTabHoverFill = PaletteInk.tertiaryFill
  /// The chosen tab's name, and any tab's under the pointer.
  static let historyTabActiveTextColor = PaletteInk.primary
  /// Every other tab's name, empty or not: grey at rest, bright under the
  /// pointer. Dimming empty tabs further makes them read as switched off.
  static let historyTabTextColor = PaletteInk.secondary

  /// Gap between the title and the directory line under it. The mock stacks the
  /// two with none at all and lets their natural leading carry the separation —
  /// which is also what makes 40pt of type fit the pill exactly. Two points,
  /// because the reply's smaller line carries less leading of its own.
  static let resultsTitleSubtitleSpacing: CGFloat = 2

  /// Tab, cycling the agent Enter would launch: the mark resolves out of a
  /// blur as it swaps. The placeholder beside it does not change, and holds
  /// still.
  ///
  /// A blur rather than a bare crossfade: a plain fade at this speed reads
  /// as a flicker rather than as a change.
  ///
  /// Short, because Tab is a keystroke that gets pressed several times in a
  /// row to walk the list, so the swap has to be finished before the next
  /// press rather than merely underway.
  ///
  /// The radius is kept small because a Gaussian blur's cost grows with it and
  /// it runs as a Core Image pass on every frame of the swap.
  static let targetSwapBlurRadius: CGFloat = 8
  static let targetSwapBlurDuration: TimeInterval = 0.18
  /// The content crossfade under the blur. Kept a touch shorter so the new mark
  /// is fully opaque while it is still sharpening, not fading and sharpening at
  /// once — two ramps on the same pixels read as sluggishness.
  static let targetSwapFadeDuration: TimeInterval = Motion.quick

  /// The transcript's reading size (`typeChat`). Several turns are on
  /// screen at once and the longest runs to paragraphs, so this is a size a
  /// person reads rather than one that announces a single sentence. The
  /// composer and the transcript share a surface, so they share a size —
  /// `PromptTextView.chatComposerFont` is this number. The initial prompt
  /// stays at `promptFontSize`: a single line announcing a task is a
  /// different job from a transcript.
  static let previewBodyFontSize: CGFloat = typeChat
  /// 18pt on 15: 1.2.
  ///
  /// **A reading decision, not a transcription.** The reply mock sets its
  /// lines at 1.19, right for the four lines it draws and tight for a
  /// transcript that runs to paragraphs: the ascenders of one line nearly
  /// reach the descenders of the line above, and a long answer reads as a
  /// block rather than as lines.
  ///
  /// On the whole-point grid for the reason `promptSize.height` is on the
  /// half-point one. Whatever the body is set at, this has to move with it.
  static let previewBodyLineHeight: CGFloat = 18
  /// **An answer's line is 24 on the 15** (1.6, close to Codex's 1.625).
  /// The rest of the card keeps `previewBodyLineHeight`: a question's
  /// prompt, a status line and the person's own bubble are a line or two,
  /// and an answer runs to paragraphs. The answer's other numbers below were
  /// measured off a screenshot of Codex at 2.88 pixels to the point.
  static let previewAnswerLineHeight: CGFloat = 24

  /// **Typography inside an answer.**
  ///
  /// The palette's chrome is one size and one weight on purpose — see
  /// `BolttyAIPreviewCard.bodyText`. An answer is not chrome. It is the
  /// document the whole surface exists to deliver, it arrives with headings and
  /// lists already in it, and a document set in a single style is a document
  /// nobody can skim. So the one-weight rule stops at the edge of the answer,
  /// and these are the steps it is allowed inside it.
  ///
  /// **Codex's proportions on the Mac**, taken as numbers, never as code —
  /// its markdown is set in units of a quarter of the text's size:
  /// headings 1.5×, 1.25× and 1.125× the text,
  /// semibold, on lines of eight, seven and seven quarters; inline code in
  /// a rounded well; a fenced block in a bordered box with its copy button;
  /// a table ruled across, never down. Sizes are whole points, so 17.5 and
  /// 15.75 land on 18 and 16.
  static let answerHeading1FontSize: CGFloat = 21
  static let answerHeading1LineHeight: CGFloat = 28
  static let answerHeading2FontSize: CGFloat = typePrimary
  static let answerHeading2LineHeight: CGFloat = 24.5
  static let answerHeading3FontSize: CGFloat = 16
  static let answerHeading3LineHeight: CGFloat = 24.5
  /// Under a heading: a quarter of the text under `#`, an eighth under `##`
  /// and `###`, none under the rest — a heading belongs to what it heads. Over
  /// it, the paragraph's own air, as Codex's margins collapse to.
  static let answerHeading1SpacingAfter: CGFloat = 7
  static let answerHeading2SpacingAfter: CGFloat = 3.5

  /// A table: a step under the text, its header semibold, ruled between rows
  /// only, its first column flush with the words around it.
  static let answerTableFontSize: CGFloat = typeMeta
  static let answerTableCellVerticalPadding: CGFloat = 8.5
  static let answerTableCellTrailingPadding: CGFloat = 21
  static let answerTableRuleWidth: CGFloat = 1
  static let answerTableRule = PaletteInk.secondaryFill
  /// Between paragraphs: a little under a line, which is what tells a
  /// paragraph from a wrapped line once there is no bubble to say it.
  static let answerParagraphSpacing: CGFloat = 16
  /// Where a bullet sits, and where its text hangs from. The marker is indented
  /// rather than flush so a list reads as inset from the prose around it.
  static let answerListMarkerIndent: CGFloat = 8
  static let answerListHeadIndent: CGFloat = 21
  /// A number ends this far short of its item's words.
  static let answerListNumberGap: CGFloat = 5
  /// A nested list steps by the same amount it is already indented by.
  static let answerListNestIndent: CGFloat = 22
  /// None: items stand a line apart, as the
  /// lines of one paragraph do, and so does a list from the sentence that
  /// introduces it — `PaletteAnswerText` closes that gap too. After the
  /// list a paragraph's air comes back.
  static let answerListItemSpacing: CGFloat = 0
  /// One point under the body. Mono at the body's own size reads *larger*
  /// than the prose beside it, because it carries more ink per character.
  /// It keeps the body's line height, so inline code does not open a gap in
  /// the line it sits in. 13 under the body's 14, i.e. `typeMeta` — Codex's
  /// 0.92 of the text, in whole points.
  static let answerCodeFontSize: CGFloat = typeMeta
  /// Inline code stands in a rounded well (`PaletteAnswerLayoutManager`):
  /// white at 10%, a corner of 6, the well reaching this far past the glyphs
  /// and as far again kept clear of the words beside it.
  static let answerInlineCodeFill = PaletteInk.fill
  static let answerInlineCodeCornerRadius: CGFloat = 6
  static let answerInlineCodeInset: CGFloat = 4
  /// A fenced block (`PaletteCodeBlockView`): a box with a hairline at white
  /// 8% on white 5%, a corner of 10, the code 14 under its top and 16 in,
  /// with room at the trailing edge for the copy button, on a line of 1.5.
  static let answerCodeBlockCornerRadius: CGFloat = 10
  static let answerCodeBlockFill = PaletteInk.tertiaryFill
  static let answerCodeBlockBorder = PaletteInk.secondaryFill
  static let answerCodeBlockVerticalPadding: CGFloat = 14
  static let answerCodeBlockLeadingPadding: CGFloat = 16
  static let answerCodeBlockTrailingPadding: CGFloat = 40
  static let answerCodeBlockLineHeight: CGFloat = 19.5
  /// The copy button's inset from the box's top and trailing edges.
  static let answerCodeBlockCopyInset: CGFloat = 8
  /// A quotation: a bar a quarter of the text wide at white 20%, the words
  /// six quarters in from it, in the answer's own ink.
  static let answerQuoteBarWidth: CGFloat = 3.5
  static let answerQuoteBar = PaletteInk.selectedFill
  static let answerQuoteIndent: CGFloat = 21
  static let answerQuoteVerticalPadding: CGFloat = 7
  /// `---`: a hairline at white 20%, with seven quarters of air either side.
  static let answerRuleSpacing: CGFloat = 24.5
  /// Under the hairline, less the leading the next line keeps over its
  /// capitals, so the words below stand as far off as the words above.
  static let answerRuleSpacingAfter: CGFloat = 14
  /// Mock 21 → 28, the same number on all four sides.
  ///
  /// Re-measured against the reply mock rather than re-read: the card there is
  /// exactly `promptSize.width`, which fixes the export's scale, and against
  /// that scale its text sits 28pt in from the left rim and its last line ends
  /// 28pt above the bottom one. The 40 this used to be (and the 39 beside it)
  /// came from a different frame; on screen it cost the answer about a word
  /// per line and a line and a half of height.
  ///
  /// **The top is the exception — there the mock's padding is 0**, and that is
  /// a behaviour rather than a number. Its text block starts at the card's top
  /// rim and the answer scrolls up under it, which is what the fade over the
  /// mock's first line is drawing. Applying 28 to the top as well is what this
  /// file used to do, and it is why a scrolled answer stopped a clear band
  /// short of the rim instead of dissolving into it. The card now spends this
  /// as a *scroll content inset* (`BolttyAIPreviewCard`): at rest the first
  /// line still sits 28pt down, so a short answer is not welded to the rim,
  /// and the inset scrolls away like any other content so a read answer
  /// reaches the rim exactly as the design shows.
  static let previewContentVerticalPadding: CGFloat = fromMock(21)
  /// **The shell's own padding, not a second number.** In the mock the
  /// transcript stack and the composer are both `self-stretch` children of one
  /// `p-5` frame, so they are inset by the same 20 and their side walls are
  /// flush. This carried `fromMock(21)` against the composer's `fromMock(20)`,
  /// which put the right edge of every user bubble 1.33pt inside the right edge
  /// of the composer under it — small enough to read as a wobble rather than a
  /// number, and visible precisely because the two are stacked.
  static let previewContentHorizontalPadding: CGFloat = shellContentInset
  /// The mock's `VStack(spacing: 6)`: prompt to card.
  static let previewTopSpacing: CGFloat = 8

  /// The options an agent offers, drawn as rows under its answer.
  ///
  /// The paddings, mark and spacing are off frame `616:968` of the reply mock,
  /// at the same 0.75 the rest of this block is transcribed at. The fills are
  /// the session row's — see `BolttyAIOptionRow`.
  static let previewOptionCornerRadius: CGFloat = fromMock(16)
  static let previewOptionHorizontalPadding: CGFloat = fromMock(9)
  static let previewOptionVerticalPadding: CGFloat = fromMock(7.5)
  static let previewOptionMarkSize: CGFloat = fromMock(14)
  static let previewOptionMarkSpacing: CGFloat = fromMock(8)
  static let previewOptionSpacing: CGFloat = fromMock(4)
  /// Between an option's label and the agent's sentence under it — a history
  /// row's title over its reply.
  static let previewOptionDetailSpacing: CGFloat = 2
  /// The gap between the answer and the choices under it.
  static let previewOptionsTopSpacing: CGFloat = fromMock(20)

  /// How tall the rows will be, measured before they exist.
  ///
  /// The card's height is set from a constraint computed ahead of layout, so
  /// the options have to be measured the same way the body is — a row wraps,
  /// and a two-line row that was budgeted one line clips.
  @MainActor
  static func previewOptionsHeight(
    options: [AgentQuestion.Option],
    width: CGFloat
  ) -> CGFloat {
    guard !options.isEmpty else { return 0 }
    let rows = options.reduce(into: CGFloat(0)) { total, option in
      total += BolttyAIOptionRow.height(for: option, width: width)
    }
    return rows + previewOptionSpacing * CGFloat(options.count - 1) + previewOptionsTopSpacing
  }

  /// How far the answer dissolves at the card's scrolling edges.
  ///
  /// One line, exactly: a line that is leaving disappears over its own height,
  /// so nothing is ever shown cut through the middle of its glyphs. The card
  /// used to hard-clip, which read as a rendering fault rather than as more
  /// text — a sliced letterform is not a thing paper or any other scrolling
  /// surface does.
  ///
  /// This is a *maximum*. The live fade is `min(this, distance scrolled)` at
  /// the top and `min(this, distance remaining)` at the bottom, so the first
  /// and last lines of an answer are never dimmed for no reason — see
  /// `BolttyAIPreviewCard.refreshEdgeFades`.
  /// The widest the question's bubble gets, as a share of the column, so it
  /// always leaves the other side some air and reads as the other speaker.
  static let previewBubbleMaxWidthFraction: CGFloat = 0.78
  static func previewBubbleMaxWidth(in column: CGFloat) -> CGFloat {
    onPixelGrid(column * previewBubbleMaxWidthFraction)
  }
  /// The question's bubble: the furthest thing from the ground, which on a
  /// dark card is white. A grey a step off the answer's makes it hard to
  /// tell whose message is whose, which is the one thing a bubble is for.
  static let previewUserBubbleFill = NSColor.white.withAlphaComponent(0.94)
  /// Black on the white bubble. Fixed rather than dynamic: the panel is
  /// `.darkAqua`, where every `labelColor` resolves to white.
  static let previewUserBubbleInk = NSColor.black
  /// A capsule 28.5 tall round one line, its words 13 in from either end. A
  /// line of 17 leaves 5.5 above and below.
  static let previewUserBubbleHorizontalPadding: CGFloat = 13
  static let previewUserBubbleVerticalPadding: CGFloat = 5.5
  /// Half the one-line bubble: a capsule, and the same corner once it grows.
  static let previewUserBubbleCornerRadius: CGFloat = 14
  /// Between a question and its answer, and between an answer and the next
  /// question — the same both ways. The answer's first capitals stand 34.5
  /// under the question's bubble: this, and the room the first line's
  /// leading leaves over them.
  static let previewMessageSpacing: CGFloat = 25.5
  /// Between two of the agent's messages in one turn: the paragraphs of one
  /// answer, as far as a reader can tell.
  static let previewAgentMessageSpacing: CGFloat = answerParagraphSpacing

  /// The work between an answer's words, as one pill (`PaletteActivityGroupView`),
  /// as Claude's app draws it: the column's width, white at 5% over the
  /// ground, a chevron at its leading end and the words after it at the
  /// answer's size in a grey of their own.
  static let previewWorkPillHeight: CGFloat = 44.5
  static let previewWorkPillCornerRadius: CGFloat = 9
  static let previewWorkPillFill = PaletteInk.tertiaryFill
  /// The chevron's middle. The point size is the largest at which
  /// `chevron.down` (14 wide at 12.5) still fits the box: any larger and it
  /// is scaled down to fit while `chevron.right` is not, so the open group's
  /// chevron draws smaller than the shut one's.
  static let previewWorkPillChevronCenter: CGFloat = 21
  static let previewWorkPillChevronWidth: CGFloat = 14
  static let previewWorkPillChevronPointSize: CGFloat = 12.5
  static let previewWorkPillTextInset: CGFloat = 40
  static let previewWorkPillTrailingInset: CGFloat = 17
  /// Opened, the calls stand under the words, from where the words' line
  /// ends, with a little air at the foot.
  static let previewWorkPillListTop: CGFloat = 35.5
  static let previewWorkPillListBottomInset: CGFloat = 10
  /// From the line above to the pill, and from the pill to the line under
  /// it: the reference stands the pill 32 under the last line's baseline and
  /// 31 over the next line's capitals, the same air either side of the
  /// glyphs. The two numbers differ because a line's leading stands over
  /// its glyphs, not around them.
  static let previewWorkPillSpacingAbove: CGFloat = 26.5
  static let previewWorkPillSpacingBelow: CGFloat = 20

  /// File result cards under a message: a picture, the name over its kind
  /// and size, and the actions only while the pointer is on the card.
  ///
  /// A filled slab like the work pill — no hairline, which read as a form
  /// field on the glass — with the picture large enough to recognise a film
  /// or a photo by. The card itself is the preview button; the eye, folder
  /// and plus come in on hover so the name has the width at rest. The tile is
  /// concentric with the card (`card = tile + inset`).
  static let previewFileRowHeight: CGFloat = 56
  static let previewFileRowSpacing: CGFloat = 6
  static let previewFileRowsTopMargin: CGFloat = 8
  /// Between the cards of what a person sent and the bubble of what they
  /// typed under them — one message, so the paragraphs' gap.
  static let previewSentFilesGap: CGFloat = 6
  static let previewFileCardWidth: CGFloat = 300
  static let previewFileCardInset: CGFloat = 8
  static let previewFileIconTileCornerRadius: CGFloat = 8
  static let previewFileCardCornerRadius: CGFloat =
    previewFileIconTileCornerRadius + previewFileCardInset
  static let previewFileCardFill = PaletteInk.secondaryFill
  static let previewFileCardHoverFill = PaletteInk.fill
  static let previewFileIconTileSize: CGFloat = previewFileRowHeight - previewFileCardInset * 2
  static let previewFileIconTileFill = PaletteInk.tertiaryFill
  static let previewFileIconSize: CGFloat = 28
  static let previewFileButtonSize: CGFloat = 24
  static let previewFileGlyphPointSize: CGFloat = 13
  static let previewFileNameFontSize: CGFloat = typeMeta
  static let previewFileSizeFontSize: CGFloat = typeFootnote

  /// Tool-call rows: what the agent *did*, as rows rather than as prose.
  ///
  /// Shorter and quieter than a file row on purpose. A turn carries one or two
  /// files and a handful of tool calls — most agent messages hold at least
  /// one, and a long one fourteen — so the column has to stay readable at
  /// length. It is
  /// set below body size, at reduced opacity, with the state in a glyph
  /// instead of a word.
  static let previewActivityRowHeight: CGFloat = 22
  static let previewActivityRowSpacing: CGFloat = 2
  static let previewActivityRowsTopMargin: CGFloat = 6
  static let previewActivityGlyphSize: CGFloat = 14
  static let previewActivityGlyphPointSize: CGFloat = 11
  static let previewActivityChevronPointSize: CGFloat = 9
  static let previewActivityNameFontSize: CGFloat = typeMeta
  /// Monospaced tool output, and every other raw text the card shows —
  /// a permission's command, a failure's details. One size for all of it.
  static let previewActivityDetailFontSize: CGFloat = typeFootnote
  /// **Pinned, not left to the typeface.** The measure ceils a bounding box
  /// while the label lays out at the font's own leading, and for monospaced 11
  /// those differ by a third of a point per line — enough that three lines of
  /// output measured 39 and needed 39.3, so the last line was clipped by the
  /// row it was measured into. Fixing the line height makes the two arithmetic.
  static let previewActivityDetailLineHeight: CGFloat = 14
  static let previewActivityDetailTopMargin: CGFloat = 4
  /// The output lines up under the name, not under the glyph.
  static let previewActivityDetailIndent: CGFloat = previewActivityGlyphSize + previewActivityRowSpacing * 2
  /// A tool's output runs to megabytes; the transcript is not a log viewer.
  /// Cut in lines rather than characters — see `PaletteActivityRowView.shown`.
  static let previewActivityDetailLineCap = 40

  /// The line over a turn's work — "Working for 8m 3s", then "Worked for …".
  /// A row of the work's own height, so the header reads as the first line of
  /// the column it heads rather than as a title. No rule under it: a line
  /// across the column reads as a table.
  static let previewTurnHeaderLabelHeight: CGFloat = previewActivityRowHeight
  static let previewTurnHeaderHeight: CGFloat = previewTurnHeaderLabelHeight
  /// From the header to the first bubble or row under it.
  static let previewTurnHeaderSpacing: CGFloat = 6

  /// The line under a running turn (`PaletteWorkingLineView`): as tall as
  /// the face-and-word row it replaced, so the card's measure did not move.
  static let workingLineHeight: CGFloat = workingFaceDiameter
  /// The face stands a hair in from the column's edge.
  static let workingLineLeadingInset: CGFloat = 2
  /// The agent's face in the line — a little over the type's height.
  static let workingLineFaceSize: CGFloat = 24
  /// The reference's gap, half the face's width from its ink to the word.
  static let workingLineFaceGap: CGFloat = 10
  /// Half a breath of the word in the agent's light — in, or out.
  static let workingLineBreathDuration: CFTimeInterval = 1.3
  /// How lit the letters stay at the bottom of the out-breath.
  static let workingLineBreathLitLow: CGFloat = 0.15
  /// The halo behind the word: its blur, and how strong it is at the top of
  /// the in-breath.
  static let workingLineHaloBlur: CGFloat = 6
  static let workingLineHaloOpacity: CGFloat = 0.55

  /// The copy control under an agent's finished answer, revealed under the
  /// pointer, on a row of its own at the answer's foot.
  ///
  /// A line of prose can run to the column's edge, so the copy control
  /// takes a row of its own, as Claude's app keeps it — and the row is the
  /// gap to the next question rather than added to it
  /// (`PaletteChatMessageView.spacing(after:)`). Only the turn's last answer
  /// carries one: between two messages of one turn it would be a hole in the
  /// middle of a reply.
  static let previewCopyButtonSize: CGFloat = previewFileButtonSize
  /// The row: the button and the air over it.
  static let previewCopyRowHeight: CGFloat = previewCopyButtonSize + 6

  /// How far past a floating control's edge the transcript keeps dissolving
  /// (`BolttyAIPreviewCard.scrollEdge`). Half the card's vertical padding,
  /// so the first and last lines *at rest* — a padding clear of the disc and
  /// of the composer — never reach it: only text travelling under a control
  /// is touched, as macOS 26's soft edge touches only what scrolls under a bar.
  static let previewScrollEdgeSoftness: CGFloat = previewContentVerticalPadding / 2
  /// The blur at its strongest where text travels under a control
  /// (`ScrollEdgeBlur`), in the chat and under the history's tabs alike.
  static let scrollEdgeBlurRadius: CGFloat = 8
  /// How far the history's rows travel up under the tab strip before they
  /// are gone — the names' band and a little over the faces. At rest the
  /// first row stands
  /// where it did: the list's top inset grows by the same amount.
  static var historyTabOverlap: CGFloat { onPixelGrid(historyTabHeight * 0.45) }

  /// A streamed word's arrival (`PaletteStreamingTailView`): it fades in over
  /// `Motion.standard` in the agent's colours, and settles into the answer's
  /// ink over three of those — Siri's spectral word, in Boltty's palette. The
  /// settle is the one number here that is not the vocabulary's own: a colour
  /// that leaves as fast as it came reads as a flicker, not as light passing.
  static let previewStreamingWordFade: TimeInterval = Motion.standard
  /// Six beats, so the last line or two of a streaming answer are still lit,
  /// the light running back into the words' ink; at three a word has settled
  /// before the next line begins.
  static let previewStreamingWordSettle: TimeInterval = Motion.standard * 6

  /// An answer reads itself onto the card: each new bubble or row fades in a
  /// beat after the one above it, so a reply resolves top to bottom. The
  /// fade is `Motion.standard`; only the
  /// beat between pieces is this file's.
  static let previewRevealDuration: TimeInterval = Motion.standard
  static let previewRevealStagger: TimeInterval = 0.06
  /// How many beats the cascade takes before the rest arrive together. An
  /// answer that lands whole — the prose a turn withholds until it ends —
  /// would otherwise take a beat per piece, the last ones below the fold
  /// waiting their turn for nobody. Four beats keep the top-to-bottom read
  /// and stop there.
  static let previewRevealStaggerSteps = 4

  /// A sent message's flight from the composer to the top of the transcript
  /// (the same recording: the words lift out of the field as a bubble and the
  /// previous turn leaves upward under them). Measured off the 240 fps
  /// capture: lift-off to landing in about 0.45 s, on a soft landing — the
  /// shell's own `emphasizedCurve`.
  static let previewSendFlightDuration: TimeInterval = 0.45

  // MARK: Shader effects (`PaletteEffects`)

  /// A thumbnail's arrival: out of a blur, colours a hair apart, a little
  /// large, settling sharp — Siri's `imageReveal`, done our way. Twice an
  /// arrival's beat: a picture has more to resolve than a word.
  static let revealDuration: TimeInterval = Motion.standard * 2
  /// The blur's radius at the start, as a share of the tile's shorter side.
  static let revealBlurFraction: CGFloat = 0.18
  /// How far red and blue part at the start, as a share of the shorter side.
  static let revealAberrationFraction: CGFloat = 0.05
  /// How much larger the picture starts than it lands.
  static let revealZoom: CGFloat = 0.08
  /// Where in the reveal the picture is whole: early, so the blur resolves on
  /// something already there rather than out of nothing.
  static let revealOpaqueAt: CGFloat = 0.35

  /// The flying chip's tail: at most this many of its own heights behind it.
  static let whipMaxLagHeights: CGFloat = 1.2
  /// Points of lag per point-per-second of speed, before the reach eases it.
  static let whipLagPerSpeed: CGFloat = 0.03
  /// The chip's picture is gone by this share of the flight; the card has
  /// arrived by half way (`BolttyAIPreviewCard.launch`).
  static let whipFadeOutAt: CGFloat = 0.4

  /// How close to the floor still counts as "reading the latest", so new
  /// output keeps scrolling into view.
  ///
  /// Small on purpose. This is the question "did they mean to leave the
  /// bottom", and one nudge of a trackpad is an answer: once someone has
  /// scrolled up at all, a streaming reply must not drag them back down.
  static let transcriptFollowSlack: CGFloat = 40

  /// How far from the floor the "↓ Latest" pill appears.
  ///
  /// **Deliberately not the same number.** For two years one 28 did both
  /// jobs, which made them one decision when they are opposites: following
  /// should stop at the first sign of intent, and a pill that covers the
  /// transcript should appear only once there is something to go back *to*.
  /// Between the two — scrolled up, but less than a screenful — the card
  /// quietly stops chasing and says nothing.
  static let transcriptLatestPillSlack: CGFloat = 120

  /// One line of reply, plus the padding it sits in.
  ///
  /// WORK PAGE (3) draws that as a capsule — the same stadium the prompt is.
  /// A previous floor of twice the card's corner (122) forced every short
  /// answer into a 122pt card so `CALayer` would not clamp the corner it was
  /// given. That "fix" is what the screenshots were rejecting: one line of reply
  /// lost in a pill the size of the prompt. The design wants the clamp, and at
  /// `cardCornerRadius` there is nothing left to protect: 24 fits any card this
  /// can produce.
  ///
  /// The top term is the close disc's band rather than the plain padding —
  /// see `previewHeaderHeight`, which already carries the card's top padding,
  /// so the second `previewContentVerticalPadding` here is the bottom one.
  ///
  /// **A one-line reply is no longer a capsule**, and that is what the
  /// corrected disc costs. It was one only while the disc was 36pt at the
  /// mock's 12: at the mock's own 48 and 22 the floor clears
  /// `cardCornerRadius * 2`, and it does so in the reference's units too.
  static let previewMinHeight: CGFloat =
    previewHeaderHeight + previewContentVerticalPadding + previewBodyLineHeight

  static func previewBodyLineCount(_ body: String, font: NSFont) -> Int {
    guard !body.isEmpty else { return 1 }
    let width = promptSize.width - previewContentHorizontalPadding * 2
    let bounds = (body as NSString).boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: font]
    )
    let naturalLineHeight = max(ceil(font.ascender - font.descender + font.leading), 1)
    return max(1, Int(ceil(bounds.height / naturalLineHeight)))
  }

  static func previewCardHeight(bodyLineCount: Int) -> CGFloat {
    previewHeaderHeight + previewContentVerticalPadding
      + previewBodyLineHeight * CGFloat(max(bodyLineCount, 1))
  }

  /// Extra transparent height below the card while the switcher is open.
  ///
  /// The borderless panel clips anything outside its frame, and the card casts
  /// a floating drop shadow (`PaletteGlassHost.floatingShadowRadius`, 13.4, cast
  /// slightly downward) — without room to fall off, the shadow ends at a hard
  /// horizontal line. The panel grows *downwards*, so this costs nothing
  /// visually.
  ///
  /// Previously 90pt, sized for the entrance blur's spread rather than the
  /// shadow's; the blur is gone, so this is now just the shadow's reach.
  static let resultsShadowBleed: CGFloat = 32

  /// The line under the prompt: an error, or where a send was routed.
  static let promptNoteFontSize: CGFloat = typeMeta

  /// The rules line under a question's rows.
  ///
  /// A step under the options it describes, and in the dimmest ink the card
  /// uses: it is a legend, and a legend that competes with the choices is a
  /// fourth thing to read before answering three.
  static let previewFooterFontSize: CGFloat = typeFootnote
  static let previewFooterTextColor = PaletteInk.secondary
  /// The room the footer takes, gap included, when it is drawn.
  static let previewFooterHeight: CGFloat = 26

  /// The failure card inside the transcript.
  ///
  /// A block, not a pill: it holds a sentence that wraps, two controls and a
  /// drawer, and a capsule around that would have to grow into a rectangle
  /// anyway the first time the sentence took two lines.
  static let failureCardCornerRadius: CGFloat = 20
  static let failureCardPadding: CGFloat = 16
  static let failureDetailsCornerRadius: CGFloat = 12
  static let failureDetailsPadding: CGFloat = 12
  /// The details' copy glyph: in from the drawer's corner, and the room the
  /// words leave it.
  static let failureDetailsCopyInset: CGFloat = 6
  static let failureDetailsCopyGap: CGFloat = 8
  static let failureCardFill = PaletteInk.secondaryFill
  /// The evidence sits *in* the card, so it goes darker rather than lighter.
  static let failureDetailsFill = NSColor.black.withAlphaComponent(0.22)
  static let failureCardAccent = NSColor.systemOrange

  /// **A card that asks or waits is one scale and one set of gaps** — a
  /// permission, a question, a plan, a queued message.
  /// An eyebrow at `typeMeta` in secondary ink says what the card is; the
  /// title stands close under it, so the two read as one heading; what the
  /// card is about stands a step further off; a caption closer to what it
  /// captions; the buttons furthest, as a dialog keeps them. The insets are
  /// measured to the ink, as the composer's are: the eyebrow's caps stand
  /// `failureCardPadding` from the top edge, not its line box.
  static let serviceEyebrowFontSize: CGFloat = typeMeta
  static let serviceEyebrowGap: CGFloat = 4
  static let serviceContentGap: CGFloat = 12
  static let serviceCaptionGap: CGFloat = 8
  static let serviceActionsGap: CGFloat = 16
  /// The well a permission shows what it is about in: the tool's name as a
  /// label over the command, the command in mono on the card's 18 rhythm,
  /// and a line that wraps hangs two characters in, so a wrap is never read
  /// as a command of its own.
  static let serviceWellPadding: CGFloat = 12
  static let serviceWellLabelFontSize: CGFloat = typeFootnote
  static let serviceWellLabelGap: CGFloat = 4
  static let serviceWellLinkGap: CGFloat = 8
  static let serviceWellCodeLineHeight: CGFloat = previewBodyLineHeight

  /// How far a line's caps stand under the top of its frame: what an inset
  /// gives up to be measured to the ink. `lineHeight` is a pinned line's —
  /// TextKit puts what it adds over the natural line above the glyphs.
  static func capTrim(_ font: NSFont, lineHeight: CGFloat? = nil) -> CGFloat {
    let descent = -font.descender
    let line = lineHeight ?? (font.ascender + descent)
    return max(line - descent - font.capHeight, 0)
  }

  /// How far a line's baseline stands over the foot of its frame.
  static func baselineTrim(_ font: NSFont) -> CGFloat { -font.descender }

  /// An inset measured to the ink, on the half-point grid.
  static func inkInset(_ inset: CGFloat, less trim: CGFloat) -> CGFloat {
    ((inset - trim) * 2).rounded() / 2
  }

  /// The height a one-line label of this font takes.
  static func labelHeight(_ font: NSFont) -> CGFloat {
    ceil(font.ascender - font.descender + font.leading)
  }
  /// **A help tag is drawn as a Mac menu row**: text at the menu's 13
  /// (`typeMeta`), a hairline edge, a corner of 10, the padding a menu row
  /// has, and each key of a shortcut in its own outlined cap at 11.
  static let helpFill = HexColor.nsColor("#202020")
  static let helpEdge = PaletteInk.fill
  static let helpCornerRadius: CGFloat = 10
  static let helpHorizontalPadding: CGFloat = 10
  static let helpVerticalPadding: CGFloat = 6
  /// Between the tag's first line and the lines that explain it.
  static let helpLineSpacing: CGFloat = 2
  static let helpTextMaxWidth: CGFloat = 280
  /// Between the words and the keys that do the same thing.
  static let helpKeysGap: CGFloat = 16
  static let helpKeycapSize: CGFloat = 17
  static let helpKeycapCornerRadius: CGFloat = 4
  static let helpKeycapSpacing: CGFloat = 3
  static let helpKeycapEdge = NSColor.white.withAlphaComponent(0.14)
  /// Above the one button a pinned tag can carry (Compact), and its height —
  /// a regular-size control at the tag's 13, not a chip-sized pill.
  static let helpActionSpacing: CGFloat = 8
  static let helpActionHeight: CGFloat = 26
  /// The plan ring: a track of white at 10% — a fill on the glass, not an
  /// opaque grey, which draws a heavy disc beside the 50% glyphs — and an
  /// arc in one of four colours.
  static let planRingTrack = PaletteInk.fill
  static let planRingColors = ["#55FF00", "#00A2FF", "#FFC800", "#FF3C00"].map(HexColor.nsColor)
  static let planRingDiameter: CGFloat = 20
  static let planRingStroke: CGFloat = 4
  /// The frames' stroke against the ring's outer edge: 3.75 of 18.75.
  static let planRingStrokeRatio: CGFloat = 0.2
  /// Where the arc starts: the ring's left, running down past the bottom
  /// (counter-clockwise in AppKit's y-up), as the frames draw it.
  static let planRingStartAngle: CGFloat = 180

  /// Shared worded pill height. Composer icon targets use voiceOrbDiameter.
  static let directoryChipHeight: CGFloat = fromMock(30)
  /// Latest floats independently above the chat composer.
  static let latestComposerSpacing: CGFloat = fromMock(6)
  static let directoryChipFontSize: CGFloat = typeSecondary
  static let directoryChipGlyphPointSize: CGFloat = 10
  /// Real Finder folder art, not an SF outline — needs its own box.
  static let directoryChipIconSize: CGFloat = 20
  static let directoryChipTextColor = PaletteInk.primary
  static let directoryChipWarningTint = NSColor.systemOrange

  // MARK: The working-folder chip, naming its folder
  //
  // Anywhere but home the folder icon carries the folder's name on a light
  // pill — icon, name, fill — and at home it is the icon alone, a glyph of
  // the control group like the ring and the microphone. **The name is 15 on
  // both screens and the folder beside it the same size** — an SF Symbol at
  // the text's point size is drawn to match it.
  static func folderChipHeight(chat: Bool) -> CGFloat { chat ? 26 : 28 }
  static func folderChipPadding(chat: Bool) -> CGFloat { chat ? 6 : 7 }
  static func folderChipIconGap(chat: Bool) -> CGFloat { chat ? 5 : 6 }
  static func folderChipCornerRadius(chat: Bool) -> CGFloat { chat ? 6.5 : 7 }
  /// The name, `typeSecondary` — the step this file always named "the
  /// folder chip" — and the folder symbol at the same point size.
  static func folderChipFontSize(chat: Bool) -> CGFloat { typeSecondary }
  /// Past this a name ends in an ellipsis; the help tag has the whole path.
  /// 120 leaves the first screen's prompt room for its placeholder — at 160
  /// a long name cut it to two words.
  static let folderChipMaxNameWidth: CGFloat = 120
  /// Air either side of the pill in the row: the glyphs beside it keep
  /// theirs inside their targets, and the pill has none of its own.
  static let folderChipSlotMargin: CGFloat = 2
  /// White at 5% — the key hints' capsule fill. Anything brighter stands
  /// out over the prompt's dark ramp.
  static let folderChipFill = PaletteInk.tertiaryFill

  /// Gap above the inline error label, and the height it always reserves.
  static let errorTopSpacing: CGFloat = 6
  /// A notice (`PaletteNoticeView`): a capsule for one line, a box with the
  /// same corner for more; the glyph 6 from the words; 8 under the shell.
  static let noticeCornerRadius: CGFloat = 18
  static let noticeHorizontalPadding: CGFloat = 14
  static let noticeVerticalPadding: CGFloat = 10
  static let noticeGlyphSpacing: CGFloat = 6
  static let noticeShellSpacing: CGFloat = 8
  /// How far a notice in an open chat keeps from the composer's walls.
  static let noticeChatInset: CGFloat = 16
  static let errorMinimumHeight: CGFloat = 16
  static let errorRevealDuration: TimeInterval = Motion.standard
  /// How far the error label rises as it fades in.
  static let errorRiseOffset: CGFloat = 4

  static func resultsListHeight(itemCount: Int) -> CGFloat {
    guard itemCount > 0 else {
      // Empty state still reserves one row so the glass card doesn't collapse.
      return resultsVerticalInset * 2 + resultsRowHeight
    }
    let visible = min(itemCount, resultsMaxVisibleRows)
    return resultsVerticalInset * 2 + CGFloat(visible) * resultsRowHeight
  }

  /// The scrollable part of ScreenAgents: headings and rows, capped.
  ///
  /// The cap is the same six rows the flat list has always had, so opening ↓
  /// does not suddenly produce a taller panel — headings spend that height
  /// rather than adding to it, which is the honest trade: a day's heading is
  /// worth about half a row, and you can see it is there.
  static func historyListHeight(headerCount: Int, rowCount: Int) -> CGFloat {
    guard headerCount > 0 else { return resultsListHeight(itemCount: rowCount) }
    let content = resultsVerticalInset * 2
      + CGFloat(headerCount) * historyHeaderHeight
      + CGFloat(headerCount - 1) * historyHeaderSeparation
      + CGFloat(rowCount) * resultsRowHeight
    return min(content, resultsListHeight(itemCount: resultsMaxVisibleRows))
  }

  /// Height of the results card when its content is not a row list
  /// (install hints, empty search). Clamped so a long install list scrolls
  /// instead of growing past the usual six-row card.
  static func resultsCardHeight(contentHeight: CGFloat) -> CGFloat {
    min(max(contentHeight, resultsListHeight(itemCount: 1)), resultsListHeight(itemCount: resultsMaxVisibleRows))
  }

  /// The borderless panel: the prompt plus the transparent bleed its shadow
  /// needs on every side, and whatever the open card adds below it.
  static func panelSize(extraHeight: CGFloat = 0) -> CGSize {
    CGSize(
      width: promptSize.width + safeAreaX * 2,
      height: promptSize.height + safeAreaY * 2 + max(0, extraHeight)
    )
  }
}

/// How big the open chat and the chat list stand, as the person left them.
///
/// Their sides and foot can be dragged (`AgentPaletteView`'s resize grips)
/// and the size is kept, so the next ⌥Space opens them as they were. Points, not
/// fractions: a chat is sized to what it holds, not to the screen — a smaller
/// screen caps it at presentation and never rewrites what is stored.
struct BolttyAISurfaceSizes: Equatable, Sendable {
  var chat: CGSize
  var history: CGSize

  static let `default` = BolttyAISurfaceSizes(
    chat: AgentPaletteMetrics.chatSurfaceSize,
    history: CGSize(
      width: AgentPaletteMetrics.promptSize.width,
      height: AgentPaletteMetrics.historySurfaceHeight
    )
  )

  private static let chatWidthKey = "boltty.askBoltty.chatSize.width"
  private static let chatHeightKey = "boltty.askBoltty.chatSize.height"
  private static let historyWidthKey = "boltty.askBoltty.historySize.width"
  private static let historyHeightKey = "boltty.askBoltty.historySize.height"

  static func load(defaults: UserDefaults = .standard) -> BolttyAISurfaceSizes {
    func size(_ widthKey: String, _ heightKey: String, _ fallback: CGSize) -> CGSize {
      guard defaults.object(forKey: widthKey) != nil, defaults.object(forKey: heightKey) != nil
      else { return fallback }
      return CGSize(
        width: CGFloat(defaults.double(forKey: widthKey)),
        height: CGFloat(defaults.double(forKey: heightKey))
      )
    }
    return BolttyAISurfaceSizes(
      chat: size(chatWidthKey, chatHeightKey, Self.default.chat),
      history: size(historyWidthKey, historyHeightKey, Self.default.history)
    ).atLeastMinimum
  }

  func save(defaults: UserDefaults = .standard) {
    defaults.set(Double(chat.width), forKey: Self.chatWidthKey)
    defaults.set(Double(chat.height), forKey: Self.chatHeightKey)
    defaults.set(Double(history.width), forKey: Self.historyWidthKey)
    defaults.set(Double(history.height), forKey: Self.historyHeightKey)
  }

  /// Neither shell smaller than it can be used at. The upper bound is the
  /// screen's, and is applied where the shell is presented.
  var atLeastMinimum: BolttyAISurfaceSizes {
    func floor(_ size: CGSize, _ minimum: CGSize) -> CGSize {
      CGSize(width: max(size.width, minimum.width), height: max(size.height, minimum.height))
    }
    return BolttyAISurfaceSizes(
      chat: floor(chat, AgentPaletteMetrics.chatSurfaceMinimumSize),
      history: floor(history, AgentPaletteMetrics.historySurfaceMinimumSize)
    )
  }
}

/// Sets a corner and the curve the layer's own bounds can carry.
///
/// The palette has nine places that set a corner by hand, and a corner is two
/// decisions, not one: the radius, and whether a squircle has room to be drawn.
/// Getting the second wrong is invisible in code and unmistakable on screen —
/// flat, angular ends where round ones were meant.
///
/// **Call this from `layout()`, not `init`.** The curve is a function of the
/// bounds, and in `init` there are none.
extension CALayer {
  func applyPaletteCorner(radius: CGFloat) {
    cornerRadius = radius
    cornerCurve = AgentPaletteMetrics.cornerCurve(
      radius: radius,
      shorterSide: min(bounds.width, bounds.height)
    )
  }
}

/// **The palette's colours are the system's own two ladders.**
///
/// Text at 0.85 / 0.55 / 0.25, fills at 0.10 / 0.08 / 0.05 — the steps macOS
/// already has in dark, rather than opacities of white chosen by eye where
/// each was used.
///
/// **Text is the real, dynamic label colour**, so Increase Contrast reaches the
/// palette the way it reaches every other window — the panel is pinned to
/// `.darkAqua`, and a label resolves against it when it draws.
///
/// **Fills are the dark values, written down**, because they end up as a
/// `CGColor` on a layer, and a layer resolves nothing: a dynamic fill converted
/// outside a drawing pass takes whatever appearance happens to be current,
/// which in a light-mode app is the *light* fill — black, on a dark card.
/// `PaletteInkTests` holds them to the system's values.
enum PaletteInk {
  /// Text that is the content: the transcript, a title, the prompt.
  static let primary = NSColor.labelColor
  /// Text about the content: a row's second line, a legend, tool output.
  static let secondary = NSColor.secondaryLabelColor
  /// Text that is not available: an empty tab, a locked folder, a step not yet run.
  static let tertiary = NSColor.tertiaryLabelColor

  /// `systemFill` in dark — a bubble, a hover.
  static let fill = NSColor.white.withAlphaComponent(0.10)
  /// `secondarySystemFill` in dark — a slab you choose within, a card in the card.
  static let secondaryFill = NSColor.white.withAlphaComponent(0.08)
  /// `tertiarySystemFill` in dark — a hover on something already quiet.
  static let tertiaryFill = NSColor.white.withAlphaComponent(0.05)
  /// The one step the system does not have: *this* one, of several slabs.
  /// Twice `fill`, so selection is never a matter of squinting between two
  /// washes the backdrop can make look alike.
  static let selectedFill = NSColor.white.withAlphaComponent(0.20)
}

/// The composer's control group: folder, plan ring, clip, microphone and
/// Send, in that order, on the initial prompt and in a chat alike.
///
/// One description so the two screens cannot drift: the glyphs stand `gap`
/// apart — targets of glyph + gap that touch, so the air between two glyphs
/// is inside their targets — and every bare glyph wears the same three inks.
/// Hover is the ink alone; there is no wash behind a glyph. A control drawn
/// on glass (the microphone while listening) is outside the group's inks.
///
/// **Their size is the screen's**: `promptGlyph` beside the first screen's
/// larger type, `glyph` in a chat. The controls are the same views on both screens,
/// so the panel re-sizes their symbols as it moves between them.
enum ComposerControlGroup {
  /// A chat's glyphs: the Return arrow's width at
  /// `restingAttachGlyphPointSize`; the ring is drawn to this outer edge.
  static let glyph: CGFloat = 16
  /// The first screen's glyphs: 20, with more air between them than a
  /// chat's (`promptGap`): the first screen carries only ring, folder and
  /// microphone.
  static let promptGlyph: CGFloat = 20
  static let gap: CGFloat = 10
  static let promptGap: CGFloat = 16
  static let target: CGFloat = glyph + gap

  static func glyph(chat: Bool) -> CGFloat { chat ? glyph : promptGlyph }
  static func gap(chat: Bool) -> CGFloat { chat ? gap : promptGap }
  static func target(chat: Bool) -> CGFloat { glyph(chat: chat) + gap(chat: chat) }
  /// The symbols' point size for that screen's glyph: `restingAttachGlyphPointSize`
  /// draws Return `glyph` wide, and a symbol scales with its point size.
  static func pointSize(chat: Bool) -> CGFloat {
    AgentPaletteMetrics.restingAttachGlyphPointSize * glyph(chat: chat) / glyph
  }
  /// One of the group's symbols, at that screen's size.
  static func symbol(_ name: String, description: String, chat: Bool) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: description)?
      .withSymbolConfiguration(.init(pointSize: pointSize(chat: chat), weight: .medium))
  }
  /// Written down rather than dynamic, like `PaletteInk`'s fills: the panel
  /// is always dark, and these are chosen numbers, not a system step.
  static let restingInk = NSColor.white.withAlphaComponent(0.5)
  static let hoverInk = NSColor.white
  static let disabledInk = NSColor.white.withAlphaComponent(0.2)

  /// Dresses a bare glyph button in the group's inks.
  @MainActor
  static func style(_ button: PaletteIconButton) {
    button.restingTint = restingInk
    button.hoverTint = hoverInk
    button.disabledTint = disabledInk
    button.hoverBackground = .clear
    button.layer?.removeAnimation(forKey: "hoverBackground")
    button.layer?.backgroundColor = NSColor.clear.cgColor
  }
}
