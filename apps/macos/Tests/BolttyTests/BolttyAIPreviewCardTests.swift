import AppKit
import XCTest
@testable import Boltty

@MainActor
final class BolttyAIProgressTests: XCTestCase {
  private func activity(_ id: String, _ name: String, _ state: AgentActivity.State,
                        summary: String? = nil, files: [String] = []) -> ConversationPart {
    .activity(AgentActivity(id: id, name: name, summary: summary, state: state, files: files))
  }

  private func running(_ parts: [ConversationPart], started: Date = Date()) -> BolttyAISessionPreview {
    BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .codex, state: .running, body: "",
      messages: [
        ConversationMessage(id: "u", role: .user, createdAt: started.addingTimeInterval(-1),
                            completedAt: started.addingTimeInterval(-1),
                            parts: [.text(TextPart(id: "ut", kind: .text, text: "Питання"))]),
        ConversationMessage(id: "a", role: .agent, createdAt: started, parts: parts),
      ]
    )
  }

  func testTheStepIsTheOneStillRunning() {
    let value = running([
      activity("1", "read", .completed, files: ["/x/AgentPaletteView.swift"]),
      activity("2", "bash", .running, summary: "swift build"),
    ])

    XCTAssertEqual(value.currentStep, "swift build")
  }

  func testAFinishedStepStandsInWhenNothingIsRunning() {
    let value = running([activity("1", "read", .completed, files: ["/x/Deep/File.swift"])])

    XCTAssertEqual(value.currentStep, "read File.swift")
  }

  func testATurnWithNoToolCallsHasNoStepToName() {
    let value = running([.text(TextPart(id: "t", kind: .text, text: "Пишу"))])

    XCTAssertNil(value.currentStep)
  }

  func testALongStepIsTruncatedInTheMiddle() throws {
    let value = running([activity("1", "read", .running,
                                  summary: String(repeating: "очень довга назва кроку ", count: 6))])

    let step = try XCTUnwrap(value.currentStep)
    XCTAssertEqual(step.count, BolttyAISessionPreview.stepLabelLimit)
    XCTAssertTrue(step.contains("…"))
  }

}

@MainActor
final class BolttyAIRevealGateTests: XCTestCase {
  private func msg(
    _ id: String,
    _ role: ConversationMessage.Role,
    _ text: String,
    done: Bool = true,
    failure: MessageFailure? = nil
  ) -> ConversationMessage {
    ConversationMessage(
      id: id, role: role, createdAt: Date(), completedAt: done ? Date() : nil,
      parts: [.text(TextPart(id: id + "t", kind: .text, text: text))], failure: failure
    )
  }

  private func preview(
    state: AgentReportedState?,
    body: String = "",
    messages: [ConversationMessage] = [],
    question: AgentQuestion? = nil,
    notice: String? = nil,
    retryPrompt: String? = nil
  ) -> BolttyAISessionPreview {
    BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .codex, state: state, body: body,
      question: question, messages: messages, notice: notice, retryPrompt: retryPrompt
    )
  }

  func testARunningTurnStreamsTheParagraphItIsStillWriting() {
    let value = preview(state: .running, messages: [
      msg("u", .user, "Питання"),
      msg("a", .agent, "Пів від", done: false),
    ])

    XCTAssertTrue(value.withholdsAnswer)
    XCTAssertEqual(value.visibleMessages.map(\.id), ["u"], "the unfinished reply is not a row yet")
    XCTAssertEqual(value.streamingTail, "Пів від", "it streams in the live bubble instead")
    XCTAssertFalse(value.hasNothingToShowYet, "words are arriving — this is the card, not the pill")
  }

  func testATurnWithNoWordsYetIsThePill() {
    let value = preview(state: .running, messages: [msg("u", .user, "Питання")])
    XCTAssertNil(value.streamingTail)
    XCTAssertTrue(value.hasNothingToShowYet)
  }

  func testAFinishedTurnWithholdsNothing() {
    let value = preview(state: .finished, messages: [
      msg("u", .user, "Питання"),
      msg("a", .agent, "Повна відповідь."),
    ])

    XCTAssertFalse(value.withholdsAnswer)
    XCTAssertEqual(value.visibleMessages.count, 2)
    XCTAssertFalse(value.hasNothingToShowYet)
  }

  func testASecondTurnKeepsTheFinishedAnswerOnScreen() {
    let value = preview(state: .running, messages: [
      msg("u1", .user, "Перше питання"),
      msg("a1", .agent, "Перша відповідь."),
      msg("u2", .user, "Друге питання"),
      msg("a2", .agent, "Друга, ще пи", done: false),
    ])

    XCTAssertTrue(value.withholdsAnswer)
    XCTAssertEqual(value.visibleMessages.map(\.id), ["u1", "a1", "u2"])
    XCTAssertFalse(value.hasNothingToShowYet, "there is a finished answer to keep showing")
  }

  func testAQuestionOpensTheCardEvenMidTurn() {
    let value = preview(
      state: .running,
      messages: [msg("a", .agent, "Мені треба дозвіл", done: false)],
      question: AgentQuestion(
        kind: .permission,
        requestID: "req_1",
        header: "Permission",
        prompt: "Дозволити?",
        options: [.init(label: "Так", detail: nil)],
        allowsMultiple: false,
        allowsCustom: false
      )
    )

    XCTAssertFalse(value.withholdsAnswer)
    XCTAssertFalse(value.hasNothingToShowYet)
  }

  func testANoticeOrARetryPromptOpensTheCard() {
    XCTAssertFalse(preview(state: .running, notice: "Session expired").withholdsAnswer)
    XCTAssertFalse(preview(state: .running, retryPrompt: "Try again?").withholdsAnswer)
  }

  func testAFailureMidTurnStopsTheWithholding() {
    let value = preview(state: .running, messages: [
      msg("a", .agent, "Почав", done: false,
          failure: MessageFailure(name: "ProviderError", message: "Connection lost")),
    ])

    XCTAssertFalse(value.withholdsAnswer)
    XCTAssertEqual(value.visibleMessages.count, 1, "nothing is hidden once it has stopped")
  }

  func testOnlyARunningTurnWithholdsAnything() {
    for state: AgentReportedState? in [.finished, .failed, .blocked, nil] {
      XCTAssertFalse(preview(state: state, body: "Щось").withholdsAnswer, "\(String(describing: state))")
    }
  }

  // MARK: - Streaming: a finished paragraph shows while the next is written

  func testAStreamIsCutAtItsLastBlankLineOutsideAFence() {
    func split(_ text: String) -> [String] {
      let cut = StreamingProse.split(text)
      return [cut.closed, cut.open]
    }
    XCTAssertEqual(split(""), ["", ""])
    XCTAssertEqual(split("Partial"), ["", "Partial"])
    XCTAssertEqual(split("One line\nnext line"), ["", "One line\nnext line"],
                   "a single newline does not end a paragraph")
    XCTAssertEqual(split("Перший абзац.\n\nДругий пи"), ["Перший абзац.", "Другий пи"])
    XCTAssertEqual(split("One.\n\nTwo.\n\n"), ["One.\n\nTwo.", ""])
    XCTAssertEqual(split("A.\r\n\r\nB"), ["A.", "B"], "CRLF")
    XCTAssertEqual(split("Intro:\n\n```\ncode\n\nmore"), ["Intro:", "```\ncode\n\nmore"],
                   "a blank line inside an open fence is code, not the end of it")
    XCTAssertEqual(split("```\ncode\n```\n\nNext"), ["```\ncode\n```", "Next"])
    XCTAssertEqual(split("~~~\na\n\nb\n~~~\n\n- item"), ["~~~\na\n\nb\n~~~", "- item"])
  }

  func testAFinishedParagraphIsShownWhileTheNextIsWritten() {
    let value = preview(state: .running, messages: [
      msg("u", .user, "Питання"),
      msg("a", .agent, "Перший абзац.\n\nДругий пи", done: false),
    ])

    XCTAssertTrue(value.withholdsAnswer)
    XCTAssertEqual(value.visibleMessages.map(\.id), ["u", "a"])
    XCTAssertEqual(value.visibleMessages.last?.plainText.trimmingCharacters(in: .whitespacesAndNewlines),
                   "Перший абзац.")
    XCTAssertTrue(value.visibleMessages.last?.proseIsClosed == true, "so the card sets it as an answer")
    XCTAssertFalse(value.hasNothingToShowYet, "a finished paragraph is something to show")
  }

  func testProseAToolCallFollowedIsSetAsAnAnswer() throws {
    var reply = msg("a", .agent, "- **lint** → `ruff.toml`\nПочну з повного списку помилок.", done: false)
    reply.parts.append(.activity(AgentActivity(id: "t", name: "shell", summary: nil, state: .completed)))
    XCTAssertTrue(reply.proseIsClosed)

    let growing = msg("b", .agent, "Почну з повного", done: false)
    XCTAssertFalse(growing.proseIsClosed, "a paragraph nothing came after is still being written")
  }

  func testTheStreamingTailIsTheParagraphStillGrowing() {
    let reply = ConversationMessage(
      id: "a", role: .agent, createdAt: Date(), completedAt: nil,
      parts: [
        .text(TextPart(id: "t1", kind: .text, text: "Подивлюсь.")),
        .activity(AgentActivity(id: "e", name: "Edit", state: .completed)),
        .text(TextPart(id: "t2", kind: .text, text: "Готово з першим.\n\nЗараз дру")),
      ])
    XCTAssertEqual(preview(state: .running, messages: [msg("u", .user, "?"), reply]).streamingTail,
                   "Зараз дру")
    XCTAssertNil(preview(state: .running, messages: [
      msg("u", .user, "?"), msg("a", .agent, "Один.\n\n", done: false),
    ]).streamingTail, "a blank line just closed it: nothing is growing")
    XCTAssertNil(preview(state: .finished, messages: [msg("a", .agent, "Все.")]).streamingTail)
  }

  func testOnlyTheGrowingParagraphAfterTheLastToolCallIsWithheld() {
    let reply = ConversationMessage(
      id: "a", role: .agent, createdAt: Date(), completedAt: nil,
      parts: [
        .text(TextPart(id: "t1", kind: .text, text: "Подивлюсь.")),
        .activity(AgentActivity(id: "e", name: "Edit", state: .completed)),
        .text(TextPart(id: "t2", kind: .text, text: "Готово з першим.\n\nЗараз дру")),
      ])
    let value = preview(state: .running, messages: [msg("u", .user, "Питання"), reply])

    let shown = value.visibleMessages.last
    XCTAssertEqual(shown?.parts.map(\.id), ["t1", "e", "t2"])
    guard case let .text(tail)? = shown?.parts.last else { return XCTFail("no text part") }
    XCTAssertEqual(tail.text.trimmingCharacters(in: .whitespacesAndNewlines), "Готово з першим.")
  }

  func testAFinishedParagraphInFlightIsSetAsAnAnswer() throws {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: AgentPaletteMetrics.promptSize.width, height: 520)
    card.apply(preview(state: .running, messages: [
      msg("u", .user, "Питання"),
      msg("a", .agent, "Це **готовий** абзац.\n\nА цей ще пи", done: false),
    ]))
    card.layoutSubtreeIfNeeded()

    let fields = try XCTUnwrap(card.messageRowForTesting("a")?.answerViewsForTesting)
    let text = fields.map(\.attributedStringValue.string).joined(separator: "|")
    XCTAssertTrue(text.contains("Це готовий абзац."), text)
    XCTAssertFalse(text.contains("**"), "set as markdown, not shown raw: \(text)")
    XCTAssertFalse(text.contains("ще пи"), "the growing paragraph is not a row")
    XCTAssertEqual(card.streamingTailTextForTesting, "А цей ще пи", "it streams in the live bubble")
  }

  func testTheLiveBubbleFollowsTheParagraphAndLeavesWithTheTurn() {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: AgentPaletteMetrics.promptSize.width, height: 520)
    func show(_ text: String, done: Bool = false) {
      card.apply(preview(state: done ? .finished : .running, messages: [
        msg("u", .user, "Питання"), msg("a", .agent, text, done: done),
      ]))
      card.layoutSubtreeIfNeeded()
    }

    show("Перш")
    XCTAssertEqual(card.streamingTailTextForTesting, "Перш")
    show("Перший абзац")
    XCTAssertEqual(card.streamingTailTextForTesting, "Перший абзац")
    show("Перший абзац.\n\nДру")
    XCTAssertEqual(card.streamingTailTextForTesting, "Дру", "the closed paragraph moved up into a row")
    show("Перший абзац.\n\nДругий.", done: true)
    XCTAssertNil(card.streamingTailTextForTesting, "the turn is over: the whole answer is rows")
  }
}

@MainActor
final class PaletteAnswerTextTests: XCTestCase {
  private func render(_ markdown: String) -> NSAttributedString {
    PaletteAnswerText.attributed(markdown: markdown, color: .white)
  }

  private func font(_ string: NSAttributedString, at index: Int) -> NSFont? {
    string.attribute(.font, at: index, effectiveRange: nil) as? NSFont
  }

  private func style(_ string: NSAttributedString, at index: Int) -> NSParagraphStyle? {
    string.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
  }

  private func index(_ string: NSAttributedString, of needle: String) throws -> Int {
    let range = (string.string as NSString).range(of: needle)
    XCTAssertNotEqual(range.location, NSNotFound, "no \(needle) in \(string.string)")
    return range.location
  }

  // MARK: - Tables

  private func textBlocks(_ string: NSAttributedString, at index: Int) -> [NSTextBlock] {
    style(string, at: index)?.textBlocks ?? []
  }

  private static let modelsTable = """
    | Model | Cost |
    |---|---|
    | opus | high |
    | haiku | low |
    """

  func testATableIsLaidOutAsAGridRatherThanAsAParagraph() throws {
    let out = render(Self.modelsTable)

    for cell in ["Model", "Cost", "opus", "high", "haiku", "low"] {
      let blocks = textBlocks(out, at: try index(out, of: cell))
      XCTAssertEqual(blocks.count, 1, "\(cell) is not in a table cell")
      XCTAssertTrue(blocks.first is NSTextTableBlock, "\(cell) is in the wrong kind of block")
    }
  }

