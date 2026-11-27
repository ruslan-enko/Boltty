import AppKit
import Foundation

enum AgentPaletteMetrics {
  static var surfaceResponse: CGFloat { live(0.3) }
  static var surfaceContentDuration: TimeInterval { Motion.standard }

  enum SurfaceShape {
    case pill
    case initial
    case chat
    case list
  }

  static var cardCornerRadius: CGFloat { chatComposerRestingCornerRadius + shellContentInset }

  static var shellContentInset: CGFloat { live(12) }

  static let chatComposerCornerRadius: CGFloat = fromMock(100)

  static var chatComposerRestingCornerRadius: CGFloat { (chatComposerBoxHeight / (2 * continuousCornerWallReach)).rounded(.down) }

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
  static var chatComposerBoxHeight: CGFloat {
    chatComposerPadding + chatComposerControlsPadding
    + chatComposerGap
    + ComposerControlGroup.glyph + {
      // `PromptTextView.textOnlyLineHeight(for: chatComposerFont)`, which is
      // the main actor's; the same sum, read off the same face.
      let font = roundedAppFont(size: previewBodyFontSize)
      return ceil(font.ascender - font.descender + font.leading)
    }()
  }
  static var chatComposerInkInset: CGFloat { live(16) }
  static var chatComposerLeadingPadding: CGFloat { chatComposerInkInset - 1 }
  static var chatComposerPadding: CGFloat { chatComposerInkInset - 3.5 }
  static var chatComposerControlsPadding: CGFloat { chatComposerInkInset }
  static var chatComposerGap: CGFloat { live(16) }
  static let chatComposerGrownTextInset: CGFloat = 2.5
  static var chatComposerGrownTextTop: CGFloat { chatComposerPadding - chatComposerGrownTextInset }
  static var chatComposerGrownControlsBand: CGFloat { chatComposerGap - chatComposerGrownTextInset + ComposerControlGroup.glyph + chatComposerControlsPadding }
  static var chatComposerPlaceholderInk: NSColor { ComposerControlGroup.restingInk }
  static var chatComposerControlDiameter: CGFloat { ComposerControlGroup.target }
  static var chatComposerTextLeading: CGFloat { chatComposerLeadingPadding }
  static var chatComposerControlsTrailingInset: CGFloat { chatComposerControlsPadding - (ComposerControlGroup.target - ComposerControlGroup.glyph) / 2 }
  static var chatComposerSendDiscInset: CGFloat { chatComposerControlsPadding + ComposerControlGroup.glyph / 2 - ComposerControlGroup.sendDisc / 2 }
  static var chatComposerTextControlsGap: CGFloat {
    onPixelGrid(fromMock(10) - (chatComposerControlDiameter - 18) / 2)
  }
  static let chatComposerMicSpacing: CGFloat = fromMock(10)

  static let mockScale: CGFloat = 0.75
  static func fromMock(_ value: CGFloat) -> CGFloat { onPixelGrid(value / mockScale) }
  static func onPixelGrid(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }

  static let promptSize = CGSize(width: 540, height: 92)
  static var promptGrownWidth: CGFloat { live(680) }
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
  static var restingControlsTrailingInset: CGFloat {
    onPixelGrid(restingControlsInkInset - ComposerControlGroup.gap(chat: false) / 2)
  }
  static let restingControlsInkInset = onPixelGrid(fromInitialPromptMock(40) * promptPaddingGrowth)
  static let iconSize: CGFloat = fromMock(25)
  static var iconScale: CGFloat { live(1.15) }
  static func iconSide(_ size: CGFloat) -> CGFloat { (size * iconScale * 2).rounded() / 2 }

  static let mascotOversize: CGFloat = 1.15
  static let promptMascotScale: CGFloat = 1.15 * 1.10
  static let promptMascotSize: CGFloat = iconSize * mascotOversize * promptMascotScale
  static let promptMascotSupersampling: CGFloat = 2
  static var promptMascotOverhang: CGFloat { (promptMascotSize - iconSize) / 2 }
  static let promptMarkHitSize: CGFloat = max(44, promptMascotSize.rounded(.up))
  static let cornerRadius: CGFloat = promptSize.height / 2
  static let safeAreaX: CGFloat = 50
  static let safeAreaY: CGFloat = 50

