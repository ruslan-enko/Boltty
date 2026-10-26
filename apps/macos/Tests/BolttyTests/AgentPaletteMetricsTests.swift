import XCTest
@testable import Boltty

final class AgentPaletteMetricsTests: XCTestCase {
  func testInterfaceTypographyAndSpacingUseTheHeroPromptScale() {
    XCTAssertEqual(AgentPaletteMetrics.promptFontSize, 20)
    XCTAssertEqual(AgentPaletteMetrics.resultsTitleFontSize, 15)
    XCTAssertEqual(AgentPaletteMetrics.resultsSubtitleFontSize, 13)
    XCTAssertEqual(AgentPaletteMetrics.promptSize.height, 85)
    XCTAssertEqual(AgentPaletteMetrics.iconSize, 33.5)
  }

  func testMockNumbersLandOnTheRetinaPixelGrid() {
    for value in [
      AgentPaletteMetrics.shellContentInset, AgentPaletteMetrics.surfaceStackSpacing,
      AgentPaletteMetrics.cardCornerRadius, AgentPaletteMetrics.chatComposerHeight,
      AgentPaletteMetrics.previewMessageSpacing, AgentPaletteMetrics.resultsRowHeight,
      AgentPaletteMetrics.resultsRowTextLeading, AgentPaletteMetrics.historyTabHeight,
      AgentPaletteMetrics.listeningOrbDiameter, AgentPaletteMetrics.iconSize,
    ] {
      XCTAssertEqual(value * 2, (value * 2).rounded(), accuracy: 0.0001, "\(value) is between pixels")
    }
    XCTAssertEqual(AgentPaletteMetrics.fromMock(22), 29.5, "never more than a quarter point from the mock")
  }

  func testTheTypeRampIsFiveWholePointSizes() {
    let ramp = [
      AgentPaletteMetrics.typePrimary, AgentPaletteMetrics.typeSecondary,
      AgentPaletteMetrics.typeChat, AgentPaletteMetrics.typeMeta, AgentPaletteMetrics.typeFootnote,
    ]
    XCTAssertEqual(ramp, [18, 15, 15, 13, 11])
    for size in [
      AgentPaletteMetrics.previewBodyFontSize,
      AgentPaletteMetrics.resultsTitleFontSize, AgentPaletteMetrics.resultsSubtitleFontSize,
      AgentPaletteMetrics.historyHeaderFontSize, AgentPaletteMetrics.historyTabFontSize,
      AgentPaletteMetrics.directoryChipFontSize,
      AgentPaletteMetrics.previewFileNameFontSize,
      AgentPaletteMetrics.previewFileSizeFontSize, AgentPaletteMetrics.previewActivityNameFontSize,
      AgentPaletteMetrics.previewActivityDetailFontSize, AgentPaletteMetrics.previewFooterFontSize,
      AgentPaletteMetrics.promptNoteFontSize,
    ] {
      XCTAssertTrue(ramp.contains(size), "\(size) is off the ramp")
    }
    XCTAssertEqual(AgentPaletteMetrics.promptFontSize, 20)
    let headings = [
      AgentPaletteMetrics.answerHeading1FontSize, AgentPaletteMetrics.answerHeading2FontSize,
      AgentPaletteMetrics.answerHeading3FontSize, AgentPaletteMetrics.previewBodyFontSize,
    ]
    XCTAssertEqual(headings, headings.sorted(by: >))
    XCTAssertEqual(Set(headings).count, headings.count)
    for size in headings { XCTAssertEqual(size, size.rounded()) }
    XCTAssertLessThan(AgentPaletteMetrics.answerCodeFontSize, AgentPaletteMetrics.previewBodyFontSize)
    XCTAssertGreaterThan(
      AgentPaletteMetrics.answerHeading1LineHeight, AgentPaletteMetrics.answerHeading1FontSize,
      "a heading's line box holds its own glyphs"
    )
  }

  func testSwitcherTypeAndRowHeightStayInProportion() {
    let title = AgentPaletteMetrics.resultsTitleFontSize
    let subtitle = AgentPaletteMetrics.resultsSubtitleFontSize

    XCTAssertEqual(title, AgentPaletteMetrics.typeSecondary)
    XCTAssertEqual(subtitle, AgentPaletteMetrics.typeMeta)
    XCTAssertGreaterThan(title, subtitle)
    XCTAssertNotEqual(PaletteInk.primary, PaletteInk.secondary)
    XCTAssertGreaterThan(AgentPaletteMetrics.resultsRowHeight, title + subtitle)
  }