  func testEveryCellOfOneTableSharesOneTable() throws {
    let out = render(Self.modelsTable)

    let tables = try ["Model", "Cost", "opus", "high", "haiku", "low"].map { cell -> NSTextTable in
      try XCTUnwrap(textBlocks(out, at: try index(out, of: cell)).first as? NSTextTableBlock).table
    }

    XCTAssertEqual(Set(tables.map(ObjectIdentifier.init)).count, 1)
    XCTAssertEqual(tables[0].numberOfColumns, 2)
  }

  func testTheColumnCountFollowsTheMarkdown() throws {
    for (markdown, expected) in [
      ("| a |\n|---|\n| 1 |", 1),
      ("| a | b | c |\n|---|---|---|\n| 1 | 2 | 3 |", 3)
    ] {
      let out = render(markdown)
      let block = try XCTUnwrap(
        textBlocks(out, at: try index(out, of: "1")).first as? NSTextTableBlock
      )
      XCTAssertEqual(block.table.numberOfColumns, expected, markdown)
    }
  }

  func testCellsLandInTheRowAndColumnTheMarkdownGaveThem() throws {
    let out = render(Self.modelsTable)

    func at(_ cell: String) throws -> (row: Int, column: Int) {
      let block = try XCTUnwrap(
        textBlocks(out, at: try index(out, of: cell)).first as? NSTextTableBlock
      )
      return (block.startingRow, block.startingColumn)
    }

    XCTAssertEqual(try at("Model").column, 0)
    XCTAssertEqual(try at("Cost").column, 1)
    XCTAssertEqual(try at("opus").row, 1)
    XCTAssertEqual(try at("opus").column, 0)
    XCTAssertEqual(try at("low").row, 2)
    XCTAssertEqual(try at("low").column, 1)
    XCTAssertLessThan(try at("Model").row, try at("opus").row, "the header is above the body")
  }

  func testTheHeaderRowIsTheOnlyHeavyOne() throws {
    let out = render(Self.modelsTable)

    let header = font(out, at: try index(out, of: "Model"))
    let body = font(out, at: try index(out, of: "opus"))
    XCTAssertEqual(header?.fontDescriptor.symbolicTraits.contains(.bold), true)
    XCTAssertEqual(body?.fontDescriptor.symbolicTraits.contains(.bold), false)
  }

  func testTwoTablesInOneAnswerDoNotMerge() throws {
    let out = render("""
      | A |
      |---|
      | 1 |

      text between

      | B |
      |---|
      | 2 |
      """)

    let first = try XCTUnwrap(
      textBlocks(out, at: try index(out, of: "1")).first as? NSTextTableBlock
    ).table
    let second = try XCTUnwrap(
      textBlocks(out, at: try index(out, of: "2")).first as? NSTextTableBlock
    ).table
    XCTAssertNotIdentical(first, second)
  }

  func testProseAfterATableLeavesTheGrid() throws {
    let out = render(Self.modelsTable + "\n\nAfter the table.")

    XCTAssertTrue(textBlocks(out, at: try index(out, of: "After")).isEmpty)
  }

  // MARK: - Code

  func testAFencedBlockIsFlushAndUnwashed() throws {
    let out = render("```swift\nlet a = 1\n```")

    let at = try index(out, of: "let a")
    let paragraph = try XCTUnwrap(style(out, at: at))
    XCTAssertEqual(paragraph.firstLineHeadIndent, 0)
    XCTAssertEqual(paragraph.headIndent, 0)
    XCTAssertNil(out.attribute(.backgroundColor, at: at, effectiveRange: nil))
    XCTAssertEqual(font(out, at: at)?.isFixedPitch, true, "mono is the voice that is left")
  }

  func testInlineCodeIsNeitherWashedNorSetIn() throws {
    let out = render("Run `ffmpeg` first.")

    let at = try index(out, of: "ffmpeg")
    XCTAssertNil(out.attribute(.backgroundColor, at: at, effectiveRange: nil))
    XCTAssertEqual(style(out, at: at)?.headIndent, 0)
  }

  func testTheLinesOfAFencedBlockAreNotSeparateParagraphs() {
    let out = render("```\nfirst\nsecond\nthird\n```")

    XCTAssertFalse(
      out.string.contains("first\nsecond"),
      "a real newline here starts a new paragraph, and pays for one"
    )
    XCTAssertTrue(out.string.contains("first\u{2028}second"), out.string.debugDescription)
  }

  func testProseKeepsItsParagraphBreaks() {
    let out = render("one\n\ntwo")

    XCTAssertFalse(out.string.contains("\u{2028}"))
  }

  func testALongTokenInCodeWrapsRatherThanWidensTheCard() throws {
    let blob = String(repeating: "abcdef0123456789", count: 20)
    let out = render("```\n\(blob)\n```")

    XCTAssertEqual(style(out, at: try index(out, of: "abcdef"))?.lineBreakMode, .byCharWrapping)
  }

  func testEveryRunOfAFencedBlockSharesOneStyle() throws {
    let out = render("```\nfirst line\nsecond line\n```")

    let first = try XCTUnwrap(style(out, at: try index(out, of: "first")))
    let second = try XCTUnwrap(style(out, at: try index(out, of: "second")))
    XCTAssertIdentical(first, second)
  }

  // MARK: - Headings, rules and retractions

  func testHeadingsStepDownAsCodexSetsThem() throws {
    let out = render("# One\n\n## Two\n\n### Three\n\n#### Four\n\nBody.")
    let sizes = try ["One", "Two", "Three", "Four", "Body"].map {
      try XCTUnwrap(font(out, at: try index(out, of: $0))?.pointSize)
    }
    XCTAssertEqual(sizes, [
      AgentPaletteMetrics.answerHeading1FontSize, AgentPaletteMetrics.answerHeading2FontSize,
      AgentPaletteMetrics.answerHeading3FontSize, AgentPaletteMetrics.previewBodyFontSize,
      AgentPaletteMetrics.previewBodyFontSize,
    ])
    let one = try XCTUnwrap(style(out, at: try index(out, of: "One")))
    XCTAssertEqual(one.paragraphSpacing, AgentPaletteMetrics.answerHeading1SpacingAfter)
    XCTAssertLessThan(one.paragraphSpacing, AgentPaletteMetrics.answerParagraphSpacing)
  }

  func testARetractionIsStruckThroughRatherThanReadAsPlainText() throws {
    let out = render("~~Not this~~ but this.")

    XCTAssertFalse(out.string.contains("~"))
    let struck = out.attribute(
      .strikethroughStyle, at: try index(out, of: "Not"), effectiveRange: nil
    ) as? Int
    XCTAssertEqual(struck, NSUnderlineStyle.single.rawValue)
    XCTAssertNil(out.attribute(
      .strikethroughStyle, at: try index(out, of: "but"), effectiveRange: nil
    ))
  }

  func testAThematicBreakIsAHairlineRatherThanAParagraph() throws {
    let out = render("above\n\n---\n\nbelow")

    XCTAssertFalse(out.string.contains("⸻"))
    let rule = try index(out, of: "\u{200B}")
    let block = try XCTUnwrap(style(out, at: rule)?.textBlocks.first)
    XCTAssertEqual(block.width(for: .border, edge: .minY), 1)
    XCTAssertNil(style(out, at: try index(out, of: "above"))?.textBlocks.first)
  }

  func testAQuotesBarIsAFilledStripWhereItsBorderStands() throws {
    let out = render("> careful\n\n| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |")
    let quote = try XCTUnwrap(textBlocks(out, at: try index(out, of: "careful")).first)
    XCTAssertTrue(quote is PaletteEdgeTextBlock)
    XCTAssertTrue(textBlocks(out, at: try index(out, of: "1")).first is PaletteEdgeTableBlock)

    let rep = try XCTUnwrap(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    PaletteEdgeTextBlock.fillBorders(of: quote, in: NSRect(x: 0, y: 0, width: 100, height: 20))
    NSGraphicsContext.restoreGraphicsState()

    let bar = quote.width(for: .border, edge: .minX)
    XCTAssertGreaterThan(rep.colorAt(x: Int(bar / 2), y: 10)?.alphaComponent ?? 0, 0, "the bar is painted")
    XCTAssertEqual(rep.colorAt(x: Int(bar) + 4, y: 10)?.alphaComponent ?? 1, 0, "and nothing past it")
  }

  func testAHeadingIsSetAsAHeadingRatherThanAsItsHashes() throws {
    let out = render("## Що я вмію\n\nЗвичайний абзац.")

    XCTAssertFalse(out.string.contains("#"), "the markup survived into the text")
    let head = try index(out, of: "Що я вмію")
    XCTAssertEqual(font(out, at: head)?.pointSize, AgentPaletteMetrics.answerHeading2FontSize)

    let body = try index(out, of: "Звичайний")
    XCTAssertEqual(font(out, at: body)?.pointSize, AgentPaletteMetrics.previewBodyFontSize)
  }

  func testABulletHangsItsWrappedLinesUnderTheText() throws {
    let out = render("- Перший пункт\n- Другий пункт")

    XCTAssertTrue(out.string.contains("•\tПерший пункт"), out.string)
    let item = try index(out, of: "Перший")
    let paragraph = try XCTUnwrap(style(out, at: item))
    XCTAssertEqual(paragraph.firstLineHeadIndent, AgentPaletteMetrics.answerListMarkerIndent)
    XCTAssertEqual(paragraph.headIndent, AgentPaletteMetrics.answerListHeadIndent)
  }

  func testAnOrderedListKeepsItsNumbers() {
    let out = render("1. Перше\n2. Друге")

    XCTAssertTrue(out.string.contains("1.\tПерше"), out.string)
    XCTAssertTrue(out.string.contains("2.\tДруге"), out.string)
  }

  func testANestedItemIsIndentedPastItsParent() throws {
    let out = render("- Верхній\n    - Вкладений")

    let parent = try XCTUnwrap(style(out, at: try index(out, of: "Верхній")))
    let child = try XCTUnwrap(style(out, at: try index(out, of: "Вкладений")))
    XCTAssertGreaterThan(child.headIndent, parent.headIndent)
    XCTAssertEqual(child.headIndent - parent.headIndent,
                   AgentPaletteMetrics.answerListNestIndent)
  }

  func testABoldLeadInIsSemiboldAndTheRestIsNot() throws {
    let out = render("**Код —** правки і команди.")

    XCTAssertFalse(out.string.contains("*"))
    let lead = try index(out, of: "Код")
    let rest = try index(out, of: "правки")
    XCTAssertEqual(font(out, at: lead)?.fontDescriptor.symbolicTraits.contains(.bold), true)
    XCTAssertEqual(font(out, at: rest)?.fontDescriptor.symbolicTraits.contains(.bold), false)
  }

  func testInlineCodeIsMono() throws {
    let out = render("Виклич `paletteBlocks` звідси.")

    let code = try index(out, of: "paletteBlocks")
    XCTAssertEqual(font(out, at: code)?.isFixedPitch, true)
    XCTAssertEqual(font(out, at: code)?.pointSize, AgentPaletteMetrics.answerCodeFontSize)
    XCTAssertNil(out.attribute(.backgroundColor, at: code, effectiveRange: nil))

    let prose = try index(out, of: "Виклич")
    XCTAssertEqual(font(out, at: prose)?.isFixedPitch, false)
  }

  func testALinkKeepsItsTextAndCarriesItsURL() throws {
    let out = render("Дивись [документацію](https://example.com/docs).")

    XCTAssertFalse(out.string.contains("https://"))
    let link = try index(out, of: "документацію")
    XCTAssertNotNil(out.attribute(.link, at: link, effectiveRange: nil))
  }

  func testBlocksAreSeparatedByOneNewlineAndSpacedByTheStyle() throws {
    let out = render("Перший абзац.\n\nДругий абзац.")

    XCTAssertFalse(out.string.contains("\n\n"), out.string.debugDescription)
    XCTAssertEqual(style(out, at: try index(out, of: "Перший"))?.paragraphSpacing,
                   AgentPaletteMetrics.answerParagraphSpacing)
  }

  func testPlainProseSurvivesUntouched() {
    XCTAssertEqual(render("Просто речення без розмітки.").string,
                   "Просто речення без розмітки.")
  }

  func testAMessageSetsItsProseAndLeavesItsToolCallsToTheRows() throws {
    let message = ConversationMessage(
      id: "m", role: .agent, createdAt: Date(), completedAt: Date(),
      parts: [
        .text(TextPart(id: "t", kind: .text, text: "## Заголовок\n\nТіло.")),
        .activity(AgentActivity(id: "a", name: "read", summary: "File.swift", state: .completed)),
        .reasoning(TextPart(id: "r", kind: .reasoning, text: "Міркую.")),
      ]
    )
    let out = PaletteAnswerText.attributed(message, color: .white)

    XCTAssertTrue(out.string.contains("Заголовок"))
    XCTAssertFalse(out.string.contains("File.swift"), "a tool call is a row, not a sentence")
    XCTAssertFalse(out.string.contains("Міркую."), "reasoning does not belong in an answer")
    XCTAssertEqual(font(out, at: try index(out, of: "Заголовок"))?.pointSize,
                   AgentPaletteMetrics.answerHeading2FontSize)
  }

  /// A chat opens on its latest, and for a long answer that is its foot. With
  /// non-contiguous layout the first display down there finds no glyph and
  /// draws nothing — a chat with a long answer opens blank until it is left
  /// and opened again. Whatever lays the text out, the foot of a
  /// long answer has to be on screen the first time it is asked for.
  func testALongAnswerDrawsWhenItIsFirstShownAtItsFoot() throws {
    final class Flipped: NSView { override var isFlipped: Bool { true } }
    let paragraph = String(repeating: "Диск у стані, запас величезний, знос мінімальний. ", count: 10)
    let text = render(Array(repeating: paragraph, count: 30).joined(separator: "\n\n"))
    let width: CGFloat = 560
    let viewport: CGFloat = 520
    let height = PaletteAnswerText.height(of: text, width: width)
    XCTAssertGreaterThan(height, viewport * 3, "the answer has to be long for this to mean anything")

    let answer = PaletteAnswerTextView()
    answer.attributedStringValue = text
    answer.fit(width: width)
    let document = Flipped(frame: NSRect(x: 0, y: 0, width: width, height: height))
    document.addSubview(answer)
    NSLayoutConstraint.activate([
      answer.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      answer.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      answer.topAnchor.constraint(equalTo: document.topAnchor),
    ])
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: viewport))
    scroll.drawsBackground = true
    scroll.backgroundColor = .black
    scroll.documentView = document
    let window = NSWindow(
      contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = scroll
    addTeardownBlock { MainActor.assumeIsolated { window.close() } }
    document.layoutSubtreeIfNeeded()

    scroll.contentView.scroll(to: NSPoint(x: 0, y: height - viewport))
    scroll.reflectScrolledClipView(scroll.contentView)
    let rep = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
    scroll.cacheDisplay(in: scroll.bounds, to: rep)

    var lit = 0
    for y in 0..<rep.pixelsHigh {
      for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 0) > 0.25 {
        lit += 1
      }
    }
    XCTAssertGreaterThan(lit, rep.pixelsWide * rep.pixelsHigh / 100, "the foot of the answer drew nothing")
  }
}