  static var typePrimary: CGFloat { live(18) }
  static var typeSecondary: CGFloat { live(15) }
  static var typeChat: CGFloat { live(15) }
  static var typeMeta: CGFloat { live(13) }
  static let typeFootnote: CGFloat = NSFont.systemFontSize(for: .small)

  static var promptFontSize: CGFloat { live(20) }

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
  static let screenSelectionHintText = String(localized: "Drag to ask about an area")
  static let screenSelectionChatHintText = String(localized: "Drag to add an area")
  static let regionHintUses = 3
  static let regionsDrawnKey = "boltty.selection.regionsDrawn"
  static let screenSelectionHintOffset = CGSize(width: 14, height: 24)
  static var screenSelectionHintDelay: TimeInterval { helpTagDelay }
  static let screenSelectionGlowWidth: CGFloat = 10
  static let screenSelectionInnerGlowDepth: CGFloat = 20
  static let screenSelectionInnerGlowStrength: CGFloat = 0.14
  static let screenSelectionHaloReach: CGFloat = 10
  static let screenSelectionHaloStrength: CGFloat = 0.3
  static let screenSelectionWaveAmplitude: CGFloat = 0.26
  static let screenSelectionDriftAmplitude: CGFloat = 0.2
  static let screenSelectionLightness: Double = 0.72
  static let screenSelectionHandleDiameter: CGFloat = 9
  static let screenSelectionMidHandleSide: CGFloat = 120
  static let screenSelectionHandleReach: CGFloat = 12
  static let screenSelectionDim: CGFloat = 0.4
  static let screenSelectionShellGap: CGFloat = 16
  static let regionSeedSide: CGFloat = 12
  static let regionMicrophoneWait: TimeInterval = 0.8
  static let regionWordsWait: TimeInterval = 0.6
  static let regionCardWordsWait: TimeInterval = 1.5
  static let regionMicrophoneRetry: TimeInterval = 0.6
  static let regionHandOverDuration: CFTimeInterval = 0.26

  static let keyHintDelay: TimeInterval = 1

  static var attachmentCardSide: CGFloat { live(100) }
  static var attachmentCardGap: CGFloat { live(8) }
  static var attachmentCardInset: CGFloat { live(11) }
  static let attachmentCardLines = 3
  static let attachmentCardLineHeight: CGFloat = 16
  static let attachmentCardPressedScale: CGFloat = 0.97
  static var attachmentThumbnailSide: CGFloat { attachmentCardSide * 2 }
  static var attachmentTagHeight: CGFloat { live(18) }
  static let attachmentTagPadding: CGFloat = 7
  static var attachmentTagFill: NSColor { PaletteInk.tertiaryFill }
  static let attachmentCloseOverhang: CGFloat = 8
  static let attachmentCloseDiameter: CGFloat = 22
  static let attachmentCloseGlyph: CGFloat = 11
  static let attachmentCardAppearDuration: TimeInterval = 0.16
  static let attachmentCardAppearScale: CGFloat = 0.94
  static let attachmentStripFadeWidth: CGFloat = 28
  static let attachmentStripWheelStep: CGFloat = 8

  @MainActor static let attachmentStripOnFirstScreen = PromptAttachmentStrip.Placement(
    inset: 20, corner: cornerRadius - 20)
  @MainActor static var attachmentStripInChat: PromptAttachmentStrip.Placement {
    PromptAttachmentStrip.Placement(inset: chatComposerInkInset, corner: attachmentCardCornerInChat)
  }
  static var attachmentCardCornerInChat: CGFloat { chatComposerRestingCornerRadius - chatComposerInkInset }

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
  static let chatDictationWaveHeight: CGFloat = 20
  static let chatDictationBarWidth: CGFloat = 2
  static let chatDictationBarGap: CGFloat = 2
  static let chatDictationBarMinimum: CGFloat = 2
  static let chatDictationWaveStep: TimeInterval = 1.0 / 30
  static let chatDictationWaveGain: CGFloat = 1.4
  static let chatDictationWaveAttack: CGFloat = 0.03
  static let chatDictationWaveRelease: CGFloat = 0.12

