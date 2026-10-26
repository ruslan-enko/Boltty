import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Boltty

final class PasteboardIngestTests: XCTestCase {
  private var pasteboard: NSPasteboard!

  override func setUp() {
    super.setUp()
    pasteboard = NSPasteboard(name: NSPasteboard.Name("boltty-ingest-\(UUID().uuidString)"))
    pasteboard.clearContents()
  }

  override func tearDown() {
    pasteboard.releaseGlobally()
    super.tearDown()
  }

  // MARK: - Files

  func testCopyingSeveralFilesYieldsOneChipEach() {
    pasteboard.writeObjects([
      URL(fileURLWithPath: "/x/clip.mov") as NSURL,
      URL(fileURLWithPath: "/x/shot.png") as NSURL,
      URL(fileURLWithPath: "/x/report.pdf") as NSURL,
    ])

    guard case let .attachments(chips) = PasteboardIngest.read(pasteboard, into: PromptDraft())
    else { return XCTFail("expected chips") }

    XCTAssertEqual(chips.map(\.kind), [.file, .image, .file])
    XCTAssertEqual(chips.map(\.label), ["file1", "image1", "file2"])
  }

  func testTooManyFilesAreRefusedRatherThanTruncated() {
    let urls = (1...PasteboardIngest.maxFileCount + 1).map {
      URL(fileURLWithPath: "/x/file\($0).txt") as NSURL
    }
    pasteboard.writeObjects(urls)

    XCTAssertEqual(
      PasteboardIngest.read(pasteboard, into: PromptDraft()),
      .tooManyFiles(limit: PasteboardIngest.maxFileCount)
    )
  }

  func testExactlyTheLimitIsAccepted() {
    let urls = (1...PasteboardIngest.maxFileCount).map {
      URL(fileURLWithPath: "/x/file\($0).txt") as NSURL
    }
    pasteboard.writeObjects(urls)

    guard case let .attachments(chips) = PasteboardIngest.read(pasteboard, into: PromptDraft())
    else { return XCTFail("expected chips") }
    XCTAssertEqual(chips.count, PasteboardIngest.maxFileCount)
  }

  func testAPastedImageFileStaysAFileInsteadOfBecomingAScreenshot() {
    pasteboard.writeObjects([URL(fileURLWithPath: "/x/diagram.png") as NSURL])
    pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)

    guard case let .attachments(chips) = PasteboardIngest.read(pasteboard, into: PromptDraft())
    else { return XCTFail("expected chips") }
    XCTAssertEqual(chips.first?.payload, .file(URL(fileURLWithPath: "/x/diagram.png")))
    XCTAssertEqual(chips.first?.label, "image1")
  }

  // MARK: - Images with no file

  func testAScreenshotBecomesOneImageChip() {
    pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)

    guard case let .attachments(chips) = PasteboardIngest.read(pasteboard, into: PromptDraft())
    else { return XCTFail("expected chips") }
    XCTAssertEqual(chips.count, 1)
    XCTAssertEqual(chips[0].kind, .image)
    XCTAssertEqual(chips[0].displayLabel(), "image1")
  }

  func testGeneratedNamesContinueFromWhatTheDraftAlreadyHolds() {
    var draft = PromptDraft()
    draft.append(
      PromptAttachment(kind: .image, payload: .imageData(Data(), type: .png), label: "image1")
    )
    pasteboard.setData(Data([0x89]), forType: .png)

    guard case let .attachments(chips) = PasteboardIngest.read(pasteboard, into: draft)
    else { return XCTFail("expected chips") }
    XCTAssertEqual(chips[0].label, "image2")
  }

  // MARK: - Text (D7)

  func testAShortWordIsTypedNotChipped() {
    pasteboard.setString("mp4", forType: .string)
    XCTAssertEqual(PasteboardIngest.read(pasteboard, into: PromptDraft()), .plainText("mp4"))
  }

  func testTheThresholdIsCheckedFromBothSides() {
    let atThreshold = String(repeating: "a", count: PasteboardIngest.textChipThreshold)
    XCTAssertFalse(PasteboardIngest.isChipWorthy(atThreshold))
    XCTAssertTrue(PasteboardIngest.isChipWorthy(atThreshold + "a"))
  }

  func testMultilineTextIsChippedAtAnyLength() {
    pasteboard.setString("line one\nline two", forType: .string)

    guard case let .attachments(chips) = PasteboardIngest.read(pasteboard, into: PromptDraft())
    else { return XCTFail("expected chips") }
    XCTAssertEqual(chips[0].kind, .text)
    XCTAssertEqual(chips[0].displayLabel(), "text1")
    XCTAssertEqual(chips[0].payload, .text("line one\nline two"))
  }

  // MARK: - Links

  func testAURLIsWordsNotAChip() {
    pasteboard.setString("https://example.com", forType: .string)
    XCTAssertEqual(
      PasteboardIngest.read(pasteboard, into: PromptDraft()),
      .plainText("https://example.com"))

    pasteboard.setString("https://example.com\n", forType: .string)
    XCTAssertEqual(
      PasteboardIngest.read(pasteboard, into: PromptDraft()),
      .plainText("https://example.com"), "a copied address brings its newline, which is not a text chip")
  }

  func testASentenceContainingAURLIsNotALink() {
    pasteboard.setString("see https://example.com", forType: .string)
    XCTAssertEqual(
      PasteboardIngest.read(pasteboard, into: PromptDraft()),
      .plainText("see https://example.com")
    )
  }

  func testForcePlainTextSkipsTheLinkRuleToo() {
    pasteboard.setString("https://example.com", forType: .string)
    XCTAssertEqual(
      PasteboardIngest.read(pasteboard, into: PromptDraft(), forcePlainText: true),
      .plainText("https://example.com")
    )
  }

  // MARK: - ⌘⇧V

  func testForcePlainTextSkipsEveryRule() {
    pasteboard.setString("line one\nline two", forType: .string)
    XCTAssertEqual(
      PasteboardIngest.read(pasteboard, into: PromptDraft(), forcePlainText: true),
      .plainText("line one\nline two")
    )
  }

  func testForcePlainTextOnAFileFallsBackToItsStringForm() {
    pasteboard.writeObjects([URL(fileURLWithPath: "/x/clip.mov") as NSURL])
    guard case let .plainText(text) = PasteboardIngest.read(
      pasteboard,
      into: PromptDraft(),
      forcePlainText: true
    ) else { return XCTFail("expected plain text") }
    XCTAssertTrue(text.contains("clip.mov"))
  }

  // MARK: - Nothing

  func testAnEmptyPasteboardProducesNothing() {
    XCTAssertEqual(PasteboardIngest.read(pasteboard, into: PromptDraft()), .nothing)
  }
}