@MainActor
final class PaletteMessageBlockTests: XCTestCase {
  private func text(_ id: String, _ value: String) -> ConversationPart {
    .text(TextPart(id: id, kind: .text, text: value))
  }

  private func message(
    _ parts: [ConversationPart],
    failure: MessageFailure? = nil
  ) -> ConversationMessage {
    ConversationMessage(id: "m", role: .agent, createdAt: Date(), parts: parts, failure: failure)
  }

  func testAMessageKeepsEveryPartAsItsOwnBlock() {
    let activity = AgentActivity(id: "a1", name: "read", summary: "AgentPaletteView.swift", state: .completed)
    let attachment = ConversationAttachment(id: "f1", displayName: "shot.png")
    let value = message([
      text("t1", "Before."),
      .reasoning(TextPart(id: "r1", kind: .reasoning, text: "Considering.")),
      .activity(activity),
      .attachment(attachment),
      text("t2", "After."),
    ])

    XCTAssertEqual(value.paletteBlocks, [
      .prose("Before."),
      .reasoning("Considering."),
      .activity(activity),
      .attachment(attachment),
      .prose("After."),
    ])
  }

  func testReasoningIsCarriedAsABlockAndLeftOutOfTheFlatString() {
    let value = message([
      .reasoning(TextPart(id: "r1", kind: .reasoning, text: "Thinking out loud.")),
      text("t1", "The answer."),
    ])

    XCTAssertEqual(value.paletteBlocks.first, .reasoning("Thinking out loud."))
    XCTAssertEqual(value.paletteText, "The answer.")
  }

  func testAWhitespaceOnlyPartIsNotABlock() {
    let value = message([text("t1", "   \n  "), text("t2", "Real.")])

    XCTAssertEqual(value.paletteBlocks, [.prose("Real.")])
    XCTAssertEqual(value.paletteText, "Real.")
  }

  func testAnEmptyPartIsNotABlock() {
    XCTAssertEqual(message([text("t1", "")]).paletteBlocks, [])
    XCTAssertTrue(message([text("t1", "")]).paletteText.isEmpty)
  }

  func testAFailureLandsAsTheLastBlockAndAnAbortIsNotOne() {
    let failed = message(
      [text("t1", "Got this far.")],
      failure: MessageFailure(name: "ProviderError", message: "Connection lost")
    )
    XCTAssertEqual(failed.paletteBlocks.last, .failure("Connection lost"))
    XCTAssertEqual(failed.paletteText, "Got this far.\n\nConnection lost")

    let aborted = message([], failure: MessageFailure(name: "MessageAbortedError", message: "nope"))
    XCTAssertEqual(aborted.paletteBlocks, [.failure("Stopped")])
  }

  func testAFailureAloneCarriesNoLeadingSeparator() {
    let value = message([], failure: MessageFailure(name: "ProviderError", message: "Connection lost"))

    XCTAssertEqual(value.paletteText, "Connection lost")
  }

  func testTheFlatStringIsUnchangedForEverythingButReasoning() {
    let value = message([
      text("t1", "Before."),
      .activity(AgentActivity(id: "a1", name: "read", summary: nil, state: .completed, files: ["/x/Deep/File.swift"])),
      .attachment(ConversationAttachment(id: "f1", displayName: "shot.png")),
    ])

    XCTAssertEqual(value.paletteText, "Before.\n\nread File.swift\n\nshot.png")
  }

  func testResultFilesCollectActivityFilesInOrder() {
    let value = message([
      text("t1", "Done."),
      .activity(AgentActivity(id: "a1", name: "write", state: .completed, files: ["/tmp/out.mp4"])),
      .activity(AgentActivity(id: "a2", name: "edit", state: .completed, files: ["/tmp/out.mp4", "/tmp/src.mov"])),
    ])

    XCTAssertEqual(value.resultFiles, ["/tmp/out.mp4", "/tmp/src.mov"])
  }

  func testAReadOrASearchIsNotAResult() {
    let value = message([
      .activity(AgentActivity(id: "a1", name: "read", state: .completed, files: ["/Users/me"])),
      .activity(AgentActivity(id: "a2", name: "read", state: .completed, files: ["/tmp/README.md"])),
      .activity(AgentActivity(id: "a3", name: "grep", state: .completed, files: ["/tmp/hit.swift"])),
      .activity(AgentActivity(id: "a4", name: "write", state: .completed, files: ["/tmp/new.md"])),
    ])

    XCTAssertEqual(value.resultFiles, ["/tmp/new.md"])
  }

  func testResultFilesIncludeAttachmentsThatHaveACopy() {
    let value = message([
      .attachment(ConversationAttachment(id: "f1", displayName: "shot.png")),
      .attachment(ConversationAttachment(
        id: "f2",
        displayName: "clip.mov",
        url: URL(fileURLWithPath: "/tmp/clip.mov")
      )),
    ])

    XCTAssertEqual(value.resultFiles, ["/tmp/clip.mov"])
  }

  func testAToolOnlyMessageStillReportsItsFiles() {
    let value = message([
      .activity(AgentActivity(id: "a1", name: "bash", state: .completed, files: ["/tmp/out.mp4"])),
    ])

    XCTAssertTrue(value.paletteText.contains("bash"))
    XCTAssertEqual(value.resultFiles, ["/tmp/out.mp4"])
  }

  func testAMessageWithNoFilesReportsNone() {
    XCTAssertEqual(message([text("t1", "Just words.")]).resultFiles, [])
  }

  // MARK: - The answer is prose

  func testAnAnswerIsOneRunAndAFailureIsNotInIt() {
    let shown = PaletteAnswerRun.shown([.prose("A.\n\nB."), .failure("HTTP 529"), .reasoning("hm")])
    XCTAssertEqual(shown, [.prose("A.\n\nB.")])
  }

  func testAStopIsANoteAndAReplyThatOnlyFailedDrawsNothing() throws {
    let stopped = ConversationMessage(
      id: "s", role: .agent, createdAt: Date(), parts: [.text(TextPart(id: "t", kind: .text, text: "Half"))],
      failure: MessageFailure(name: "MessageAbortedError", message: "aborted"))
    XCTAssertTrue(PaletteChatMessageView.draws(stopped))
    XCTAssertTrue(try XCTUnwrap(MessageFailure(name: "MessageAbortedError", message: "aborted")).isAbort,
                  "the fixture has to be an abort for this to say anything")
    let onlyFailed = ConversationMessage(
      id: "f", role: .agent, createdAt: Date(), parts: [],
      failure: MessageFailure(name: "ProviderError", message: "HTTP 529"))
    XCTAssertFalse(PaletteChatMessageView.draws(onlyFailed),
                   "its words are the card's, and an empty row is a gap")
  }
}

@MainActor
final class BolttyAIPreviewCardTests: XCTestCase {
  func testAReplyBecomesARowWhenItLandsAndKeepsThatRow() {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: 520, height: 260)
    let user = ConversationMessage(id: "u", role: .user, createdAt: Date(), parts: [.text(TextPart(id: "ut", kind: .text, text: "Hello"))])
    var value = BolttyAISessionPreview(id: UUID(), title: "Chat", agent: .opencode, state: .running, body: "", messages: [user])
    card.apply(value)
    XCTAssertEqual(card.messageCountForTesting, 1, "the question stands while the first turn runs")
    XCTAssertFalse(card.workingLineForTesting.isHidden)
    card.suspendAnimations()
    XCTAssertFalse(card.workingLineForTesting.showsFaceForTesting)
    card.apply(value)
    XCTAssertTrue(card.workingLineForTesting.showsFaceForTesting)

    var answer = ConversationMessage(id: "a", role: .agent, createdAt: Date(), parts: [.text(TextPart(id: "at", kind: .text, text: "Hello back"))])
    value.messages.append(answer)
    card.apply(value)
    XCTAssertTrue(value.withholdsAnswer)
    XCTAssertEqual(card.messageCountForTesting, 1, "a half-written reply is not a row")

    answer.parts = [.text(TextPart(id: "at", kind: .text, text: "Hello back and more"))]
    answer.completedAt = Date()
    value.messages[1] = answer
    value = BolttyAISessionPreview(id: value.id, title: value.title, agent: value.agent,
                                    state: .finished, body: "", messages: value.messages)
    card.apply(value)
    XCTAssertEqual(card.messageCountForTesting, 2)