  static let voiceControlsIconSize: CGFloat = fromMock(16)
  static let voiceControlsTimerFontSize: CGFloat = fromMock(12)
  static let voiceControlsCancelGlyphColor = PaletteInk.primary
  static let voiceControlsConfirmFillColor = NSColor.white
  static let voiceControlsConfirmGlyphColor = NSColor.black
  static let voiceControlsConfirmHoverFillColor = NSColor.white
  static var voiceControlsCancelHoverFillColor: NSColor { PaletteInk.fill }
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

  static var previewCloseDiameter: CGFloat { live(36) }
  static var previewCloseGlyphPointSize: CGFloat { live(18) }
  static let discArrowGlyphPointSize: CGFloat = 15.5
  static let previewCloseGlyphNudge: CGFloat = 1.5
  static var previewCloseInset: CGFloat {
    let radius = previewCloseDiameter / 2
    let fromArcCentre = cardCornerRadius - shellContentInset - radius
    return onPixelGrid(cardCornerRadius - fromArcCentre / 2.squareRoot() - radius)
  }
  static var historyFootDiscInset: CGFloat { live(18) }
  static var historyLimitsWidth: CGFloat { live(80) }
  static var historyLimitsBarWidth: CGFloat { live(48) }
  static var historyLimitsBarHeight: CGFloat { live(5) }
  static var historyLimitsBarGap: CGFloat { live(5) }
  static let historyLimitsMaxBars = 2
  static var historyFootHeight: CGFloat { historyFootDiscInset + previewCloseDiameter + previewContentVerticalPadding }

  static var previewHeaderHeight: CGFloat { previewCloseInset + previewCloseDiameter + previewContentVerticalPadding }

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

  static var listeningOrbDiameter: CGFloat { live(84) }
  static var listeningFaceSize: CGFloat { live(48) }
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
  static var listeningWordsInset: CGFloat { live(30) }
  static var listeningWordsFontSize: CGFloat { typePrimary }
  static var listeningMaxWidth: CGFloat { live(380) }
  static var listeningWordArrival: CFTimeInterval { live(1.1) }
  static let listeningWordBlur: CGFloat = 9
  static let listeningWordRise: CGFloat = 4
  static let listeningWordStagger: CFTimeInterval = 0.09
  static let listeningWordGlide: CFTimeInterval = 0.14

  static var controlPressedScale: CGFloat { live(0.95) }
  static var rowPressedScale: CGFloat { live(0.985) }
  static var hoverFadeDuration: TimeInterval { Motion.quick }
  static var helpTagDelay: TimeInterval { live(0.45) }
  static let helpTagWarmWindow: TimeInterval = 0.5

  static let panelFadeOutDuration: TimeInterval = 0.10
  static var lockedTopGap: CGFloat { live(30) }

  static var dripInPace: CGFloat { live(0.65) }
  static var dripInDuration: TimeInterval { TimeInterval(0.6 * dripInPace) }
  static let dripOutDuration: TimeInterval = 0.38
  static var dripFallResponse: CGFloat { 0.26 * dripInPace }
  static var dripSpreadAfter: TimeInterval { TimeInterval(0.11 * dripInPace) }
  static var dripSpreadResponse: CGFloat { 0.3 * dripInPace }
  static let dripShrinkResponse: CGFloat = 0.18
  static let dripRiseAfter: TimeInterval = 0.08
  static let dripRiseResponse: CGFloat = 0.2
  static var dripContentInAfter: TimeInterval { TimeInterval(0.12 * dripInPace) }
  static var dripContentInDuration: TimeInterval { TimeInterval(0.24 * dripInPace) }
  static let dripEdgeSliver: CGFloat = 8
  static let dripSeed: CGFloat = 0.5
  static let dripFallWidth: CGFloat = 0.8
  static let dripFallHeight: CGFloat = 0.92

  static let resultsTopSpacing = fromMock(6)
  static let resultsRowHeight: CGFloat = fromHistoryMock(48)
  static let resultsMaxVisibleRows = 6
  /// Measured: rendering a continuous layer at three radii gives 1.34 × radius
  /// every time.
  static let continuousCornerWallReach: CGFloat = 1.34

  static func cornerCurve(radius: CGFloat, shorterSide: CGFloat) -> CALayerCornerCurve {
    guard shorterSide > 0 else { return .continuous }
    let capped = min(radius, shorterSide / 2)
    return 2 * continuousCornerWallReach * capped <= shorterSide ? .continuous : .circular
  }

