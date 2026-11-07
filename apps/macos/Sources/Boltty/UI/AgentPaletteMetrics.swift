import AppKit
import Foundation

enum AgentPaletteMetrics {
  static let surfaceResponse: CGFloat = 0.3
  static let surfaceContentDuration: TimeInterval = Motion.standard

  enum SurfaceShape {
    case pill
    case initial
    case chat
    case list
  }

  static let cardCornerRadius: CGFloat = chatComposerRestingCornerRadius + shellContentInset

  static let shellContentInset: CGFloat = 12

  /// The composer's corner: the mock's `rounded-[100px]`, i.e. a capsule.
  ///
  /// Over-large on purpose — `PaletteGlassHost` clamps to half the shorter side,
  /// so "more than can be drawn" is how a capsule is written at any height.
  static let chatComposerCornerRadius: CGFloat = fromMock(100)

  static let chatComposerRestingCornerRadius: CGFloat =
    (chatComposerBoxHeight / (2 * continuousCornerWallReach)).rounded(.down)

  static let listCardCornerRadius: CGFloat =
    resultsRowCornerRadius + resultsRowHorizontalInset

  static func surfaceCornerRadius(
    forHeight height: CGFloat, shape: SurfaceShape
  ) -> CGFloat {
    let radius: CGFloat
    switch shape {
    case .pill: radius = cornerRadius
    case .initial: radius = cornerRadius
    case .chat: radius = cardCornerRadius
    case .list: radius = listCardCornerRadius
    }
    return min(radius, max(0, height) / 2)
  }

  static let surfaceStackSpacing: CGFloat = fromMock(20)

  static let workingFaceDiameter: CGFloat = fromMock(24)

  static let chatComposerHeight: CGFloat = 64
  static let chatComposerBoxHeight: CGFloat = chatComposerPadding + chatComposerControlsPadding
    + chatComposerGap
    + ComposerControlGroup.glyph + {
      // `PromptTextView.textOnlyLineHeight(for: chatComposerFont)`, which is
      // the main actor's; the same sum, read off the same face.
      let font = roundedAppFont(size: previewBodyFontSize)
      return ceil(font.ascender - font.descender + font.leading)
    }()
  static let chatComposerInkInset: CGFloat = 16
  static let chatComposerLeadingPadding: CGFloat = chatComposerInkInset - 1
  static let chatComposerPadding: CGFloat = chatComposerInkInset - 3.5
  static let chatComposerControlsPadding: CGFloat = chatComposerInkInset
  static let chatComposerGap: CGFloat = 16
  static let chatComposerGrownTextInset: CGFloat = 2.5
  static let chatComposerGrownTextTop: CGFloat = chatComposerPadding - chatComposerGrownTextInset
  static let chatComposerGrownControlsBand: CGFloat =
    chatComposerGap - chatComposerGrownTextInset + ComposerControlGroup.glyph + chatComposerControlsPadding
  static let chatComposerPlaceholderInk = ComposerControlGroup.restingInk
  static let chatComposerControlDiameter: CGFloat = ComposerControlGroup.target
  static let chatComposerTextLeading: CGFloat = chatComposerLeadingPadding
  static let chatComposerControlsTrailingInset: CGFloat =
    chatComposerControlsPadding - (ComposerControlGroup.target - ComposerControlGroup.glyph) / 2
  static let chatComposerSendDiscInset: CGFloat =
    chatComposerControlsPadding + ComposerControlGroup.glyph / 2 - ComposerControlGroup.sendDisc / 2
  static let chatComposerTextControlsGap = onPixelGrid(
    fromMock(10) - (chatComposerControlDiameter - 18) / 2
  )
  static let chatComposerMicSpacing: CGFloat = fromMock(10)

  static let mockScale: CGFloat = 0.75
  static func fromMock(_ value: CGFloat) -> CGFloat { onPixelGrid(value / mockScale) }
  static func onPixelGrid(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }

  static let promptSize = CGSize(width: 540, height: 92)
  static let promptGrownWidth: CGFloat = 680
  static let promptMockHeight: CGFloat = (fromMock(56) * 2).rounded() / 2
  static let promptPaddingGrowth: CGFloat = 1.15
  static let chatSurfaceSize = CGSize(width: 584, height: 680)
  static let chatSurfaceMinimumSize = CGSize(width: 420, height: 360)
  static var historySurfaceHeight: CGFloat {
    historyTabStripHeight + resultsListHeight(itemCount: historyDefaultVisibleRows)
  }
  static let historyDefaultVisibleRows = 5
  static var historySurfaceMinimumSize: CGSize {
    CGSize(width: 440, height: historyTabStripHeight + resultsListHeight(itemCount: 2))
  }
  static let surfaceResizeInnerGrip: CGFloat = 6
  static let surfaceResizeOuterGrip: CGFloat = 8
  static let surfaceResizeCornerReach: CGFloat = 30
  static let surfaceResizeTopClearance: CGFloat = 28
  static let scrollIndicatorInset: CGFloat = 7
  static let scrollIndicatorWidth: CGFloat = 5
  static let scrollIndicatorMinimumLength: CGFloat = 14
  static let scrollIndicatorLinger: TimeInterval = 0.9
  static let scrollIndicatorInk = NSColor.white.withAlphaComponent(0.45)
  static let resizeGrabberOutset: CGFloat = 6
  static let resizeGrabberLineWidth: CGFloat = 4
  static let resizeGrabberHalfAngle: CGFloat = .pi / 12
  static let resizeGrabberRestingInk = NSColor.clear
  static let resizeGrabberLitInk = NSColor.white.withAlphaComponent(0.75)
  static func fromInitialPromptMock(_ value: CGFloat) -> CGFloat {
    onPixelGrid(value * promptMockHeight / 112)
  }