  func testTheSwitcherCardIsNeverAStadium() {
    XCTAssertEqual(
      AgentPaletteMetrics.cornerRadius,
      AgentPaletteMetrics.promptSize.height / 2
    )

    XCTAssertEqual(
      AgentPaletteMetrics.cardCornerRadius,
      AgentPaletteMetrics.chatComposerRestingCornerRadius + AgentPaletteMetrics.shellContentInset,
      accuracy: 0.0001
    )

    for rows in 1...AgentPaletteMetrics.resultsMaxVisibleRows {
      let height = AgentPaletteMetrics.resultsListHeight(itemCount: rows)
      XCTAssertEqual(
        AgentPaletteMetrics.surfaceCornerRadius(forHeight: height, shape: .list),
        min(AgentPaletteMetrics.listCardCornerRadius, height / 2),
        accuracy: 0.0001,
        "a \(rows)-row card wears the list corner, clamped to what it can draw"
      )
    }
  }

  func testAPillIsACapsuleUntilItOutgrowsOneAndACardNeverIs() {
    for height in [AgentPaletteMetrics.listeningOrbDiameter,
                   AgentPaletteMetrics.chatComposerHeight,
                   AgentPaletteMetrics.promptSize.height] as [CGFloat] {
      XCTAssertEqual(
        AgentPaletteMetrics.surfaceCornerRadius(forHeight: height, shape: .pill),
        height / 2,
        accuracy: 0.0001,
        "a pill is an exact stadium at \(height)pt"
      )
    }
    for height in [140, 212, 392] as [CGFloat] {
      XCTAssertEqual(
        AgentPaletteMetrics.surfaceCornerRadius(forHeight: height, shape: .pill),
        AgentPaletteMetrics.cornerRadius,
        accuracy: 0.0001,
        "a grown prompt keeps the capsule's corner at \(height)pt"
      )
    }
    XCTAssertEqual(
      AgentPaletteMetrics.surfaceCornerRadius(forHeight: 30, shape: .chat),
      15,
      accuracy: 0.0001
    )
  }

  func testInstallHintsCardIsTallerThanOneSwitcherRowAndCapped() {
    let oneRow = AgentPaletteMetrics.resultsListHeight(itemCount: 1)
    let sixRows = AgentPaletteMetrics.resultsListHeight(itemCount: 6)
    XCTAssertGreaterThan(
      AgentPaletteMetrics.resultsCardHeight(contentHeight: 200),
      oneRow
    )
    XCTAssertEqual(
      AgentPaletteMetrics.resultsCardHeight(contentHeight: 800),
      sixRows
    )
    XCTAssertEqual(
      AgentPaletteMetrics.resultsCardHeight(contentHeight: 10),
      oneRow
    )
  }

  func testThePillIsInsetTheWayTheMockInsetsIt() {
    XCTAssertEqual(
      AgentPaletteMetrics.resultsVerticalInset,
      AgentPaletteMetrics.fromMock(12),
      accuracy: 0.0001
    )
    XCTAssertEqual(
      AgentPaletteMetrics.resultsRowHorizontalInset,
      AgentPaletteMetrics.resultsVerticalInset,
      accuracy: 0.0001,
      "the card's padding is square — one 12 on all four sides"
    )
  }

  func testTheFourRowCardMatchesTheMocksOverallHeight() {
    XCTAssertEqual(AgentPaletteMetrics.mockScale, 0.75)
    XCTAssertEqual(AgentPaletteMetrics.fromMock(388.449), 517.9, accuracy: 0.25)
    XCTAssertEqual(
      AgentPaletteMetrics.resultsListHeight(itemCount: 4),
      AgentPaletteMetrics.resultsVerticalInset * 2
        + AgentPaletteMetrics.resultsRowHeight * 4,
      accuracy: 0.1
    )
    XCTAssertEqual(AgentPaletteMetrics.resultsTopSpacing, 8, accuracy: 0.01)
  }

  func testPresentationIsShortEnoughForAKeyboardTriggeredSurface() {
    XCTAssertLessThanOrEqual(AgentPaletteMetrics.panelFadeOutDuration, Motion.quick)
  }

  func testHighFrameRateRangeAsksForProMotion() {
    XCTAssertEqual(MotionPreferences.highFrameRateRange.preferred, 120)
    XCTAssertEqual(MotionPreferences.highFrameRateRange.maximum, 120)
  }

  func testPanelSizeUsesOnlyTheCapsuleAndShadowBleedByDefault() {
    XCTAssertEqual(
      AgentPaletteMetrics.panelSize(),
      CGSize(
        width: AgentPaletteMetrics.promptSize.width
          + AgentPaletteMetrics.safeAreaX * 2,
        height: AgentPaletteMetrics.promptSize.height
          + AgentPaletteMetrics.safeAreaY * 2
      )
    )
    XCTAssertEqual(AgentPaletteMetrics.panelSize().width, 640)
  }