  static var resultsMascotSize: CGFloat { resultsIconFrameSize }
  static var resultsIconFrameSize: CGFloat { live(32) }
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

  static var resultsTitleFontSize: CGFloat { typeSecondary }
  static var resultsSubtitleFontSize: CGFloat { typeMeta }
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
  static var resultsUnreadDotDiameter: CGFloat { live(8) }
  static let resultsUnreadDotGap: CGFloat = 8
  static var resultsUnreadDotFill: NSColor { live(NSColor(oklch: 0.624, 0.206, 255.5)) }
  static var resultsRowFaceInset: CGFloat {
    onPixelGrid((resultsRowHeight - resultsRowInset * 2 - resultsMascotSize) / 2)
  }
  static var resultsRowFacedTextLeading: CGFloat {
    resultsRowFaceInset + resultsMascotSize + resultsRowIconTextSpacing
  }

  static let historyMockCardWidth: CGFloat = 582.67
  static let historyMockScaleWidth: CGFloat = 520
  static func fromHistoryMock(_ value: CGFloat) -> CGFloat {
    onPixelGrid(value * historyMockScaleWidth / historyMockCardWidth)
  }

  static let historyHeaderHeight: CGFloat = fromHistoryMock(50)
  static var historyHeaderFontSize: CGFloat { typeMeta }
  static let historyHeaderTextColor = PaletteInk.secondary
  static var historyHeaderBottomInset: CGFloat { live(10) }
  static let historyHeaderSeparation: CGFloat = 8
  static func historyHeaderHeight(followsRows: Bool) -> CGFloat {
    historyHeaderHeight + (followsRows ? historyHeaderSeparation : 0)
  }
  static var historyHeaderLeading: CGFloat {
    resultsRowHorizontalInset + resultsRowTextLeading
  }

  static var historyTabTopInset: CGFloat { shellContentInset }
  static let historyTabTrackPadding: CGFloat = 0
  static var historyTabPadding: CGFloat { live(10) }
  static let historyTabMascotSize: CGFloat = fromHistoryMock(40)
  static let historyTabMascotTextSpacing: CGFloat = fromHistoryMock(4)
  static let historyTabLatestMascotSize: CGFloat = fromHistoryMock(28)
  static let historyTabLatestTextSpacing: CGFloat = fromHistoryMock(6)
  static var historyTabClusterSide: CGFloat { 2 * historyTabLatestMascotSize }
  static var historyTabSegmentInset: CGFloat { live(6) }
  static var historyTabFontSize: CGFloat { typeSecondary }
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
  static var historyTabSlideResponse: CGFloat { CGFloat(Motion.standard) }
  static var historyTabHoverFill: NSColor { PaletteInk.tertiaryFill }
  static var historyRowSelectedFill: NSColor { live(NSColor.white.withAlphaComponent(0.14)) }
  static var historyRowHoverFill: NSColor { PaletteInk.secondaryFill }
  static let historyTabActiveTextColor = PaletteInk.primary
  static let historyTabTextColor = PaletteInk.secondary


  static let targetSwapBlurRadius: CGFloat = 8
  static let targetSwapBlurDuration: TimeInterval = 0.18
  static var targetSwapFadeDuration: TimeInterval { Motion.quick }

  static var previewBodyFontSize: CGFloat { typeChat }
  static var previewBodyLineHeight: CGFloat { live(18) }
  static var previewAnswerLineHeight: CGFloat { live(24) }

  static var answerHeading1FontSize: CGFloat { live(21) }
  static let answerHeading1LineHeight: CGFloat = 28
  static var answerHeading2FontSize: CGFloat { typePrimary }
  static let answerHeading2LineHeight: CGFloat = 24.5
  static var answerHeading3FontSize: CGFloat { live(16) }
  static let answerHeading1SpacingAfter: CGFloat = 7
  static let answerHeading2SpacingAfter: CGFloat = 3.5