  static let restingWaveformGlyphSize = CGSize(
    width: fromInitialPromptMock(30.75), height: fromInitialPromptMock(32.8)
  )
  static let restingControlsSpacing: CGFloat = 0
  static let restingControlsTrailingInset = onPixelGrid(
    restingControlsInkInset - ComposerControlGroup.gap(chat: false) / 2
  )
  static let restingControlsInkInset = onPixelGrid(fromInitialPromptMock(40) * promptPaddingGrowth)
  static let iconSize: CGFloat = fromMock(25)

  static let mascotOversize: CGFloat = 1.15
  static let promptMascotScale: CGFloat = 1.15 * 1.10
  static let promptMascotSize: CGFloat = iconSize * mascotOversize * promptMascotScale
  static var promptMascotOverhang: CGFloat { (promptMascotSize - iconSize) / 2 }
  static let promptMarkHitSize: CGFloat = max(44, promptMascotSize.rounded(.up))
  static let cornerRadius: CGFloat = promptSize.height / 2
  static let safeAreaX: CGFloat = 50
  static let safeAreaY: CGFloat = 50

  // MARK: - Type ramp

  static let typePrimary: CGFloat = 18
  static let typeSecondary: CGFloat = 15
  static let typeChat: CGFloat = 15
  static let typeMeta: CGFloat = 13
  static let typeFootnote: CGFloat = NSFont.systemFontSize(for: .small)

  static let promptFontSize: CGFloat = 20

  // MARK: The caret (`PromptCaretView`)

  static let caretWidthPerPoint: CGFloat = 0.09
  static let caretReachPerPoint: CGFloat = 0.227
  static let caretGlowMarginPerPoint: CGFloat = 0.7
  static let caretGlowSpreadPerPoint: CGFloat = 0.075
  static let caretGlowBlurPerPoint: CGFloat = 0.175
  static let caretGlowAlpha: CGFloat = 0.68
  static let caretBlinkDelay: TimeInterval = 0.5
  static let caretBlinkPeriod: TimeInterval = 1.0
  static let expandedPromptMaximumHeight: CGFloat = fromMock(148)
  static let promptLeadingInset =
    restingControlsInkInset + promptMascotInkOutset - promptMascotOpticalInset
  static let promptMascotOpticalInset: CGFloat = 6
  static let promptMascotInkOutset: CGFloat = 4
  static let promptTrailingInset = fromMock(12)
  static let promptIconTextSpacing =
    fromMock(5) + promptMascotOverhang + mascotOpticalTextGap
  static let mascotOpticalTextGap: CGFloat = 5.5
  static let promptTextLeading: CGFloat =
    promptLeadingInset + iconSize + promptIconTextSpacing
  static let promptMicTextSpacing: CGFloat = 10

  static let promptLineHeightPerPoint: CGFloat = 1.46

  static let screenSelectionDragThreshold: CGFloat = 4
  static let screenSelectionMinimumSide: CGFloat = 12
  static let screenSelectionLineWidth: CGFloat = 2.5
  static let screenSelectionCornerRadius: CGFloat = 8
  static let screenSelectionHintText = "Drag to ask about an area"
  static let screenSelectionChatHintText = "Drag to add an area"
  static let regionHintUses = 3
  static let regionsDrawnKey = "boltty.selection.regionsDrawn"
  static let screenSelectionHintOffset = CGSize(width: 14, height: 24)
  static let screenSelectionHintDelay: TimeInterval = helpTagDelay
  static let screenSelectionGlowWidth: CGFloat = 10
  static let screenSelectionInnerGlowDepth: CGFloat = 36
  static let screenSelectionInnerGlowStrength: CGFloat = 0.3
  static let screenSelectionHaloReach: CGFloat = 10
  static let screenSelectionHaloStrength: CGFloat = 0.3
  static let screenSelectionWaveAmplitude: CGFloat = 0.26
  static let screenSelectionDriftAmplitude: CGFloat = 0.2
  static let screenSelectionLightness: Double = 0.72
  static let screenSelectionHandleDiameter: CGFloat = 9
  static let screenSelectionHandleReach: CGFloat = 12
  static let screenSelectionDim: CGFloat = 0.4
  static let screenSelectionShellGap: CGFloat = 16
  static let regionSeedSide: CGFloat = 12
  static let regionVoiceWait: TimeInterval = 2
  static let regionHandOverDuration: CFTimeInterval = 0.26

  static let keyHintDelay: TimeInterval = 1

  // MARK: What came with the words

