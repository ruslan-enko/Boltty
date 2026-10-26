import XCTest
@testable import Boltty

@MainActor
final class PermissionSentenceTests: XCTestCase {
  private func sentence(_ action: String, _ resources: [String]) -> String {
    PermissionSentence.sentence(action: action, resources: resources)
  }

  func testAKnownToolBecomesAVerb() {
    XCTAssertEqual(sentence("bash", ["ffmpeg -i in.mov out.mp4"]), "Run this command?")
    XCTAssertEqual(sentence("webfetch", ["https://example.com"]), "Fetch from the web?")
  }

  func testASingleFileIsNamedInTheSentence() {
    XCTAssertEqual(
      sentence("edit", ["/Users/someone/Code/AgentPaletteView.swift"]),
      "Edit AgentPaletteView.swift?"
    )
    XCTAssertEqual(sentence("read", ["/tmp/notes.md"]), "Read notes.md?")
  }

  func testACommandLineIsNeverMistakenForAFile() {
    XCTAssertEqual(sentence("bash", ["rm -rf /tmp/build"]), "Run this command?")
  }

  func testSeveralFilesKeepTheGeneralSentence() {
    XCTAssertEqual(sentence("edit", ["/a/one.swift", "/a/two.swift"]), "Edit a file?")
  }

  func testAnUnknownToolIsNotTranslated() {
    XCTAssertEqual(sentence("mcp__jira__create", ["BOLT-12"]), "Allow “mcp__jira__create”?")
  }

  func testTheProvidersOwnWordsSurviveVerbatim() {
    let detail = PermissionSentence.detail(action: "bash", resources: ["rm -rf build"])
    XCTAssertTrue(detail.contains("bash"))
    XCTAssertTrue(detail.contains("rm -rf build"))
  }
}