    let identity = card.messageIdentityForTesting("a")
    card.apply(value)
    XCTAssertEqual(card.messageIdentityForTesting("a"), identity)
  }

  func testResumingStartsTheTurnClockAnUnchangedPreviewLeavesStopped() {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: 520, height: 260)
    let user = ConversationMessage(id: "u", role: .user, createdAt: Date(), parts: [.text(TextPart(id: "ut", kind: .text, text: "Build it"))])
    let running = BolttyAISessionPreview(id: UUID(), title: "Chat", agent: .codex, state: .running, body: "", messages: [user])
    card.apply(running)
    XCTAssertTrue(card.turnClockIsRunningForTesting, "precondition: a running turn keeps time")

    card.suspendAnimations()
    card.apply(running)
    XCTAssertFalse(card.turnClockIsRunningForTesting, "the same preview starts nothing")
    card.resumeAnimations()
    XCTAssertTrue(card.turnClockIsRunningForTesting)

    let finished = BolttyAISessionPreview(id: running.id, title: "Chat", agent: .codex, state: .finished, body: "", messages: [user])
    card.apply(finished)
    card.resumeAnimations()
    XCTAssertFalse(card.turnClockIsRunningForTesting, "a turn that is over has no clock to start")
  }

  func testStreamingDoesNotPullAReaderAwayFromEarlierMessages() {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: 520, height: 220)
    let answer = ConversationMessage(id: "a", role: .agent, createdAt: Date(), parts: [.text(TextPart(id: "at", kind: .text, text: String(repeating: "A readable line of history.\n", count: 50)))])
    var preview = BolttyAISessionPreview(id: UUID(), title: "History", agent: .opencode, state: .running, body: "", messages: [answer])
    card.apply(preview)
    card.layoutSubtreeIfNeeded()
    card.scrollForTesting(to: 80)
    preview.messages[0].parts.append(.text(TextPart(id: "new", kind: .text, text: "New output")))
    card.apply(preview)
    card.layoutSubtreeIfNeeded()
    XCTAssertEqual(card.scrollOffsetForTesting, 80, accuracy: 1)
  }

  func testResizingTheCardReflowsMarkdownWithoutReplacingItsMessage() throws {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
    let answer = ConversationMessage(
      id: "a", role: .agent, createdAt: Date(), completedAt: Date(),
      parts: [.text(TextPart(
        id: "at", kind: .text,
        text: String(repeating: "The **report** compares rendering geometry and stable state boundaries. ", count: 30)
      ))]
    )
    card.apply(BolttyAISessionPreview(
      id: UUID(), title: "History", agent: .opencode, state: .finished,
      body: "", messages: [answer]
    ))
    card.layoutSubtreeIfNeeded()
    card.layoutSubtreeIfNeeded()
    let row = try XCTUnwrap(card.messageRowForTesting("a"))
    let identity = card.messageIdentityForTesting("a")
    let initialRowHeight = row.frame.height
    let initialMeasure = card.measuredHeight()

    card.setFrameSize(NSSize(width: 650, height: 320))
    card.layoutSubtreeIfNeeded()
    card.layoutSubtreeIfNeeded()

    XCTAssertEqual(card.messageIdentityForTesting("a"), identity)
    XCTAssertEqual(card.contentWidthForTesting,
      650 - AgentPaletteMetrics.previewContentHorizontalPadding * 2, accuracy: 0.5)
    XCTAssertLessThan(row.frame.height, initialRowHeight, "the wider card actually wraps fewer lines")
    XCTAssertEqual(initialMeasure - card.measuredHeight(),
      initialRowHeight - row.frame.height, accuracy: 1,
      "the height measure uses the same width as the row on screen")

    card.setFrameSize(NSSize(width: 520, height: 320))
    card.layoutSubtreeIfNeeded()
    card.layoutSubtreeIfNeeded()
    XCTAssertEqual(card.measuredHeight(), initialMeasure, accuracy: 0.5)
    XCTAssertEqual(card.messageIdentityForTesting("a"), identity)
  }

  func testQuestionAndQueuedMessageReflowAtTheCardsCurrentWidth() {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
    let question = AgentQuestion(
      kind: .question, requestID: "width", header: "Rendering",
      prompt: String(repeating: "Choose the most useful rendering option for this project. ", count: 6),
      options: [.init(label: String(repeating: "Adapt to the available display space. ", count: 8), detail: nil)],
      allowsMultiple: false, allowsCustom: true
    )
    card.apply(BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .opencode, state: .blocked, body: "",
      question: question,
      queuedPrompt: String(repeating: "Then compare the selected result with the original geometry. ", count: 8)
    ))
    card.layoutSubtreeIfNeeded()
    card.layoutSubtreeIfNeeded()
    let initialMeasure = card.measuredHeight()
    let initialContentHeight = card.contentHeightForTesting

    card.setFrameSize(NSSize(width: 650, height: 320))
    card.layoutSubtreeIfNeeded()
    card.layoutSubtreeIfNeeded()
    XCTAssertLessThan(card.measuredHeight(), initialMeasure)
    XCTAssertLessThan(card.contentHeightForTesting, initialContentHeight,
      "service cards lay out against the wider viewport too")

    card.setFrameSize(NSSize(width: 400, height: 320))
    card.layoutSubtreeIfNeeded()
    card.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(card.measuredHeight(), initialMeasure)
    XCTAssertGreaterThan(card.contentHeightForTesting, initialContentHeight)
    XCTAssertLessThanOrEqual(card.contentWidthForTesting,
      card.viewportBoundsForTesting.width + 0.5, "the service cards never widen the transcript")
  }

  private func makeScrollableTranscript() -> BolttyAIPreviewCard {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: 520, height: 220)
    let answer = ConversationMessage(
      id: "a", role: .agent, createdAt: Date(), completedAt: Date(),
      parts: [.text(TextPart(
        id: "at", kind: .text,
        text: String(repeating: "A readable line of history.\n", count: 120)
      ))]
    )
    let preview = BolttyAISessionPreview(
      id: UUID(), title: "History", agent: .opencode, state: nil,
      body: "", messages: [answer]
    )
    card.apply(preview)
    card.layoutSubtreeIfNeeded()
    card.layoutSubtreeIfNeeded()
    XCTAssertTrue(
      card.isScrollableForTesting,
      "precondition: \(card.contentHeightForTesting)pt of transcript in a "
        + "\(card.viewportBoundsForTesting.height)pt viewport"
    )
    return card
  }

  private func scroll(_ card: BolttyAIPreviewCard, toDistanceFromFloor distance: CGFloat) {
    let floor = card.contentHeightForTesting - card.viewportBoundsForTesting.height
    card.scrollForTesting(to: floor - distance)
  }

  func testFollowingAndThePillAreTwoSeparateDecisions() {
    let card = makeScrollableTranscript()
    scroll(card, toDistanceFromFloor: 0)
    XCTAssertTrue(card.followsBottomForTesting)
    XCTAssertFalse(card.isLatestPillVisibleForTesting)

    scroll(card, toDistanceFromFloor: AgentPaletteMetrics.transcriptFollowSlack + 10)
    XCTAssertFalse(card.followsBottomForTesting, "one nudge is an answer")
    XCTAssertFalse(
      card.isLatestPillVisibleForTesting,
      "a pill covering the transcript for a 50pt scroll is noise"
    )

    scroll(card, toDistanceFromFloor: AgentPaletteMetrics.transcriptLatestPillSlack + 10)
    XCTAssertFalse(card.followsBottomForTesting)
    XCTAssertTrue(card.isLatestPillVisibleForTesting)
  }

  func testTheQuietBandBetweenTheTwoThresholdsExists() {
    XCTAssertLessThan(
      AgentPaletteMetrics.transcriptFollowSlack,
      AgentPaletteMetrics.transcriptLatestPillSlack,
      "the pill must never appear before following has stopped"
    )
    let card = makeScrollableTranscript()
    let middle = (AgentPaletteMetrics.transcriptFollowSlack
                  + AgentPaletteMetrics.transcriptLatestPillSlack) / 2
    scroll(card, toDistanceFromFloor: middle)
    XCTAssertFalse(card.followsBottomForTesting)
    XCTAssertFalse(card.isLatestPillVisibleForTesting)
  }

  func testGoingBackToTheLatestResumesFollowing() {
    let card = makeScrollableTranscript()
    scroll(card, toDistanceFromFloor: AgentPaletteMetrics.transcriptLatestPillSlack + 10)
    XCTAssertTrue(card.isLatestPillVisibleForTesting, "precondition: the pill is up")

    card.scrollToLatestForTesting()

    XCTAssertTrue(card.followsBottomForTesting)
    XCTAssertFalse(card.isLatestPillVisibleForTesting)
  }

  func testPanelDraftRoundTripsWithAttachmentOrder() throws {
    let draft = PromptDraft(elements: [.text("Read "), .attachment(PromptAttachment(kind: .text, payload: .text("source"), label: "text1")), .text(" then explain")])
    var conversation = Conversation(title: "Test", workingDirectory: "/tmp")
    conversation.panelDraft = draft
    let decoded = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
    XCTAssertEqual(decoded.panelDraft, draft)
  }

  func testAThousandLinesAnUnbreakableURLAndCodeAllStayInsideTheCard() {
    let url = "https://example.com/" + String(repeating: "x", count: 280)
    var lines = (1...1000).map { "Line \($0) of an answer long enough to outrun any viewport." }
    lines.append(url)
    lines.append(contentsOf: ["```swift", "let answer = Transcript(lines: 1000)", "```"])
    let card = makeCard(body: lines.joined(separator: "\n"), height: 520)
    card.setFloatingBottomInset(chip: 40, composer: 96)
    card.layoutSubtreeIfNeeded()

    XCTAssertTrue(card.isScrollableForTesting, "precondition: a thousand lines do not fit")

    XCTAssertLessThanOrEqual(
      card.contentWidthForTesting,
      card.viewportBoundsForTesting.width + 0.5,
      "a 300-character URL has to wrap, not widen the transcript"
    )

    XCTAssertGreaterThanOrEqual(
      card.contentInsetsForTesting.bottom,
      96 + 40,
      "the transcript must clear the composer and the chip, not end under them"
    )

    card.scrollForTesting(to: -card.contentInsetsForTesting.top)
    XCTAssertEqual(
      card.scrollOffsetForTesting,
      -AgentPaletteMetrics.previewHeaderHeight,
      accuracy: 0.5,
      "the top of a thousand lines is still the top"
    )
  }

  private func makeCard(
    body: String,
    height: CGFloat,
    question: AgentQuestion? = nil
  ) -> BolttyAIPreviewCard {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: AgentPaletteMetrics.promptSize.width, height: height)
    card.apply(preview(body: body, question: question))
    card.layoutSubtreeIfNeeded()
    return card
  }

  private func preview(body: String, question: AgentQuestion? = nil) -> BolttyAISessionPreview {
    BolttyAISessionPreview(
      id: UUID(),
      title: "session",
      agent: .claude,
      state: nil,
      body: body,
      question: question
    )
  }

  private func question(
    multiple: Bool = false,
    labels: [String] = ["Upscayl", "Topaz", "Real-ESRGAN"]
  ) -> AgentQuestion {
    AgentQuestion(
      kind: .question,
      requestID: "qst_1",
      header: "Upscaler",
      prompt: "Which upscaler?",
      options: labels.map { .init(label: $0, detail: nil) },
      allowsMultiple: multiple,
      allowsCustom: true
    )
  }

  func testTheBodyIsSetTheWayTheMockSetsIt() {
    let card = makeCard(body: "Доступно на всіх платних планах Claude.", height: 400)
    let attributes = card.bodyAttributesForTesting

    let font = try? XCTUnwrap(attributes[.font] as? NSFont)
    XCTAssertEqual(font?.pointSize, 15)
    XCTAssertEqual(font?.pointSize, AgentPaletteMetrics.previewBodyFontSize)
    XCTAssertEqual(
      font?.fontName,
      roundedAppFont(size: AgentPaletteMetrics.previewBodyFontSize, weight: .regular).fontName
    )
    XCTAssertNil(attributes[.kern])

    let insets = card.contentInsetsForTesting
    XCTAssertEqual(insets.top, AgentPaletteMetrics.previewHeaderHeight, accuracy: 0.5)
    XCTAssertEqual(insets.bottom, AgentPaletteMetrics.previewContentVerticalPadding, accuracy: 0.01)
    XCTAssertEqual(insets.left, AgentPaletteMetrics.shellContentInset, accuracy: 0.5)
    XCTAssertEqual(insets.right, AgentPaletteMetrics.shellContentInset, accuracy: 0.5)
  }

  func testAScrolledAnswerReachesTheRim() {
    let body = (1...80).map { "Line \($0) of a reply long enough to scroll." }.joined(separator: "\n")
    let card = makeCard(body: body, height: 220)

    XCTAssertEqual(
      card.viewportFrameForTesting.height,
      card.viewportBoundsForTesting.height,
      accuracy: 0.01,
      "the viewport must span the scroll view, or the text can never reach a rim"
    )

    XCTAssertEqual(
      card.contentInsetsForTesting.top,
      AgentPaletteMetrics.previewHeaderHeight,
      accuracy: 0.01
    )
    XCTAssertGreaterThan(
      AgentPaletteMetrics.previewHeaderHeight,
      AgentPaletteMetrics.previewCloseInset + AgentPaletteMetrics.previewCloseDiameter,
      "the band has to clear the disc, not merely match it"
    )

    XCTAssertEqual(
      card.scrollOffsetForTesting,
      -AgentPaletteMetrics.previewHeaderHeight,
      accuracy: 0.5
    )

    card.scrollForTesting(to: 200)
    XCTAssertGreaterThan(
      card.scrollOffsetForTesting,
      AgentPaletteMetrics.previewCloseInset,
      "the answer travels behind the disc rather than stopping under it"
    )
    XCTAssertEqual(card.edgeOpacityForTesting(atY: 0), 0, accuracy: 0.001)
    XCTAssertLessThan(
      card.edgeOpacityForTesting(atY: AgentPaletteMetrics.previewCloseInset), 0.5,
      "the text is mostly gone where the disc begins")
  }

  // MARK: - The agent's question

  func testStreamingAnAnswerPreservesTheReadersScrollPosition() {
    let body = (1...100).map { "Line \($0) of the answer" }.joined(separator: "\n")
    let card = makeCard(body: body, height: 260)
    let first = preview(body: body)
    card.apply(first)
    card.layoutSubtreeIfNeeded()
    card.scrollForTesting(to: 120)
    XCTAssertGreaterThan(card.scrollOffsetForTesting, 0)
    card.apply(.init(id: first.id, title: first.title, agent: first.agent, state: nil,
                     body: body + "\nAnother streamed line"))
    XCTAssertGreaterThan(card.scrollOffsetForTesting, 0,
                         "streaming must not jump back to the start while reading")
  }

  func testTheQuestionIsVisibleEvenWhenThePreviousReplyHasNoQuestionText() {
    let card = makeCard(body: "Previous answer", height: 400, question: question())
    XCTAssertTrue(card.bodyForTesting.contains("Which upscaler?"))
  }

  func testAQuestionBecomesRowsWithTheFirstOneChosen() {
    let card = makeCard(body: "Pick one.", height: 400, question: question())

    XCTAssertTrue(card.isAnswering)
    XCTAssertEqual(card.optionLabelsForTesting, ["Upscayl", "Topaz", "Real-ESRGAN"])
    XCTAssertEqual(card.chosenOptionLabelsForTesting, ["Upscayl"])
  }

  func testNoQuestionMeansNoRows() {
    let card = makeCard(body: "Just an answer.", height: 400)

    XCTAssertFalse(card.isAnswering)
    XCTAssertTrue(card.optionLabelsForTesting.isEmpty)
  }

  func testMovingChoosesWhenOnlyOneAnswerIsAllowed() {
    let card = makeCard(body: "Pick one.", height: 400, question: question())

    XCTAssertTrue(card.moveOptionFocus(by: 1))
    XCTAssertEqual(card.chosenOptionLabelsForTesting, ["Topaz"])
    XCTAssertEqual(card.focusedOptionIndex, 1)
  }

  func testFocusStopsAtTheEnds() {
    let card = makeCard(body: "Pick one.", height: 400, question: question())

    card.moveOptionFocus(by: -5)
    XCTAssertEqual(card.focusedOptionIndex, 0)
    card.moveOptionFocus(by: 99)
    XCTAssertEqual(card.focusedOptionIndex, 2)
  }

  func testConfirmingSendsTheAgentsOwnLabel() {
    let card = makeCard(body: "Pick one.", height: 400, question: question())
    var answered: (AgentQuestion, [String])?
    card.onAnswer = { answered = ($0, $1) }

    card.moveOptionFocus(by: 2)
    XCTAssertTrue(card.confirmOptions())

    XCTAssertEqual(answered?.0.requestID, "qst_1")
    XCTAssertEqual(answered?.1, ["Real-ESRGAN"])
  }

  func testSeveralAnswersStartEmptyAndRefuseAnEmptyConfirm() {
    let card = makeCard(body: "Pick some.", height: 400, question: question(multiple: true))
    var answered = false
    card.onAnswer = { _, _ in answered = true }

    XCTAssertTrue(card.chosenOptionLabelsForTesting.isEmpty)
    card.moveOptionFocus(by: 1)
    XCTAssertTrue(card.chosenOptionLabelsForTesting.isEmpty)
    XCTAssertFalse(card.confirmOptions())
    XCTAssertFalse(answered)

    XCTAssertTrue(card.toggleFocusedOption())
    card.moveOptionFocus(by: 1)
    XCTAssertTrue(card.toggleFocusedOption())
    XCTAssertEqual(card.chosenOptionLabelsForTesting, ["Topaz", "Real-ESRGAN"])
    XCTAssertTrue(card.confirmOptions())
  }

  func testAnotherTickOfTheSameQuestionKeepsTheChoice() {
    let asked = question()
    let card = makeCard(body: "Pick one.", height: 400, question: asked)

    card.moveOptionFocus(by: 1)
    card.apply(preview(body: "Pick one. Still thinking…", question: asked))

    XCTAssertEqual(card.chosenOptionLabelsForTesting, ["Topaz"])
    XCTAssertEqual(card.focusedOptionIndex, 1)
  }

  func testAnAnsweredQuestionTakesItsRowsAway() {
    let card = makeCard(body: "Pick one.", height: 400, question: question())

    card.apply(preview(body: "Done — installed Upscayl."))

    XCTAssertFalse(card.isAnswering)
    XCTAssertTrue(card.optionLabelsForTesting.isEmpty)
  }

  func testTheTextDissolvesOnlyUnderTheFloatingControls() {
    let body = (1...80).map { "Line \($0) of a reply long enough to scroll." }.joined(separator: "\n")
    let card = makeCard(body: body, height: 600)
    let field: CGFloat = 140
    let band = AgentPaletteMetrics.surfaceStackSpacing + field + AgentPaletteMetrics.shellContentInset
    card.setFloatingBottomInset(chip: 0, composer: band)
    card.layoutSubtreeIfNeeded()
    XCTAssertTrue(card.isScrollableForTesting)
    XCTAssertNotNil(card.edgeMaskForTesting)
    XCTAssertTrue(card.edgeMaskRunsTopDownForTesting, "location 0 is the card's top")

    let height: CGFloat = 600
    let composerTop = height - field - AgentPaletteMetrics.shellContentInset
    let padding = AgentPaletteMetrics.previewContentVerticalPadding

    XCTAssertEqual(card.edgeOpacityForTesting(atY: 0), 0, accuracy: 0.001, "the rim, under the disc")
    XCTAssertEqual(
      card.edgeOpacityForTesting(atY: AgentPaletteMetrics.previewHeaderHeight), 1, accuracy: 0.001,
      "the first line at rest is whole")
    XCTAssertEqual(card.edgeOpacityForTesting(atY: height / 2), 1, accuracy: 0.001)
    XCTAssertEqual(
      card.edgeOpacityForTesting(atY: composerTop - AgentPaletteMetrics.surfaceStackSpacing - padding),
      1, accuracy: 0.001, "the last line at rest, a padding over the composer's band, is whole")
    XCTAssertLessThan(card.edgeOpacityForTesting(atY: composerTop + 1), 0.6, "under the composer's edge it goes")
    XCTAssertEqual(card.edgeOpacityForTesting(atY: composerTop + field / 2), 0, accuracy: 0.001)
    XCTAssertEqual(
      card.edgeOpacityForTesting(atY: height - AgentPaletteMetrics.shellContentInset / 2), 0, accuracy: 0.001,
      "nothing shows in the strip under the composer")

    let short = makeCard(body: "Short answer.", height: 400)
    XCTAssertFalse(short.isScrollableForTesting)
    XCTAssertEqual(short.edgeOpacityForTesting(atY: AgentPaletteMetrics.previewHeaderHeight), 1, accuracy: 0.001)
  }

  @MainActor
  func testSelectableRepliesKeepTheirTypographyWhenClicked() {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: AgentPaletteMetrics.promptSize.width, height: 300)
    let answer = ConversationMessage(
      id: "a", role: .agent, createdAt: Date(),
      parts: [.text(TextPart(id: "at", kind: .text, text: "A readable line of history."))]
    )
    card.apply(BolttyAISessionPreview(
      id: UUID(), title: "History", agent: .opencode, state: .finished,
      body: "A readable line of history.", messages: [answer]
    ))
    card.layoutSubtreeIfNeeded()

    let labels = card.selectableLabelsForTesting
    XCTAssertFalse(labels.isEmpty, "precondition: there is something to select")
    for label in labels where label.isSelectable {
      XCTAssertTrue(
        label.allowsEditingTextAttributes,
        "a plain-text field editor would repaint this in the system font"
      )
      XCTAssertFalse(label.isEditable, "selectable, never editable")
    }
  }
}

