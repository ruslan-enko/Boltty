import UniformTypeIdentifiers
import XCTest
@testable import Boltty

final class PromptDraftTests: XCTestCase {
  private final class StubStore: PromptAttachmentStoring, @unchecked Sendable {
    private(set) var requested: [PromptAttachment] = []
    var result: URL = URL(fileURLWithPath: "/tmp/boltty-stub/pasted.png")
    var failure: Error?

    func fileURL(for attachment: PromptAttachment) throws -> URL {
      requested.append(attachment)
      if let failure { throw failure }
      return result
    }

    var screenResult: URL = URL(fileURLWithPath: "/tmp/boltty-stub/pasted-screen.png")

    func screenFileURL(for attachment: PromptAttachment) throws -> URL {
      if let failure { throw failure }
      return screenResult
    }
  }

  private var store: StubStore!

  override func setUp() {
    super.setUp()
    store = StubStore()
  }

  // MARK: - Kind resolution (D13)

  func testKindComesFromUTIConformanceNotExtensionStrings() {
    XCTAssertEqual(PromptAttachmentKind.resolve(for: .png), .image)
    XCTAssertEqual(PromptAttachmentKind.resolve(for: .heic), .image)
    XCTAssertEqual(PromptAttachmentKind.resolve(for: .pdf), .file)
    XCTAssertEqual(PromptAttachmentKind.resolve(for: .mpeg4Movie), .file)
    XCTAssertEqual(PromptAttachmentKind.resolve(for: .quickTimeMovie), .file)
    XCTAssertEqual(PromptAttachmentKind.resolve(for: .mp3), .file)
    XCTAssertEqual(PromptAttachmentKind.resolve(for: .zip), .file)
    XCTAssertEqual(PromptAttachmentKind.resolve(for: .swiftSource), .file)
    XCTAssertEqual(PromptAttachmentKind.resolve(for: .folder), .file)
    XCTAssertEqual(PromptAttachmentKind.resolve(for: nil), .file)
  }

  func testKindResolvesForPathsThatDoNotExist() {
    XCTAssertEqual(
      PromptAttachmentKind.resolve(for: URL(fileURLWithPath: "/nope/clip.mov")),
      .file
    )
    XCTAssertEqual(
      PromptAttachmentKind.resolve(for: URL(fileURLWithPath: "/nope/shot.png")),
      .image
    )
    XCTAssertEqual(
      PromptAttachmentKind.resolve(for: URL(fileURLWithPath: "/nope/notes")),
      .file
    )
  }

  // MARK: - Labels

  func testFileChipsAreNamedByKindNotByPath() {
    let chip = PromptAttachment.file(
      URL(fileURLWithPath: "/Users/e/clips/IMG_4821.mov"),
      label: "file1"
    )
    XCTAssertEqual(chip.label, "file1")
    XCTAssertEqual(chip.displayLabel(), "file1")
    XCTAssertEqual(chip.tooltip, "/Users/e/clips/IMG_4821.mov", "the path is still reachable")
  }

  func testNoChipIsDrawnInBrackets() {
    let pasted = PromptAttachment(kind: .text, payload: .text("hello"), label: "text1")
    let onDisk = PromptAttachment.file(URL(fileURLWithPath: "/x/a.png"), label: "image1")

    XCTAssertEqual(pasted.displayLabel(), "text1")
    XCTAssertEqual(onDisk.displayLabel(), "image1")
  }

  func testLongNamesLoseTheirMiddleNotTheirExtension() {
    let chip = PromptAttachment(
      kind: .file,
      payload: .text("x"),
      label: "a-very-long-recording-name-from-the-camera.mov"
    )
    let shown = chip.displayLabel()
    XCTAssertEqual(shown.count, PromptAttachment.defaultLabelLimit)
    XCTAssertTrue(shown.contains("…"))
    XCTAssertTrue(shown.hasSuffix(".mov"), "the extension is the informative part: \(shown)")
  }

  // MARK: - Links

  func testOnlyAWholeURLWithASchemeAndHostIsALink() {
    XCTAssertTrue(PromptAttachmentKind.isLink("https://figma.com/design/abc?node-id=1-2"))
    XCTAssertTrue(PromptAttachmentKind.isLink("http://localhost:3000"))
    XCTAssertTrue(PromptAttachmentKind.isLink("  https://example.com  "))

    XCTAssertFalse(PromptAttachmentKind.isLink("see https://example.com for more"))
    XCTAssertFalse(PromptAttachmentKind.isLink("Documents/Projects/boltty"))
    XCTAssertFalse(PromptAttachmentKind.isLink("example.com"))
    XCTAssertFalse(PromptAttachmentKind.isLink("file:///Users/e/a.png"))
    XCTAssertFalse(PromptAttachmentKind.isLink(""))
  }