@MainActor
final class PermissionDisclosureTests: XCTestCase {
  private func permissionCard() -> BolttyAIPreviewCard {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: AgentPaletteMetrics.promptSize.width, height: 320)
    card.apply(BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .opencode, state: .blocked, body: "",
      question: AgentQuestion(
        kind: .permission,
        requestID: "perm_1",
        header: "Permission",
        prompt: PermissionSentence.sentence(action: "bash", resources: ["rm -rf build"]),
        detail: PermissionSentence.detail(action: "bash", resources: ["rm -rf build"]),
        options: [
          .init(label: "Allow once", detail: nil, value: "once"),
          .init(label: "Deny", detail: nil, value: "reject"),
        ],
        allowsMultiple: false,
        allowsCustom: false
      )
    ))
    card.layoutSubtreeIfNeeded()
    return card
  }

  func testTheCommandIsOnScreenNotFolded() {
    let card = permissionCard()

    XCTAssertEqual(card.bodyForTesting, "Run this command?")
    XCTAssertEqual(card.permissionWellTextForTesting, "bash\nrm -rf build")
  }

  func testTheAnswersAreADialogsButtons() throws {
    let card = permissionCard()
    let bar = try XCTUnwrap(card.approvalBarForTesting)
    XCTAssertEqual(bar.buttonTitlesForTesting, ["Deny", "Allow once"])
    XCTAssertEqual(bar.returnTitleForTesting, "Allow once")

    XCTAssertTrue(card.moveOptionFocus(by: 1))
    XCTAssertEqual(bar.returnTitleForTesting, "Deny")

    var sent: [String] = []
    card.onAnswer = { _, values in sent = values }
    bar.pressForTesting(0)
    XCTAssertEqual(sent, ["once"], "a button sends its answer's own word")
  }

  func testThreeAnswersAndTheReachOfAlways() throws {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: AgentPaletteMetrics.promptSize.width, height: 320)
    card.apply(Self.preview(PermissionCardContactSheet.external))
    card.layoutSubtreeIfNeeded()
    let bar = try XCTUnwrap(card.approvalBarForTesting)
    XCTAssertEqual(bar.buttonTitlesForTesting, ["Deny", "Always allow", "Allow once"])
    XCTAssertEqual(bar.noteForTesting, "Always allow: this chat, for /private/var/folders/98/tmp/*")
    XCTAssertEqual(card.bodyForTesting, "Work outside the project folder?")
  }

  func testTheToolsNameIsALabelOverTheCommand() {
    XCTAssertEqual(BolttyAICommandWell.parts(of: "bash\nls\npwd").tool, "bash")
    XCTAssertEqual(BolttyAICommandWell.parts(of: "bash\nls\npwd").command, "ls\npwd")
    XCTAssertNil(BolttyAICommandWell.parts(of: "swift build").tool, "one line is shown as it is")
  }

  func testALongCommandSaysHowMuchIsLeft() {
    let well = BolttyAICommandWell(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    well.show((["bash"] + (1...9).map { "echo \($0)" }).joined(separator: "\n"))
    XCTAssertEqual(well.moreTitleForTesting, "Show 3 More Lines", "the tool's name is not a line")
    XCTAssertFalse(well.stringForTesting.contains("…"), "the link says it, not a line of dots")
    well.toggleForTesting()
    XCTAssertEqual(well.moreTitleForTesting, "Show Less")

    well.show((["bash"] + (1...7).map { "echo \($0)" }).joined(separator: "\n"))
    XCTAssertNil(well.moreTitleForTesting, "a link never hides the one line it would stand in")
  }

  func testTheHeadingStandsTogetherAndTheButtonsFurthest() {
    let gap = BolttyAIPreviewCard.serviceGap
    XCTAssertLessThan(gap(.eyebrow, .title), gap(.title, .well))
    XCTAssertLessThan(gap(.well, .actions(captioned: true)), gap(.title, .well),
                      "the reach captions the command it is about")
    XCTAssertGreaterThan(gap(.well, .actions(captioned: false)), gap(.title, .well))
  }

  static func preview(_ question: AgentQuestion) -> BolttyAISessionPreview {
    BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .opencode, state: .blocked, body: "", question: question)
  }

  func testAnOrdinaryQuestionHasNoDisclosure() {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: AgentPaletteMetrics.promptSize.width, height: 320)
    card.apply(BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .opencode, state: .blocked, body: "",
      question: AgentQuestion(
        kind: .question,
        requestID: "que_1",
        header: "Approach",
        prompt: "Which approach should I use?",
        options: [.init(label: "SwiftUI", detail: nil)],
        allowsMultiple: false,
        allowsCustom: true
      )
    ))
    card.layoutSubtreeIfNeeded()

    XCTAssertNil(card.permissionWellTextForTesting)
    XCTAssertNil(card.approvalBarForTesting, "a question keeps its rows")
    XCTAssertEqual(card.optionLabelsForTesting, ["SwiftUI"])
  }
}


@MainActor
final class PermissionCardContactSheet: XCTestCase {
  static let external = AgentQuestion(
    kind: .permission, requestID: "p1", header: "Permission",
    prompt: PermissionSentence.sentence(action: "external_directory", resources: ["/private/var/folders/98/tmp/*"]),
    detail: PermissionSentence.detail(action: "external_directory", resources: ["/private/var/folders/98/tmp/*"]),
    options: [
      .init(label: "Allow once", detail: nil, value: "once"),
      .init(label: "Always allow",
            detail: AgentQuestion.alwaysAllowScope(savePatterns: ["/private/var/folders/98/tmp/*"]),
            value: "always"),
      .init(label: "Deny", detail: nil, value: "reject"),
    ],
    allowsMultiple: false, allowsCustom: false)