// MARK: - The failure card

@MainActor
final class BolttyAIFailureCardTests: XCTestCase {
  private func card(_ preview: BolttyAISessionPreview) -> BolttyAIPreviewCard {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
    card.apply(preview)
    card.layoutSubtreeIfNeeded()
    return card
  }

  private func failedPreview(
    notice: String? = "opencode: SystemPrompt.environment — undefined is not an object",
    retryPrompt: String? = nil,
    messages: [ConversationMessage] = []
  ) -> BolttyAISessionPreview {
    BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .opencode, state: .failed, body: "",
      messages: messages, notice: notice, retryPrompt: retryPrompt
    )
  }

  func testAFailedTurnDrawsTheCardAndNotTheRawLine() {
    let card = card(failedPreview())

    XCTAssertTrue(card.isFailureCardVisibleForTesting)
    XCTAssertNil(card.statusTextForTesting, "the status line no longer carries failures")
    XCTAssertEqual(
      card.failureCardForTesting.visibleSentenceForTesting,
      AgentFailureReport.universalSentence
    )
  }

  func testNoProviderTextIsVisibleUntilDetailsAreOpened() {
    let card = card(failedPreview())
    let failure = card.failureCardForTesting

    XCTAssertFalse(failure.isShowingDetailsForTesting)
    XCTAssertFalse(
      failure.visibleSentenceForTesting.contains("undefined is not an object"),
      "the CLI's own line must not be the sentence"
    )

    failure.toggleDetailsForTesting()
    XCTAssertTrue(failure.isShowingDetailsForTesting)
    XCTAssertTrue(failure.detailsTextForTesting.contains("undefined is not an object"))
  }

  func testFailureDetailsUseTheResizedTranscriptWidth() {
    let evidence = String(repeating: "The provider refused the operation while loading the current session. ", count: 12)
    let card = card(failedPreview(notice: evidence))
    card.failureCardForTesting.toggleDetailsForTesting()
    card.layoutSubtreeIfNeeded()
    card.layoutSubtreeIfNeeded()
    let initialMeasure = card.measuredHeight()
    let initialFailureHeight = card.failureCardForTesting.frame.height

    card.setFrameSize(NSSize(width: 650, height: 320))
    card.layoutSubtreeIfNeeded()
    card.layoutSubtreeIfNeeded()
    let widerMeasure = card.measuredHeight()
    card.layoutSubtreeIfNeeded()
    card.layoutSubtreeIfNeeded()

    XCTAssertLessThan(widerMeasure, initialMeasure)
    XCTAssertLessThan(card.failureCardForTesting.frame.height, initialFailureHeight)
    XCTAssertTrue(card.failureCardForTesting.isShowingDetailsForTesting,
      "resizing preserves the drawer the reader opened")
    XCTAssertEqual(card.failureCardForTesting.detailsTextForTesting,
      evidence.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  func testANewFailureCollapsesTheDetailsAgain() {
    let card = card(failedPreview())
    let failure = card.failureCardForTesting
    failure.toggleDetailsForTesting()
    XCTAssertTrue(failure.isShowingDetailsForTesting)

    card.apply(failedPreview(notice: "claude: Invalid session ID. Must be a valid UUID."))
    XCTAssertFalse(
      failure.isShowingDetailsForTesting,
      "raw text would otherwise be on screen by default again"
    )
  }

  func testCopyPutsTheEvidenceOnThePasteboardVerbatim() {
    let raw = "opencode: SystemPrompt.environment — undefined is not an object"
    let card = card(failedPreview(notice: raw))
    NSPasteboard.general.clearContents()

    card.failureCardForTesting.copyDetailsForTesting()

    XCTAssertEqual(NSPasteboard.general.string(forType: .string), raw)
  }

  func testRetryIsOfferedOnlyWithAPromptAndSendsItOnce() {
    XCTAssertFalse(
      card(failedPreview()).failureCardForTesting.isRetryVisibleForTesting,
      "nothing to send again"
    )

    let card = card(failedPreview(retryPrompt: "Check my SSD"))
    var sent: [String] = []
    card.onRetry = { sent.append($0) }
    XCTAssertTrue(card.failureCardForTesting.isRetryVisibleForTesting)

    card.failureCardForTesting.retryForTesting()
    card.failureCardForTesting.retryForTesting()

    XCTAssertEqual(sent, ["Check my SSD"], "a second press is a duplicate turn, not a faster one")
  }

  func testTheRestoreButtonStandsDownWhileTheCardIsUp() {
    XCTAssertFalse(
      card(failedPreview(retryPrompt: "Check my SSD")).isRecoverVisibleForTesting
    )
    XCTAssertTrue(
      card(BolttyAISessionPreview(
        id: UUID(), title: "Chat", agent: .opencode, state: .finished, body: "Done",
        messages: [], notice: nil, retryPrompt: "An unsent draft"
      )).isRecoverVisibleForTesting,
      "no failure — the draft can still be restored"
    )
  }

  func testAnEmptyButSuccessfulTurnKeepsItsOrdinaryStatusLine() {
    let user = ConversationMessage(
      id: "u", role: .user, createdAt: Date(), completedAt: Date(),
      parts: [.text(TextPart(id: "ut", kind: .text, text: "Hello"))]
    )
    let card = card(BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .opencode, state: .finished, body: "",
      messages: [user]
    ))

    XCTAssertFalse(card.isFailureCardVisibleForTesting)
    XCTAssertEqual(card.statusTextForTesting, "Finished without a text response.")
  }
}