  static let attachmentCardSide: CGFloat = 100
  static let attachmentCardGap: CGFloat = 8
  static let attachmentCardInset: CGFloat = 11
  static let attachmentCardLines = 3
  static let attachmentCardLineHeight: CGFloat = 16
  static let attachmentCardPressedScale: CGFloat = 0.97
  static let attachmentThumbnailSide: CGFloat = attachmentCardSide * 2
  static let attachmentTagHeight: CGFloat = 18
  static let attachmentTagPadding: CGFloat = 7
  static let attachmentTagFill = PaletteInk.tertiaryFill
  static let attachmentCloseOverhang: CGFloat = 8
  static let attachmentCloseDiameter: CGFloat = 22
  static let attachmentCloseGlyph: CGFloat = 11
  static let attachmentCardAppearDuration: TimeInterval = 0.16
  static let attachmentCardAppearScale: CGFloat = 0.94
  static let attachmentStripFadeWidth: CGFloat = 28
  static let attachmentStripWheelStep: CGFloat = 8

  @MainActor static let attachmentStripOnFirstScreen = PromptAttachmentStrip.Placement(
    inset: 20, corner: cornerRadius - 20)
  @MainActor static let attachmentStripInChat = PromptAttachmentStrip.Placement(
    inset: chatComposerInkInset, corner: attachmentCardCornerInChat)
  static let attachmentCardCornerInChat: CGFloat = chatComposerRestingCornerRadius - chatComposerInkInset

  static func sentCardFrames(count: Int, width: CGFloat) -> [CGRect] {
    let side = attachmentCardSide
    let gap = attachmentCardGap
    let columns = max(1, Int((width + gap) / (side + gap)))
    return (0..<count).map { index in
      let row = index / columns
      let inRow = min(columns, count - row * columns)
      let column = index % columns
      let rowWidth = CGFloat(inRow) * side + CGFloat(inRow - 1) * gap
      return CGRect(
        x: width - rowWidth + CGFloat(column) * (side + gap),
        y: CGFloat(row) * (side + gap),
        width: side, height: side)
    }
  }

  static func sentCardsHeight(count: Int, width: CGFloat) -> CGFloat {
    sentCardFrames(count: count, width: width).last?.maxY ?? 0
  }

  static let voiceOrbDiameter: CGFloat = 44

  static let voiceOrbBarCount = 6
  static let voiceOrbBarWidth: CGFloat = fromMock(1.4613)
  static let voiceOrbBarSpacing: CGFloat = fromMock(1.2449)
  static let restingWaveformBarSpacing =
    (restingWaveformGlyphSize.width - CGFloat(voiceOrbBarCount) * voiceOrbBarWidth)
      / CGFloat(voiceOrbBarCount - 1)
  static let voiceOrbBarHeight: CGFloat = 22
  static let voiceOrbBarProfile: [CGFloat] = [0.26, 0.65, 1.0, 0.53, 0.80, 0.35]
  static let voiceOrbBarSwing: CGFloat = 0.5
  static let voiceOrbBarPhaseStep: CGFloat = 0.38
  static let voiceOrbBarPhaseSpread: CGFloat = 1.1

  static let voiceControlsPadding: CGFloat = fromMock(2)
  static let voiceControlsSpacing: CGFloat = fromMock(10)
  static let voiceControlsCornerRadius: CGFloat = fromMock(50)
  static var voiceControlsHeight: CGFloat { voiceOrbDiameter + voiceControlsPadding * 2 }

  static let voiceControlsIconSize: CGFloat = fromMock(16)
  static let voiceControlsTimerFontSize: CGFloat = fromMock(12)
  static let voiceControlsCancelGlyphColor = PaletteInk.primary
  static let voiceControlsConfirmFillColor = NSColor.white
  static let voiceControlsConfirmGlyphColor = NSColor.black
  static let voiceControlsConfirmHoverFillColor = NSColor.white
  static let voiceControlsCancelHoverFillColor = PaletteInk.fill
  static let voiceControlsCancelHoverBlurRadius: CGFloat = 3

  static let voiceMeterSize = CGSize(width: fromMock(35.77), height: fromMock(16))
  static let voiceMeterBarCount = 14
  static let voiceMeterBarWidth: CGFloat = 1.6
  static let voiceMeterMinimumBarFraction: CGFloat = 0.18

  @MainActor
  static var promptGrownInset: CGFloat {
    max(0, (promptSize.height - PromptTextView.textOnlyLineHeight) / 2)
  }

  @MainActor
  static var promptGrownMaximumHeight: CGFloat {
    promptGrownInset * 2
      + CGFloat(PromptTextView.maxVisibleLines) * PromptTextView.textOnlyLineHeight
  }

  static let voiceConfirmGraceInterval: TimeInterval = 2.0

  static let restingAttachGlyphPointSize: CGFloat = 15

  static let previewCloseDiameter: CGFloat = 36
  static let previewCloseGlyphPointSize: CGFloat = 18
  static let previewCloseGlyphNudge: CGFloat = 1
  static let previewCloseInset: CGFloat = {
    let radius = previewCloseDiameter / 2
    let fromArcCentre = cardCornerRadius - shellContentInset - radius
    return onPixelGrid(cardCornerRadius - fromArcCentre / 2.squareRoot() - radius)
  }()
  static let historyFootDiscInset: CGFloat = 18
  static let historyFootHeight: CGFloat =
    historyFootDiscInset + previewCloseDiameter + previewContentVerticalPadding

  static let previewHeaderHeight: CGFloat =
    previewCloseInset + previewCloseDiameter + previewContentVerticalPadding