  func testRenderThePermissionCard() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let heredoc = (["cat > notes.md <<'EOF'"] + (1...14).map { "line \($0) of the notes" } + ["EOF"])
      .joined(separator: "\n")
    let cases: [(String, AgentQuestion)] = [
      ("external", Self.external),
      ("words", Self.external),
      ("bash", AgentQuestion(
        kind: .permission, requestID: "p2", header: "Bash",
        prompt: PermissionSentence.sentence(action: "bash", resources: ["git push --force origin main"]),
        detail: PermissionSentence.detail(action: "bash", resources: ["git push --force origin main"]),
        options: [.init(label: "Allow once", detail: nil, value: "accept"),
                  .init(label: "Always allow", detail: "this session", value: "acceptForSession"),
                  .init(label: "Deny", detail: nil, value: "decline")],
        allowsMultiple: false, allowsCustom: false)),
      ("heredoc", AgentQuestion(
        kind: .permission, requestID: "p3", header: "Bash",
        prompt: PermissionSentence.sentence(action: "bash", resources: [heredoc]),
        detail: PermissionSentence.detail(action: "bash", resources: [heredoc]),
        options: [.init(label: "Allow once", detail: nil, value: "once"),
                  .init(label: "Deny", detail: nil, value: "reject")],
        allowsMultiple: false, allowsCustom: false)),
      ("grok", AgentQuestion(
        kind: .permission, requestID: "p4", header: "Edit",
        prompt: PermissionSentence.sentence(action: "edit", resources: ["/Users/me/Projects/app/Sources/App.swift"]),
        detail: PermissionSentence.detail(action: "edit", resources: ["/Users/me/Projects/app/Sources/App.swift"]),
        options: [.init(label: "Allow once", detail: nil, value: "allow_once"),
                  .init(label: "Always allow", detail: nil, value: "allow_always"),
                  .init(label: "Reject once", detail: nil, value: "reject_once"),
                  .init(label: "Always reject", detail: nil, value: "reject_always")],
        allowsMultiple: false, allowsCustom: false)),
    ]
    let ask = ConversationMessage(
      id: "u0", role: .user, createdAt: Date(),
      parts: [.text(TextPart(id: "u0t", kind: .text, text: "Tidy the build folder"))])
    for (name, question) in cases {
      let view = AgentPaletteView()
      view.appearance = NSAppearance(named: .darkAqua)
      view.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
      view.prepareForPresentation()
      var preview = PermissionDisclosureTests.preview(question)
      preview.messages = [ask]
      view.enterAddressing(preview)
      view.cancelAllAnimationsAndSettle()
      view.layoutSubtreeIfNeeded()
      if name == "words" {
        view.field.setDraft(PromptDraft("Use the project's own tmp folder"))
        view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))
      }
      let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: .darkAqua)
      let ground = NSView(frame: view.bounds)
      ground.wantsLayer = true
      ground.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
      ground.addSubview(view)
      window.contentView = ground
      view.cancelAllAnimationsAndSettle()
      if name == "words" { RunLoop.main.run(until: Date().addingTimeInterval(1.5)) }
      ground.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      CATransaction.flush()
      let bitmap = try XCTUnwrap(ground.bitmapImageRepForCachingDisplay(in: ground.bounds))
      ground.cacheDisplay(in: ground.bounds, to: bitmap)
      let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("permission-\(name).png"))
      window.close()
    }
  }

  static let storage = AgentQuestion(
    kind: .question, requestID: "frm_1", header: "Зберігання пароля",
    prompt: "Де зберігати облікові дані toloka?",
    options: [
      .init(label: "Keychain (macOS)",
            detail: "Читає з macOS Keychain через `security` — пароль ніде не лежить на диску. Працює на macOS лише."),
      .init(label: "Файл з правами 600",
            detail: "Окремий файл поза репозиторієм з правами 600, напр. ~/.config/exua/toloka. Простіший, працює на всіх ОС."),
      .init(label: "Змінні оточення",
            detail: "Через змінні оточення — пароль у пам'яті процесу, на диск не потрапляє. Але треба щоразу експортувати перед запуском."),
    ],
    allowsMultiple: false, allowsCustom: true)

  func testRenderTheQuestionCard() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let several = AgentQuestion(
      kind: .question, requestID: "frm_2", header: "Платформи",
      prompt: "Для яких платформ збирати?",
      options: [.init(label: "macOS", detail: nil), .init(label: "Linux", detail: nil),
                .init(label: "Windows", detail: "Через WSL — повільніше")],
      allowsMultiple: true, allowsCustom: true)
    let cases: [(String, AgentQuestion, String?)] = [
      ("question", Self.storage, nil),
      ("question-words", Self.storage, "чи можемо ввести пароль просто в застосунку?"),
      ("question-several", several, nil),
    ]
    let ask = ConversationMessage(
      id: "u0", role: .user, createdAt: Date(),
      parts: [.text(TextPart(id: "u0t", kind: .text, text: "Додай логін до toloka"))])
    for (name, question, words) in cases {
      let view = AgentPaletteView()
      view.appearance = NSAppearance(named: .darkAqua)
      view.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
      view.prepareForPresentation()
      var preview = PermissionDisclosureTests.preview(question)
      preview.messages = [ask]
      view.enterAddressing(preview)
      view.cancelAllAnimationsAndSettle()
      view.layoutSubtreeIfNeeded()
      if let words {
        view.field.setDraft(PromptDraft(words))
        view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))
      }
      let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: .darkAqua)
      let ground = NSView(frame: view.bounds)
      ground.wantsLayer = true
      ground.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
      ground.addSubview(view)
      window.contentView = ground
      view.cancelAllAnimationsAndSettle()
      if words != nil { RunLoop.main.run(until: Date().addingTimeInterval(1.5)) }
      ground.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      CATransaction.flush()
      let bitmap = try XCTUnwrap(ground.bitmapImageRepForCachingDisplay(in: ground.bounds))
      ground.cacheDisplay(in: ground.bounds, to: bitmap)
      let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
      window.close()
    }
  }
}