  func testLinksInASentenceAreFoundWithoutItsPunctuation() {
    func found(_ text: String) -> [String] {
      PromptAttachmentKind.linkRanges(in: text).map { (text as NSString).substring(with: $0) }
    }
    XCTAssertEqual(found("(see https://a.com/x)."), ["https://a.com/x"])
    XCTAssertEqual(found("«https://a.com», and www.b.org/y?z=1!"), ["https://a.com", "www.b.org/y?z=1"])
    XCTAssertEqual(found("http://localhost:3000"), ["http://localhost:3000"])
    XCTAssertEqual(found("https://a.com\nhttps://b.com"), ["https://a.com", "https://b.com"])
    XCTAssertEqual(found("a\u{FFFC}https://a.com"), ["https://a.com"], "a chip parts words like a space")

    XCTAssertEqual(found("README.md and main.sh"), [], "a file is not a link")
    XCTAssertEqual(found("file:///Users/e/a.png"), [])
    XCTAssertEqual(found("www. and www.com"), [])
    XCTAssertEqual(found(""), [])
  }

  func testShortNamesAreLeftAlone() {
    XCTAssertEqual("clip.mov".middleTruncated(to: 22), "clip.mov")
  }

  func testGeneratedNamesAreSequentialPerKind() {
    var draft = PromptDraft("look at ")
    XCTAssertEqual(draft.nextGeneratedLabel(for: .text), "text1")

    draft.append(PromptAttachment(kind: .text, payload: .text("a"), label: "text1"))
    XCTAssertEqual(draft.nextGeneratedLabel(for: .text), "text2")
    XCTAssertEqual(draft.nextGeneratedLabel(for: .image), "image1")

    draft.append(PromptAttachment.file(URL(fileURLWithPath: "/x/shot.png"), label: "image1"))
    XCTAssertEqual(draft.nextGeneratedLabel(for: .image), "image2")
  }

  func testABatchOfNamesCountsWithinItself() {
    var draft = PromptDraft()
    draft.append(PromptAttachment(kind: .image, payload: .text("a"), label: "image1"))

    XCTAssertEqual(
      draft.generatedLabels(for: [.image, .file, .image, .link]),
      ["image2", "file1", "image3", "link1"]
    )
  }

  // MARK: - Expansion (D9, D10)

  func testFileChipExpandsToItsAbsolutePath() throws {
    var draft = PromptDraft("Optimize ")
    draft.append(PromptAttachment.file(URL(fileURLWithPath: "/Users/e/clips/video1.mov")))
    draft.append(text: " in mp4")

    XCTAssertEqual(
      try PromptExpansion.expand(draft, store: store),
      "Optimize /Users/e/clips/video1.mov in mp4"
    )
    XCTAssertTrue(store.requested.isEmpty, "a file on disk needs no store")
  }

  func testShortTextIsInlinedInsideDelimiters() throws {
    var draft = PromptDraft("Rewrite ")
    draft.append(PromptAttachment(kind: .text, payload: .text("line one\nline two"), label: "text1"))

    XCTAssertEqual(
      try PromptExpansion.expand(draft, store: store),
      "Rewrite <pasted-text>line one\nline two</pasted-text>"
    )
    XCTAssertTrue(store.requested.isEmpty)
  }

  func testALinkExpandsToTheBareURL() throws {
    var draft = PromptDraft("look at ")
    draft.append(
      PromptAttachment(
        kind: .link,
        payload: .text("https://example.com/a?b=c"),
        label: "link1"
      )
    )

    XCTAssertEqual(
      try PromptExpansion.expand(draft, store: store),
      "look at https://example.com/a?b=c"
    )
    XCTAssertTrue(store.requested.isEmpty, "a link never reaches the store")
  }

  func testProseContainingAURLKeepsItsDelimiters() throws {
    let sentence = "see https://example.com for the details"
    XCTAssertFalse(
      PromptAttachmentKind.isLink(sentence),
      "a sentence with a URL in it is not a link"
    )

    var draft = PromptDraft()
    draft.append(PromptAttachment(kind: .text, payload: .text(sentence), label: "text1"))

    XCTAssertEqual(
      try PromptExpansion.expand(draft, store: store),
      PromptExpansion.textOpenTag + sentence + PromptExpansion.textCloseTag
    )
  }

