import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Boltty

@MainActor
final class PromptTextViewTests: XCTestCase {
  private func makeField() -> PromptTextView {
    let (scrollView, textView) = PromptTextView.makeInScrollView()
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: PromptTextView.lineHeight)
    scrollView.layoutSubtreeIfNeeded()
    return textView
  }

  private func fileChip(_ path: String) -> PromptAttachment {
    PromptAttachment.file(URL(fileURLWithPath: path))
  }

  // MARK: - The caret

  func testTheCaretStandsCentredOnTheCapitals() throws {
    let field = makeField()
    let font = try XCTUnwrap(field.font)
    func check(_ label: String) throws {
      let bar = try XCTUnwrap(field.caretBarRect, label)
      XCTAssertEqual(bar.width, 2, label)
      let reach = font.pointSize * AgentPaletteMetrics.caretReachPerPoint
      XCTAssertEqual(bar.height, font.capHeight + reach * 2, accuracy: 0.01, label)
      let layout = try XCTUnwrap(field.layoutManager)
      let glyphLine = layout.extraLineFragmentRect.height > 0 && field.selectedRange().location == field.string.count
        ? layout.extraLineFragmentRect
        : layout.lineFragmentRect(
            forGlyphAt: layout.glyphIndexForCharacter(at: max(0, min(field.selectedRange().location, field.string.count - 1))),
            effectiveRange: nil)
      XCTAssertTrue(bar.midY > field.textContainerOrigin.y + glyphLine.minY, label)
      XCTAssertTrue(bar.midY < field.textContainerOrigin.y + glyphLine.maxY, label)
    }
    try check("empty")
    let empty = try XCTUnwrap(field.caretBarRect)

    field.setDraft(PromptDraft("Describe"))
    try check("at the end")
    let end = try XCTUnwrap(field.caretBarRect)
    XCTAssertEqual(end.midY, empty.midY, accuracy: 0.5, "typing does not move it up or down")
    XCTAssertGreaterThan(end.minX, empty.minX + 40)

    field.setSelectedRange(NSRange(location: 3, length: 0))
    try check("mid-word")
    let mid = try XCTUnwrap(field.caretBarRect)
    XCTAssertTrue(mid.minX > empty.minX && mid.minX < end.minX)

    field.setSelectedRange(NSRange(location: 2, length: 3))
    XCTAssertNil(field.caretBarRect, "a selection is a highlight, not a caret")
  }

  func testTheCaretAfterAChipIsTheSentencesHeight() throws {
    let field = makeField()
    field.setDraft(PromptDraft("Describe"))
    let plain = try XCTUnwrap(field.caretBarRect)

    field.setDraft(PromptDraft(elements: [
      .attachment(PromptAttachment(kind: .image, payload: .text("x"), label: "image 1")),
    ]))
    field.setSelectedRange(NSRange(location: field.string.utf16.count, length: 0))
    let afterChip = try XCTUnwrap(field.caretBarRect)

    XCTAssertEqual(afterChip.width, plain.width)
    XCTAssertEqual(afterChip.height, plain.height, accuracy: 0.01)
  }

  func testTheCaretBesideAChipStandsOnTheLinesBaseline() throws {
    let field = makeField()
    let chip = PromptDraft.Element.attachment(
      PromptAttachment(kind: .image, payload: .text("x"), label: "image 1"))
    field.setDraft(PromptDraft(elements: [chip, .text(" ")]))
    field.setSelectedRange(NSRange(location: field.string.utf16.count, length: 0))
    let afterSpace = try XCTUnwrap(field.caretBarRect)

    field.deleteBackward(nil)
    XCTAssertEqual(field.string.utf16.count, 1, "precondition: only the chip is left")
    let afterChip = try XCTUnwrap(field.caretBarRect)
    XCTAssertEqual(afterChip.midY, afterSpace.midY, accuracy: 0.01, "deleting the space does not drop it")
    XCTAssertEqual(afterChip.height, afterSpace.height, accuracy: 0.01)

    field.setSelectedRange(NSRange(location: 0, length: 0))
    let beforeChip = try XCTUnwrap(field.caretBarRect)
    XCTAssertEqual(beforeChip.midY, afterSpace.midY, accuracy: 0.01, "nor does standing before the chip")
  }

  func testTheKeysBesideAChipStandOnTheLinesBaseline() throws {
    let field = makeField()
    field.trailingHint = [PromptKeyHint(words: "Ask OpenCode", key: "↵")]
    let chip = PromptDraft.Element.attachment(
      PromptAttachment(kind: .file, payload: .text("x"), label: "file 1"))
    field.setDraft(PromptDraft(elements: [chip, .text(" ")]))
    let afterSpace = try XCTUnwrap(field.trailingHintFrame)

    field.deleteBackward(nil)
    XCTAssertEqual(field.string.utf16.count, 1, "precondition: only the chip is left")
    let afterChip = try XCTUnwrap(field.trailingHintFrame)
    XCTAssertEqual(afterChip.minY, afterSpace.minY, accuracy: 0.01, "deleting the space does not drop them")
    XCTAssertEqual(afterChip.height, afterSpace.height, accuracy: 0.01)

    field.setDraft(PromptDraft("file"))
    let afterWords = try XCTUnwrap(field.trailingHintFrame)
    XCTAssertEqual(afterChip.midY, afterWords.midY, accuracy: 0.5, "after a chip as after words")
  }

  // MARK: - Links

  func testALinkInTheDraftIsTextDrawnAsALink() throws {
    let field = makeField()
    let sentence = "see https://example.com/a, then"
    field.setDraft(PromptDraft(sentence))
    let storage = try XCTUnwrap(field.textStorage)
    let link = (sentence as NSString).range(of: "https://example.com/a")

    XCTAssertEqual(field.draft, PromptDraft(sentence), "the words are the words")
    XCTAssertFalse(field.containsChips)
    for index in [link.location, link.location + link.length - 1] {
      XCTAssertEqual(storage.attribute(.underlineStyle, at: index, effectiveRange: nil) as? Int,
                     NSUnderlineStyle.single.rawValue)
      XCTAssertEqual((storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)?.hexForTesting,
                     PromptLinkStyle.color.hexForTesting)
    }
    for index in [0, link.location - 1, link.location + link.length, sentence.utf16.count - 1] {
      XCTAssertNil(storage.attribute(.underlineStyle, at: index, effectiveRange: nil), "only the address")
    }
  }

  func testAWordThatStopsBeingALinkGoesBackToTheSentencesInk() throws {
    let field = makeField()
    field.setDraft(PromptDraft("https://example.com"))
    let storage = try XCTUnwrap(field.textStorage)
    XCTAssertNotNil(storage.attribute(.underlineStyle, at: 0, effectiveRange: nil))

    field.insertText("", replacementRange: NSRange(location: 5, length: 3))
    XCTAssertEqual(field.string, "httpsexample.com")
    XCTAssertNil(storage.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    XCTAssertEqual((storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.hexForTesting,
                   AgentPaletteView.promptTypingTextColor.hexForTesting)
  }

  func testASavedLinkChipComesBackAsItsWords() {
    let field = makeField()
    field.setDraft(PromptDraft(elements: [
      .attachment(PromptAttachment(kind: .link, payload: .text("https://example.com"), label: "link1")),
      .text(" please"),
    ]))
    XCTAssertEqual(field.string, "https://example.com please")
    XCTAssertFalse(field.containsChips)
  }

  func testRenderTheChips() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let chip = { (kind: PromptAttachmentKind) in
      PromptDraft.Element.attachment(
        PromptAttachment(kind: kind, payload: .text("x"), label: "\(kind.rawValue)1"))
    }
    let draft = PromptDraft(elements: [
      .text("Look at "), chip(.image), .text(" and "), chip(.file),
      .text(", then "), chip(.text), .text(" from https://example.com/a?b=1 please"),
    ])
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (name, chat) in [("prompt", false), ("chat", true)] {
      let (scroll, field) = PromptTextView.makeInScrollView()
      field.setChatComposerStyle(chat)
      field.textColor = .white
      field.setDraft(draft)
      let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 90))
      root.wantsLayer = true
      root.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
      let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless],
                            backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: .darkAqua)
      window.contentView = root
      scroll.translatesAutoresizingMaskIntoConstraints = true
      scroll.frame = root.bounds.insetBy(dx: 24, dy: 20)
      root.addSubview(scroll)
      root.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
      root.cacheDisplay(in: root.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        .write(to: URL(fileURLWithPath: dir).appendingPathComponent("chips-\(name).png"))
      window.close()
    }
  }

  func testTheSystemCaretIsClearAndTheDrawnOneTakesTheColour() {
    let field = makeField()
    field.insertionPointColor = .systemRed
    XCTAssertEqual(field.insertionPointColor, .clear)
    XCTAssertEqual(field.caretViewForTesting.color, .systemRed)
  }

  // MARK: - Round trip

  func testExpandingPreservesSelectionAndAttachmentIdentity() throws {
    let field = makeField()
    var draft = PromptDraft("Review ")
    draft.append(fileChip("/x/report.pdf"))
    draft.append(text: " with these details")
    field.setDraft(draft)
    let selection = NSRange(location: 2, length: 3)
    field.setSelectedRange(selection)
    let storage = try XCTUnwrap(field.textStorage)
    let attachment = try XCTUnwrap(storage.attribute(.attachment, at: 7, effectiveRange: nil) as? PromptChipAttachment)
    field.setExpandedStyle(true)
    XCTAssertEqual(field.draft, draft)
    XCTAssertEqual(field.selectedRange(), selection)
    XCTAssertTrue(storage.attribute(.attachment, at: 7, effectiveRange: nil) as? PromptChipAttachment === attachment)
    let cell = try XCTUnwrap(attachment.attachmentCell as? PromptChipCell)
    XCTAssertEqual(cell.displayFont.pointSize, PromptTextView.promptFont.pointSize)
    XCTAssertLessThanOrEqual(cell.cellSize().height, PromptTextView.lineHeight)
    field.setExpandedStyle(false)
    XCTAssertEqual(cell.displayFont.pointSize, PromptTextView.promptFont.pointSize)
    XCTAssertEqual(field.selectedRange(), selection)
  }

  func testAWrappedDraftReportsMoreThanOneLine() {
    let field = makeField()
    field.setDraft(PromptDraft(String(repeating: "wrapping text ", count: 40)))
    XCTAssertTrue(field.wrapsBeyondOneLine)
    field.clearPrompt()
    XCTAssertFalse(field.wrapsBeyondOneLine)
  }

  func testExpandedDraftIsCappedAndKeepsAllItsText() {
    let text = String(repeating: "Український текст 👩🏽‍💻 with a long paragraph. ", count: 50)
    let field = makeField()
    field.setExpandedStyle(true)
    field.setDraft(PromptDraft(text))
    XCTAssertEqual(field.string, text)
    XCTAssertTrue(field.isScrollable)
    XCTAssertEqual(field.clampedContentHeight, AgentPaletteMetrics.promptGrownMaximumHeight)

    let chat = makeField()
    chat.setChatComposerStyle(true)
    chat.setExpandedStyle(true)
    chat.setDraft(PromptDraft(text))
    XCTAssertEqual(chat.string, text)
    XCTAssertEqual(chat.clampedContentHeight, AgentPaletteMetrics.expandedPromptMaximumHeight)
  }

  func testCaretAfterATrailingNewlineIsNotOnTheFirstLine() {
    let field = makeField()
    field.setDraft(PromptDraft("Hello 👩🏽‍💻\n"))
    XCTAssertFalse(field.isCaretOnFirstLine, "Up must move inside the editor, not leave the reply card")
    field.setSelectedRange(NSRange(location: 2, length: 0))
    XCTAssertTrue(field.isCaretOnFirstLine)
  }

  func testADraftSurvivesGoingThroughTextStorageAndBack() {
    let field = makeField()
    var original = PromptDraft("Optimize ")
    original.append(fileChip("/x/video1.mov"))
    original.append(text: " in mp4")

    field.setDraft(original)
    let recovered = field.draft

    XCTAssertEqual(recovered.typedText, "Optimize  in mp4")
    XCTAssertEqual(recovered.attachments.count, 1)
    XCTAssertEqual(recovered.attachments.first?.label, "file1")
    XCTAssertEqual(recovered.attachments.first?.kind, .file)
  }

  func testTheRawStringIsNotTheDraft() {
    let field = makeField()
    var draft = PromptDraft()
    draft.append(fileChip("/x/report.pdf"))
    field.setDraft(draft)

    XCTAssertEqual(field.string, "\u{FFFC}")
    XCTAssertEqual(field.draft.attachments.first?.label, "file1")
    XCTAssertTrue(field.draft.typedText.isEmpty)
  }

  func testSeveralChipsAreSeparatedBySpaces() {
    let field = makeField()
    field.insertChips([
      fileChip("/x/a.mov"),
      fileChip("/x/b.png"),
      fileChip("/x/c.pdf"),
    ])

    let draft = field.draft
    XCTAssertEqual(draft.attachments.map(\.kind), [.file, .image, .file])
    XCTAssertEqual(draft.typedText, "   ", "spaces between chips, and one after the last")
  }

  func testInsertingAChipLeavesASpaceSoTypingDoesNotJamAgainstIt() {
    let field = makeField()
    field.insertChips([fileChip("/x/a.mov")])
    field.insertPlainText("in png")

    XCTAssertEqual(field.draft.typedText, " in png")
  }

  func testTypingAfterAChipIsPlainText() {
    let field = makeField()
    field.insertChips([fileChip("/x/a.mov")])
    field.insertPlainText("in mp4")

    let storage = field.textStorage!
    let last = storage.length - 1
    XCTAssertNil(
      storage.attribute(.attachment, at: last, effectiveRange: nil),
      "typing must not inherit the attachment attribute and draw a second chip"
    )
    XCTAssertEqual(field.draft.typedText, " in mp4")
  }

  func testTheSwitcherQueryIgnoresChips() {
    let field = makeField()
    var draft = PromptDraft("shell")
    draft.append(fileChip("/x/a.mov"))
    field.setDraft(draft)

    XCTAssertEqual(field.searchQuery, "shell")
  }

  func testClearingRemovesChipsAsWellAsText() {
    let field = makeField()
    var draft = PromptDraft("a")
    draft.append(fileChip("/x/a.mov"))
    field.setDraft(draft)

    field.clearPrompt()
    XCTAssertTrue(field.isEmptyPrompt)
    XCTAssertTrue(field.draft.attachments.isEmpty)
  }

  func testAnEmptyPromptIsEmptyEvenThoughAChipHasNoCharacters() {
    let field = makeField()
    XCTAssertTrue(field.isEmptyPrompt)
    field.insertChips([fileChip("/x/a.mov")])
    XCTAssertFalse(field.isEmptyPrompt, "the placeholder must not show over a chip")
  }

  // MARK: - Hit testing

  func testAChipCanBeFoundUnderAPoint() {
    let field = makeField()
    field.insertChips([fileChip("/x/a.mov")])
    field.layoutManager?.ensureLayout(for: field.textContainer!)

    let cellFrame = field.layoutManager!.boundingRect(
      forGlyphRange: NSRange(location: 0, length: 1),
      in: field.textContainer!
    )
    let point = NSPoint(x: cellFrame.midX, y: cellFrame.midY)
    XCTAssertEqual(field.attachment(at: field.convert(point, to: nil))?.label, "file1")
  }

  // MARK: - Geometry

  /// A chip is a tinted capsule, as Spotlight draws its tokens.
  func testAChipIsACapsuleAtTheSentencesHeight() {
    for font in [PromptTextView.promptFont, PromptTextView.chatComposerFont] {
      for kind in PromptAttachmentKind.allCases {
        let cell = PromptChipCell(PromptAttachment(kind: kind, payload: .text("x"), label: "\(kind.rawValue)1"))
        cell.displayFont = font
        let size = cell.cellSize()
        XCTAssertEqual(size.height, PromptChipCell.height(for: font))
        XCTAssertEqual(size.height, (font.pointSize * AgentPaletteMetrics.chipHeightPerPoint * 2).rounded() / 2)
        XCTAssertGreaterThan(size.width, size.height, "\(kind): a name in a capsule is wider than tall")
      }
    }
  }

  func testAChipDrawsAFillOfItsKindsColourAtAFifth() throws {
    let font = PromptTextView.promptFont
    for kind in [PromptAttachmentKind.image, .file, .text] {
      let cell = PromptChipCell(PromptAttachment(kind: kind, payload: .text("x"), label: "\(kind.rawValue)1"))
      cell.displayFont = font
      let size = cell.cellSize()
      let bitmap = try XCTUnwrap(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
      bitmap.size = size
      let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      cell.draw(withFrame: NSRect(origin: .zero, size: size), in: nil)
      NSGraphicsContext.restoreGraphicsState()
      let edge = try XCTUnwrap(bitmap.colorAt(x: 4, y: bitmap.pixelsHigh / 2))
      XCTAssertEqual(edge.alphaComponent, AgentPaletteMetrics.chipFillAlpha, accuracy: 0.04,
                     "\(kind): the capsule's end is the kind's colour at a fifth")
    }
  }

  func testALineIsTallEnoughForAChip() {
    let chipHeight = PromptChipCell(fileChip("/x/a.mov")).cellSize().height
    XCTAssertGreaterThanOrEqual(
      PromptTextView.lineHeight,
      chipHeight,
      "a capsule taller than the line would be clipped"
    )
  }

  func testAChipIsWiderThanItsLabelByItsPadding() {
    let cell = PromptChipCell(fileChip("/x/a.mov"))
    let size = cell.cellSize()
    let font = cell.displayFont
    XCTAssertGreaterThan(
      size.width,
      font.pointSize * (AgentPaletteMetrics.chipPaddingPerPoint * 2 + AgentPaletteMetrics.chipSymbolGapPerPoint)
    )
    XCTAssertEqual(size.height, PromptChipCell.height(for: font))
  }

  func testTheCapsuleSitsOnTheBaselineRatherThanAboveIt() {
    let cell = PromptChipCell(fileChip("/x/a.mov"))
    XCTAssertLessThan(
      cell.cellBaselineOffset().y,
      0,
      "the capsule has to drop below the baseline by its descender plus padding"
    )
  }

  func testChipLabelInkIsVerticallyCentredInTheCapsule() throws {
    let samples: [PromptAttachment] = [
      PromptAttachment(kind: .text, payload: .text("hello"), label: "text1"),
      fileChip("/x/glyph.png"),
      fileChip("/x/a.mov"),
    ]
    for attachment in samples {
      let cell = PromptChipCell(attachment)
      let size = cell.cellSize()
      let ink = try XCTUnwrap(
        Self.measureChipInk(cell: cell, size: size),
        "no ink for \(attachment.displayLabel())"
      )
      let title = PromptChipCell.title(for: attachment)
      let hangs = title.rangeOfCharacter(from: CharacterSet(charactersIn: "gjpqy")) != nil
      let allowance = hangs ? -cell.displayFont.descender / 2 : 0
      XCTAssertEqual(
        ink.labelMidY,
        ink.capsuleMidY + allowance / 2,
        accuracy: 1.0 + allowance / 2,
        "\(attachment.displayLabel()) ink midY \(ink.labelMidY) vs capsule midY \(ink.capsuleMidY)"
      )
    }
  }

  func testTheCapsuleKeepsTheReferencesProportions() {
    XCTAssertEqual(AgentPaletteMetrics.chipHeightPerPoint, 1.33)
    XCTAssertEqual(AgentPaletteMetrics.chipPaddingPerPoint, 0.4)
    XCTAssertEqual(AgentPaletteMetrics.chipSymbolPerPoint, 0.62)
    XCTAssertEqual(AgentPaletteMetrics.chipSymbolGapPerPoint, 0.28)
    XCTAssertEqual(AgentPaletteMetrics.chipCornerRadius, AgentPaletteMetrics.fromMock(50))
  }

  func testTheCapsuleIsTallerThanItsTypeAndItsLineHoldsIt() throws {
    for font in [PromptTextView.promptFont, PromptTextView.chatComposerFont] {
      let cell = PromptChipCell(PromptAttachment(kind: .image, payload: .text("x"), label: "image1"))
      cell.displayFont = font
      XCTAssertEqual(cell.cellSize().height, PromptChipCell.height(for: font))
      XCTAssertGreaterThan(cell.cellSize().height, ceil(font.ascender - font.descender))
      XCTAssertLessThanOrEqual(cell.cellSize().height, PromptChipCell.lineHeight(for: font))
    }
    XCTAssertEqual(
      PromptTextView.lineHeight,
      PromptChipCell.lineHeight(for: PromptTextView.promptFont)
    )
  }

  func testTheNumberIsAWordOfItsOwn() {
    let image = PromptAttachment(kind: .image, payload: .text("x"), label: "image12")
    XCTAssertEqual(PromptChipCell.title(for: image), "image 12")
    let named = PromptAttachment(kind: .file, payload: .text("x"), label: "report.pdf")
    XCTAssertEqual(PromptChipCell.title(for: named), "report.pdf")
  }

  func testTheCornerIsAStadiumAtEveryHeightAChipReaches() {
    let chipHeight = PromptChipCell(
      PromptAttachment(kind: .image, payload: .text("x"), label: "image1")
    ).cellSize().height
    XCTAssertEqual(PromptChipCell.cornerRadius(forHeight: chipHeight), chipHeight / 2)
    XCTAssertEqual(PromptChipCell.cornerRadius(forHeight: 10), 5)

    XCTAssertEqual(
      PromptChipCell.cornerRadius(forHeight: 400),
      AgentPaletteMetrics.chipCornerRadius
    )
  }

  // MARK: - Paste

  private func commandV(
    characters: String,
    modifiers: NSEvent.ModifierFlags = .command
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: 9 // kVK_ANSI_V
    )!
  }

  func testCommandVPastesWhateverLayoutIsActive() {
    let field = makeField()
    var literalPaste: Bool?
    field.onPaste = { literalPaste = $0 }

    XCTAssertTrue(field.performKeyEquivalent(with: commandV(characters: "в")))
    XCTAssertEqual(literalPaste, false)
  }

  func testCommandShiftVStillPastesLiterally() {
    let field = makeField()
    var literalPaste: Bool?
    field.onPaste = { literalPaste = $0 }

    let event = commandV(characters: "В", modifiers: [.command, .shift])
    XCTAssertTrue(field.performKeyEquivalent(with: event))
    XCTAssertEqual(literalPaste, true)
  }

  func testTheKeyAloneDoesNotPaste() {
    let field = makeField()
    var pasted = false
    field.onPaste = { _ in pasted = true }

    XCTAssertFalse(field.performKeyEquivalent(with: commandV(characters: "в", modifiers: [])))
    XCTAssertFalse(pasted)
  }

  func testEntranceScaleRunsFromTheStartScaleToOne() {
    XCTAssertEqual(PromptChipCell.entranceScale(for: 0), AgentPaletteMetrics.chipAppearStartScale)
    XCTAssertEqual(PromptChipCell.entranceScale(for: 1), 1)
    XCTAssertEqual(PromptChipCell.entranceScale(for: -5), AgentPaletteMetrics.chipAppearStartScale)
    XCTAssertEqual(PromptChipCell.entranceScale(for: 5), 1)
  }

  // MARK: - Colours (D13)

  func testEachKindGetsItsOwnColourAndAFaintFillOfIt() {
    let kinds = PromptAttachmentKind.allCases
    let colors = Set(kinds.map { $0.chipColor.description })
    XCTAssertEqual(colors.count, kinds.count, "four kinds, four colours")

    for kind in kinds {
      XCTAssertEqual(kind.chipColor.alphaComponent, 1)
      XCTAssertEqual(kind.chipFillColor.alphaComponent, AgentPaletteMetrics.chipFillAlpha, accuracy: 0.001)
      XCTAssertEqual(
        kind.chipFillColor.usingColorSpace(.sRGB)?.redComponent,
        kind.chipColor.usingColorSpace(.sRGB)?.redComponent,
        "\(kind): the fill is the label's own colour, not a second one"
      )
    }

    XCTAssertEqual(PromptAttachmentKind.image.chipColor.hexForTesting, "5FE3BD")
    XCTAssertEqual(PromptAttachmentKind.file.chipColor.hexForTesting, "3D94FF")
    XCTAssertEqual(PromptAttachmentKind.text.chipColor.hexForTesting, "FFAA3D")
    XCTAssertEqual(PromptAttachmentKind.link.chipColor.hexForTesting, "C7C7CC")
  }

  private struct ChipInk {
    let labelMidY: CGFloat
    let capsuleMidY: CGFloat
    let labelHeight: CGFloat
    let capsuleHeight: CGFloat
  }

  private static func measureChipInk(cell: PromptChipCell, size: NSSize) -> ChipInk? {
    let host = ChipInkHost(frame: NSRect(origin: .zero, size: size), cell: cell)
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)

    var labelMin = Int.max
    var labelMax = Int.min
    var capsuleMin = Int.max
    var capsuleMax = Int.min
    let width = rep.pixelsWide
    let height = rep.pixelsHigh
    for y in 0..<height {
      for x in 0..<width {
        guard let color = rep.colorAt(x: x, y: y) else { continue }
        let alpha = color.alphaComponent
        guard alpha > 0.05 else { continue }
        capsuleMin = min(capsuleMin, y)
        capsuleMax = max(capsuleMax, y)
        let brightest = max(color.redComponent, color.greenComponent, color.blueComponent)
        if alpha > 0.9, brightest > 0.7 {
          labelMin = min(labelMin, y)
          labelMax = max(labelMax, y)
        }
      }
    }
    guard labelMin <= labelMax, capsuleMin <= capsuleMax else { return nil }
    let scale = CGFloat(rep.pixelsHigh) / max(size.height, 1)
    let px = { (minY: Int, maxY: Int) in
      (CGFloat(minY + maxY) / 2) / scale
    }
    let span = { (minY: Int, maxY: Int) in
      CGFloat(maxY - minY + 1) / scale
    }
    return ChipInk(
      labelMidY: px(labelMin, labelMax),
      capsuleMidY: px(capsuleMin, capsuleMax),
      labelHeight: span(labelMin, labelMax),
      capsuleHeight: span(capsuleMin, capsuleMax)
    )
  }
}

private final class ChipInkHost: NSView {
  private let cell: PromptChipCell

  init(frame: NSRect, cell: PromptChipCell) {
    self.cell = cell
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  override var isOpaque: Bool { false }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    cell.draw(withFrame: bounds, in: self)
  }
}

extension NSColor {
  var hexForTesting: String {
    guard let srgb = usingColorSpace(.sRGB) else { return "??????" }
    return String(
      format: "%02X%02X%02X",
      Int((srgb.redComponent * 255).rounded()),
      Int((srgb.greenComponent * 255).rounded()),
      Int((srgb.blueComponent * 255).rounded())
    )
  }
}