@MainActor
final class PermissionAnsweringTests: XCTestCase {
  private func panel(_ question: AgentQuestion = PermissionCardContactSheet.external)
    -> (AgentPaletteView, () -> [String]?)
  {
    let view = AgentPaletteView()
    view.appearance = NSAppearance(named: .darkAqua)
    view.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    view.layoutSubtreeIfNeeded()
    view.enterAddressing(PermissionDisclosureTests.preview(question))
    view.cancelAllAnimationsAndSettle()
    view.layoutSubtreeIfNeeded()
    var answered: [String]?
    view.onAnswerQuestion = { _, _, values in answered = values }
    return (view, { answered })
  }

  private func key(_ view: AgentPaletteView, _ selector: Selector) {
    _ = view.textView(view.field, doCommandBy: selector)
  }

  func testReturnAllowsOnce() {
    let (view, answered) = panel()
    key(view, #selector(NSResponder.insertNewline(_:)))
    XCTAssertEqual(answered(), ["once"])
  }

  func testDownMovesReturnToTheNextAnswerAndUpBringsItBack() throws {
    let (view, answered) = panel()
    let bar = try XCTUnwrap(view.previewCardForTesting.approvalBarForTesting)
    key(view, #selector(NSResponder.moveDown(_:)))
    XCTAssertEqual(bar.returnTitleForTesting, "Always allow")
    key(view, #selector(NSResponder.moveDown(_:)))
    XCTAssertEqual(bar.returnTitleForTesting, "Deny")
    key(view, #selector(NSResponder.moveDown(_:)))
    XCTAssertEqual(bar.returnTitleForTesting, "Deny", "the last answer holds")
    key(view, #selector(NSResponder.moveUp(_:)))
    XCTAssertEqual(bar.returnTitleForTesting, "Always allow")
    key(view, #selector(NSResponder.insertNewline(_:)))
    XCTAssertEqual(answered(), ["always"])
  }

  func testDownTwiceThenReturnDenies() {
    let (view, answered) = panel()
    key(view, #selector(NSResponder.moveDown(_:)))
    key(view, #selector(NSResponder.moveDown(_:)))
    key(view, #selector(NSResponder.insertNewline(_:)))
    XCTAssertEqual(answered(), ["reject"])
  }

  func testClickingAButtonSendsItsAnswer() throws {
    for (label, value) in [("Allow once", "once"), ("Always allow", "always"), ("Deny", "reject")] {
      let (view, answered) = panel()
      let bar = try XCTUnwrap(view.previewCardForTesting.approvalBarForTesting)
      try XCTUnwrap(bar.buttonForTesting(label)).performClick(nil)
      XCTAssertEqual(answered(), [value], label)
    }
  }

  func testANumberAnswersAQuestionAtOnce() {
    let question = AgentQuestion(
      kind: .question, requestID: "q", header: "Approach", prompt: "Which one?",
      options: [.init(label: "SwiftUI", detail: nil, value: "swiftui"),
                .init(label: "AppKit", detail: nil, value: "appkit"),
                .init(label: "Both", detail: nil, value: "both")],
      allowsMultiple: false, allowsCustom: false)
    for (digit, value) in [("1", "swiftui"), ("2", "appkit"), ("3", "both")] {
      let (view, answered) = panel(question)
      XCTAssertFalse(
        view.textView(view.field, shouldChangeTextIn: .init(location: 0, length: 0), replacementString: digit),
        "the digit is the answer, not a letter in the composer")
      XCTAssertEqual(answered(), [value], digit)
      XCTAssertTrue(view.field.isEmptyPrompt)
    }
  }

  func testADigitOnAPermissionIsTheFirstLetterOfTheWords() {
    for digit in ["1", "2", "3", "7"] {
      let (view, answered) = panel()
      XCTAssertTrue(view.textView(
        view.field, shouldChangeTextIn: .init(location: 0, length: 0), replacementString: digit), digit)
      XCTAssertNil(answered(), digit)
    }
  }

  func testTheButtonsWearTheirKeys() throws {
    let (view, _) = panel()
    let bar = try XCTUnwrap(view.previewCardForTesting.approvalBarForTesting)
    XCTAssertEqual(bar.keysForTesting, ["Deny", "Always allow", "Allow once  ↵"])
    key(view, #selector(NSResponder.moveDown(_:)))
    XCTAssertEqual(bar.keysForTesting, ["Deny", "Always allow  ↵", "Allow once"])
  }

  func testAnswersThatDoNotFitStandInAColumn() throws {
    func permission(_ labels: [String]) -> AgentQuestion {
      AgentQuestion(
        kind: .permission, requestID: "g", header: nil, prompt: "Edit App.swift?",
        detail: "edit\n/tmp/App.swift",
        options: labels.map { .init(label: $0, detail: nil, value: $0) },
        allowsMultiple: false, allowsCustom: false)
    }
    let grokLabels = ["Allow once", "Always allow", "Reject once", "Always reject"]
    let (grok, _) = panel(permission(grokLabels))
    let grokBar = try XCTUnwrap(grok.previewCardForTesting.approvalBarForTesting)
    grokBar.layoutSubtreeIfNeeded()
    XCTAssertEqual(
      grokBar.isStacked,
      !BolttyAIApprovalBar.fitsInOneRow(permission(grokLabels).options, width: grokBar.bounds.width))
    try assertEveryButtonFits(grokBar, grokLabels)

    let wordy = ["Allow this edit once", "Always allow edits like it",
                 "Reject this edit", "Always reject edits like it"]
    let (long, _) = panel(permission(wordy))
    let column = try XCTUnwrap(long.previewCardForTesting.approvalBarForTesting)
    XCTAssertTrue(column.isStacked)
    XCTAssertEqual(column.buttonTitlesForTesting, wordy)

    let (three, _) = panel()
    let row = try XCTUnwrap(three.previewCardForTesting.approvalBarForTesting)
    XCTAssertFalse(row.isStacked)
    try assertEveryButtonFits(row, ["Allow once", "Always allow", "Deny"])
  }

  private func assertEveryButtonFits(
    _ bar: BolttyAIApprovalBar, _ labels: [String],
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    bar.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(bar.bounds.width, 0, file: file, line: line)
    for label in labels {
      let button = try XCTUnwrap(bar.buttonForTesting(label), file: file, line: line)
      let frame = bar.convert(button.bounds, from: button)
      XCTAssertGreaterThanOrEqual(
        frame.width + 0.5, button.intrinsicContentSize.width, label, file: file, line: line)
      XCTAssertGreaterThanOrEqual(frame.minX, -0.5, label, file: file, line: line)
      XCTAssertLessThanOrEqual(frame.maxX, bar.bounds.width + 0.5, label, file: file, line: line)
    }
  }

  func testTheRowIsDecidedOnTheButtonsAsTheyLayOut() throws {
    let options: [AgentQuestion.Option] = ["Allow once", "Always allow", "Reject once", "Always reject"]
      .map { .init(label: $0, detail: nil, value: $0) }
    let widths = BolttyAIApprovalBar.buttonWidths(for: options)
    XCTAssertEqual(widths.count, options.count)

    let bar = BolttyAIApprovalBar(options: options)
    for focused in options.indices {
      bar.focusedIndex = focused
      for (index, option) in options.enumerated() {
        let button = try XCTUnwrap(bar.buttonForTesting(option.label))
        XCTAssertLessThanOrEqual(
          ceil(button.intrinsicContentSize.width), widths[index], "\(option.label), ↵ on \(focused)")
      }
    }
    let wearing = try XCTUnwrap(bar.buttonForTesting(options[1].label))
    bar.focusedIndex = 1
    XCTAssertEqual(ceil(wearing.intrinsicContentSize.width), widths[1], accuracy: 0.5)

    let needed = widths.reduce(0, +) + BolttyAIApprovalBar.buttonSpacing * CGFloat(options.count)
    XCTAssertTrue(BolttyAIApprovalBar.fitsInOneRow(options, width: needed))
    XCTAssertFalse(BolttyAIApprovalBar.fitsInOneRow(options, width: needed - 1))
  }

  private func type(_ text: String, into view: AgentPaletteView) {
    view.field.setDraft(PromptDraft(text))
    view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))
  }

  func testWordsRefuseAndTravelWithTheRefusal() throws {
    let (view, answered) = panel()
    XCTAssertEqual(view.promptPlaceholderForTesting, "Or tell OpenCode what to do instead")
    type("use pnpm", into: view)
    let bar = try XCTUnwrap(view.previewCardForTesting.approvalBarForTesting)
    XCTAssertNil(bar.returnTitleForTesting, "Return presses no button while words stand")
    XCTAssertFalse(bar.keysForTesting.contains { $0.contains("↵") }, "\(bar.keysForTesting)")
    XCTAssertEqual(view.trailingHintForTesting, ["Deny and send ↵"])
    key(view, #selector(NSResponder.insertNewline(_:)))
    XCTAssertEqual(answered(), ["reject", "use pnpm"])
  }

  func testClearingTheWordsGivesReturnBackToTheButton() throws {
    let (view, answered) = panel()
    type("use pnpm", into: view)
    type("", into: view)
    let bar = try XCTUnwrap(view.previewCardForTesting.approvalBarForTesting)
    XCTAssertEqual(bar.returnTitleForTesting, "Allow once")
    key(view, #selector(NSResponder.insertNewline(_:)))
    XCTAssertEqual(answered(), ["once"])
  }

  func testBlankWordsAreNotARefusal() {
    let (view, answered) = panel()
    type("   ", into: view)
    key(view, #selector(NSResponder.insertNewline(_:)))
    XCTAssertEqual(answered(), ["once"])
  }

  private static let typeable = AgentQuestion(
    kind: .question, requestID: "frm_1", header: "Зберігання пароля",
    prompt: "Де зберігати облікові дані toloka?",
    options: [.init(label: "Keychain (macOS)", detail: nil), .init(label: "Файл з правами 600", detail: nil)],
    allowsMultiple: false, allowsCustom: true)

  func testAQuestionThatTakesATypedAnswerSaysSo() throws {
    let (view, _) = panel(Self.typeable)
    XCTAssertEqual(view.promptPlaceholderForTesting, "Or type your own answer")
    let footer = try XCTUnwrap(view.previewCardForTesting.optionsFooterForTesting)
    XCTAssertTrue(footer.contains("type your own answer"), footer)
  }

  func testTypedWordsAreTheAnswerReturnSends() {
    let (view, answered) = panel(Self.typeable)
    let card = view.previewCardForTesting
    XCTAssertEqual(card.chosenRowsForTesting, [0])
    type("а в самому застосунку?", into: view)
    XCTAssertEqual(card.chosenRowsForTesting, [], "no row is what Return sends")
    XCTAssertEqual(card.optionsFooterForTesting, AgentQuestion.typedAnswerFooter)
    type("", into: view)
    XCTAssertEqual(card.chosenRowsForTesting, [0])
    XCTAssertEqual(card.optionsFooterForTesting, Self.typeable.keyboardFooter)
    type("а в самому застосунку?", into: view)
    key(view, #selector(NSResponder.insertNewline(_:)))
    XCTAssertEqual(answered(), ["а в самому застосунку?"])
  }
}

final class PermissionRefusalWireTests: XCTestCase {
  func testClaudeCodeFramesTheWordsAsTheUsers() {
    XCTAssertEqual(ClaudeCodeClient.denialMessage(saying: nil), "The user did not allow this.")
    XCTAssertEqual(ClaudeCodeClient.denialMessage(saying: "  "), "The user did not allow this.")
    XCTAssertEqual(
      ClaudeCodeClient.denialMessage(saying: "use pnpm"),
      "The user did not allow this. To tell you how to proceed, the user said:\nuse pnpm")
  }

  func testOpenCodeTakesItsDecisionAndTheWords() throws {
    func json(_ body: some Encodable) throws -> [String: String] {
      try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: String])
    }
    XCTAssertEqual(
      try json(OpenCodeDTO.PermissionReplyRequest(decision: "once", message: nil)),
      ["decision": "once"])
    XCTAssertEqual(
      try json(OpenCodeDTO.PermissionReplyRequest(decision: "reject", message: "use pnpm")),
      ["decision": "reject", "message": "use pnpm"])
    XCTAssertEqual(
      try json(OpenCodeDTO.LegacyPermissionReplyRequest(reply: "reject", message: nil)),
      ["reply": "reject"])
  }

  func testAReplyToAGoneAskIsRequestGoneEverywhere() async {
    func gone(_ reply: () async throws -> Void) async -> Bool {
      do { try await reply(); return false } catch { return error as? AgentClientError == .requestGone }
    }
    var ok = await gone { try await OpenCodeClient.answering { throw AgentClientError.sessionNotFound } }
    XCTAssertTrue(ok, "OpenCode: a 404 on the reply route")
    ok = await gone { try await OpenCodeClient.answering { throw AgentClientError.transport("HTTP 500: x") } }
    XCTAssertFalse(ok, "anything else stays what it was, and keeps its retry")

    let claude = ClaudeCodeClient()
    ok = await gone { try await claude.answerPermission(
      requestID: "req", sessionID: UUID().uuidString, decision: .once, message: nil) }
    XCTAssertTrue(ok, "Claude Code")
    let codex = CodexClient()
    ok = await gone { try await codex.answerPermission(
      requestID: "req", sessionID: "thr", decision: .once, message: nil) }
    XCTAssertTrue(ok, "Codex, a permission")
    ok = await gone { try await codex.answerQuestion(requestID: "req", sessionID: "thr", answers: []) }
    XCTAssertTrue(ok, "Codex, a question")
    ok = await gone { try await codex.rejectQuestion(requestID: "req", sessionID: "thr") }
    XCTAssertTrue(ok, "Codex, a dismissal")
    let grok = ACPClient(agent: .grok)
    ok = await gone { try await grok.answerPermission(
      requestID: "req", sessionID: "s", decision: .once, message: nil) }
    XCTAssertTrue(ok, "Grok")
  }

  func testOnlyClaudeCodeAndOpenCodeCarryWords() {
    XCTAssertTrue(ClaudeCodeClient().capabilities.contains(.permissionMessage))
    XCTAssertTrue(OpenCodeClient().capabilities.contains(.permissionMessage))
    XCTAssertFalse(CodexClient().capabilities.contains(.permissionMessage))
    XCTAssertFalse(ACPClient(agent: .grok).capabilities.contains(.permissionMessage))
  }
}

@MainActor
final class PlanCardTests: XCTestCase {
  static let markdown = "# Rename the tray\n\n1. Rename it."

  static func plan(_ markdown: String = markdown) -> AgentQuestion {
    let empty = markdown.isEmpty
    return AgentQuestion(
      kind: .plan, requestID: "call-1",
      header: PlanPrompt(markdown: markdown).title,
      prompt: empty ? PlanPrompt.emptyText : "",
      options: [
        .init(label: "Approve", detail: nil, value: "approved"),
        .init(label: "Request changes", detail: nil, value: "cancelled"),
        .init(label: "Quit", detail: nil, value: "abandoned"),
      ],
      allowsMultiple: false, allowsCustom: false,
      copyText: empty ? nil : markdown
    )
  }

  private func card(_ question: AgentQuestion = plan()) -> BolttyAIPreviewCard {
    let card = BolttyAIPreviewCard()
    card.frame = NSRect(x: 0, y: 0, width: AgentPaletteMetrics.promptSize.width, height: 420)
    card.apply(BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .grok, state: .blocked, body: "",
      question: question,
      messages: [ConversationMessage(
        id: "msg_1-reply", role: .agent, createdAt: Date(),
        parts: [.text(TextPart(id: "msg_1-reply-plan-call-1", kind: .text, text: Self.markdown))]
      )]
    ))
    card.layoutSubtreeIfNeeded()
    return card
  }

  func testThePlanIsTitledByItsHeadingAndAnsweredWithButtons() throws {
    let card = card()
    XCTAssertEqual(card.questionTitleForTesting, "Rename the tray")
    let bar = try XCTUnwrap(card.approvalBarForTesting)
    XCTAssertEqual(bar.buttonTitlesForTesting, ["Quit", "Request changes", "Approve"],
                   "set right to left from the default, Quit apart at the leading edge")
    XCTAssertEqual(bar.rowTitlesForTesting, ["Quit", "Copy", "Request changes", "Approve"])
    XCTAssertEqual(bar.returnTitleForTesting, "Approve")
  }

  func testAHeadinglessPlanIsCalledPlan() {
    XCTAssertEqual(PlanPrompt(markdown: "Just do it.").title, "Plan")
    XCTAssertEqual(PlanPrompt(markdown: "Intro\n\n## Steps\n- one").title, "Steps")
    XCTAssertEqual(PlanPrompt(markdown: "").title, "Plan")
  }

  func testReturnNeverReachesQuit() throws {
    let card = card()
    let bar = try XCTUnwrap(card.approvalBarForTesting)
    XCTAssertTrue(card.moveOptionFocus(by: 5))
    XCTAssertEqual(bar.returnTitleForTesting, "Request changes")
    XCTAssertEqual(Self.plan().returnReachableCount, 2)
  }

  func testEachButtonSendsItsOwnAnswer() throws {
    let card = card()
    let bar = try XCTUnwrap(card.approvalBarForTesting)
    var sent: [[String]] = []
    card.onAnswer = { _, values in sent.append(values) }

    bar.pressForTesting(0)
    bar.pressForTesting(1)
    bar.pressForTesting(2)
    XCTAssertEqual(sent, [["approved"], ["cancelled"], ["abandoned"]])
  }

  func testCopyCopiesThePlanAndAnswersNothing() throws {
    let card = card()
    let bar = try XCTUnwrap(card.approvalBarForTesting)
    var sent: [[String]] = []
    card.onAnswer = { _, values in sent.append(values) }
    let pasteboard = NSPasteboard.general
    let saved = pasteboard.string(forType: .string)
    defer {
      pasteboard.clearContents()
      if let saved { pasteboard.setString(saved, forType: .string) }
    }

    let copy = try XCTUnwrap(bar.copyButtonForTesting)
    copy.performClick(nil)

    XCTAssertEqual(pasteboard.string(forType: .string), Self.markdown)
    XCTAssertTrue(sent.isEmpty, "copying is not an answer")
  }

  func testAnEmptyPlanSaysSoAndKeepsItsAnswers() throws {
    let card = card(Self.plan(""))
    XCTAssertEqual(card.questionTitleForTesting, "Plan")
    XCTAssertEqual(card.bodyForTesting, "No plan written yet")
    let bar = try XCTUnwrap(card.approvalBarForTesting)
    XCTAssertEqual(bar.buttonTitlesForTesting, ["Quit", "Request changes", "Approve"])
    XCTAssertNil(bar.copyButtonForTesting, "nothing to copy")
  }

  func testWordsOnAPlanRequestChanges() {
    let plan = Self.plan()
    XCTAssertTrue(plan.takesWordsAsRefusal)
    XCTAssertFalse(plan.answersByNumber)
    XCTAssertEqual(plan.refusing(with: "smaller"), ["cancelled", "smaller"])
    XCTAssertEqual(plan.refusalWords, "Request changes")
    XCTAssertEqual(
      AgentPaletteView.composerPlaceholder(for: BolttyAISessionPreview(
        id: UUID(), title: "Chat", agent: .grok, state: .blocked, body: "", question: plan)),
      "Or tell Grok what to change")
  }
}