  // MARK: - Mascot geometry

  func testOnlyThePromptsFaceOverhangsItsBox() {
    let prompt = AgentPaletteMetrics.promptMascotSize / AgentPaletteMetrics.iconSize
    let row = AgentPaletteMetrics.resultsMascotSize / AgentPaletteMetrics.resultsIconFrameSize

    XCTAssertEqual(
      prompt, AgentPaletteMetrics.mascotOversize * AgentPaletteMetrics.promptMascotScale,
      accuracy: 0.0001
    )
    XCTAssertEqual(row, 1, accuracy: 0.0001, "a row's face is its box exactly")
    XCTAssertGreaterThan(prompt, row)
  }

  func testTheMarkToTextGapIsDerivedFromTheOverhangRatherThanTyped() {
    let mock = AgentPaletteMetrics.fromMock(5)
    let overhang = AgentPaletteMetrics.promptMascotOverhang

    XCTAssertEqual(
      AgentPaletteMetrics.promptIconTextSpacing,
      mock + overhang + AgentPaletteMetrics.mascotOpticalTextGap,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      overhang,
      (AgentPaletteMetrics.promptMascotSize - AgentPaletteMetrics.iconSize) / 2,
      accuracy: 0.0001
    )
  }

  func testTheVisibleGapBesideTheFaceMatchesTheMockPlusTheNudge() {
    let markRightEdge = AgentPaletteMetrics.promptLeadingInset
      + AgentPaletteMetrics.iconSize / 2
      + AgentPaletteMetrics.promptMascotSize / 2
    let textStarts = AgentPaletteMetrics.promptTextLeading

    XCTAssertEqual(
      textStarts - markRightEdge,
      AgentPaletteMetrics.fromMock(5) + AgentPaletteMetrics.mascotOpticalTextGap,
      accuracy: 0.0001
    )
  }

  func testThePromptMarkClickTargetClearsTheFaceItDraws() {
    XCTAssertGreaterThanOrEqual(
      AgentPaletteMetrics.promptMarkHitSize,
      AgentPaletteMetrics.promptMascotSize
    )
    XCTAssertGreaterThanOrEqual(AgentPaletteMetrics.promptMarkHitSize, 44)
  }

  func testTextLeadingIsStatedRatherThanChainedOffTheIconBox() {
    XCTAssertEqual(
      AgentPaletteMetrics.promptTextLeading,
      AgentPaletteMetrics.promptLeadingInset
        + AgentPaletteMetrics.iconSize
        + AgentPaletteMetrics.promptIconTextSpacing,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      AgentPaletteMetrics.resultsRowTextLeading,
      AgentPaletteMetrics.fromHistoryMock(20),
      accuracy: 0.0001
    )
    XCTAssertLessThan(
      AgentPaletteMetrics.resultsRowTextTrailing, AgentPaletteMetrics.resultsRowTextLeading
    )
  }

  func testNoNestedCornerOutRoundsTheSurfaceHoldingIt() {
    let card = AgentPaletteMetrics.cardCornerRadius

    XCTAssertEqual(
      AgentPaletteMetrics.resultsRowCornerRadius,
      AgentPaletteMetrics.listCardCornerRadius - AgentPaletteMetrics.resultsRowHorizontalInset,
      accuracy: 0.0001,
      "the list card is exactly its row pill plus the gap — arcs stay parallel"
    )

    XCTAssertEqual(
      AgentPaletteMetrics.chatComposerRestingCornerRadius,
      card - AgentPaletteMetrics.shellContentInset,
      accuracy: 0.0001,
      "the composer's corner is concentric with the shell's"
    )

    XCTAssertEqual(
      AgentPaletteMetrics.resultsRowHorizontalInset,
      AgentPaletteMetrics.resultsVerticalInset,
      accuracy: 0.0001
    )
  }

