import AppKit

enum ComposerChord: CaseIterable {
  case dictate, folder, attach, model

  init?(key: String, modifiers: NSEvent.ModifierFlags) {
    guard let chord = Self.allCases.first(where: {
      $0.key == key && $0.modifiers == modifiers
    }) else { return nil }
    self = chord
  }

  var key: String {
    switch self {
    case .dictate: "d"
    case .folder: "o"
    case .attach: "a"
    case .model: "m"
    }
  }

  var modifiers: NSEvent.ModifierFlags {
    self == .attach || self == .model ? [.command, .shift] : [.command]
  }

  var display: String {
    switch self {
    case .dictate: "⌘D"
    case .folder: "⌘O"
    case .attach: "⇧⌘A"
    case .model: "⇧⌘M"
    }
  }
}

enum PromptLinkStyle {
  static let color = HexColor.nsColor("#5AC8FA")
  static let key = NSAttributedString.Key("boltty.promptLink")
}

final class PromptTextView: NSTextView {
  var onPaste: ((Bool) -> Void)?
  var onCommandPeriod: (() -> Bool)?
  var onCommandReturn: (() -> Bool)?
  var onCommandN: (() -> Bool)?
  var onComposerChord: ((ComposerChord) -> Bool)?
  var onMouseDown: (() -> Void)?

  var trailingHint: [PromptKeyHint] = [] {
    didSet {
      guard trailingHint != oldValue else { return }
      syncTrailingHintView(animated: true)
    }
  }
  var trailingHintDelay = AgentPaletteMetrics.keyHintDelay
  private let trailingHintView = PromptKeyHintView()
  private var trailingHintLeading: NSLayoutConstraint?
  private var trailingHintTop: NSLayoutConstraint?
  private var trailingHintTimer: Timer?
  private var trailingHintIsDue = false
  private(set) var isTrailingHintShown = false

  private(set) var usesExpandedStyle = false
  var maximumViewportHeight: CGFloat?