  static var answerTableFontSize: CGFloat { typeMeta }
  static let answerTableCellVerticalPadding: CGFloat = 8.5
  static let answerTableCellTrailingPadding: CGFloat = 21
  static let answerTableRuleWidth: CGFloat = 1
  static var answerTableRule: NSColor { PaletteInk.secondaryFill }
  static var answerParagraphSpacing: CGFloat { live(16) }
  static let answerListMarkerIndent: CGFloat = 8
  static var answerListHeadIndent: CGFloat { live(21) }
  static let answerListNumberGap: CGFloat = 5
  static let answerListNestIndent: CGFloat = 22
  static let answerListItemSpacing: CGFloat = 0
  static var answerCodeFontSize: CGFloat { typeMeta }
  static var answerInlineCodeFill: NSColor { PaletteInk.fill }
  static var answerInlineCodeCornerRadius: CGFloat { live(6) }
  static let answerInlineCodeInset: CGFloat = 4
  static var answerCodeBlockCornerRadius: CGFloat { live(10) }
  static var answerCodeBlockFill: NSColor { PaletteInk.secondaryFill }
  static var answerCodeBlockVerticalPadding: CGFloat { live(14) }
  static var answerCodeBlockLeadingPadding: CGFloat { live(16) }
  static let answerCodeBlockTrailingPadding: CGFloat = 40
  static let answerCodeBlockLineHeight: CGFloat = 19.5
  static let answerCodeBlockCopyInset: CGFloat = 8
  static let answerQuoteBarWidth: CGFloat = 3.5
  static var answerQuoteBar: NSColor { PaletteInk.selectedFill }
  static let answerQuoteIndent: CGFloat = 21
  static let answerQuoteVerticalPadding: CGFloat = 7
  static let answerRuleSpacing: CGFloat = 24.5
  static let answerRuleSpacingAfter: CGFloat = 14
  static let previewContentVerticalPadding: CGFloat = fromMock(21)
  static var previewContentHorizontalPadding: CGFloat { shellContentInset }
  static let previewTopSpacing: CGFloat = 8

  static let previewOptionCornerRadius: CGFloat = 12
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

  static var previewBubbleMaxWidthFraction: CGFloat { live(0.78) }
  static func previewBubbleMaxWidth(in column: CGFloat) -> CGFloat {
    onPixelGrid(column * previewBubbleMaxWidthFraction)
  }
  static var previewUserBubbleFill: NSColor { live(NSColor.white.withAlphaComponent(0.94)) }
  static let previewUserBubbleInk = NSColor.black
  static var previewUserBubbleHorizontalPadding: CGFloat { live(13) }
  static var previewUserBubbleVerticalPadding: CGFloat { live(5.5) }
  static var previewUserBubbleCornerRadius: CGFloat { live(18) }
  static let previewMessageSpacing: CGFloat = 25.5
  static var previewQuestionAnswerSpacing: CGFloat { live(28) }

  static let lightboxDim: CGFloat = 0.7
  static let lightboxMargin: CGFloat = 48
  static let lightboxCorner: CGFloat = 12
  static let lightboxDuration: TimeInterval = 0.32
  static let lightboxMaxPixels = 6000
  static let lightboxDocumentSize = CGSize(width: 820, height: 1000)
  static var previewTurnSpacing: CGFloat { live(40) }
  static var previewAgentMessageSpacing: CGFloat { answerParagraphSpacing }

  static var previewWorkPillHeight: CGFloat { live(28) }
  static let previewWorkPillChevronGap: CGFloat = 5
  static var previewWorkPillChevronWidth: CGFloat { iconSide(12) }
  static let previewWorkPillChevronPointSize: CGFloat = 13
  static let previewWorkPillTextInset: CGFloat = 0
  static let previewWorkPillTrailingInset: CGFloat = 0
  static let previewWorkThreadX: CGFloat = 5
  static let previewWorkThreadWidth: CGFloat = 1.5
  static var previewWorkThreadFill: NSColor { PaletteInk.secondaryFill }
  static let previewWorkListInset: CGFloat = 18
  static var previewWorkPillListTop: CGFloat { previewWorkPillHeight + 2 }
  static let previewWorkPillListBottomInset: CGFloat = 4
  static let previewWorkPillSpacingAbove: CGFloat = 14
  static let previewWorkPillSpacingBelow: CGFloat = 10