@MainActor
final class PaletteFileRowViewTests: XCTestCase {
  private func temporaryFile(named name: String, contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  func testAnExistingFileShowsItsNameAndSize() throws {
    let url = try temporaryFile(named: "boltty-row-test.mp4", contents: "eleven bytes")
    defer { try? FileManager.default.removeItem(at: url) }
    let row = PaletteFileRowView(path: url.path)

    XCTAssertEqual(row.displayedNameForTesting, "boltty-row-test.mp4")
    XCTAssertFalse(row.displayedSizeForTesting.isEmpty)
    XCTAssertFalse(row.isDimmedForTesting)
    XCTAssertFalse(row.useButtonForTesting.isHidden, "the composer exists, so Use always has somewhere to go")
  }

  func testAMissingFileDimsInsteadOfVanishing() {
    let row = PaletteFileRowView(path: "/tmp/boltty-definitely-not-here.mov")

    XCTAssertEqual(row.displayedNameForTesting, "boltty-definitely-not-here.mov")
    XCTAssertEqual(row.displayedSizeForTesting, "No longer on disk")
    XCTAssertTrue(row.isDimmedForTesting)
    XCTAssertFalse(row.previewButtonForTesting.isEnabled)
    XCTAssertFalse(row.revealButtonForTesting.isEnabled)
    XCTAssertTrue(row.useButtonForTesting.isHidden, "nothing to attach when the file is gone")
  }

  func testButtonsFireWithTheRowsURL() throws {
    let url = try temporaryFile(named: "boltty-row-action.mp4", contents: "x")
    defer { try? FileManager.default.removeItem(at: url) }
    let row = PaletteFileRowView(path: url.path)
    var previewed: [URL] = []
    var revealed: [URL] = []
    var used: [URL] = []
    row.onPreview = { previewed.append($0) }
    row.onReveal = { revealed.append($0) }
    row.onUse = { used.append($0) }

    row.previewButtonForTesting.performClick(nil)
    row.revealButtonForTesting.performClick(nil)
    row.useButtonForTesting.performClick(nil)

    XCTAssertEqual(previewed, [url])
    XCTAssertEqual(revealed, [url])
    XCTAssertEqual(used, [url])
  }

  func testTheUseButtonHidesWhenNothingHandlesIt() throws {
    let url = try temporaryFile(named: "boltty-row-nouse.mp4", contents: "x")
    defer { try? FileManager.default.removeItem(at: url) }
    let row = PaletteFileRowView(path: url.path)
    row.onUse = nil

    XCTAssertTrue(row.useButtonForTesting.isHidden)
  }

  func testOnScreenThePictureIsRevealedAndThenStays() throws {
    try XCTSkipIf(MotionPreferences.reduceMotion, "Reduce Motion fades it instead")
    try XCTSkipIf(PaletteEffects.shared == nil, "no Metal device")
    let url = try temporaryFile(named: "boltty-row-reveal-\(UUID().uuidString).png", contents: "x")
    defer { try? FileManager.default.removeItem(at: url) }
    let thumbnails = FileThumbnails.shared
    let real = thumbnails.generate
    defer { thumbnails.generate = real }
    var answer: (@Sendable (CGImage?) -> Void)?
    thumbnails.generate = { _, _, _, done in answer = done }

    let row = PaletteFileRowView(path: url.path)
    row.frame = NSRect(x: 0, y: 0, width: 300, height: AgentPaletteMetrics.previewFileRowHeight)
    let window = NSWindow(
      contentRect: row.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = row
    window.setFrame(NSRect(x: -20_000, y: -20_000, width: 300, height: 52), display: false)
    window.orderFrontRegardless()
    addTeardownBlock { MainActor.assumeIsolated { window.close() } }
    row.layoutSubtreeIfNeeded()

    answer?(PaletteEffectsTests.halves(width: 8, height: 8))
    // The picture reaches the main thread asynchronously; under a full run's
    // load a fixed 20 ms was sometimes short of it.
    let arrival = Date().addingTimeInterval(1)
    while row.revealForTesting == nil, Date() < arrival {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertNotNil(row.revealForTesting, "the picture arrives through the shader")
    XCTAssertTrue(row.showsThumbnailForTesting)

    let deadline = Date().addingTimeInterval(AgentPaletteMetrics.revealDuration + 2)
    while row.revealForTesting?.superview != nil, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    XCTAssertNil(row.revealForTesting?.superview, "the Metal surface leaves when it is done")
    XCTAssertEqual(row.thumbnailOpacityForTesting, 1, "and the layer that stays is showing")
  }

  func testAPictureWearsItsThumbnailAndIsAskedForOnce() throws {
    let url = try temporaryFile(named: "boltty-row-thumb-\(UUID().uuidString).png", contents: "x")
    defer { try? FileManager.default.removeItem(at: url) }
    let thumbnails = FileThumbnails.shared
    let real = thumbnails.generate
    defer { thumbnails.generate = real }
    var asked = 0
    var answer: (@Sendable (CGImage?) -> Void)?
    thumbnails.generate = { _, _, _, done in
      asked += 1
      answer = done
    }

    let card = PaletteFileRowView(path: url.path)
    let copy = PaletteFileRowView(path: url.path)
    XCTAssertEqual(asked, 1, "one question for both")
    XCTAssertFalse(card.showsThumbnailForTesting, "the icon stands until the picture comes")

    let context = try XCTUnwrap(CGContext(
      data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    answer?(context.makeImage())
    let deadline = Date().addingTimeInterval(2)
    while !(card.showsThumbnailForTesting && copy.showsThumbnailForTesting), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(card.showsThumbnailForTesting)
    XCTAssertTrue(copy.showsThumbnailForTesting)

    XCTAssertTrue(FileThumbnails.wantsThumbnail(URL(fileURLWithPath: "/x/a.pdf")))
    XCTAssertTrue(FileThumbnails.wantsThumbnail(URL(fileURLWithPath: "/x/a.mov")))
    XCTAssertFalse(FileThumbnails.wantsThumbnail(URL(fileURLWithPath: "/x/a.swift")),
                   "a page of grey lines says less than the icon")
  }

  func testRowsAreLabelledForAssistiveTechnology() throws {
    let url = try temporaryFile(named: "boltty-row-a11y.mp4", contents: "x")
    defer { try? FileManager.default.removeItem(at: url) }
    let row = PaletteFileRowView(path: url.path)

    XCTAssertEqual(row.previewButtonForTesting.accessibilityIdentifier(), "boltty.ask.chat.file.preview")
    XCTAssertEqual(row.revealButtonForTesting.accessibilityIdentifier(), "boltty.ask.chat.file.reveal")
    XCTAssertEqual(row.useButtonForTesting.accessibilityIdentifier(), "boltty.ask.chat.file.use")
  }
}

@MainActor
final class PaletteFileRowIntegrationTests: XCTestCase {
  private func card(_ preview: BolttyAISessionPreview) -> BolttyAIPreviewCard {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
    card.apply(preview)
    card.layoutSubtreeIfNeeded()
    return card
  }

  private func answerWithFiles(_ paths: [String]) -> ConversationMessage {
    ConversationMessage(
      id: "a", role: .agent, createdAt: Date(), completedAt: Date(),
      parts: [
        .text(TextPart(id: "t", kind: .text, text: "Done.")),
        .activity(AgentActivity(id: "act", name: "write", state: .completed, files: paths)),
      ]
    )
  }

  private func preview(_ messages: [ConversationMessage]) -> BolttyAISessionPreview {
    BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .opencode, state: .finished, body: "",
      messages: messages
    )
  }

  func testAMessageWithTouchedFilesDrawsFileRows() {
    let card = card(preview([answerWithFiles(["/tmp/out.mp4", "/tmp/src.mov"])]))

    XCTAssertEqual(card.filePathsForTesting["a"], ["/tmp/out.mp4", "/tmp/src.mov"])
  }

  func testAMessageWithoutFilesDrawsNoRows() {
    let plain = ConversationMessage(
      id: "a", role: .agent, createdAt: Date(), completedAt: Date(),
      parts: [.text(TextPart(id: "t", kind: .text, text: "Just words."))]
    )
    let card = card(preview([plain]))

    XCTAssertEqual(card.filePathsForTesting["a"], [])
  }

  func testFileRowsGrowTheMeasuredCardHeight() {
    func files(_ paths: [String]) -> ConversationMessage {
      ConversationMessage(
        id: "a", role: .agent, createdAt: Date(), completedAt: Date(),
        parts: [
          .text(TextPart(id: "t", kind: .text, text: "Done.")),
          .activity(AgentActivity(id: "act", name: "write", state: .completed, files: paths)),
        ]
      )
    }
    let one = card(preview([files(["/tmp/one.mp4"])]))
    let two = card(preview([files(["/tmp/one.mp4", "/tmp/two.mov"])]))

    XCTAssertEqual(
      two.measuredHeight() - one.measuredHeight(),
      AgentPaletteMetrics.previewFileRowHeight + AgentPaletteMetrics.previewFileRowSpacing,
      accuracy: 1.5,
      "the measure reads the same rows the draw does"
    )
  }

  func testUseButtonReachesTheCardsCallback() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("boltty-card-use.mp4")
    try "x".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
    var used: [URL] = []
    card.onUseFile = { used.append($0) }
    card.apply(preview([answerWithFiles([url.path])]))
    card.layoutSubtreeIfNeeded()

    let rows = card.messageFileRowsForTesting["a"] ?? []
    XCTAssertEqual(rows.count, 1)
    XCTAssertFalse(rows[0].useButtonForTesting.isHidden)
    rows[0].useButtonForTesting.performClick(nil)

    XCTAssertEqual(used, [url])
  }

  func testFileRowsSurviveATextUpdate() {
    let id = UUID()
    func preview(id: UUID, _ messages: [ConversationMessage]) -> BolttyAISessionPreview {
      BolttyAISessionPreview(
        id: id, title: "Chat", agent: .opencode, state: .finished, body: "",
        messages: messages
      )
    }
    let card = card(preview(id: id, [answerWithFiles(["/tmp/out.mp4"])]))
    let messageRow = card.messageFileRowsForTesting["a"]?.first
    XCTAssertNotNil(messageRow)

    var updated = answerWithFiles(["/tmp/out.mp4"])
    updated.parts = [
      .text(TextPart(id: "t", kind: .text, text: "Done, with more detail.")),
      .activity(AgentActivity(id: "act", name: "write", state: .completed, files: ["/tmp/out.mp4"])),
    ]
    card.apply(preview(id: id, [updated]))
    card.layoutSubtreeIfNeeded()

    XCTAssertTrue(
      card.messageFileRowsForTesting["a"]?.first === messageRow,
      "new words must not rebuild the file rows mid-turn"
    )
  }
}

@MainActor
final class PaletteSentFilesTests: XCTestCase {
  private let path = "/tmp/boltty-sent-report.pdf"

  private func request(id: String = "u", _ text: String?, files: [String]) -> ConversationMessage {
    var parts: [ConversationPart] = text.map { [.text(TextPart(id: "t", kind: .text, text: $0))] } ?? []
    parts += files.map { path in
      .attachment(ConversationAttachment(
        id: "sent-\(path)", displayName: "Report.pdf", url: URL(fileURLWithPath: path)))
    }
    return ConversationMessage(id: id, role: .user, createdAt: Date(), completedAt: Date(), parts: parts)
  }

  private func preview(_ id: UUID, _ messages: [ConversationMessage]) -> BolttyAISessionPreview {
    BolttyAISessionPreview(
      id: id, title: "Chat", agent: .opencode, state: .finished, body: "", messages: messages)
  }

  private func card(_ messages: [ConversationMessage]) -> BolttyAIPreviewCard {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
    card.apply(preview(UUID(), messages))
    card.layoutSubtreeIfNeeded()
    return card
  }

  private func isAbove(_ upper: NSRect, _ lower: NSRect, in view: NSView) -> Bool {
    view.isFlipped ? upper.maxY <= lower.minY + 0.5 : upper.minY >= lower.maxY - 0.5
  }

  func testARequestsFilesStandOverItsWordsOnItsSide() throws {
    let message = request("Look at file1", files: [path])
    let card = card([message])
    let row = try XCTUnwrap(card.messageRowForTesting("u"))
    let file = try XCTUnwrap(card.messageFileRowsForTesting["u"]?.first)
    let cardFrame = row.convert(file.bounds, from: file)
    let bubble = row.bubbleFrameForFlight

    XCTAssertEqual(file.displayedNameForTesting, "Report.pdf", "the name it was attached under")
    XCTAssertTrue(isAbove(cardFrame, bubble, in: row), "\(cardFrame) over \(bubble)")
    XCTAssertEqual(
      abs(row.isFlipped ? bubble.minY - cardFrame.maxY : cardFrame.minY - bubble.maxY),
      AgentPaletteMetrics.previewSentFilesGap, accuracy: 0.5)
    XCTAssertEqual(cardFrame.maxX, row.bounds.maxX, accuracy: 0.5, "on the person's side")
    XCTAssertEqual(
      row.frame.height, PaletteChatMessageView.height(for: message, width: row.frame.width),
      accuracy: 0.5, "the measure is the draw")
    XCTAssertEqual(
      row.frame.height,
      AgentPaletteMetrics.previewFileRowHeight + AgentPaletteMetrics.previewSentFilesGap
        + bubble.height,
      accuracy: 0.5)
  }

  func testARequestOfOnlyFilesIsItsCards() throws {
    let card = card([request(nil, files: [path])])
    let row = try XCTUnwrap(card.messageRowForTesting("u"))

    XCTAssertFalse(row.isBubbleShownForTesting)
    XCTAssertEqual(row.frame.height, AgentPaletteMetrics.previewFileRowHeight, accuracy: 0.5)
  }

  func testASentFileFliesFromItsChipToItsCard() throws {
    try XCTSkipIf(MotionPreferences.reduceMotion, "Reduce Motion lands everything in place")
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
    card.wantsLayer = true
    let window = NSWindow(
      contentRect: card.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = card
    window.setFrame(NSRect(x: -20_000, y: -20_000, width: 520, height: 420), display: false)
    window.orderFrontRegardless()
    addTeardownBlock { MainActor.assumeIsolated { window.close() } }

    let id = UUID()
    let first = request(id: "q1", "First", files: [])
    let answer = ConversationMessage(
      id: "a1", role: .agent, createdAt: Date(), completedAt: Date(),
      parts: [.text(TextPart(id: "t", kind: .text, text: "Answer."))])
    card.apply(preview(id, [first, answer]))
    card.layoutSubtreeIfNeeded()

    let other = "/tmp/boltty-sent-notes.txt"
    let chip = NSRect(x: 60, y: 30, width: 64, height: 26)
    let picture = NSImage(size: chip.size, flipped: false) { rect in
      NSColor.systemGreen.setFill()
      rect.fill()
      return true
    }
    card.prepareFileFlights([path: .init(frameInWindow: chip, image: picture)])
    card.apply(preview(id, [first, answer, request(id: "q2", "Compare", files: [path, other])]))

    let flights = card.fileFlightsForTesting
    XCTAssertEqual(flights.map(\.path), [path, other])
    let row = try XCTUnwrap(card.messageRowForTesting("q2"))
    let cards = try XCTUnwrap(card.messageFileRowsForTesting["q2"])
    XCTAssertEqual(flights[0].start, card.convert(chip, from: nil), "from where the chip stood")
    XCTAssertEqual(card.fileFlightGrowsForTesting.first, true, "the card grows out of the chip")
    if PaletteEffects.shared != nil {
      XCTAssertEqual(card.fileFlightWhipsForTesting, 1, "the chip flies on the GPU, bending")
    }
    XCTAssertEqual(flights[1].start.minX, flights[1].landing.minX, accuracy: 0.5,
                   "a file with no chip on screen rises straight up")
    XCTAssertEqual(flights[1].start.size, flights[1].landing.size)
    XCTAssertEqual(row.alphaValue, 0, "the row waits for its flights to land")

    let deadline = Date().addingTimeInterval(AgentPaletteMetrics.previewSendFlightDuration + 3)
    while row.alphaValue < 1, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    XCTAssertEqual(row.alphaValue, 1)
    for (flight, file) in zip(flights, cards) {
      let frame = card.convert(file.bounds, from: file)
      XCTAssertEqual(flight.landing.minX, frame.minX, accuracy: 0.5)
      XCTAssertEqual(flight.landing.midY, frame.midY, accuracy: 0.5, "onto its card")
    }
  }
}

@MainActor
final class SentFilePreviewTests: XCTestCase {
  private var root: URL!

  override func setUp() async throws {
    try await super.setUp()
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-sent-preview-\(UUID().uuidString)")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: root)
    try await super.tearDown()
  }

  func testARebuiltPreviewIsWhatLiftingEveryRequestAgainGives() throws {
    let store = ConversationStore(persistence: ConversationPersistence(root: root))
    defer { store.close() }
    let panel: any BolttyAIConversations = ChatWorkspaceCoordinator(
      store: store, engine: ConversationEngine(store: store, client: FakeAgentClient()))
    let chat = store.createConversation(title: "Files", workingDirectory: "/tmp")
    let report = SentFile(path: "/tmp/report.pdf", label: "file1", name: "report.pdf")
    let notes = SentFile(path: "/tmp/notes.txt", label: "file2", name: "notes.txt")
    store.recordSentFiles([report], for: chat.id)
    store.appendUserMessage(
      id: "q1", text: "Summarise /tmp/report.pdf", attachments: [], to: chat.id)

    func requests() -> [String] {
      let messages = panel.preview(for: chat.id)?.messages ?? []
      let files = store.conversation(id: chat.id)?.sentFiles ?? []
      XCTAssertEqual(
        messages, store.transcript(id: chat.id).messages.map { SentFile.lift($0, files: files) })
      return messages.filter { $0.role == .user }.map(\.plainText)
    }

    XCTAssertEqual(requests(), ["Summarise file1"])
    XCTAssertEqual(requests(), ["Summarise file1"], "built again, the same")

    store.appendUserMessage(
      id: "q2", text: "Compare /tmp/report.pdf with /tmp/notes.txt", attachments: [], to: chat.id)
    XCTAssertEqual(requests(), ["Summarise file1", "Compare file1 with /tmp/notes.txt"],
                   "a new request is lifted")

    store.recordSentFiles([notes], for: chat.id)
    XCTAssertEqual(requests(), ["Summarise file1", "Compare file1 with file2"],
                   "a file remembered later lifts the requests already drawn")

    var rewritten = store.transcript(id: chat.id).messages
    let first = try XCTUnwrap(rewritten.firstIndex { $0.id == "q1" })
    rewritten[first].parts = [.text(TextPart(id: "q1-text", kind: .text, text: "Read /tmp/notes.txt"))]
    store.replaceMessages(rewritten, in: chat.id, openInteractions: [])
    XCTAssertEqual(requests(), ["Read file2", "Compare file1 with file2"],
                   "words rewritten under the same id are read again, not remembered")
  }
}

@MainActor
final class PaletteAnswerCopyTests: XCTestCase {
  private func message(
    _ id: String,
    role: ConversationMessage.Role,
    parts: [ConversationPart]
  ) -> ConversationMessage {
    ConversationMessage(
      id: id, role: role, createdAt: Date(), completedAt: Date(), parts: parts
    )
  }

  private func prose(_ id: String, _ text: String) -> ConversationPart {
    .text(TextPart(id: id, kind: .text, text: text))
  }

  func testCopyingTakesTheWordsAndLeavesTheToolLog() {
    let value = message("a", role: .agent, parts: [
      .activity(AgentActivity(id: "1", name: "read", summary: nil, state: .completed,
                              files: ["/x/Thing.swift"])),
      prose("t", "Run `ffmpeg -i in.mov out.mp4`."),
    ])

    XCTAssertEqual(value.copyableText, "Run `ffmpeg -i in.mov out.mp4`.")
    XCTAssertTrue(value.paletteText.contains("read"), "the log still belongs on screen")
  }

  func testATurnWithNoProseHasNothingToCopy() {
    let value = message("a", role: .agent, parts: [
      .activity(AgentActivity(id: "1", name: "bash", summary: "swift build",
                              state: .completed, files: [])),
    ])

    XCTAssertTrue(value.copyableText.isEmpty)
  }

  func testTheButtonAppearsUnderThePointerAndCopiesTheAnswer() throws {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: AgentPaletteMetrics.promptSize.width, height: 320)
    let answer = message("a", role: .agent, parts: [prose("t", "## Done\n\nTwo files changed.")])
    card.apply(BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .opencode, state: .finished, body: "",
      messages: [message("u", role: .user, parts: [prose("ut", "Питання")]), answer]
    ))
    card.layoutSubtreeIfNeeded()

    let row = try XCTUnwrap(card.messageRowForTesting("a"))
    XCTAssertFalse(row.isCopyVisibleForTesting, "nothing is offered until the pointer arrives")

    row.hoverForTesting(true)
    XCTAssertTrue(row.isCopyVisibleForTesting)

    NSPasteboard.general.clearContents()
    row.pressCopyForTesting()
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "## Done\n\nTwo files changed.")

    row.hoverForTesting(false)
    XCTAssertFalse(row.isCopyVisibleForTesting)
  }

  func testReadAloudSitsBesideCopyAndStaysUpWhileItSpeaks() throws {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: AgentPaletteMetrics.promptSize.width, height: 320)
    var spoken: [String] = []
    card.onSpeak = { spoken.append($0.id) }
    let answer = message("a", role: .agent, parts: [prose("t", "Two files changed.")])
    card.apply(BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .opencode, state: .finished, body: "",
      messages: [message("u", role: .user, parts: [prose("ut", "Питання")]), answer]
    ))
    card.layoutSubtreeIfNeeded()