  static let voiceOrbGlyphColor = PaletteInk.primary

  static let voiceOrbLevelAttack: CGFloat = 0.5
  static let voiceOrbLevelRelease: CGFloat = 0.12

  static let voiceGlowIdle: CGFloat = 0.26
  static let voiceGlowBreatheDuration: CGFloat = 3.4
  static let voiceGlowAttack: CGFloat = 0.325
  static let voiceGlowRelease: CGFloat = 0.86

  static let voiceGlowFlowRest: CGFloat = 0.55
  static let voiceGlowFlowVoice: CGFloat = 3.4
  static let voiceGlowFlowProcessing: CGFloat = 1.7
  static let voiceGlowSwayRate: CGFloat = 0.9
  static let voiceGlowLightness: Double = 0.62
  static let voiceGlowFadeDuration: TimeInterval = 0.4

  static let voiceGlowCompletedFadeDuration: TimeInterval = 0.55
  static let voiceGlowOrbReleaseDuration: TimeInterval = 0.3
  static let voiceGlowAbortFadeDuration: TimeInterval = 0.18

  static let voiceGlowGate: CGFloat = 0.055
  static let voiceGlowGateKnee: CGFloat = 0.11
  static let voiceGlowBeamLevel: CGFloat = 0.74
  static let voiceGlowBeamGatherDuration: CGFloat = 0.32

  static let voiceSilenceSubmitDelay: TimeInterval = 2.4

  static let listeningOrbDiameter: CGFloat = 84
  static let listeningFaceSize: CGFloat = 48
  static let listeningFaceTopInset: CGFloat = 14
  static let listeningFaceWordsGap: CGFloat = 4
  static let listeningWordsBottomInset: CGFloat = 16
  static let listeningMaxLines = 5
  static let listeningWordsLineSpacing: CGFloat = 1.34
  static func listeningWordedHeight(lines: Int, lineHeight: CGFloat) -> CGFloat {
    listeningFaceTopInset + listeningFaceSize + listeningFaceWordsGap
      + CGFloat(max(1, lines)) * lineHeight + listeningWordsBottomInset
  }
  static let listeningFaceFlight: CFTimeInterval = 0.55
  static let listeningWordsInset: CGFloat = 30
  static let listeningWordsFontSize: CGFloat = typePrimary
  static let listeningMaxWidth: CGFloat = 380
  static let listeningWordArrival: CFTimeInterval = 1.1
  static let listeningWordBlur: CGFloat = 9
  static let listeningWordRise: CGFloat = 4
  static let listeningWordStagger: CFTimeInterval = 0.09
  static let listeningWordGlide: CFTimeInterval = 0.14

  static let controlPressedScale: CGFloat = 0.95
  static let rowPressedScale: CGFloat = 0.985
  static let hoverFadeDuration: TimeInterval = Motion.quick
  static let helpTagDelay: TimeInterval = 0.45
  static let helpTagWarmWindow: TimeInterval = 0.5

  static let panelFadeOutDuration: TimeInterval = 0.10
  static let lockedTopGap: CGFloat = 30

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
  static let dripEdgeSliver: CGFloat = 8
  static let dripSeed: CGFloat = 0.5
  static let dripFallWidth: CGFloat = 0.8
  static let dripFallHeight: CGFloat = 0.92

  static let resultsTopSpacing = fromMock(6)
  static let resultsRowHeight: CGFloat = fromHistoryMock(64)
  static let resultsMaxVisibleRows = 6
  /// Measured: rendering a continuous layer at three radii gives 1.34 × radius
  /// every time.
  static let continuousCornerWallReach: CGFloat = 1.34

  static func cornerCurve(radius: CGFloat, shorterSide: CGFloat) -> CALayerCornerCurve {
    guard shorterSide > 0 else { return .continuous }
    let capped = min(radius, shorterSide / 2)
    return 2 * continuousCornerWallReach * capped <= shorterSide ? .continuous : .circular
  }

  static let resultsMascotSize: CGFloat = resultsIconFrameSize
  static let resultsIconFrameSize: CGFloat = 32
  static let resultsEmptyMascotSize: CGFloat = fromMock(48.4)
  static let resultsEmptyMascotTextSpacing: CGFloat = fromMock(15)
  static let resultsEmptyVerticalPadding: CGFloat = fromMock(24)
  static var resultsEmptyOwnVerticalPadding: CGFloat {
    max(0, resultsEmptyVerticalPadding - resultsVerticalInset)
  }

  static let resultsVerticalInset: CGFloat = fromMock(12)
  static var resultsRowCornerRadius: CGFloat {
    (resultsRowHeight - resultsRowInset * 2) / 2
  }

  static let resultsTitleFontSize: CGFloat = typeSecondary
  static let resultsSubtitleFontSize: CGFloat = typeMeta
  static let resultsRowInset: CGFloat = 0
  static let resultsShimmerSweepDuration: CFTimeInterval = 1.4
  static let resultsShimmerRest: CFTimeInterval = 0.6
  static let resultsShimmerBandShare: CGFloat = 0.45
  static let resultsShimmerMinimumBand: CGFloat = 48
  static let resultsShimmerFade: CGFloat = 0.3
  static let resultsWorkingStillOpacity: CGFloat = 0.5