  func setExpandedStyle(_ expanded: Bool) {
    guard usesExpandedStyle != expanded else { return }
    usesExpandedStyle = expanded
    syncVerticalInset()
    minSize.height = Self.textOnlyLineHeight
    layoutManager?.invalidateLayout(
      forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0),
      actualCharacterRange: nil
    )
  }

  private(set) var attachments: [PromptAttachment] = []

  var onAttachmentsChange: ((_ animated: Bool) -> Void)?

  var draft: PromptDraft {
    var draft = PromptDraft(string)
    attachments.forEach { draft.append($0) }
    return draft
  }

  var searchQuery: String { string }

  // MARK: - The keys after the text

  var trailingHintFrame: NSRect? { fittedTrailingHint?.frame }

  private var fittedTrailingHint: (keys: [PromptKeyHint], frame: NSRect)? {
    guard !trailingHint.isEmpty,
          let layoutManager, let textContainer,
          let storage = textStorage, storage.length > 0,
          !storage.string.hasSuffix("\n")
    else { return nil }
    let last = layoutManager.glyphIndexForCharacter(at: storage.length - 1)
    let line = layoutManager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
    let glyph = layoutManager.boundingRect(
      forGlyphRange: NSRange(location: last, length: 1), in: textContainer)
    let baseline = line.maxY - layoutManager.typesetter.baselineOffset(
      in: layoutManager, glyphIndex: last)
    let font = trailingHintFont
    let origin = textContainerOrigin
    let room = origin.x + textContainer.size.width - textContainer.lineFragmentPadding
    for count in stride(from: trailingHint.count, through: 1, by: -1) {
      let keys = Array(trailingHint.prefix(count))
      let size = PromptKeyHintView.size(of: keys, font: font)
      let frame = NSRect(
        x: origin.x + glyph.maxX + PromptKeyHintView.spacing(font),
        y: origin.y + baseline - PromptKeyHintView.baselineFromTop(font),
        width: size.width, height: size.height)
      if frame.maxX <= room { return (keys, frame) }
    }
    return nil
  }

  private var trailingHintFont: NSFont {
    PromptKeyHintView.font(following: isChatComposer ? Self.chatComposerFont : Self.promptFont)
  }

  private func holdTrailingHint() {
    trailingHintIsDue = false
    trailingHintTimer?.invalidate()
    let timer = Timer(timeInterval: trailingHintDelay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.trailingHintRested() }
    }
    RunLoop.main.add(timer, forMode: .common)
    trailingHintTimer = timer
    syncTrailingHintView(animated: false)
  }

  private func trailingHintRested() {
    trailingHintTimer?.invalidate()
    trailingHintTimer = nil
    trailingHintIsDue = true
    syncTrailingHintView(animated: true)
  }

  func syncTrailingHintView(animated: Bool = false) {
    guard trailingHintIsDue, let fitted = fittedTrailingHint,
          let scroll = enclosingScrollView, let host = scroll.superview,
          visibleRect.minY <= fitted.frame.midY, fitted.frame.midY <= visibleRect.maxY
    else { return setTrailingHintShown(false, animated: animated) }
    let (keys, frame) = fitted
    if trailingHintView.superview !== host {
      trailingHintView.removeFromSuperview()
      trailingHintView.translatesAutoresizingMaskIntoConstraints = false
      trailingHintView.wantsLayer = true
      trailingHintView.alphaValue = 0
      host.addSubview(trailingHintView, positioned: .above, relativeTo: scroll)
      let leading = trailingHintView.leadingAnchor.constraint(equalTo: scroll.leadingAnchor)
      let top = trailingHintView.topAnchor.constraint(equalTo: scroll.topAnchor)
      NSLayoutConstraint.activate([leading, top])
      (trailingHintLeading, trailingHintTop) = (leading, top)
    }
    trailingHintView.font = trailingHintFont
    trailingHintView.keys = keys
    let inScroll = scroll.convert(frame, from: self)
    trailingHintLeading?.constant = inScroll.minX - scroll.bounds.minX
    trailingHintTop?.constant = scroll.isFlipped
      ? inScroll.minY - scroll.bounds.minY
      : scroll.bounds.maxY - inScroll.maxY
    setTrailingHintShown(true, animated: animated)
  }

  private func setTrailingHintShown(_ shown: Bool, animated: Bool) {
    guard shown != isTrailingHintShown else { return }
    isTrailingHintShown = shown
    let view = trailingHintView
    view.layer?.removeAllAnimations()
    guard shown || animated else {
      view.alphaValue = 0
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = shown ? Motion.standard : Motion.quick
      context.timingFunction = shown ? Motion.emphasizedCurve : Motion.standardCurve
      view.animator().alphaValue = shown ? 1 : 0
    }
  }

  func restTrailingHintForTesting() { trailingHintRested() }
  var isTrailingHintPendingForTesting: Bool { trailingHintTimer != nil }
  var trailingHintViewForTesting: PromptKeyHintView { trailingHintView }

  // MARK: - The caret

  private let caretView = PromptCaretView()
  private var caretLeading: NSLayoutConstraint?
  private var caretTop: NSLayoutConstraint?
  private var caretWidth: NSLayoutConstraint?
  private var caretHeight: NSLayoutConstraint?
  private var caretWindowObservers: [NSObjectProtocol] = []
  private(set) var isCaretShown = false

  var suppressesCaret = false {
    didSet { if suppressesCaret != oldValue { syncCaret() } }
  }

  override var insertionPointColor: NSColor! {
    get { super.insertionPointColor }
    set {
      caretView.color = newValue ?? AgentPaletteView.promptTypingTextColor
      super.insertionPointColor = .clear
    }
  }

  /// The sentence's face, never `font`, which answers with the first character's.
  private var caretFont: NSFont { isChatComposer ? Self.chatComposerFont : Self.promptFont }

  var caretBarRect: NSRect? {
    guard let layoutManager, let textContainer, let storage = textStorage else { return nil }
    let selection = selectedRange()
    guard selection.length == 0, storage.editedMask.isEmpty else { return nil }
    layoutManager.ensureLayout(for: textContainer)
    let font = caretFont
    let index = selection.location
    let x: CGFloat
    let baseline: CGFloat
    if storage.length == 0 || (index >= storage.length && storage.string.hasSuffix("\n")) {
      let extra = layoutManager.extraLineFragmentRect
      x = extra.minX + textContainer.lineFragmentPadding
      baseline = extra.minY + layoutManager.defaultBaselineOffset(for: font)
    } else {
      let glyph = layoutManager.glyphIndexForCharacter(at: min(index, storage.length - 1))
      let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let location = layoutManager.location(forGlyphAt: glyph)
      baseline = line.maxY - layoutManager.typesetter.baselineOffset(
        in: layoutManager, glyphIndex: glyph)
      x = index < storage.length
        ? line.minX + location.x
        : layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).maxX
    }
    let width = max(1, (font.pointSize * AgentPaletteMetrics.caretWidthPerPoint * 2).rounded() / 2)
    let height = font.capHeight + font.pointSize * AgentPaletteMetrics.caretReachPerPoint * 2
    let origin = textContainerOrigin
    return NSRect(
      x: origin.x + x - width / 2,
      y: origin.y + baseline - font.capHeight / 2 - height / 2,
      width: width, height: height)
  }

  private var caretLook: PromptCaretView.Look? {
    guard let bar = caretBarRect else { return nil }
    let size = caretFont.pointSize
    return PromptCaretView.Look(
      barSize: bar.size,
      glowMargin: (size * AgentPaletteMetrics.caretGlowMarginPerPoint).rounded(.up),
      glowSpread: size * AgentPaletteMetrics.caretGlowSpreadPerPoint,
      glowBlur: size * AgentPaletteMetrics.caretGlowBlurPerPoint,
      glowAlpha: AgentPaletteMetrics.caretGlowAlpha)
  }

  private var ownsCaret: Bool {
    guard let window, window.isKeyWindow, window.firstResponder === self else { return false }
    return !isHiddenOrHasHiddenAncestor
  }

  func syncCaret(restartBlink: Bool = false) {
    guard !suppressesCaret, ownsCaret, let bar = caretBarRect, let look = caretLook,
          let scroll = enclosingScrollView, let host = scroll.superview,
          visibleRect.minY <= bar.midY, bar.midY <= visibleRect.maxY
    else { return setCaretShown(false) }
    if caretView.superview !== host {
      caretView.removeFromSuperview()
      caretView.translatesAutoresizingMaskIntoConstraints = false
      caretView.glowColors = Self.caretGlowColors(of: caretPalette)
      host.addSubview(caretView, positioned: .above, relativeTo: scroll)
      let leading = caretView.leadingAnchor.constraint(equalTo: scroll.leadingAnchor)
      let top = caretView.topAnchor.constraint(equalTo: scroll.topAnchor)
      let width = caretView.widthAnchor.constraint(equalToConstant: 0)
      let height = caretView.heightAnchor.constraint(equalToConstant: 0)
      NSLayoutConstraint.activate([leading, top, width, height])
      (caretLeading, caretTop, caretWidth, caretHeight) = (leading, top, width, height)
    }
    caretView.apply(look)
    let size = PromptCaretView.size(for: look)
    let frame = bar.insetBy(dx: -look.glowMargin, dy: -look.glowMargin)
    let inScroll = scroll.convert(frame, from: self)
    caretLeading?.constant = inScroll.minX - scroll.bounds.minX
    caretTop?.constant = scroll.isFlipped
      ? inScroll.minY - scroll.bounds.minY
      : scroll.bounds.maxY - inScroll.maxY
    caretWidth?.constant = size.width
    caretHeight?.constant = size.height
    let arriving = !isCaretShown
    setCaretShown(true)
    if arriving || restartBlink {
      caretView.restartBlink(
        delay: AgentPaletteMetrics.caretBlinkDelay, period: AgentPaletteMetrics.caretBlinkPeriod)
    }
  }

  private func setCaretShown(_ shown: Bool) {
    isCaretShown = shown
    caretView.isHidden = !shown
  }

  var caretPalette: MascotPalette? {
    didSet { if caretPalette != oldValue { caretView.glowColors = Self.caretGlowColors(of: caretPalette) } }
  }

  private static func caretGlowColors(of palette: MascotPalette?) -> [NSColor] {
    let glow = (palette ?? MascotPalette.face(for: nil)).glowColors
    return [glow[0], glow[2], glow[1]]
  }

  override func setSelectedRanges(
    _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
  ) {
    super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    syncCaret(restartBlink: true)
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    syncCaret(restartBlink: true)
    return became
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { setCaretShown(false) }
    return resigned
  }

  override func viewDidHide() {
    super.viewDidHide()
    setCaretShown(false)
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    syncCaret(restartBlink: true)
  }

  private func observeCaretWindow() {
    caretWindowObservers.forEach(NotificationCenter.default.removeObserver)
    caretWindowObservers = []
    guard let window else { return setCaretShown(false) }
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      caretWindowObservers.append(NotificationCenter.default.addObserver(
        forName: name, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.syncCaret(restartBlink: true) }
      })
    }
  }

  var caretViewForTesting: PromptCaretView { caretView }

  var isEmptyPrompt: Bool { (textStorage?.length ?? 0) == 0 }
  var isWhollyEmpty: Bool { isEmptyPrompt && attachments.isEmpty }

  var isCaretOnFirstLine: Bool {
    guard let layoutManager, let storage = textStorage, storage.length > 0 else { return true }
    if let textContainer { layoutManager.ensureLayout(for: textContainer) }
    let caret = selectedRange().location
    guard caret > 0 else { return true }
    let firstLine = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
    if caret == storage.length, layoutManager.extraLineFragmentTextContainer != nil {
      return abs(layoutManager.extraLineFragmentRect.minY - firstLine.minY) < 0.5
    }
    let caretGlyph = layoutManager.glyphIndexForCharacter(at: min(caret, storage.length - 1))
    let caretLine = layoutManager.lineFragmentRect(forGlyphAt: caretGlyph, effectiveRange: nil)
    return abs(caretLine.minY - firstLine.minY) < 0.5
  }

  func notifyContentHeightIfNeeded() {
    let height = clampedContentHeight
    guard abs(height - lastReportedContentHeight) > 0.5 else { return }
    lastReportedContentHeight = height
    onContentHeightChange?()
  }

  func syncVerticalInset() {
    let inset = usesExpandedStyle
      ? (isChatComposer ? AgentPaletteMetrics.chatComposerGrownTextInset : AgentPaletteMetrics.promptGrownInset)
      : PromptTextView.verticalInset(font: isChatComposer ? Self.chatComposerFont : Self.promptFont)
    guard abs(textContainerInset.height - inset) > 0.01 else { return }
    textContainerInset = NSSize(width: 0, height: inset)
    syncCaret()
  }

  static let maxVisibleLines = 5

  var onContentHeightChange: (() -> Void)?

  var onWrapWidthChange: (() -> Void)?

  var clampedContentHeight: CGFloat {
    let height = measuredContentHeight
    return maximumViewportHeight.map { min(height, $0) } ?? height
  }

  private var measuredContentHeight: CGFloat {
    guard let layoutManager, let textContainer else { return Self.lineHeight }
    layoutManager.ensureLayout(for: textContainer)
    let used = layoutManager.usedRect(for: textContainer).height
    if usesExpandedStyle {
      let floor = isChatComposer
        ? Self.textOnlyLineHeight(for: Self.chatComposerFont) + textContainerInset.height * 2
        : AgentPaletteMetrics.promptSize.height
      return min(
        isChatComposer
          ? AgentPaletteMetrics.expandedPromptMaximumHeight
          : AgentPaletteMetrics.promptGrownMaximumHeight,
        max(floor, ceil(used) + textContainerInset.height * 2)
      )
    }
    let lines = max(1, min(Self.maxVisibleLines, Int(ceil(used / Self.lineHeight))))
    return CGFloat(lines) * Self.lineHeight
  }

  private var lastReportedContentHeight: CGFloat = 0

  override func setFrameSize(_ newSize: NSSize) {
    let widthMoved = abs(newSize.width - frame.width) > 0.5
    super.setFrameSize(newSize)
    guard widthMoved else { return }
    lastReportedContentHeight = clampedContentHeight
    onWrapWidthChange?()
    syncTrailingHintView()
    syncCaret()
  }

  override func layout() {
    super.layout()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    observeCaretWindow()
    syncCaret(restartBlink: true)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
  }

  func styleLinks() {
    guard let storage = textStorage else { return }
    let wanted = PromptAttachmentKind.linkRanges(in: storage.string)
    var styled: [NSRange] = []
    storage.enumerateAttribute(
      PromptLinkStyle.key, in: NSRange(location: 0, length: storage.length)
    ) { value, range, _ in
      if value != nil { styled.append(range) }
    }
    guard wanted != styled else { return }
    let ink = defaultTypingAttributes[.foregroundColor] as Any
    storage.beginEditing()
    for range in styled {
      storage.removeAttribute(PromptLinkStyle.key, range: range)
      storage.removeAttribute(.underlineStyle, range: range)
      storage.addAttribute(.foregroundColor, value: ink, range: range)
    }
    for range in wanted {
      storage.addAttributes(
        [
          PromptLinkStyle.key: true,
          .underlineStyle: NSUnderlineStyle.single.rawValue,
          .foregroundColor: PromptLinkStyle.color,
        ],
        range: range)
    }
    storage.endEditing()
  }

  override func didChangeText() {
    holdTrailingHint()
    styleLinks()
    super.didChangeText()
    syncVerticalInset()
    notifyContentHeightIfNeeded()
    scrollRangeToVisible(selectedRange())
    syncCaret(restartBlink: true)
  }

  static var promptFont: NSFont {
    roundedAppFont(size: AgentPaletteMetrics.promptFontSize)
  }

  static var lineHeight: CGFloat {
    let font = promptFont
    let text = ceil(font.ascender - font.descender + font.leading)
    return max(text, restingLineHeight(for: font))
  }

  private static func restingLineHeight(for font: NSFont) -> CGFloat {
    let height = (font.pointSize * AgentPaletteMetrics.promptLineHeightPerPoint * 2).rounded() / 2
    let descent = height / 2 - font.capHeight / 2
    return ceil(max(font.ascender, height - descent) + max(-font.descender, descent))
  }

  var wrapsBeyondOneLine: Bool {
    guard let layoutManager, let textContainer else { return false }
    layoutManager.ensureLayout(for: textContainer)
    return layoutManager.usedRect(for: textContainer).height > Self.textOnlyLineHeight + 0.5
  }

  var storageFontSizeForTesting: CGFloat {
    guard let textStorage, textStorage.length > 0 else { return Self.promptFont.pointSize }
    let font = textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    return font?.pointSize ?? Self.promptFont.pointSize
  }

  var isScrollable: Bool {
    guard let layoutManager, let textContainer else { return false }
    layoutManager.ensureLayout(for: textContainer)
    return layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2
      > clampedContentHeight + 0.5
  }

  static var textOnlyLineHeight: CGFloat { textOnlyLineHeight(for: promptFont) }
  static func textOnlyLineHeight(for font: NSFont) -> CGFloat {
    ceil(font.ascender - font.descender + font.leading)
  }

  static func verticalInset(font: NSFont = promptFont) -> CGFloat {
    max(0, (lineHeight - textOnlyLineHeight(for: font)) / 2)
  }

  static var firstBaselineOffsetFromTop: CGFloat {
    firstBaselineOffsetFromTop(for: promptFont)
  }

  static func firstBaselineOffsetFromTop(for font: NSFont) -> CGFloat {
    verticalInset(font: font) + typesetBaseline(for: font)
  }

  static func typesetBaseline(for font: NSFont) -> CGFloat {
    baselineProbe.defaultBaselineOffset(for: font)
  }
  private static let baselineProbe = NSLayoutManager()

  var typedBaselineFromTop: CGFloat {
    textContainerInset.height + Self.typesetBaseline(for: font ?? Self.promptFont)
  }

  static var chatComposerFont: NSFont {
    roundedAppFont(size: AgentPaletteMetrics.previewBodyFontSize)
  }

  private var isChatComposer = false
  func setChatComposerStyle(_ chat: Bool) {
    guard chat != isChatComposer else { return }
    isChatComposer = chat
    let font = chat ? Self.chatComposerFont : Self.promptFont
    self.font = font
    if let textStorage, textStorage.length > 0 {
      textStorage.addAttribute(.font, value: font, range: NSRange(location: 0, length: textStorage.length))
    }
    typingAttributes = defaultTypingAttributes
    syncVerticalInset()
    syncCaret()
  }

  var defaultTypingAttributes: [NSAttributedString.Key: Any] {
    [
      .font: isChatComposer ? Self.chatComposerFont : Self.promptFont,
      // Never `textColor`, which answers with the first character's: a link
      // opening the text would turn the sentence the link's blue.
      .foregroundColor: AgentPaletteView.promptTypingTextColor,
    ]
  }

  // MARK: - Editing

  func setDraft(_ draft: PromptDraft) {
    let (words, attachments) = draft.separated
    textStorage?.setAttributedString(NSAttributedString(string: words, attributes: defaultTypingAttributes))
    typingAttributes = defaultTypingAttributes
    setSelectedRange(NSRange(location: textStorage?.length ?? 0, length: 0))
    undoManager?.removeAllActions(withTarget: self)
    if attachments != self.attachments {
      self.attachments = attachments
      onAttachmentsChange?(false)
    }
    didChangeText()
  }

  func replaceTail(from location: Int, with text: String) {
    guard let textStorage, location >= 0, location <= textStorage.length else { return }
    let range = NSRange(location: location, length: textStorage.length - location)
    textStorage.replaceCharacters(
      in: range,
      with: NSAttributedString(string: text, attributes: defaultTypingAttributes)
    )
    typingAttributes = defaultTypingAttributes
    setSelectedRange(NSRange(location: textStorage.length, length: 0))
    didChangeText()
  }

  func clearPrompt() {
    textStorage?.setAttributedString(NSAttributedString())
    typingAttributes = defaultTypingAttributes
    setSelectedRange(NSRange(location: 0, length: 0))
    undoManager?.removeAllActions(withTarget: self)
    if !attachments.isEmpty {
      attachments = []
      onAttachmentsChange?(false)
    }
    didChangeText()
  }

  func insertAttachments(_ new: [PromptAttachment]) {
    guard !new.isEmpty else { return }
    changeAttachments(to: attachments + new)
  }

  func removeAttachment(id: UUID) {
    guard attachments.contains(where: { $0.id == id }) else { return }
    changeAttachments(to: attachments.filter { $0.id != id })
  }

  func removeLastAttachmentFromFieldStart() -> Bool {
    guard selectedRange() == NSRange(location: 0, length: 0), let last = attachments.last else {
      return false
    }
    removeAttachment(id: last.id)
    return true
  }

  private func changeAttachments(to next: [PromptAttachment]) {
    let previous = attachments
    breakUndoCoalescing()
    undoManager?.registerUndo(withTarget: self) { field in
      MainActor.assumeIsolated { field.changeAttachments(to: previous) }
    }
    attachments = next
    onAttachmentsChange?(true)
    didChangeText()
  }

  func insertPlainText(_ text: String) {
    insertText(
      NSAttributedString(string: text, attributes: defaultTypingAttributes),
      replacementRange: selectedRange()
    )
    typingAttributes = defaultTypingAttributes
  }

  // MARK: - Pointer

  override func mouseDown(with event: NSEvent) {
    onMouseDown?()
    super.mouseDown(with: event)
  }

  override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }

  // MARK: - Paste

  override func paste(_ sender: Any?) {
    onPaste?(false)
  }

  override func pasteAsPlainText(_ sender: Any?) {
    onPaste?(true)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .intersection([.command, .shift, .option, .control])
    let key = event.latinCharactersIgnoringModifiers
    if key == ".", modifiers == [.command], onCommandPeriod?() == true {
      return true
    }
    if key == "n", modifiers == [.command], onCommandN?() == true {
      return true
    }
    if let key, let chord = ComposerChord(key: key, modifiers: modifiers),
       onComposerChord?(chord) == true {
      return true
    }
    if event.keyCode == 36 || event.keyCode == 76, modifiers == [.command],
       onCommandReturn?() == true {
      return true
    }
    guard key == "v" else {
      return super.performKeyEquivalent(with: event)
    }
    if modifiers == [.command, .shift] {
      pasteAsPlainText(nil)
      return true
    }
    if modifiers == [.command] {
      paste(nil)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  // MARK: - Configuration

  static func makeInScrollView() -> (scrollView: NSScrollView, textView: PromptTextView) {
    let scrollView = NSScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.verticalScrollElasticity = .none
    scrollView.horizontalScrollElasticity = .none
    scrollView.autohidesScrollers = true

    let container = NSTextContainer(
      size: NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      )
    )
    container.widthTracksTextView = true
    container.heightTracksTextView = false
    container.lineFragmentPadding = 0

    let layoutManager = NSLayoutManager()
    layoutManager.addTextContainer(container)
    let storage = NSTextStorage()
    storage.addLayoutManager(layoutManager)

    let textView = PromptTextView(frame: .zero, textContainer: container)
    textView.configureAsPrompt()
    scrollView.documentView = textView

    return (scrollView, textView)
  }

  private func configureAsPrompt() {
    drawsBackground = false
    isRichText = false
    writingToolsBehavior = .none
    importsGraphics = false
    allowsUndo = true
    isEditable = true
    isSelectable = true
    usesFindPanel = false
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
    isAutomaticTextReplacementEnabled = false
    isAutomaticSpellingCorrectionEnabled = false
    updateDragTypeRegistration()
    syncVerticalInset()

    isHorizontallyResizable = false
    isVerticallyResizable = true
    minSize = NSSize(width: 0, height: PromptTextView.lineHeight)
    maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )

    font = Self.promptFont
    textColor = AgentPaletteView.promptTypingTextColor
    insertionPointColor = AgentPaletteView.promptTypingTextColor
    typingAttributes = defaultTypingAttributes
    setAccessibilityIdentifier("boltty.ask.input")
  }
}