  static var previewFileRowHeight: CGFloat { live(56) }
  static let previewFileRowSpacing: CGFloat = 6
  static let previewFileRowsTopMargin: CGFloat = 8
  static let previewSentFilesGap: CGFloat = 6
  static let previewFileCardWidth: CGFloat = 300
  static var previewFileCardInset: CGFloat { live(8) }
  static var previewFileIconTileCornerRadius: CGFloat { live(8) }
  static var previewFileCardCornerRadius: CGFloat { previewFileIconTileCornerRadius + previewFileCardInset }
  static var previewFileCardFill: NSColor { PaletteInk.secondaryFill }
  static var previewFileCardHoverFill: NSColor { PaletteInk.fill }
  static var previewFileIconTileSize: CGFloat { previewFileRowHeight - previewFileCardInset * 2 }
  static var previewFileIconTileFill: NSColor { PaletteInk.tertiaryFill }
  static let previewFileIconSize: CGFloat = 28
  static let previewFileButtonSize: CGFloat = 24
  static let previewFileGlyphPointSize: CGFloat = 16
  static var previewFileNameFontSize: CGFloat { typeMeta }
  static let previewFileSizeFontSize: CGFloat = typeFootnote

  static var previewActivityRowHeight: CGFloat { live(22) }
  static let previewActivityRowSpacing: CGFloat = 2
  static let previewActivityRowsTopMargin: CGFloat = 6
  static var previewActivityGlyphSize: CGFloat { iconSide(14) }
  static let previewActivityGlyphPointSize: CGFloat = 14
  static let previewActivityChevronPointSize: CGFloat = 12
  static var previewActivityNameFontSize: CGFloat { typeMeta }
  static let previewActivityDetailFontSize: CGFloat = typeFootnote
  /// Pinned: the measure ceils a bounding box while the label uses the font's
  /// leading, which clipped the last line of monospaced output.
  static let previewActivityDetailLineHeight: CGFloat = 14
  static let previewActivityDetailTopMargin: CGFloat = 4
  static let previewActivityDetailWellInset: CGFloat = 8
  static let previewActivityDetailWellCornerRadius: CGFloat = 8
  static var previewActivityDetailWellFill: NSColor { PaletteInk.tertiaryFill }
  static var previewActivityDetailIndent: CGFloat { previewActivityGlyphSize + previewActivityRowSpacing * 2 }
  static let previewActivityDetailLineCap = 40

  static var previewTurnHeaderLabelHeight: CGFloat { previewActivityRowHeight }
  static var previewTurnHeaderHeight: CGFloat { previewTurnHeaderLabelHeight }
  static let previewTurnHeaderSpacing: CGFloat = 6

  static let workingLineHeight: CGFloat = workingFaceDiameter
  static let workingLineLeadingInset: CGFloat = 2
  static var workingLineFaceSize: CGFloat { live(24) }
  static var workingLineFaceGap: CGFloat { live(10) }
  static let workingLineBreathDuration: CFTimeInterval = 1.3
  static let workingLineBreathLitLow: CGFloat = 0.15
  static let workingLineHaloBlur: CGFloat = 6
  static let workingLineHaloOpacity: CGFloat = 0.55

  static let previewCopyButtonSize: CGFloat = 30
  static let previewCopyRowHeight: CGFloat = previewCopyButtonSize + 6
  static let previewQuestionMetaRowHeight: CGFloat = 22
  static let previewQuestionMetaTopGap: CGFloat = 6
  static let previewQuestionMetaSpacing: CGFloat = 6

  static let previewScrollEdgeSoftness: CGFloat = previewContentVerticalPadding / 2
  static let scrollEdgeBlurRadius: CGFloat = 8
  static var historyTabOverlap: CGFloat { onPixelGrid(historyTabHeight * 0.45) }

  static var previewStreamingWordFade: TimeInterval { live(0.32) }
  static var previewStreamingWordSettle: TimeInterval { Motion.standard * 6 }
  static let previewStreamingWordGap: TimeInterval = 0.03
  static let previewStreamingWordLag: TimeInterval = 0.35

  static var previewRevealDuration: TimeInterval { Motion.standard }
  static let previewRevealStagger: TimeInterval = 0.06
  static let previewRevealStaggerSteps = 4

  static var previewSendFlightDuration: TimeInterval { live(0.45) }
  static let sendWordsBubbleStartScale: CGFloat = 0.9

  static var revealDuration: TimeInterval { Motion.standard * 2 }
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

  static var previewMinHeight: CGFloat { previewHeaderHeight + previewContentVerticalPadding + previewBodyLineHeight }

  static func previewCardHeight(bodyLineCount: Int) -> CGFloat {
    previewHeaderHeight + previewContentVerticalPadding
      + previewBodyLineHeight * CGFloat(max(bodyLineCount, 1))
  }