  static let resultsRowHorizontalInset: CGFloat = fromMock(12)
  static let resultsRowIconTextSpacing: CGFloat = 10.5
  static let resultsRowTextLeading: CGFloat = fromHistoryMock(20)
  static let resultsRowTextTrailing: CGFloat = fromHistoryMock(12)
  static let resultsUnreadDotDiameter: CGFloat = 8
  static let resultsUnreadDotGap: CGFloat = 8
  static let resultsUnreadDotFill = HexColor.nsColor("#0A84FF")
  static var resultsRowFacedTextLeading: CGFloat {
    resultsRowTextLeading + resultsMascotSize + resultsRowIconTextSpacing
  }

  // MARK: - History

  /// Every number of the history card goes through this, not `fromMock`; type sizes
  /// are the ramp's.
  static let historyMockCardWidth: CGFloat = 582.67
  static let historyMockScaleWidth: CGFloat = 520
  static func fromHistoryMock(_ value: CGFloat) -> CGFloat {
    onPixelGrid(value * historyMockScaleWidth / historyMockCardWidth)
  }

  static let historyHeaderHeight: CGFloat = fromHistoryMock(50)
  static let historyHeaderFontSize: CGFloat = typeMeta
  static let historyHeaderTextColor = PaletteInk.secondary
  static let historyHeaderBottomInset: CGFloat = 10
  static let historyHeaderSeparation: CGFloat = 8
  static func historyHeaderHeight(followsRows: Bool) -> CGFloat {
    historyHeaderHeight + (followsRows ? historyHeaderSeparation : 0)
  }
  static var historyHeaderLeading: CGFloat {
    resultsRowHorizontalInset + resultsRowTextLeading
  }

  static let historyTabTopInset: CGFloat = shellContentInset
  static let historyTabTrackPadding: CGFloat = 0
  static let historyTabPadding: CGFloat = 10
  static let historyTabMascotSize: CGFloat = fromHistoryMock(40)
  static let historyTabMascotTextSpacing: CGFloat = fromHistoryMock(4)
  static let historyTabLatestMascotSize: CGFloat = fromHistoryMock(20)
  static let historyTabLatestTextSpacing: CGFloat = fromHistoryMock(6)
  static var historyTabClusterSide: CGFloat { 2 * historyTabLatestMascotSize }
  static let historyTabSegmentInset: CGFloat = 6
  static let historyTabFontSize: CGFloat = typeSecondary
  static var historyTabLabelHeight: CGFloat {
    let font = roundedAppFont(size: historyTabFontSize)
    return ceil(font.ascender - font.descender + font.leading)
  }
  static var historyTabHeight: CGFloat {
    let latest = 2 * historyTabLatestMascotSize + historyTabLatestTextSpacing
    let agent = historyTabMascotSize + historyTabMascotTextSpacing
    return onPixelGrid(2 * historyTabPadding + max(latest, agent) + historyTabLabelHeight)
  }
  static var historyTabTrackHeight: CGFloat { historyTabHeight + 2 * historyTabTrackPadding }
  static var historyTabCornerRadius: CGFloat { listCardCornerRadius - historyTabTopInset }
  static let historyTabListSpacing: CGFloat = fromHistoryMock(14)
  static var historyTabStripHeight: CGFloat {
    historyTabTopInset + historyTabTrackHeight + historyTabListSpacing - resultsVerticalInset
  }
  static let historyTabSlideResponse = CGFloat(Motion.standard)
  static let historyTabHoverFill = PaletteInk.tertiaryFill
  static let historyRowSelectedFill = NSColor.white.withAlphaComponent(0.14)
  static let historyRowHoverFill = PaletteInk.secondaryFill
  static let historyTabActiveTextColor = PaletteInk.primary
  static let historyTabTextColor = PaletteInk.secondary

  static let resultsTitleSubtitleSpacing: CGFloat = 2

  static let targetSwapBlurRadius: CGFloat = 8
  static let targetSwapBlurDuration: TimeInterval = 0.18
  static let targetSwapFadeDuration: TimeInterval = Motion.quick

  static let previewBodyFontSize: CGFloat = typeChat
  static let previewBodyLineHeight: CGFloat = 18
  static let previewAnswerLineHeight: CGFloat = 24

  static let answerHeading1FontSize: CGFloat = 21
  static let answerHeading1LineHeight: CGFloat = 28
  static let answerHeading2FontSize: CGFloat = typePrimary
  static let answerHeading2LineHeight: CGFloat = 24.5
  static let answerHeading3FontSize: CGFloat = 16
  static let answerHeading1SpacingAfter: CGFloat = 7
  static let answerHeading2SpacingAfter: CGFloat = 3.5