struct PromptKeyHint: Equatable {
  let words: String
  let key: String
}

final class PromptKeyHintView: NSView {
  var keys: [PromptKeyHint] = [] {
    didSet { if keys != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } }
  }
  var font = PromptKeyHintView.font(following: PromptTextView.promptFont) {
    didSet { if font != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } }
  }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var intrinsicContentSize: NSSize { Self.size(of: keys, font: font) }

  static func font(following typed: NSFont) -> NSFont { typed }

  static func spacing(_ font: NSFont) -> CGFloat {
    AgentPaletteMetrics.onPixelGrid(NSAttributedString(string: " ", attributes: [.font: font]).size().width)
  }
  static func height(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender) }
  static func baselineFromTop(_ font: NSFont) -> CGFloat { AgentPaletteMetrics.onPixelGrid(font.ascender) }

  static func text(of keys: [PromptKeyHint], font: NSFont) -> NSAttributedString {
    let text = NSMutableAttributedString()
    let first: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: PaletteInk.secondary]
    let rest: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: PaletteInk.tertiary]
    for (index, hint) in keys.enumerated() {
      if index == 0 {
        text.append(NSAttributedString(string: "\u{2014} \(hint.words)", attributes: first))
      } else {
        text.append(NSAttributedString(string: " \u{00B7} \(hint.words) \(hint.key)", attributes: rest))
      }
    }
    return text
  }

  static func size(of keys: [PromptKeyHint], font: NSFont) -> NSSize {
    guard !keys.isEmpty else { return .zero }
    return NSSize(width: ceil(text(of: keys, font: font).size().width), height: height(font))
  }

  var drawnText: String { Self.text(of: keys, font: font).string }

  override func draw(_ dirtyRect: NSRect) {
    Self.text(of: keys, font: font).draw(
      at: NSPoint(x: 0, y: Self.baselineFromTop(font) - font.ascender))
  }
}
