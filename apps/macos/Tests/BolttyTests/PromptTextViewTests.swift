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

  // MARK: - Links

  func testALinkInTheDraftIsTextDrawnAsALink() throws {
    let field = makeField()
    let sentence = "see https://example.com/a, then"
    field.setDraft(PromptDraft(sentence))
    let storage = try XCTUnwrap(field.textStorage)
    let link = (sentence as NSString).range(of: "https://example.com/a")

    XCTAssertEqual(field.draft, PromptDraft(sentence), "the words are the words")
    XCTAssertTrue(field.attachments.isEmpty)
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
    XCTAssertTrue(field.attachments.isEmpty)
  }

  func testTheSystemCaretIsClearAndTheDrawnOneTakesTheColour() {
    let field = makeField()
    field.insertionPointColor = .systemRed
    XCTAssertEqual(field.insertionPointColor, .clear)
    XCTAssertEqual(field.caretViewForTesting.color, .systemRed)
  }

  // MARK: - Round trip

  func testExpandingPreservesSelectionAndTheDraft() {
    let field = makeField()
    var draft = PromptDraft("Review with these details")
    draft.append(fileChip("/x/report.pdf"))
    field.setDraft(draft)
    let selection = NSRange(location: 2, length: 3)
    field.setSelectedRange(selection)
    field.setExpandedStyle(true)
    XCTAssertEqual(field.draft, draft)
    XCTAssertEqual(field.selectedRange(), selection)
    field.setExpandedStyle(false)
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

    XCTAssertEqual(recovered.typedText, "Optimize in mp4", "the space either side was the chip's")
    XCTAssertEqual(recovered.attachments.count, 1)
    XCTAssertEqual(recovered.attachments.first?.label, "file1")
    XCTAssertEqual(recovered.attachments.first?.kind, .file)
  }

  func testTheRawStringIsNotTheDraft() {
    let field = makeField()
    var draft = PromptDraft()
    draft.append(fileChip("/x/report.pdf"))
    field.setDraft(draft)

    XCTAssertEqual(field.string, "", "an attachment is not a character in the sentence")
    XCTAssertEqual(field.draft.attachments.first?.label, "file1")
    XCTAssertTrue(field.draft.typedText.isEmpty)
  }

  func testSeveralAttachmentsKeepTheirOrderAndAddNoWords() {
    let field = makeField()
    field.insertAttachments([
      fileChip("/x/a.mov"),
      fileChip("/x/b.png"),
      fileChip("/x/c.pdf"),
    ])

    let draft = field.draft
    XCTAssertEqual(draft.attachments.map(\.kind), [.file, .image, .file])
    XCTAssertEqual(draft.typedText, "")
  }

  func testTheCaretStaysInTheWordsWhenAFileArrives() {
    let field = makeField()
    field.insertPlainText("in png")
    field.insertAttachments([fileChip("/x/a.mov")])
    XCTAssertEqual(field.selectedRange(), NSRange(location: 6, length: 0))
    field.insertPlainText(", please")
    XCTAssertEqual(field.draft.typedText, "in png, please")
  }

  func testTheSwitcherQueryIgnoresAttachments() {
    let field = makeField()
    var draft = PromptDraft("shell")
    draft.append(fileChip("/x/a.mov"))
    field.setDraft(draft)

    XCTAssertEqual(field.searchQuery, "shell")
  }

  func testClearingRemovesAttachmentsAsWellAsText() {
    let field = makeField()
    var draft = PromptDraft("a")
    draft.append(fileChip("/x/a.mov"))
    field.setDraft(draft)

    field.clearPrompt()
    XCTAssertTrue(field.isWhollyEmpty)
    XCTAssertTrue(field.draft.attachments.isEmpty)
  }

  func testAnAttachmentLeavesTheWordsEmptyAndTheDraftNot() {
    let field = makeField()
    XCTAssertTrue(field.isWhollyEmpty)
    field.insertAttachments([fileChip("/x/a.mov")])
    XCTAssertTrue(field.isEmptyPrompt, "the placeholder stands beside a card")
    XCTAssertFalse(field.isWhollyEmpty)
    XCTAssertFalse(field.draft.isEffectivelyEmpty, "and there is something to send")
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