  static let answerTableFontSize: CGFloat = typeMeta
  static let answerTableCellVerticalPadding: CGFloat = 8.5
  static let answerTableCellTrailingPadding: CGFloat = 21
  static let answerTableRuleWidth: CGFloat = 1
  static let answerTableRule = PaletteInk.secondaryFill
  static let answerParagraphSpacing: CGFloat = 16
  static let answerListMarkerIndent: CGFloat = 8
  static let answerListHeadIndent: CGFloat = 21
  static let answerListNumberGap: CGFloat = 5
  static let answerListNestIndent: CGFloat = 22
  static let answerListItemSpacing: CGFloat = 0
  static let answerCodeFontSize: CGFloat = typeMeta
  static let answerInlineCodeFill = PaletteInk.fill
  static let answerInlineCodeCornerRadius: CGFloat = 6
  static let answerInlineCodeInset: CGFloat = 4
  static let answerCodeBlockCornerRadius: CGFloat = 10
  static let answerCodeBlockFill = PaletteInk.secondaryFill
  static let answerCodeBlockVerticalPadding: CGFloat = 14
  static let answerCodeBlockLeadingPadding: CGFloat = 16
  static let answerCodeBlockTrailingPadding: CGFloat = 40
  static let answerCodeBlockLineHeight: CGFloat = 19.5
  static let answerCodeBlockCopyInset: CGFloat = 8
  static let answerQuoteBarWidth: CGFloat = 3.5
  static let answerQuoteBar = PaletteInk.selectedFill
  static let answerQuoteIndent: CGFloat = 21
  static let answerQuoteVerticalPadding: CGFloat = 7
  static let answerRuleSpacing: CGFloat = 24.5
  static let answerRuleSpacingAfter: CGFloat = 14
  static let previewContentVerticalPadding: CGFloat = fromMock(21)
  static let previewContentHorizontalPadding: CGFloat = shellContentInset
  static let previewTopSpacing: CGFloat = 8

  static let previewOptionCornerRadius: CGFloat = fromMock(16)
  static let previewOptionHorizontalPadding: CGFloat = fromMock(9)
  static let previewOptionVerticalPadding: CGFloat = fromMock(7.5)
  static let previewOptionMarkSize: CGFloat = fromMock(14)
  static let previewOptionMarkSpacing: CGFloat = fromMock(8)
  static let previewOptionSpacing: CGFloat = fromMock(4)
  static let previewOptionDetailSpacing: CGFloat = 2
  static let previewOptionsTopSpacing: CGFloat = fromMock(20)

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

  static let previewBubbleMaxWidthFraction: CGFloat = 0.78
  static func previewBubbleMaxWidth(in column: CGFloat) -> CGFloat {
    onPixelGrid(column * previewBubbleMaxWidthFraction)
  }
  static let previewUserBubbleFill = NSColor.white.withAlphaComponent(0.94)
  static let previewUserBubbleInk = NSColor.black
  static let previewUserBubbleHorizontalPadding: CGFloat = 13
  static let previewUserBubbleVerticalPadding: CGFloat = 5.5
  static let previewUserBubbleCornerRadius: CGFloat = 14
  static let previewMessageSpacing: CGFloat = 25.5
  static let previewAgentMessageSpacing: CGFloat = answerParagraphSpacing

  static let previewWorkPillHeight: CGFloat = 28
  static let previewWorkPillChevronGap: CGFloat = 5
  static let previewWorkPillChevronWidth: CGFloat = 12
  static let previewWorkPillChevronPointSize: CGFloat = 13
  static let previewWorkPillTextInset: CGFloat = 0
  static let previewWorkPillTrailingInset: CGFloat = 0
  static let previewWorkThreadX: CGFloat = 5
  static let previewWorkThreadWidth: CGFloat = 1.5
  static let previewWorkThreadFill = PaletteInk.secondaryFill
  static let previewWorkListInset: CGFloat = 18
  static let previewWorkPillListTop: CGFloat = previewWorkPillHeight + 2
  static let previewWorkPillListBottomInset: CGFloat = 4
  static let previewWorkPillSpacingAbove: CGFloat = 14
  static let previewWorkPillSpacingBelow: CGFloat = 10

  static let previewFileRowHeight: CGFloat = 56
  static let previewFileRowSpacing: CGFloat = 6
  static let previewFileRowsTopMargin: CGFloat = 8
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
  static let previewFileGlyphPointSize: CGFloat = 16
  static let previewFileNameFontSize: CGFloat = typeMeta
  static let previewFileSizeFontSize: CGFloat = typeFootnote

  static let previewActivityRowHeight: CGFloat = 22
  static let previewActivityRowSpacing: CGFloat = 2
  static let previewActivityRowsTopMargin: CGFloat = 6
  static let previewActivityGlyphSize: CGFloat = 14
  static let previewActivityGlyphPointSize: CGFloat = 14
  static let previewActivityChevronPointSize: CGFloat = 12
  static let previewActivityNameFontSize: CGFloat = typeMeta
  static let previewActivityDetailFontSize: CGFloat = typeFootnote
  /// Pinned: the measure ceils a bounding box while the label uses the font's
  /// leading, which clipped the last line of monospaced output.
  static let previewActivityDetailLineHeight: CGFloat = 14
  static let previewActivityDetailTopMargin: CGFloat = 4
  static let previewActivityDetailWellInset: CGFloat = 8
  static let previewActivityDetailWellCornerRadius: CGFloat = 8
  static let previewActivityDetailWellFill = PaletteInk.tertiaryFill
  static let previewActivityDetailIndent: CGFloat = previewActivityGlyphSize + previewActivityRowSpacing * 2
  static let previewActivityDetailLineCap = 40

  static let previewTurnHeaderLabelHeight: CGFloat = previewActivityRowHeight
  static let previewTurnHeaderHeight: CGFloat = previewTurnHeaderLabelHeight
  static let previewTurnHeaderSpacing: CGFloat = 6