  func testTextIsFiledOnlyOnceItPassesTheCeiling() throws {
    let atLimit = String(repeating: "a", count: PromptExpansion.inlineTextByteLimit)
    let overLimit = atLimit + "a"

    var inline = PromptDraft()
    inline.append(PromptAttachment(kind: .text, payload: .text(atLimit), label: "text1"))
    XCTAssertEqual(
      try PromptExpansion.expand(inline, store: store),
      PromptExpansion.textOpenTag + atLimit + PromptExpansion.textCloseTag
    )
    XCTAssertTrue(store.requested.isEmpty, "8 KB exactly still inlines")

    var filed = PromptDraft()
    filed.append(PromptAttachment(kind: .text, payload: .text(overLimit), label: "text1"))
    store.result = URL(fileURLWithPath: "/tmp/boltty-stub/pasted.txt")
    XCTAssertEqual(try PromptExpansion.expand(filed, store: store), "/tmp/boltty-stub/pasted.txt")
    XCTAssertEqual(store.requested.count, 1)
  }

  func testEveryChipThatBecameAPathIsRememberedAsASentFile() throws {
    let report = PromptAttachment.file(
      URL(fileURLWithPath: "/Users/e/Boltty copies/3f2a1b2c-Report final.pdf"), label: "file1")
    let picture = PromptAttachment(
      kind: .image, payload: .imageData(Data([1]), type: .png), label: "image1")
    var draft = PromptDraft("Compare ")
    draft.append(report)
    draft.append(text: " with ")
    draft.append(picture)
    draft.append(text: " and ")
    draft.append(PromptAttachment(kind: .link, payload: .text("https://example.com"), label: "link1"))
    store.result = URL(fileURLWithPath: "/tmp/boltty-stub/image1-ab12cd34.png")

    let (text, files) = try PromptExpansion.expandRecordingFiles(
      draft, names: [report.id: "Report final.pdf"], store: store)

    XCTAssertEqual(
      text,
      "Compare \"/Users/e/Boltty copies/3f2a1b2c-Report final.pdf\" with "
        + "/tmp/boltty-stub/image1-ab12cd34.png and https://example.com",
      "the agent's string is exactly what `expand` always sent"
    )
    XCTAssertEqual(files.map(\.chip), [report.id, picture.id])
    XCTAssertEqual(files.map(\.file), [
      SentFile(
        path: "/Users/e/Boltty copies/3f2a1b2c-Report final.pdf", label: "file1",
        name: "Report final.pdf"),
      SentFile(path: "/tmp/boltty-stub/image1-ab12cd34.png", label: "image1", name: "image1.png"),
    ])
  }

  func testTheCeilingCountsBytesNotCharacters() throws {
    let emoji = String(repeating: "🙂", count: PromptExpansion.inlineTextByteLimit / 4 + 1)
    XCTAssertLessThan(emoji.count, PromptExpansion.inlineTextByteLimit)

    var draft = PromptDraft()
    draft.append(PromptAttachment(kind: .text, payload: .text(emoji), label: "text1"))
    _ = try PromptExpansion.expand(draft, store: store)
    XCTAssertEqual(store.requested.count, 1)
  }

  func testPastedImageIsWrittenOutAndExpandsToThatPath() throws {
    var draft = PromptDraft("Describe ")
    draft.append(
      PromptAttachment(
        kind: .image,
        payload: .imageData(Data([0x89, 0x50]), type: .png),
        label: "image1"
      )
    )
    store.result = URL(fileURLWithPath: "/tmp/boltty-stub/shot.png")

    XCTAssertEqual(
      try PromptExpansion.expand(draft, store: store),
      "Describe /tmp/boltty-stub/shot.png"
    )
  }

  func testAStoreFailureSurfacesRatherThanExpandingToNothing() {
    var draft = PromptDraft()
    draft.append(
      PromptAttachment(
        kind: .image,
        payload: .imageData(Data(), type: .png),
        label: "image1"
      )
    )
    store.failure = PromptExpansionError.attachmentUnavailable("image1")

    XCTAssertThrowsError(try PromptExpansion.expand(draft, store: store))
  }

  // MARK: - Reaching the agent intact

