import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Boltty

@MainActor
final class PromptAttachmentCardTests: XCTestCase {
  private func makeField() -> PromptTextView {
    let (scrollView, textView) = PromptTextView.makeInScrollView()
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: PromptTextView.lineHeight)
    scrollView.layoutSubtreeIfNeeded()
    return textView
  }

  private func file(_ path: String) -> PromptAttachment {
    PromptAttachment.file(URL(fileURLWithPath: path))
  }

  private let font = roundedAppFont(size: AgentPaletteMetrics.typeMeta)
  private var wordsWidth: CGFloat {
    AgentPaletteMetrics.attachmentCardSide - AgentPaletteMetrics.attachmentCardInset * 2
  }

  // MARK: - Taking one back

  func testBackspaceAtTheFieldsStartTakesTheLastCard() {
    let field = makeField()
    let first = file("/x/a.mov")
    let second = file("/x/b.mov")
    field.insertAttachments([first, second])

    XCTAssertTrue(field.removeLastAttachmentFromFieldStart())

    XCTAssertEqual(field.attachments, [first])
  }

  func testBackspaceAfterAWordIsTheWords() {
    let field = makeField()
    field.insertPlainText("ab")
    field.insertAttachments([file("/x/a.mov")])

    XCTAssertFalse(field.removeLastAttachmentFromFieldStart(), "the caret stands after the words")
    XCTAssertEqual(field.attachments.count, 1)
  }

  func testASelectionFromTheStartIsDeletedAsWords() {
    let field = makeField()
    field.insertPlainText("ab")
    field.insertAttachments([file("/x/a.mov")])
    field.setSelectedRange(NSRange(location: 0, length: 2))

    XCTAssertFalse(field.removeLastAttachmentFromFieldStart())
  }

  func testRemovingOneBringsItBackOnUndo() throws {
    let field = makeField()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = field.enclosingScrollView
    addTeardownBlock { MainActor.assumeIsolated { window.close() } }
    let attachment = file("/x/a.mov")
    // Not inserted here: with no event between them, an insertion and the removal
    // are one undo group, and undoing it takes the card away again.
    var draft = PromptDraft()
    draft.append(attachment)
    field.setDraft(draft)

    field.removeAttachment(id: attachment.id)
    XCTAssertTrue(field.attachments.isEmpty)

    try XCTUnwrap(field.undoManager).undo()
    XCTAssertEqual(field.attachments, [attachment])
  }

  func testChangesReachTheStripAndOnlyAnInsertionAnimates() {
    let field = makeField()
    var told: [Bool] = []
    field.onAttachmentsChange = { told.append($0) }
    let attachment = file("/x/a.mov")

    field.insertAttachments([attachment])
    var restored = PromptDraft()
    restored.append(file("/x/b.mov"))
    field.setDraft(restored)
    field.clearPrompt()

    XCTAssertEqual(told, [true, false, false], "a draft put back is simply there")
  }

  func testADraftWithTheSameAttachmentsLeavesTheCardsAlone() {
    let field = makeField()
    var draft = PromptDraft("a")
    draft.append(file("/x/a.mov"))
    field.setDraft(draft)
    var told = 0
    field.onAttachmentsChange = { _ in told += 1 }

    field.setDraft(draft)

    XCTAssertEqual(told, 0, "dictation rewrites the words on every result")
  }

  // MARK: - What it says

  func testAFileSaysWhereItIsAndWhatItIs() throws {
    let path = NSHomeDirectory() + "/Desktop/Upload 1.mp4"
    let look = PromptAttachmentCard.look(for: file(path))

    XCTAssertNil(look.picture)
    XCTAssertEqual(look.words, .path("~/Desktop/Upload 1.mp4"))
    XCTAssertEqual(look.tag, "MP4")
  }

  func testAPictureFillsTheCardWithItsWordsKeptForIfItNeverComes() {
    let url = URL(fileURLWithPath: "/x/shot.png")
    let look = PromptAttachmentCard.look(for: PromptAttachment.file(url))
    XCTAssertEqual(look.picture, .file(url))
    XCTAssertFalse(look.showsWordsAtRest)

    let pasted = PromptAttachment(
      kind: .image, payload: .imageData(Data([1]), type: .png), label: "image1")
    XCTAssertEqual(PromptAttachmentCard.look(for: pasted).picture, .data(Data([1])))
  }

  func testAVideoAndAPDFAreWordsNotPictures() {
    XCTAssertNil(PromptAttachmentCard.look(for: file("/x/clip.mov")).picture)
    XCTAssertNil(PromptAttachmentCard.look(for: file("/x/report.pdf")).picture)
  }

  func testPastedTextShowsItsBeginning() {
    let pasted = PromptAttachment(
      kind: .text, payload: .text("  first line\nsecond  "), label: "text1")
    let look = PromptAttachmentCard.look(for: pasted)
    XCTAssertEqual(look.words, .excerpt("first line\nsecond"))
    XCTAssertEqual(look.tag, "Text")
  }

  func testAFolderAndAFileWithNoExtensionHaveAWordForWhatTheyAre() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("boltty-card-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    XCTAssertEqual(PromptAttachmentCard.tag(forPath: folder.path), "Folder")
    XCTAssertEqual(PromptAttachmentCard.tag(forPath: "/nope/Makefile"), "File")
  }

  func testACopyInBolttysFolderGoesByItsName() {
    let url = URL(fileURLWithPath: NSHomeDirectory()
      + "/Library/Application Support/Boltty/Conversations/x/attachments/3F2A1B2C-Report.pdf")
    XCTAssertEqual(PromptAttachmentCard.shownPath(of: url, named: "Report.pdf"), "Report.pdf")
  }

  func testASentFileThatIsGoneSaysSo() {
    let look = PromptAttachmentCard.look(forSentPath: "/nope/report.pdf", name: "report.pdf")
    XCTAssertTrue(look.isMissing)
    XCTAssertEqual(look.tag, "Missing")
    XCTAssertNil(look.picture)
  }

  func testASentPasteReadsAsItsWords() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("Application Support/Boltty/Pasteboard-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("text1-ab12cd34.txt")
    try Data("the words pasted".utf8).write(to: url)

    let look = PromptAttachmentCard.look(forSentPath: url.path, name: "text1.txt")

    XCTAssertEqual(look.words, .excerpt("the words pasted"))
    XCTAssertEqual(look.tag, "Text")
  }

  // MARK: - A path in three lines

  func testAPathThatFitsIsLeftWhole() {
    XCTAssertEqual(
      PromptAttachmentCard.fitted(path: "~/Desktop/a.mp4", font: font, width: wordsWidth, lines: 3),
      "~/Desktop/a.mp4")
  }

  func testALongPathLosesItsLeadingFoldersAndKeepsItsName() {
    let path = "~/Documents/Projects/boltty/apps/macos/Sources/Boltty/UI/README.md"
    let fitted = PromptAttachmentCard.fitted(path: path, font: font, width: wordsWidth, lines: 3)

    XCTAssertTrue(fitted.hasPrefix("…/"), fitted)
    XCTAssertTrue(fitted.hasSuffix("/README.md"), fitted)
  }

  func testANameTooLongAloneLosesItsMiddle() {
    let name = String(repeating: "a", count: 200) + ".mov"
    let fitted = PromptAttachmentCard.fitted(path: "~/x/" + name, font: font, width: wordsWidth, lines: 3)

    XCTAssertTrue(fitted.contains("…"), fitted)
    XCTAssertTrue(fitted.hasSuffix(".mov"), fitted)
    XCTAssertFalse(fitted.contains("/"), "not even a folder left")
  }

  // MARK: - The ×

  func testTheCloseComesWithThePointerOnlyWhereACardCanBeTakenBack() {
    let inDraft = PromptAttachmentCard(attachment: file("/x/a.mov"), corner: 13)
    var removed = 0
    inDraft.onRemove = { removed += 1 }
    XCTAssertFalse(inDraft.isCloseShownForTesting)
    inDraft.setHoveredForTesting(true)
    XCTAssertTrue(inDraft.isCloseShownForTesting)
    inDraft.pressCloseForTesting()
    XCTAssertEqual(removed, 1)
    inDraft.setHoveredForTesting(false)
    XCTAssertFalse(inDraft.isCloseShownForTesting)

    let sent = PromptAttachmentCard(sentPath: "/nope/a.mov", name: nil, corner: 13)
    sent.setHoveredForTesting(true)
    XCTAssertFalse(sent.isCloseShownForTesting, "what has gone cannot be taken back")
  }

  // MARK: - The strip

  private func makeStrip(width: CGFloat = 300) -> PromptAttachmentStrip {
    let strip = PromptAttachmentStrip(frame: NSRect(
      x: 0, y: 0, width: width, height: AgentPaletteMetrics.attachmentStripInChat.band))
    strip.placement = AgentPaletteMetrics.attachmentStripInChat
    return strip
  }

  func testACardThatStaysIsTheSameCard() {
    let strip = makeStrip()
    let first = file("/x/a.mov")
    let second = file("/x/b.mov")
    strip.show([first, second], animated: false)
    let kept = strip.cardsForTesting[1]

    strip.show([second], animated: false)

    XCTAssertEqual(strip.cardsForTesting.count, 1)
    XCTAssertTrue(strip.cardsForTesting[0] === kept, "it keeps its picture")
    XCTAssertEqual(kept.frame.minX, AgentPaletteMetrics.attachmentStripInChat.inset, "and takes the place left")
  }

  func testACardFollowsTheOrderOfTheDraft() {
    let strip = makeStrip()
    let first = file("/x/a.mov")
    let second = file("/x/b.mov")
    strip.show([first], animated: false)
    strip.show([second, first], animated: false)

    XCTAssertEqual(strip.cardsForTesting.map(\.attachmentID), [second.id, first.id])
  }

  func testTheStripGoesToTheNewestWhenThereIsMoreThanFits() {
    let strip = makeStrip()
    let many = (0..<6).map { file("/x/\($0).mov") }
    strip.show(many, animated: false)

    XCTAssertGreaterThan(strip.scrollForTesting.contentView.bounds.minX, 0)
  }

  func testAWordOnTheCardNeverRunsPastItsTag() {
    let card = PromptAttachmentCard(attachment: file("/x/a.mov"), corner: 13)
    card.layoutSubtreeIfNeeded()
    let height = CGFloat(AgentPaletteMetrics.attachmentCardLines) * AgentPaletteMetrics.attachmentCardLineHeight
    XCTAssertLessThanOrEqual(
      AgentPaletteMetrics.attachmentCardInset + height + AgentPaletteMetrics.attachmentTagHeight
        + AgentPaletteMetrics.attachmentCardInset,
      AgentPaletteMetrics.attachmentCardSide)
  }

  // MARK: - What it says under the pointer

  func testAFileShowsItsWholePath() {
    let path = "/Users/e/clips/a-very-long-recording-name-from-the-camera.mov"
    XCTAssertEqual(file(path).tooltip, path)
  }

  func testFilelessAttachmentsShowWhatTheyAreAndHowBigTheyAre() {
    let text = PromptAttachment(
      kind: .text,
      payload: .text(String(repeating: "a", count: 4200)),
      label: "text1"
    )
    XCTAssertTrue(text.tooltip.hasPrefix("Pasted text · "), text.tooltip)
    XCTAssertTrue(text.tooltip.contains("KB"), text.tooltip)

    let image = PromptAttachment(
      kind: .image,
      payload: .imageData(Data(count: 2048), type: .png),
      label: "image1"
    )
    XCTAssertTrue(image.tooltip.hasPrefix("Pasted "), image.tooltip)
    XCTAssertTrue(image.tooltip.contains("KB"), image.tooltip)
  }
}