  static let workingLineHeight: CGFloat = workingFaceDiameter
  static let workingLineLeadingInset: CGFloat = 2
  static let workingLineFaceSize: CGFloat = 24
  static let workingLineFaceGap: CGFloat = 10
  static let workingLineBreathDuration: CFTimeInterval = 1.3
  static let workingLineBreathLitLow: CGFloat = 0.15
  static let workingLineHaloBlur: CGFloat = 6
  static let workingLineHaloOpacity: CGFloat = 0.55

  static let previewCopyButtonSize: CGFloat = 30
  static let previewCopyRowHeight: CGFloat = previewCopyButtonSize + 6
  static let previewQuestionMetaRowHeight: CGFloat = 28
  static let previewQuestionMetaSpacing: CGFloat = 6

  static let previewScrollEdgeSoftness: CGFloat = previewContentVerticalPadding / 2
  static let scrollEdgeBlurRadius: CGFloat = 8
  static var historyTabOverlap: CGFloat { onPixelGrid(historyTabHeight * 0.45) }

  static let previewStreamingWordFade: TimeInterval = Motion.standard
  static let previewStreamingWordSettle: TimeInterval = Motion.standard * 6

  static let previewRevealDuration: TimeInterval = Motion.standard
  static let previewRevealStagger: TimeInterval = 0.06
  static let previewRevealStaggerSteps = 4

  static let previewSendFlightDuration: TimeInterval = 0.45

  // MARK: Shader effects (`PaletteEffects`)

  static let revealDuration: TimeInterval = Motion.standard * 2
  static let revealBlurFraction: CGFloat = 0.18
  static let revealAberrationFraction: CGFloat = 0.05
  static let revealZoom: CGFloat = 0.08
  static let revealOpaqueAt: CGFloat = 0.35

  static let whipMaxLagHeights: CGFloat = 1.2
  static let whipMaxLag: CGFloat = 40
  static func whipReach(height: CGFloat) -> CGFloat { min(whipMaxLagHeights * height, whipMaxLag) }
  static let whipLagPerSpeed: CGFloat = 0.03
  static let whipFadeOutAt: CGFloat = 0.4

  static let transcriptFollowSlack: CGFloat = 40

  static let transcriptLatestPillSlack: CGFloat = 120

  static let previewMinHeight: CGFloat =
    previewHeaderHeight + previewContentVerticalPadding + previewBodyLineHeight

  static func previewCardHeight(bodyLineCount: Int) -> CGFloat {
    previewHeaderHeight + previewContentVerticalPadding
      + previewBodyLineHeight * CGFloat(max(bodyLineCount, 1))
  }

  static let resultsShadowBleed: CGFloat = 32

  static let promptNoteFontSize: CGFloat = typeMeta

  static let previewFooterFontSize: CGFloat = typeFootnote
  static let previewFooterTextColor = PaletteInk.secondary

  static let failureCardCornerRadius: CGFloat = 20
  static let failureCardPadding: CGFloat = 16
  static let failureDetailsCornerRadius: CGFloat = 12
  static let failureDetailsPadding: CGFloat = 12
  static let failureDetailsCopyInset: CGFloat = 6
  static let failureDetailsCopyGap: CGFloat = 8
  static let failureCardFill = PaletteInk.secondaryFill
  static let failureDetailsFill = NSColor.black.withAlphaComponent(0.22)
  static let failureCardAccent = NSColor.systemOrange

  static let serviceEyebrowFontSize: CGFloat = typeMeta
  static let serviceEyebrowGap: CGFloat = 4
  static let serviceContentGap: CGFloat = 12
  static let serviceCaptionGap: CGFloat = 8
  static let serviceActionsGap: CGFloat = 16
  static let serviceWellPadding: CGFloat = 12
  static let serviceWellLabelFontSize: CGFloat = typeFootnote
  static let serviceWellLabelGap: CGFloat = 4
  static let serviceWellLinkGap: CGFloat = 8
  static let serviceWellCodeLineHeight: CGFloat = previewBodyLineHeight

  static func capTrim(_ font: NSFont, lineHeight: CGFloat? = nil) -> CGFloat {
    let descent = -font.descender
    let line = lineHeight ?? (font.ascender + descent)
    return max(line - descent - font.capHeight, 0)
  }

  static func baselineTrim(_ font: NSFont) -> CGFloat { -font.descender }

  static func inkInset(_ inset: CGFloat, less trim: CGFloat) -> CGFloat {
    ((inset - trim) * 2).rounded() / 2
  }

  static func labelHeight(_ font: NSFont) -> CGFloat {
    ceil(font.ascender - font.descender + font.leading)
  }
  static let helpDensity = NSColor.black.withAlphaComponent(0.55)
  static let helpCornerRadius: CGFloat = 10
  static let helpHorizontalPadding: CGFloat = 10
  static let helpVerticalPadding: CGFloat = 6
  static let helpLineSpacing: CGFloat = 2
  static let helpTextMaxWidth: CGFloat = 280
  static let helpKeysGap: CGFloat = 16
  static let helpKeycapSize: CGFloat = 18
  static let helpKeycapCornerRadius: CGFloat = 4
  static let helpKeycapSpacing: CGFloat = 3
  static let helpKeycapInset: CGFloat = 5
  static let helpActionSpacing: CGFloat = 8
  static let helpActionHeight: CGFloat = 26
  static let planRingTrack = ComposerControlGroup.disabledInk
  static let planRingInk = ComposerControlGroup.restingInk
  static let planRingDiameter: CGFloat = 20
  static let planRingStroke: CGFloat = 2.5
  static let planRingStrokeRatio: CGFloat = 0.125