  func testAPathWithSpacesIsQuotedForTheReader() throws {
    var draft = PromptDraft("Convert ")
    draft.append(PromptAttachment.file(URL(fileURLWithPath: "/Users/e/my clip (final).mov")))
    draft.append(text: " to mp4")

    let prompt = try PromptExpansion.expand(draft, store: store)
    XCTAssertTrue(prompt.contains("\"/Users/e/my clip (final).mov\""))

    XCTAssertEqual(prompt.components(separatedBy: "\n").count, 1)
  }

  func testPathsWithoutSpacesAreNotQuoted() throws {
    var draft = PromptDraft()
    draft.append(PromptAttachment.file(URL(fileURLWithPath: "/Users/e/clip.mov")))
    XCTAssertEqual(try PromptExpansion.expand(draft, store: store), "/Users/e/clip.mov")
  }

  // MARK: - Emptiness (D17)

  func testAChipWithNoWordsIsAValidPrompt() throws {
    var draft = PromptDraft()
    draft.append(PromptAttachment.file(URL(fileURLWithPath: "/Users/e/report.pdf")))

    XCTAssertFalse(draft.isEffectivelyEmpty)
    let prompt = try PromptExpansion.expand(draft, store: store)
    XCTAssertFalse(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  func testWhitespaceAloneIsStillEmpty() {
    XCTAssertTrue(PromptDraft("   ").isEffectivelyEmpty)
    XCTAssertTrue(PromptDraft().isEffectivelyEmpty)
  }

  // MARK: - Draft bookkeeping

  func testAdjacentTypingMergesIntoOneRun() {
    var draft = PromptDraft()
    draft.append(text: "Opti")
    draft.append(text: "mize")
    XCTAssertEqual(draft.elements, [.text("Optimize")])
    XCTAssertEqual(draft.typedText, "Optimize")
  }

  func testTypedTextIgnoresChips() {
    var draft = PromptDraft("a ")
    draft.append(PromptAttachment.file(URL(fileURLWithPath: "/x/b.png")))
    draft.append(text: " c")
    XCTAssertEqual(draft.typedText, "a  c")
    XCTAssertEqual(draft.attachments.count, 1)
  }
}

extension PromptAttachment {
  static func file(_ url: URL, id: UUID = UUID()) -> PromptAttachment {
    let kind = PromptAttachmentKind.resolve(for: url)
    return file(url, label: "\(kind.rawValue)1", id: id)
  }
}

final class SentFileTests: XCTestCase {
  func testOnlyAPictureSmallEnoughToSendIsAPicture() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("boltty-pictures-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    func file(_ name: String, bytes: Int) throws -> SentFile {
      let url = folder.appendingPathComponent(name)
      try Data(count: bytes).write(to: url)
      return SentFile(path: url.path, label: "image1", name: "image1.png")
    }

    let small = try XCTUnwrap(try file("small.png", bytes: 1_000).picture)
    XCTAssertEqual(small.id, "sent-\(folder.appendingPathComponent("small.png").path)")
    XCTAssertEqual(small.displayName, "image1.png")
    XCTAssertEqual(small.mimeType, "image/png")
    XCTAssertNil(try file("notes.txt", bytes: 10).picture)
    XCTAssertNil(try file("huge.png", bytes: SentFile.pictureByteLimit + 1).picture)
  }

  private let picture = SentFile(
    path: "/Users/e/Library/Application Support/Boltty/Pasteboard/image1-ab12cd34.png",
    label: "image1", name: "image1.png")
  private let report = SentFile(path: "/Users/e/Desktop/report.pdf", label: "file1", name: "report.pdf")

  private func request(_ text: String, role: ConversationMessage.Role = .user) -> ConversationMessage {
    ConversationMessage(
      id: "m", role: role, createdAt: Date(), completedAt: Date(),
      parts: [.text(TextPart(id: "t", kind: .text, text: text))])
  }

  private func words(_ message: ConversationMessage) -> [String] {
    message.parts.compactMap { part in
      if case let .text(text) = part { return text.text }
      return nil
    }
  }

  private func files(_ message: ConversationMessage) -> [ConversationAttachment] {
    message.parts.compactMap { part in
      if case let .attachment(attachment) = part { return attachment }
      return nil
    }
  }

  func testAChipComesBackAsItsNameAndItsFileAsAnAttachment() {
    let lifted = SentFile.lift(
      request("Compare \"\(picture.path)\" with \(report.path), please"),
      files: [report, picture])

    XCTAssertEqual(words(lifted), ["Compare image1 with file1, please"])
    XCTAssertEqual(files(lifted).map(\.url?.path), [picture.path, report.path],
                   "in the order they were written, not the order they were remembered")
    XCTAssertEqual(files(lifted).map(\.displayName), ["image1.png", "report.pdf"])
  }

  func testARequestOfOnlyChipsKeepsNoWords() {
    let lifted = SentFile.lift(request("\(report.path) \n"), files: [report])

    XCTAssertEqual(words(lifted), [])
    XCTAssertEqual(files(lifted).map(\.url?.path), [report.path])
  }

  func testAPathThePersonTypedThemselvesIsLeftAlone() {
    let typed = request("Read /etc/hosts")
    XCTAssertEqual(SentFile.lift(typed, files: [report]), typed)
  }

  func testOnlyAPersonsRequestIsLifted() {
    let answer = request("I wrote \(report.path)", role: .agent)
    XCTAssertEqual(SentFile.lift(answer, files: [report]), answer)
  }

  func testTheLongerOfTwoPathsWins() {
    let notes = SentFile(path: report.path + ".txt", label: "text1", name: "text1.txt")
    let lifted = SentFile.lift(request("\(notes.path) and \(report.path)"), files: [report, notes])

    XCTAssertEqual(words(lifted), ["text1 and file1"])
    XCTAssertEqual(files(lifted).map(\.displayName), ["text1.txt", "report.pdf"])
  }

  // MARK: - A region of the screen

  private struct FixedStore: PromptAttachmentStoring {
    func fileURL(for attachment: PromptAttachment) throws -> URL {
      URL(fileURLWithPath: "/tmp/boltty-stub/pasted.png")
    }
    func screenFileURL(for attachment: PromptAttachment) throws -> URL {
      URL(fileURLWithPath: "/tmp/boltty-stub/pasted-screen.png")
    }
  }

  private let store = FixedStore()

  private func screenChip(context: String? = "Figma — “Boltty”", text: String? = "Sessions 161") -> PromptAttachment {
    PromptAttachment(
      kind: .image,
      payload: .screen(ScreenSelection(
        region: Data([1]), screen: Data([2]), frame: CGRect(x: 10, y: 20, width: 300, height: 200),
        context: context, recognizedText: text)),
      label: "image1")
  }

  func testAScreenChipBecomesBothPicturesWhereTheyWereTakenAndItsText() throws {
    var draft = PromptDraft("What is this? ")
    draft.append(screenChip())

    let (text, files) = try PromptExpansion.expandRecordingFiles(draft, store: store)

    XCTAssertEqual(
      text,
      "What is this? [Selected on screen in Figma — “Boltty”: /tmp/boltty-stub/pasted.png. "
        + "The whole screen, the selection outlined: /tmp/boltty-stub/pasted-screen.png. "
        + "Text read from the selection: <screen-text>Sessions 161</screen-text>]")
    XCTAssertEqual(files.map(\.file.path), ["/tmp/boltty-stub/pasted.png", "/tmp/boltty-stub/pasted-screen.png"])
    XCTAssertEqual(files.map(\.file.name), ["image1.png", "image1-screen.png"])
    XCTAssertEqual(files.first?.file.expansion, String(text.dropFirst("What is this? ".count)),
                   "the first file carries the whole bracket, so the card lifts it as one")
    XCTAssertNil(files.last?.file.expansion)
  }

  func testARegionWithNoTextAndNoWindowIsThePicturesAlone() throws {
    var draft = PromptDraft()
    draft.append(screenChip(context: nil, text: nil))

    let text = try PromptExpansion.expandRecordingFiles(draft, store: store).text

    XCTAssertEqual(
      text,
      "[Selected on screen: /tmp/boltty-stub/pasted.png. "
        + "The whole screen, the selection outlined: /tmp/boltty-stub/pasted-screen.png]")
  }

  func testALiftedScreenRequestReadsAsTheChipWithBothPictures() throws {
    var draft = PromptDraft("What is this? ")
    draft.append(screenChip())
    let (text, sent) = try PromptExpansion.expandRecordingFiles(draft, store: store)

    let lifted = SentFile.lift(request(text), files: sent.map(\.file).reversed())

    XCTAssertEqual(words(lifted), ["What is this? image1"])
    XCTAssertEqual(files(lifted).map(\.displayName), ["image1.png", "image1-screen.png"])
  }

  func testAScreenChipStoredBeforeExpansionDecodesAsItself() throws {
    let chip = screenChip()
    let decoded = try JSONDecoder().decode(PromptAttachment.self, from: JSONEncoder().encode(chip))
    XCTAssertEqual(decoded, chip)
  }
}