  static let resultsShadowBleed: CGFloat = 32

  static var promptNoteFontSize: CGFloat { typeMeta }

  static let previewFooterFontSize: CGFloat = typeFootnote
  static let previewFooterTextColor = PaletteInk.secondary

  static var failureCardCornerRadius: CGFloat { live(20) }
  static var failureCardPadding: CGFloat { live(16) }
  static var failureDetailsCornerRadius: CGFloat { live(12) }
  static let failureDetailsPadding: CGFloat = 12
  static let failureDetailsCopyInset: CGFloat = 6
  static let failureDetailsCopyGap: CGFloat = 8
  static var failureCardFill: NSColor { PaletteInk.secondaryFill }
  static var failureDetailsFill: NSColor { live(NSColor.black.withAlphaComponent(0.22)) }
  static let failureCardAccent = NSColor.systemOrange

  static var serviceEyebrowFontSize: CGFloat { typeMeta }
  static let serviceEyebrowGap: CGFloat = 4
  static var serviceContentGap: CGFloat { live(12) }
  static let serviceCaptionGap: CGFloat = 8
  static var serviceActionsGap: CGFloat { live(16) }
  static var serviceWellPadding: CGFloat { live(12) }
  static let serviceWellLabelFontSize: CGFloat = typeFootnote
  static let serviceWellLabelGap: CGFloat = 4
  static let serviceWellLinkGap: CGFloat = 8
  static var serviceWellCodeLineHeight: CGFloat { previewBodyLineHeight }

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
  static var helpDensity: NSColor { live(NSColor.black.withAlphaComponent(0.55)) }
  static var helpCornerRadius: CGFloat { live(10) }

  static let mentionWidth: CGFloat = 400
  static let mentionInset: CGFloat = 6
  static let mentionRowHeight: CGFloat = 30
  static let mentionRowCornerRadius: CGFloat = 8
  static let mentionCornerRadius: CGFloat = mentionRowCornerRadius + mentionInset
  static let mentionRowPadding: CGFloat = 8
  static let mentionIconSide: CGFloat = 16
  static let mentionIconGap: CGFloat = 8
  static let mentionPlaceGap: CGFloat = 12
  static let mentionGap: CGFloat = 8
  static var helpHorizontalPadding: CGFloat { live(10) }
  static var helpVerticalPadding: CGFloat { live(6) }
  static let helpLineSpacing: CGFloat = 2
  static let helpTextMaxWidth: CGFloat = 280
  static let helpKeysGap: CGFloat = 16
  static var helpKeycapSize: CGFloat { live(18) }
  static let helpKeycapCornerRadius: CGFloat = 4
  static let helpKeycapSpacing: CGFloat = 3
  static let helpKeyWordsGap: CGFloat = 6
  static let regionKeyHintsGap: CGFloat = 10
  static var keyHintsCapInset: CGFloat { live(6) }
  static var keyHintsWordsInset: CGFloat { live(14) }
  static let keyHintsFillSoftness: CGFloat = 16
  static let keyHintsIgnoredPause: CGFloat = 0.2
  static let keyHintsFillTime: CFTimeInterval = 0.16
  static let keyHintsDrainTime: CFTimeInterval = 0.22
  static let keyHintsFilledInk = NSColor.black
  static let keyHintsFilledCap = NSColor.black.withAlphaComponent(0.14)
  static let regionSilentMicrophone: TimeInterval = 5
  static let regionSoundFloor: CGFloat = 0.00005
  static let helpKeycapInset: CGFloat = 5
  static let helpActionSpacing: CGFloat = 8
  static let helpActionHeight: CGFloat = 26
  static var planRingTrack: NSColor { ComposerControlGroup.disabledInk }
  static let planRingWarningPercent = 80
  static var planRingInk: NSColor { ComposerControlGroup.restingInk }
  static var planRingDiameter: CGFloat { live(20) }
  static var planRingStroke: CGFloat { live(2.5) }
  static let planRingStrokeRatio: CGFloat = 1.3 / 13.8
  static func planRingOuterDiameter(chat: Bool) -> CGFloat {
    iconSide(ComposerControlGroup.iconSize(chat: chat)) * 13.925 / 16
  }