  static let directoryChipHeight: CGFloat = fromMock(30)
  static let latestComposerSpacing: CGFloat = fromMock(6)
  static let directoryChipFontSize: CGFloat = typeSecondary
  static let directoryChipGlyphPointSize: CGFloat = 10
  static let directoryChipTextColor = PaletteInk.primary
  static let directoryChipWarningTint = NSColor.systemOrange

  // MARK: The working-folder chip, naming its folder
  static func folderChipHeight(chat: Bool) -> CGFloat { chat ? 26 : 28 }
  static func folderChipPadding(chat: Bool) -> CGFloat { chat ? 6 : 7 }
  static func folderChipIconGap(chat: Bool) -> CGFloat { chat ? 5 : 6 }
  static func folderChipCornerRadius(chat: Bool) -> CGFloat { chat ? 6.5 : 7 }
  static func folderChipFontSize(chat: Bool) -> CGFloat { typeSecondary }
  static let folderChipMaxNameWidth: CGFloat = 120
  static let folderChipSlotMargin: CGFloat = 2
  static let folderChipFill = PaletteInk.tertiaryFill

  static let errorTopSpacing: CGFloat = 6
  static let noticeCornerRadius: CGFloat = 18
  static let noticeHorizontalPadding: CGFloat = 14
  static let noticeVerticalPadding: CGFloat = 10
  static let noticeGlyphSpacing: CGFloat = 6
  static let noticeShellSpacing: CGFloat = 8
  static let noticeChatInset: CGFloat = 16
  static let errorMinimumHeight: CGFloat = 16
  static let errorRevealDuration: TimeInterval = Motion.standard
  static let errorRiseOffset: CGFloat = 4

  static func resultsListHeight(itemCount: Int) -> CGFloat {
    guard itemCount > 0 else {
      return resultsVerticalInset * 2 + resultsRowHeight
    }
    let visible = min(itemCount, resultsMaxVisibleRows)
    return resultsVerticalInset * 2 + CGFloat(visible) * resultsRowHeight
  }

  static func resultsCardHeight(contentHeight: CGFloat) -> CGFloat {
    min(max(contentHeight, resultsListHeight(itemCount: 1)), resultsListHeight(itemCount: resultsMaxVisibleRows))
  }

  static func panelSize(extraHeight: CGFloat = 0) -> CGSize {
    CGSize(
      width: promptSize.width + safeAreaX * 2,
      height: promptSize.height + safeAreaY * 2 + max(0, extraHeight)
    )
  }
}

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

extension CALayer {
  func applyPaletteCorner(radius: CGFloat) {
    cornerRadius = radius
    cornerCurve = AgentPaletteMetrics.cornerCurve(
      radius: radius,
      shorterSide: min(bounds.width, bounds.height)
    )
  }
}

enum PaletteInk {
  static let primary = NSColor.labelColor
  static let secondary = NSColor.secondaryLabelColor
  static let tertiary = NSColor.tertiaryLabelColor

  static let fill = NSColor.white.withAlphaComponent(0.10)
  static let secondaryFill = NSColor.white.withAlphaComponent(0.08)
  static let tertiaryFill = NSColor.white.withAlphaComponent(0.05)
  static let selectedFill = NSColor.white.withAlphaComponent(0.20)
}

enum ComposerControlGroup {
  static let glyph: CGFloat = 16
  static let promptGlyph: CGFloat = 20
  static let gap: CGFloat = 10
  static let promptGap: CGFloat = 16
  static let target: CGFloat = glyph + gap

  static func glyph(chat: Bool) -> CGFloat { chat ? glyph : promptGlyph }
  static func gap(chat: Bool) -> CGFloat { chat ? gap : promptGap }
  static func target(chat: Bool) -> CGFloat { glyph(chat: chat) + gap(chat: chat) }
  static func iconSize(chat: Bool) -> CGFloat { glyph(chat: chat) + 1 }
  static let restingInk = NSColor.white.withAlphaComponent(0.5)
  static let hoverInk = NSColor.white
  static let disabledInk = NSColor.white.withAlphaComponent(0.2)

  static let sendDisc: CGFloat = 28
  static let sendGap: CGFloat = gap / 2
  static let sendIconSize: CGFloat = 16
  static let sendFill = NSColor.white
  static let sendHoverFill = NSColor.white.withAlphaComponent(0.85)
  static let sendInk = NSColor.black
  static let sendDisabledFill = PaletteInk.fill
  static let sendDisabledInk = NSColor.white.withAlphaComponent(0.35)
  static func sendIcon(_ icon: BolttyIcon, description: String) -> NSImage? {
    icon.image(size: sendIconSize, description: description)
  }

  @MainActor
  static func styleSendDisc(_ button: PaletteIconButton) {
    button.restingTint = sendInk
    button.hoverTint = sendInk
    button.disabledTint = sendDisabledInk
  }

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