  func testAOneLineReplySizesToItsPaddedLine() {
    XCTAssertEqual(AgentPaletteMetrics.previewBodyFontSize, AgentPaletteMetrics.typeChat)
    XCTAssertEqual(AgentPaletteMetrics.previewBodyLineHeight, 18)
    XCTAssertGreaterThan(
      AgentPaletteMetrics.previewBodyLineHeight,
      AgentPaletteMetrics.previewBodyFontSize,
      "a line box has to hold its own glyphs"
    )

    XCTAssertEqual(
      AgentPaletteMetrics.previewMinHeight,
      AgentPaletteMetrics.previewHeaderHeight
        + AgentPaletteMetrics.previewContentVerticalPadding
        + AgentPaletteMetrics.previewBodyLineHeight
    )

    let corner = AgentPaletteMetrics.cardCornerRadius
    let radius = AgentPaletteMetrics.previewCloseDiameter / 2
    let inset = AgentPaletteMetrics.previewCloseInset
    let toArc = corner - (2.squareRoot() * (corner - inset - radius) + radius)
    XCTAssertEqual(toArc, AgentPaletteMetrics.shellContentInset, accuracy: 0.5)
    XCTAssertGreaterThanOrEqual(inset, AgentPaletteMetrics.previewContentHorizontalPadding)

    XCTAssertEqual(AgentPaletteMetrics.previewCloseDiameter, 36)

    XCTAssertEqual(
      AgentPaletteMetrics.previewCardHeight(bodyLineCount: 1),
      AgentPaletteMetrics.previewMinHeight
    )
    XCTAssertGreaterThan(
      AgentPaletteMetrics.previewMinHeight,
      AgentPaletteMetrics.cardCornerRadius * 2,
      "a one-line reply is a rounded card, which is what the corrected disc costs"
    )
  }

  func testEveryCardTakesTheCurveItsWallCanCarry() {
    for rows in 1...AgentPaletteMetrics.resultsMaxVisibleRows {
      let height = AgentPaletteMetrics.resultsListHeight(itemCount: rows)
      let curve = AgentPaletteMetrics.cornerCurve(
        radius: AgentPaletteMetrics.cardCornerRadius,
        shorterSide: height
      )
      let capped = min(AgentPaletteMetrics.cardCornerRadius, height / 2)
      let fits = 2 * AgentPaletteMetrics.continuousCornerWallReach * capped <= height
      XCTAssertEqual(
        curve,
        fits ? .continuous : .circular,
        "a \(rows)-row card takes the curve its \(height)pt wall can carry"
      )
    }
  }

  func testTheEmptyCardsPaddingIsNotPaidTwice() {
    XCTAssertEqual(
      AgentPaletteMetrics.resultsEmptyOwnVerticalPadding
        + AgentPaletteMetrics.resultsVerticalInset,
      AgentPaletteMetrics.resultsEmptyVerticalPadding,
      accuracy: 0.0001,
      "what the view lays out plus what the stack adds is the padding the mock states"
    )
    XCTAssertEqual(
      AgentPaletteMetrics.resultsEmptyMascotSize,
      AgentPaletteMetrics.fromMock(48.4),
      accuracy: 0.01
    )
    XCTAssertGreaterThan(
      AgentPaletteMetrics.resultsEmptyMascotSize,
      AgentPaletteMetrics.resultsIconFrameSize,
      "the empty card's face is a hero, not a row's icon"
    )
  }
}

extension AgentPaletteMetricsTests {
  func testTheHistoryFrameScalesToTheCardsOwnWidth() {
    XCTAssertEqual(
      AgentPaletteMetrics.fromHistoryMock(AgentPaletteMetrics.historyMockCardWidth),
      AgentPaletteMetrics.historyMockScaleWidth,
      accuracy: 0.25
    )
    XCTAssertEqual(
      AgentPaletteMetrics.historyTabTrackHeight,
      AgentPaletteMetrics.historyTabHeight + 2 * AgentPaletteMetrics.historyTabTrackPadding,
      accuracy: 0.0001
    )
    XCTAssertGreaterThanOrEqual(
      AgentPaletteMetrics.historyTabHeight,
      2 * AgentPaletteMetrics.historyTabLatestMascotSize
        + AgentPaletteMetrics.historyTabLatestTextSpacing
        + AgentPaletteMetrics.historyTabLabelHeight,
      "Latest's two-by-two and its name fit the segment"
    )
    XCTAssertLessThan(
      AgentPaletteMetrics.historyTabMascotSize,
      2 * AgentPaletteMetrics.historyTabLatestMascotSize,
      "an agent's face is smaller than Latest's group, so its name stands higher"
    )
  }

  func testTheStripLeavesTheFramesGapAboveTheFirstHeading() {
    XCTAssertEqual(
      AgentPaletteMetrics.historyTabStripHeight + AgentPaletteMetrics.resultsVerticalInset,
      AgentPaletteMetrics.historyTabTopInset + AgentPaletteMetrics.historyTabTrackHeight
        + AgentPaletteMetrics.historyTabListSpacing,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      AgentPaletteMetrics.historyTabCornerRadius,
      AgentPaletteMetrics.listCardCornerRadius - AgentPaletteMetrics.historyTabTopInset,
      accuracy: 0.0001,
      "the chosen segment is concentric with the card (2026-10-09)"
    )
  }
}