    let row = try XCTUnwrap(card.messageRowForTesting("a"))
    XCTAssertFalse(row.isSpeakVisibleForTesting, "nothing is offered until the pointer arrives")
    row.hoverForTesting(true)
    XCTAssertTrue(row.isSpeakVisibleForTesting)
    row.pressSpeakForTesting()
    XCTAssertEqual(spoken, ["a"])

    card.speakingMessageID = "a"
    row.hoverForTesting(false)
    XCTAssertTrue(row.isSpeakVisibleForTesting, "the stop stays under the answer while it is read")
    XCTAssertFalse(row.isCopyVisibleForTesting)

    card.speakingMessageID = nil
    XCTAssertFalse(row.isSpeakVisibleForTesting)
  }

  func testASentStandInHandsItsRowToTheStoredMessage() throws {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: AgentPaletteMetrics.promptSize.width, height: 420)
    let id = UUID()
    let first = message("u0", role: .user, parts: [prose("u0t", "Rename them")])
    let answer = message("a0", role: .agent, parts: [prose("a0t", "Done.")])
    func preview(_ last: ConversationMessage) -> BolttyAISessionPreview {
      BolttyAISessionPreview(id: id, title: "Chat", agent: .claude, state: .running, body: "",
                              messages: [first, answer, last])
    }
    card.apply(BolttyAISessionPreview(id: id, title: "Chat", agent: .claude, state: .finished,
                                       body: "", messages: [first, answer]))
    card.apply(preview(message("pending-\(id)", role: .user, parts: [prose("p", "And the subtitles")])))
    let standIn = try XCTUnwrap(card.messageIdentityForTesting("pending-\(id)"))

    card.apply(preview(message("u1", role: .user, parts: [prose("u1t", "And the subtitles")])))

    XCTAssertEqual(card.messageIdentityForTesting("u1"), standIn)
    XCTAssertNil(card.messageIdentityForTesting("pending-\(id)"))
  }

  func testTheCopyButtonStandsUnderTheLastAnswer() throws {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: AgentPaletteMetrics.promptSize.width, height: 420)
    let answer = message("a", role: .agent, parts: [prose("t", "Two files changed.")])
    card.apply(BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .opencode, state: .finished, body: "",
      messages: [answer]
    ))
    card.layoutSubtreeIfNeeded()

    let row = try XCTUnwrap(card.messageRowForTesting("a"))
    row.hoverForTesting(true)
    card.layoutSubtreeIfNeeded()
    XCTAssertTrue(row.isCopyVisibleForTesting)

    let (copy, text) = row.copyLayoutForTesting
    XCTAssertLessThanOrEqual(copy.maxY, text.minY, "under the words, never over them")
    XCTAssertEqual(copy.height, AgentPaletteMetrics.previewCopyButtonSize, accuracy: 0.5)
    let glyph = try XCTUnwrap(NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: AgentPaletteMetrics.previewFileGlyphPointSize, weight: .medium)))
    XCTAssertEqual(copy.midX - glyph.size.width / 2, row.bubbleFrameForFlight.minX, accuracy: 0.25)
    XCTAssertEqual(
      PaletteChatMessageView.height(for: answer, width: 464, offersCopy: true),
      PaletteChatMessageView.height(for: answer, width: 464) + AgentPaletteMetrics.previewCopyRowHeight,
      accuracy: 0.5)
    XCTAssertEqual(
      PaletteChatMessageView.spacing(
        after: answer, before: message("u", role: .user, parts: [prose("u", "Thanks")]), offersCopy: true),
      max(0, AgentPaletteMetrics.previewMessageSpacing - AgentPaletteMetrics.previewCopyRowHeight),
      accuracy: 0.5, "the row is the gap to the next question, not added to it")
  }

  func testAUserMessageIsNotOfferedBackToThePersonWhoWroteIt() throws {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: AgentPaletteMetrics.promptSize.width, height: 320)
    card.apply(BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .opencode, state: .finished, body: "",
      messages: [message("u", role: .user, parts: [prose("ut", "Питання")])]
    ))
    card.layoutSubtreeIfNeeded()

    let row = try XCTUnwrap(card.messageRowForTesting("u"))
    row.hoverForTesting(true)
    XCTAssertFalse(row.isCopyVisibleForTesting)
  }
}

@MainActor
final class PaletteThinkingVocabularyTests: XCTestCase {
  private func card(_ preview: BolttyAISessionPreview) -> BolttyAIPreviewCard {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: AgentPaletteMetrics.promptSize.width, height: 320)
    card.apply(preview)
    card.layoutSubtreeIfNeeded()
    return card
  }

  private func running(_ parts: [ConversationPart]) -> BolttyAISessionPreview {
    BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .opencode, state: .running, body: "",
      messages: [
        ConversationMessage(id: "u", role: .user, createdAt: Date(), completedAt: Date(),
                            parts: [.text(TextPart(id: "ut", kind: .text, text: "Стисни це"))]),
        ConversationMessage(id: "a", role: .agent, createdAt: Date(), parts: parts),
      ]
    )
  }

  func testTheWorkingLineStandsUnderARunningTurn() {
    let card = card(
      BolttyAISessionPreview(
        id: UUID(), title: "Chat", agent: .opencode, state: .running, body: "",
        messages: [
          ConversationMessage(
            id: "u", role: .user, createdAt: Date(), completedAt: Date(),
            parts: [.text(TextPart(id: "ut", kind: .text, text: "Питання"))]
          ),
          ConversationMessage(
            id: "a", role: .agent, createdAt: Date(), completedAt: Date(),
            parts: [.text(TextPart(id: "at", kind: .text, text: "An answer already landed."))]
          ),
        ]
      )
    )

    let line = card.workingLineForTesting
    XCTAssertFalse(line.isHidden, "the working line stands under the running turn")
    XCTAssertTrue(line.showsFaceForTesting, "the face belongs to the whole turn")
  }

  func testACardAskingAQuestionOpensOnItsOptions() {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: AgentPaletteMetrics.promptSize.width, height: 260)
    card.setFloatingBottomInset(chip: 48, composer: 0)
    let preamble = (1...12).map { "Line \($0) of what the agent looked at." }.joined(separator: "\n\n")
    card.apply(BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .opencode, state: .blocked, body: preamble,
      question: AgentQuestion(
        kind: .question, requestID: "q",
        header: "Choice", prompt: "Which one?",
        options: [.init(label: "This", detail: nil), .init(label: "That", detail: nil)],
        allowsMultiple: false, allowsCustom: false
      )
    ))
    card.layoutSubtreeIfNeeded()
    XCTAssertTrue(card.isScrollableForTesting, "the fixture has to overflow to mean anything")
    let resting = card.scrollOffsetForTesting

    card.scrollToLatestForTesting()
    XCTAssertEqual(resting, card.scrollOffsetForTesting, accuracy: 0.5)
  }

  func testTheCardSaysTheStepTheAgentNamed() {
    let preview = running([
      .activity(AgentActivity(id: "1", name: "bash", summary: "ffmpeg -i in.mov out.mp4",
                              state: .running, files: [])),
    ])
    XCTAssertEqual(preview.currentStep, "ffmpeg -i in.mov out.mp4")
  }
}

@MainActor
final class PaletteActivityRowTests: XCTestCase {
  private func activity(
    _ id: String,
    _ name: String,
    state: AgentActivity.State = .completed,
    summary: String? = nil,
    detail: String? = nil,
    files: [String] = []
  ) -> ConversationPart {
    .activity(AgentActivity(
      id: id, name: name, summary: summary, state: state, detail: detail, files: files
    ))
  }

  private func answer(_ parts: [ConversationPart]) -> ConversationMessage {
    ConversationMessage(
      id: "a", role: .agent, createdAt: Date(), completedAt: Date(), parts: parts
    )
  }

  private func card(_ message: ConversationMessage) -> BolttyAIPreviewCard {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: AgentPaletteMetrics.promptSize.width, height: 520)
    card.apply(BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .opencode, state: .finished, body: "",
      messages: [message]
    ))
    card.layoutSubtreeIfNeeded()
    return card
  }

  // MARK: - The order the turn happened in

  func testTheBodyKeepsTheOrderTheTurnHappenedIn() {
    let segments = answer([
      .text(TextPart(id: "t1", kind: .text, text: "Looking.")),
      activity("1", "read", files: ["/x/File.swift"]),
      .text(TextPart(id: "t2", kind: .text, text: "Found it.")),
    ]).paletteSegments

    guard case let .text(first) = segments.first,
          case let .group(work) = segments[1],
          case let .text(last) = segments[2]
    else { return XCTFail("expected text, pill, text — got \(segments)") }
    XCTAssertEqual(segments.count, 3)
    XCTAssertEqual(first, [.prose("Looking.")])
    XCTAssertEqual(work.map(\.id), ["1"])
    XCTAssertEqual(last, [.prose("Found it.")])
  }

  func testARunOfToolCallsIsOneGroup() {
    let segments = answer([
      activity("1", "read"), activity("2", "write"), activity("3", "bash"),
    ]).paletteSegments

    guard segments.count == 1, case let .group(run) = segments[0]
    else { return XCTFail("expected one group — got \(segments)") }
    XCTAssertEqual(run.map(\.id), ["1", "2", "3"])
  }

  func testASingleToolCallIsAPillInItsOwnWords() {
    let segments = answer([
      .text(TextPart(id: "t", kind: .text, text: "Looking.")),
      activity("1", "read", summary: "Read README.md"),
    ]).paletteSegments

    guard case let .group(work)? = segments.last else { return XCTFail("expected a pill — got \(segments)") }
    XCTAssertEqual(AgentActivityGroup.summary(of: work), "Read README.md")
  }

  func testACompactionBreaksARunAndStandsAlone() {
    let segments = answer([
      activity("1", "read"), activity("2", "bash"),
      .activity(AgentCompaction.activity(id: "c")),
      activity("3", "read"), activity("4", "bash"),
    ]).paletteSegments

    XCTAssertEqual(segments.count, 3)
    guard case .group = segments[0], case let .activity(middle) = segments[1], case .group = segments[2]
    else { return XCTFail("expected group, compaction, group — got \(segments)") }
    XCTAssertEqual(middle.id, "c")
  }

  func testReasoningBesideACallIsAThoughtInItsPill() {
    let segments = answer([
      .reasoning(TextPart(id: "r", kind: .reasoning, text: "Міркую.")),
      activity("1", "read"),
    ]).paletteSegments

    XCTAssertEqual(segments.count, 1)
    guard case let .group(work) = segments[0] else { return XCTFail("expected the pill alone") }
    XCTAssertEqual(work.map(\.isThought), [true, false])
  }

  // MARK: - The row itself

  func testTheCardDrawsAGroupAndNotAWordOfItInTheProse() throws {
    let card = card(answer([
      .text(TextPart(id: "t", kind: .text, text: "Done.")),
      activity("1", "read", summary: "AgentPaletteView.swift"),
      activity("2", "bash", state: .failed, summary: "swift build"),
    ]))

    let row = try XCTUnwrap(card.messageRowForTesting("a"))
    let group = try XCTUnwrap(row.activityGroupsForTesting.first)
    XCTAssertEqual(group.headlineForTesting, "AgentPaletteView.swift • Ran swift build")
    XCTAssertFalse(group.isOpenForTesting, "a group starts folded")
    group.pressForTesting()
    card.layoutSubtreeIfNeeded()
    XCTAssertTrue(group.isOpenForTesting)
    XCTAssertEqual(group.rows.map(\.headlineForTesting),
                   ["AgentPaletteView.swift", "swift build"])
    XCTAssertEqual(row.answerViewsForTesting.count, 1)
    let prose = try XCTUnwrap(row.answerViewsForTesting.first).attributedStringValue.string
    XCTAssertEqual(prose, "Done.", "the headline is a row, so it is not also a sentence")
  }

  func testOnlyARowWithOutputOffersToOpen() throws {
    let card = card(answer([
      activity("1", "read", state: .running),
      activity("2", "bash", detail: "3 warnings"),
    ]))

    let group = try XCTUnwrap(card.messageRowForTesting("a")?.activityGroupsForTesting.first)
    group.pressForTesting()
    XCTAssertEqual(group.rows.map(\.hasDisclosureForTesting), [false, true])
  }

  func testPressingARowOpensItsOutputAndPressingItAgainClosesIt() throws {
    let card = card(answer([activity("1", "bash", summary: "swift build",
                                     detail: "warning: unused result")]))
    let row = try XCTUnwrap(card.messageRowForTesting("a"))
    let pill = try XCTUnwrap(row.activityGroupsForTesting.first)
    pill.pressForTesting()
    let tool = try XCTUnwrap(pill.rows.first)

    XCTAssertFalse(tool.isDetailVisibleForTesting)
    tool.pressForTesting()
    card.layoutSubtreeIfNeeded()
    XCTAssertTrue(tool.isDetailVisibleForTesting)
    XCTAssertEqual(tool.detailForTesting, "warning: unused result")
    XCTAssertEqual(card.expandedActivitiesForTesting, ["group:1", "1"])

    tool.pressForTesting()
    card.layoutSubtreeIfNeeded()
    XCTAssertFalse(tool.isDetailVisibleForTesting)
    XCTAssertEqual(card.expandedActivitiesForTesting, ["group:1"])
  }

  func testARowWithNoOutputDoesNotRespondToBeingPressed() throws {
    let card = card(answer([activity("1", "read", state: .running)]))
    let tool = try XCTUnwrap(card.messageRowForTesting("a")?.activityGroupsForTesting.first?.rows.first)

    tool.pressForTesting()

    XCTAssertTrue(card.expandedActivitiesForTesting.isEmpty)
  }

  // MARK: - The measure and the draw

  func testAnOpenRowIsTallerThanAClosedOneByItsOutput() {
    let value = answer([activity("1", "bash", detail: "one\ntwo\nthree")])
    let closed = PaletteChatMessageView.height(for: value, width: 464, expanded: ["group:1"])
    let open = PaletteChatMessageView.height(for: value, width: 464, expanded: ["group:1", "1"])

    XCTAssertGreaterThan(open, closed + AgentPaletteMetrics.previewActivityDetailTopMargin)
  }

  func testAToolOnlyTurnIsOnePillUntilItIsOpened() {
    let value = answer([activity("1", "read"), activity("2", "write"), activity("3", "bash")])

    XCTAssertEqual(
      PaletteChatMessageView.height(for: value, width: 464),
      AgentPaletteMetrics.previewWorkPillHeight, accuracy: 0.5)
    XCTAssertEqual(
      PaletteChatMessageView.height(for: value, width: 464, expanded: ["group:1"]),
      AgentPaletteMetrics.previewWorkPillListTop
        + 3 * AgentPaletteMetrics.previewActivityRowHeight
        + 2 * AgentPaletteMetrics.previewActivityRowSpacing
        + AgentPaletteMetrics.previewWorkPillListBottomInset,
      accuracy: 0.5
    )
  }

  func testOutputIsCutInLinesAndSaysHowManyItKeptBack() {
    let long = (1...60).map { "line \($0)" }.joined(separator: "\n")

    let shown = PaletteActivityRowView.shown(long)

    let lines = shown.split(separator: "\n")
    XCTAssertEqual(lines.count, AgentPaletteMetrics.previewActivityDetailLineCap + 1)
    XCTAssertEqual(lines.first, "line 1")
    XCTAssertEqual(lines.last, "… 20 more lines")
  }

  func testShortOutputIsShownWhole() {
    XCTAssertEqual(PaletteActivityRowView.shown("  two\nlines  "), "two\nlines")
  }

  func testAnOpenRowSurvivesTheNextTickOfTheSameTurn() throws {
    let card = card(answer([activity("1", "bash", state: .running, detail: "building")]))
    let row = try XCTUnwrap(card.messageRowForTesting("a"))
    let pill = try XCTUnwrap(row.activityGroupsForTesting.first)
    pill.pressForTesting()
    try XCTUnwrap(pill.rows.first).pressForTesting()

    row.apply(answer([activity("1", "bash", state: .completed, detail: "building\ndone")]))
    card.layoutSubtreeIfNeeded()

    let tool = try XCTUnwrap(row.activityGroupsForTesting.first?.rows.first)
    XCTAssertTrue(tool.isDetailVisibleForTesting, "the row stayed open")
    XCTAssertEqual(tool.detailForTesting, "building\ndone", "and caught up with the tool")
  }
}