  static let glassButtonHeight: CGFloat = 32
  static let latestComposerSpacing: CGFloat = fromMock(6)
  static var glassButtonFontSize: CGFloat { typeMeta }
  static let directoryChipTextColor = PaletteInk.primary

  static func folderChipHeight(chat: Bool) -> CGFloat { chat ? 26 : 28 }
  static func folderChipPadding(chat: Bool) -> CGFloat { chat ? 6 : 7 }
  static func folderChipIconGap(chat: Bool) -> CGFloat { chat ? 5 : 6 }
  static func folderChipCornerRadius(chat: Bool) -> CGFloat { chat ? 6.5 : 7 }
  static func folderChipFontSize(chat: Bool) -> CGFloat { chat ? 14.5 : typeSecondary }
  static var modelChipPadding: CGFloat { live(9) }
  static let modelChipMaxWidth: CGFloat = 260
  static let modelChipLeadingGap: CGFloat = 4
  static var folderChipMaxNameWidth: CGFloat { live(120) }
  static let folderChipSlotMargin: CGFloat = 2
  static var folderChipFill: NSColor { PaletteInk.tertiaryFill }

  static let errorTopSpacing: CGFloat = 6
  static var noticeCornerRadius: CGFloat { live(18) }
  static var noticeHorizontalPadding: CGFloat { live(14) }
  static var noticeVerticalPadding: CGFloat { live(10) }
  static let noticeGlyphSpacing: CGFloat = 6
  static let noticeShellSpacing: CGFloat = 8
  static let noticeChatInset: CGFloat = 16
  static let errorMinimumHeight: CGFloat = 16
  static var errorRevealDuration: TimeInterval { Motion.standard }
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

struct PaletteCorner: Equatable {
  var radius: CGFloat
  var curve: CALayerCornerCurve

  func inset(by inset: CGFloat) -> PaletteCorner {
    PaletteCorner(radius: max(0, radius - inset), curve: curve)
  }

  func path(in rect: CGRect) -> CGPath {
    let r = min(radius, rect.width / 2, rect.height / 2)
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
  }

  static let edgeOverlap: CGFloat = 2
}

extension CALayer {
  func applyCorner(_ corner: PaletteCorner) {
    cornerRadius = corner.radius
    cornerCurve = corner.curve
  }

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

  static var fill: NSColor { live(NSColor.white.withAlphaComponent(0.10)) }
  static var secondaryFill: NSColor { live(NSColor.white.withAlphaComponent(0.08)) }
  static var tertiaryFill: NSColor { live(NSColor.white.withAlphaComponent(0.05)) }
  static var selectedFill: NSColor { live(NSColor.white.withAlphaComponent(0.20)) }
}

enum ComposerControlGroup {
  static var glyph: CGFloat { live(16) }
  static var promptGlyph: CGFloat { live(20) }
  static var gap: CGFloat { live(10) }
  static var promptGap: CGFloat { live(16) }
  static var target: CGFloat { glyph + gap }

  static func glyph(chat: Bool) -> CGFloat { chat ? glyph : promptGlyph }
  static func gap(chat: Bool) -> CGFloat { chat ? gap : promptGap }
  static func target(chat: Bool) -> CGFloat { glyph(chat: chat) + gap(chat: chat) }
  static func iconSize(chat: Bool) -> CGFloat { glyph(chat: chat) + 1 }
  static var restingInk: NSColor { live(NSColor.white.withAlphaComponent(0.5)) }
  static var hoverInk: NSColor { live(NSColor.white) }
  static var disabledInk: NSColor { live(NSColor.white.withAlphaComponent(0.2)) }

  static var sendDisc: CGFloat { live(28) }
  static var sendGap: CGFloat { gap / 2 }
  static var sendIconSize: CGFloat { live(16) }
  static var sendFill: NSColor { live(NSColor.white) }
  static var sendHoverFill: NSColor { live(NSColor.white.withAlphaComponent(0.85)) }
  static var sendInk: NSColor { live(NSColor.black) }
  static var sendDisabledFill: NSColor { PaletteInk.fill }
  static var sendDisabledInk: NSColor { live(NSColor.white.withAlphaComponent(0.35)) }
  static func sendIcon(_ icon: BolttyIcon, description: String) -> NSImage? {
    icon.image(size: AgentPaletteMetrics.iconSide(sendIconSize), description: description)
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