@MainActor
final class PaletteTranscriptTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_000_000)

  private func user(_ id: String, at offset: TimeInterval = 0) -> ConversationMessage {
    ConversationMessage(
      id: id, role: .user, createdAt: start.addingTimeInterval(offset),
      completedAt: start.addingTimeInterval(offset),
      parts: [.text(TextPart(id: id + "t", kind: .text, text: "Зроби"))])
  }

  private func work(_ id: String, done: TimeInterval? = 483) -> ConversationMessage {
    ConversationMessage(
      id: id, role: .agent, createdAt: start.addingTimeInterval(1),
      completedAt: done.map { start.addingTimeInterval($0) },
      parts: [
        .text(TextPart(id: id + "1", kind: .text, text: "Приберу капс.")),
        .activity(AgentActivity(id: id + "e", name: "Edit", state: .completed)),
        .activity(AgentActivity(id: id + "r", name: "Read", state: .completed)),
        .text(TextPart(id: id + "2", kind: .text, text: "Скоротив вступи.")),
      ])
  }

  private func answerOnly(_ id: String) -> ConversationMessage {
    ConversationMessage(
      id: id, role: .agent, createdAt: start, completedAt: start.addingTimeInterval(2),
      parts: [.text(TextPart(id: id + "t", kind: .text, text: "Так."))])
  }

  func testAFinishedTurnFoldsToItsAnswerUnderWorkedFor() {
    let items = PaletteTranscript.items(for: [user("u"), work("a")], isBusy: false, expandedTurns: [])

    XCTAssertEqual(items.count, 3)
    guard case let .turnHeader(header) = items[1], case let .message(answer, folded) = items[2]
    else { return XCTFail("expected request, header, answer — got \(items)") }
    XCTAssertTrue(header.isCollapsed)
    XCTAssertEqual(header.text(), "Worked for 8m 3s")
    XCTAssertEqual(answer.id, "a")
    XCTAssertTrue(folded)
    XCTAssertEqual(PaletteChatMessageView.height(for: answer, width: 464, folded: true),
                   PaletteChatMessageView.height(for: answerOnly("x"), width: 464),
                   accuracy: 0.5, "folded, only the last run of prose is left")
  }

  func testOpeningAFinishedTurnShowsTheWholeOfIt() {
    let items = PaletteTranscript.items(for: [user("u"), work("a")], isBusy: false, expandedTurns: ["u"])

    guard case let .turnHeader(header) = items[1], case let .message(_, folded) = items[2]
    else { return XCTFail("got \(items)") }
    XCTAssertFalse(header.isCollapsed)
    XCTAssertFalse(folded)
  }

  func testARunningTurnHasNoHeaderAndKeepsItsWorkWhereItWasDone() {
    let items = PaletteTranscript.items(for: [user("u"), work("a", done: nil)], isBusy: true, expandedTurns: [])

    XCTAssertFalse(items.contains { if case .turnHeader = $0 { return true }; return false })
    XCTAssertEqual(items, [.message(user("u"), folded: false), .message(work("a", done: nil), folded: false)])
  }

  func testATurnThatHasOnlyJustStartedIsHeaded() {
    let items = PaletteTranscript.items(for: [user("u")], isBusy: true, expandedTurns: [])

    XCTAssertEqual(items, [.message(user("u"), folded: false)])
  }

  func testAnAnswerWithNoWorkHasNoHeader() {
    let items = PaletteTranscript.items(for: [user("u"), answerOnly("a")], isBusy: false, expandedTurns: [])

    XCTAssertEqual(items, [.message(user("u"), folded: false), .message(answerOnly("a"), folded: false)])
  }

  func testEachTurnIsHeadedAndOnlyTheLastRuns() {
    let items = PaletteTranscript.items(
      for: [user("u1"), work("a1"), user("u2", at: 600), work("a2", done: nil)],
      isBusy: true, expandedTurns: [])

    let headers = items.compactMap { item -> PaletteTurnHeader? in
      if case let .turnHeader(header) = item { return header }
      return nil
    }
    XCTAssertEqual(headers.map(\.id), ["u1"])
    XCTAssertEqual(headers.map(\.isRunning), [false])
  }

  func testDurationsReadTheWayAPersonSaysThem() {
    XCTAssertEqual(PaletteTurnHeader.duration(12), "12s")
    XCTAssertEqual(PaletteTurnHeader.duration(483), "8m 3s")
    XCTAssertEqual(PaletteTurnHeader.duration(3_840), "1h 4m")
  }

  func testThePillSaysTheWorkInTheOrderItWasDone() {
    func call(_ name: String, _ summary: String? = nil) -> AgentActivity {
      AgentActivity(id: name + (summary ?? ""), name: name, summary: summary)
    }
    XCTAssertEqual(
      AgentActivityGroup.summary(of: [
        AgentActivityGroup.thought(id: "th"), call("shell", "ls -la"), call("shell", "git status"),
        call("Read", "a.swift"), call("Read", "b.swift"), call("shell", "cat /workspace/home/x"),
      ]),
      "Thought • Ran 2 commands • Read 2 files • Ran cat /workspace/home/x")
    XCTAssertEqual(AgentActivityGroup.summary(of: [call("Bash", "List files in current directory")]),
                   "List files in current directory", "a call the CLI put in a sentence keeps it")
    XCTAssertEqual(AgentActivityGroup.summary(of: [call("Edit"), call("Edit"), call("Grep")]),
                   "Edited 2 files • Grep")
  }

  func testAThoughtIsSaidOnceAndDoesNotCutAStretch() {
    func step(_ name: String, _ file: String) -> [AgentActivity] {
      [AgentActivityGroup.thought(id: "t" + name + file),
       AgentActivity(id: name + file, name: name, state: .completed, files: ["/x/" + file])]
    }
    XCTAssertEqual(
      AgentActivityGroup.summary(of: step("read", "App.tsx") + step("read", "App.tsx")
        + step("read", "config.ts") + step("edit", "config.ts")),
      "Thought • Read 3 files • Edit config.ts")
    XCTAssertEqual(
      AgentActivityGroup.summary(of: [AgentActivity(id: "c", name: "bash", summary: "ls", state: .completed)]),
      "ls", "a command line is what was run, never capitalised")
  }

  private func step(_ id: String, _ tool: String, _ file: String) -> ConversationMessage {
    ConversationMessage(
      id: id, role: .agent, createdAt: start.addingTimeInterval(1), completedAt: start.addingTimeInterval(2),
      parts: [
        .reasoning(TextPart(id: id + "r", kind: .reasoning, text: "hm")),
        .activity(AgentActivity(id: id + "c", name: tool, state: .completed, files: ["/x/" + file])),
      ])
  }

  func testWordlessStepsJoinTheMessageAfterThemAsOnePill() throws {
    let answer = ConversationMessage(
      id: "a", role: .agent, createdAt: start.addingTimeInterval(3), completedAt: nil,
      parts: [.text(TextPart(id: "at", kind: .text, text: "Готово."))])
    let messages = [user("u"), step("s1", "read", "App.tsx"), step("s2", "read", "config.ts"),
                    step("s3", "edit", "config.ts"), answer]

    let running = PaletteTranscript.items(for: messages, isBusy: true, expandedTurns: [])
    XCTAssertEqual(running.count, 2, "the request, and one row for the whole stretch")
    guard case let .message(joined, folded) = running[1] else { return XCTFail("got \(running)") }
    XCTAssertEqual(joined.id, "s1", "the stretch keeps its first message's id")
    XCTAssertFalse(folded)
    guard case let .group(work)? = joined.paletteSegments.first else {
      return XCTFail("got \(joined.paletteSegments)")
    }
    XCTAssertEqual(AgentActivityGroup.summary(of: work), "Thought • Read 2 files • Edit config.ts")
    XCTAssertEqual(joined.paletteSegments.count, 2, "one pill, then the words")
    XCTAssertEqual(joined.resultFiles, ["/x/config.ts"], "the files the stretch made, under it")

    XCTAssertEqual(PaletteTranscript.rowID(of: "a", in: messages), "s1")
    XCTAssertEqual(PaletteTranscript.rowID(of: "s2", in: messages), "s1")
    XCTAssertEqual(PaletteTranscript.rowID(of: "u", in: messages), "u")

    var done = messages
    done[4].completedAt = start.addingTimeInterval(9)
    let finished = PaletteTranscript.items(for: done, isBusy: false, expandedTurns: [])
    guard case let .turnHeader(header) = finished[1], case let .message(folding, true) = finished[2]
    else { return XCTFail("got \(finished)") }
    XCTAssertEqual(header.text(), "Worked for 9s")
    XCTAssertEqual(folding.id, "s1")
  }

  func testWordsAndFailuresEndAStretch() {
    var stopped = step("s2", "read", "b.swift")
    stopped.failure = MessageFailure(name: "aborted", message: "Step interrupted")
    let joined = PaletteTranscript.joined([
      step("s1", "read", "a.swift"), stopped, step("s3", "read", "c.swift"), answerOnly("a"),
    ])
    XCTAssertEqual(joined.map(\.id), ["s1", "s3"])
    XCTAssertEqual(joined[0].failure?.isAbort, true, "the stop ends the first stretch")
  }

  func testAThoughtJoinsTheWorkBesideItAndNothingElse() {
    let reply = ConversationMessage(
      id: "a", role: .agent, createdAt: Date(), completedAt: Date(),
      parts: [
        .text(TextPart(id: "p1", kind: .text, text: "I'll look.")),
        .reasoning(TextPart(id: "r1", kind: .reasoning, text: "hm")),
        .activity(AgentActivity(id: "c1", name: "shell", summary: "ls", state: .completed)),
        .text(TextPart(id: "p2", kind: .text, text: "Found it.")),
        .reasoning(TextPart(id: "r2", kind: .reasoning, text: "and")),
        .text(TextPart(id: "p3", kind: .text, text: "Done.")),
      ])
    let segments = reply.paletteSegments
    XCTAssertEqual(segments.count, 3)
    guard case let .group(work) = segments[1] else { return XCTFail("the work is one pill") }
    XCTAssertEqual(work.map(\.isThought), [true, false])
    XCTAssertEqual(AgentActivityGroup.id(of: work), "group:c1", "known by its call, not its thought")
    guard case let .text(words) = segments[2] else { return XCTFail("words after the pill") }
    XCTAssertEqual(words, [.prose("Found it."), .prose("Done.")])
  }

  func testARunningReplyShowsItsWorkAndWithholdsOnlyItsLastSentence() {
    let preview = BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .codex, state: .running, body: "",
      messages: [user("u"), work("a", done: nil)])

    let shown = preview.visibleMessages.last
    XCTAssertEqual(shown?.id, "a")
    XCTAssertEqual(shown?.parts.map(\.id), ["a1", "ae", "ar"], "the growing sentence is not a row yet")
  }

  func testPressingTheHeaderOfAFinishedTurnOpensIt() throws {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: AgentPaletteMetrics.promptSize.width, height: 520)
    card.apply(BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .codex, state: .finished, body: "",
      messages: [user("u"), work("a")]))
    card.layoutSubtreeIfNeeded()
    let folded = card.measuredHeight()

    XCTAssertEqual(card.transcriptOrderForTesting, ["u", "turn:u", "a"])
    XCTAssertEqual(card.turnHeaderTextsForTesting, ["Worked for 8m 3s"])
    let header = try XCTUnwrap(card.turnHeaderForTesting("u"))
    XCTAssertTrue(header.isCollapsedForTesting)

    header.pressForTesting()
    card.layoutSubtreeIfNeeded()

    XCTAssertFalse(header.isCollapsedForTesting)
    XCTAssertEqual(card.messageRowForTesting("a")?.activityGroupsForTesting.count, 1)
    XCTAssertGreaterThan(card.measuredHeight(), folded, "the measure follows the open turn")
  }
}
