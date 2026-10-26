import AppKit
import Carbon.HIToolbox
import XCTest

@MainActor
final class BolttyAIScreenshotTests: XCTestCase {
  private var app: XCUIApplication!
  private var extraLaunchArguments: [String] = []

  private var outputDirectory: URL {
    if let path = ProcessInfo.processInfo.environment["BOLTTY_SCREENSHOT_DIR"] {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent("boltty-shots", isDirectory: true)
  }

  override func setUp() async throws {
    try await super.setUp()
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments = ["--ui-testing"] + extraLaunchArguments
      app.launch()
    }
  }

  override func tearDown() async throws {
    await MainActor.run {
      app.terminate()
      app = nil
    }
    try await super.tearDown()
  }

  private var mainWindow: XCUIElement {
    app.windows.firstMatch
  }

  @discardableResult
  private func waitForApp(timeout: TimeInterval = 10) -> Bool {
    app.activate()
    guard app.wait(for: .runningForeground, timeout: timeout) else { return false }
    return app.windows["boltty.settings.window"].waitForExistence(timeout: timeout)
  }

  private var askInput: XCUIElement {
    app.descendants(matching: .any)["boltty.ask.input"]
  }

  private func physicalShortcutKey(_ keyCode: Int, fallback: String) -> String {
    guard
      let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let rawLayoutData = TISGetInputSourceProperty(
        inputSource,
        kTISPropertyUnicodeKeyLayoutData
      )
    else { return fallback }

    let layoutData = Unmanaged<CFData>.fromOpaque(rawLayoutData).takeUnretainedValue()
    let layout = unsafeBitCast(
      CFDataGetBytePtr(layoutData),
      to: UnsafePointer<UCKeyboardLayout>.self
    )

    var deadKeyState: UInt32 = 0
    var length = 0
    var characters = [UniChar](repeating: 0, count: 4)
    let status = UCKeyTranslate(
      layout,
      UInt16(keyCode),
      UInt16(kUCKeyActionDisplay),
      0,
      UInt32(LMGetKbdType()),
      OptionBits(kUCKeyTranslateNoDeadKeysBit),
      &deadKeyState,
      characters.count,
      &length,
      &characters
    )

    guard status == noErr, length > 0 else { return fallback }
    return String(utf16CodeUnits: characters, count: length).lowercased()
  }

  private func save(_ screenshot: XCUIScreenshot, as name: String) throws {
    try FileManager.default.createDirectory(
      at: outputDirectory,
      withIntermediateDirectories: true
    )
    let url = outputDirectory.appendingPathComponent("\(name).png")
    try screenshot.pngRepresentation.write(to: url)

    print("BOLTTY_SHOT \(url.path)")
  }

  func testCaptureChatAndInitialThinking() throws {
    for thinking in [true, false] {
      app.terminate()
      app = XCUIApplication()
      app.launchArguments = ["--ui-testing", "--ui-testing-chat"] + (thinking ? ["--ui-testing-thinking"] : [])
      app.launch()
      XCTAssertTrue(waitForApp())
      app.windows["boltty.settings.window"].click()
      app.typeKey(physicalShortcutKey(kVK_ANSI_P, fallback: "p"), modifierFlags: [.command, .shift])
      XCTAssertTrue(askInput.waitForExistence(timeout: 5))
      Thread.sleep(forTimeInterval: 1)
      try save(XCUIScreen.main.screenshot(), as: thinking ? "chat-thinking" : "chat-history")
      app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
      XCTAssertTrue(askInput.exists)
      app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }
  }

  func testCaptureBolttyAIEmptyAndWithSessionList() throws {
    XCTAssertTrue(waitForApp(timeout: 10))
    app.windows["boltty.settings.window"].click()

    app.typeKey(
      physicalShortcutKey(kVK_ANSI_P, fallback: "p"),
      modifierFlags: [.command, .shift]
    )
    XCTAssertTrue(askInput.waitForExistence(timeout: 5))

    Thread.sleep(forTimeInterval: 1.0)
    try save(XCUIScreen.main.screenshot(), as: "ask-collapsed")

    app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
    for (index, delay) in [0.06, 0.14, 0.24].enumerated() {
      Thread.sleep(forTimeInterval: index == 0 ? delay : delay - [0.06, 0.14, 0.24][index - 1])
      try save(XCUIScreen.main.screenshot(), as: "ask-entrance-\(index)")
    }

    Thread.sleep(forTimeInterval: 1.0)
    try save(XCUIScreen.main.screenshot(), as: "ask-expanded")

    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
  }

  func testCaptureHistoryTabs() throws {
    XCTAssertTrue(waitForApp(timeout: 10))
    app.windows["boltty.settings.window"].click()
    app.typeKey(physicalShortcutKey(kVK_ANSI_P, fallback: "p"), modifierFlags: [.command, .shift])
    XCTAssertTrue(askInput.waitForExistence(timeout: 5))
    Thread.sleep(forTimeInterval: 0.6)

    app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
    Thread.sleep(forTimeInterval: 1.5)
    for _ in 0..<4 { app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: []) }
    Thread.sleep(forTimeInterval: 0.6)
    try save(XCUIScreen.main.screenshot(), as: "history-tab-0")
    for index in 1...4 {
      app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
      Thread.sleep(forTimeInterval: 0.6)
      try save(XCUIScreen.main.screenshot(), as: "history-tab-\(index)")
    }
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
  }

  func testCaptureBolttyAIWhileListening() throws {
    app.terminate()
    app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--ui-testing-voice"]
    app.launch()

    XCTAssertTrue(waitForApp(timeout: 10))
    app.windows["boltty.settings.window"].click()
    app.typeKey(
      physicalShortcutKey(kVK_ANSI_P, fallback: "p"),
      modifierFlags: [.command, .shift]
    )
    XCTAssertTrue(askInput.waitForExistence(timeout: 5))

    Thread.sleep(forTimeInterval: 1.5)
    try save(XCUIScreen.main.screenshot(), as: "ask-listening")


    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
  }

  func testCaptureBolttyAIListeningWithTranscript() throws {
    app.terminate()
    app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--ui-testing-voice", "--ui-testing-voice-transcript"]
    app.launch()

    XCTAssertTrue(waitForApp(timeout: 10))
    app.windows["boltty.settings.window"].click()
    app.typeKey(
      physicalShortcutKey(kVK_ANSI_P, fallback: "p"),
      modifierFlags: [.command, .shift]
    )
    XCTAssertTrue(askInput.waitForExistence(timeout: 5))

    Thread.sleep(forTimeInterval: 1.5)
    try save(XCUIScreen.main.screenshot(), as: "ask-listening-transcript")

    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
  }

  func testCaptureBolttyAIWhileProcessing() throws {
    app.terminate()
    app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--ui-testing-voice", "--ui-testing-voice-processing"]
    app.launch()

    XCTAssertTrue(waitForApp(timeout: 10))
    app.windows["boltty.settings.window"].click()
    app.typeKey(
      physicalShortcutKey(kVK_ANSI_P, fallback: "p"),
      modifierFlags: [.command, .shift]
    )
    XCTAssertTrue(askInput.waitForExistence(timeout: 5))

    Thread.sleep(forTimeInterval: 1.2)
    try save(XCUIScreen.main.screenshot(), as: "ask-processing")

    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
  }

  func testCaptureBolttyAIListeningOverSeveralLines() throws {
    app.terminate()
    app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--ui-testing-voice", "--ui-testing-voice-long"]
    app.launch()

    XCTAssertTrue(waitForApp(timeout: 10))
    app.windows["boltty.settings.window"].click()
    app.typeKey(
      physicalShortcutKey(kVK_ANSI_P, fallback: "p"),
      modifierFlags: [.command, .shift]
    )
    XCTAssertTrue(askInput.waitForExistence(timeout: 5))

    Thread.sleep(forTimeInterval: 1.5)
    try save(XCUIScreen.main.screenshot(), as: "ask-listening-multiline")

    let mic = app.buttons["boltty.ask.mic"]
    XCTAssertTrue(mic.waitForExistence(timeout: 3))
    mic.hover()
    let cancel = app.buttons["boltty.ask.voice.cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 3))
    cancel.click()
    Thread.sleep(forTimeInterval: 0.3)
    try save(XCUIScreen.main.screenshot(), as: "ask-draft-multiline")

    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
  }

  func testCaptureBolttyAIReplyWithOptions() throws {
    app.terminate()
    app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--ui-testing-reply"]
    app.launch()
    XCTAssertTrue(waitForApp(timeout: 10))
    app.windows["boltty.settings.window"].click()
    app.typeKey(UITestKeyboard.key(kVK_ANSI_P, fallback: "p"), modifierFlags: [.command, .shift])
    XCTAssertTrue(askInput.waitForExistence(timeout: 5))
    XCTAssertTrue(app.descendants(matching: .any)["boltty.ask.preview"].waitForExistence(timeout: 5))
    Thread.sleep(forTimeInterval: 0.5)
    try save(XCUIScreen.main.screenshot(), as: "ask-reply-options")
  }

  func testCaptureChips() throws {
    XCTAssertTrue(waitForApp(timeout: 10))
    app.windows["boltty.settings.window"].click()
    app.typeKey(UITestKeyboard.key(kVK_ANSI_P, fallback: "p"), modifierFlags: [.command, .shift])
    XCTAssertTrue(askInput.waitForExistence(timeout: 5))
    askInput.click()

    let pasteboard = NSPasteboard.general
    func paste() {
      app.typeKey(UITestKeyboard.key(kVK_ANSI_V, fallback: "v"), modifierFlags: [.command])
      Thread.sleep(forTimeInterval: 0.4)
    }

    pasteboard.clearContents()
    pasteboard.setString("Hello! ", forType: .string)
    paste()

    pasteboard.clearContents()
    pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/boltty-lens-probe.txt") as NSURL])
    paste()

    pasteboard.clearContents()
    pasteboard.setString(String(repeating: "lorem ipsum dolor sit amet ", count: 24), forType: .string)
    paste()

    pasteboard.clearContents()
    pasteboard.setString("https://example.com/some/long/path", forType: .string)
    paste()

    pasteboard.clearContents()
    let image = NSImage(size: NSSize(width: 64, height: 64))
    image.lockFocus()
    NSColor.systemGreen.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 64, height: 64)).fill()
    image.unlockFocus()
    if let tiff = image.tiffRepresentation {
      pasteboard.setData(tiff, forType: .tiff)
      paste()
    }

    Thread.sleep(forTimeInterval: 1.0)
    try save(XCUIScreen.main.screenshot(), as: "ask-chips")

    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
  }

  // MARK: - Every state with glass in it

  private func openPanel(_ flags: [String]) {
    app.terminate()
    app = XCUIApplication()
    app.launchArguments = ["--ui-testing"] + flags
    app.launch()
    XCTAssertTrue(waitForApp(timeout: 10))
    app.windows["boltty.settings.window"].click()
    app.typeKey(UITestKeyboard.key(kVK_ANSI_P, fallback: "p"), modifierFlags: [.command, .shift])
    XCTAssertTrue(askInput.waitForExistence(timeout: 5))
  }

  private func paste(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    app.typeKey(UITestKeyboard.key(kVK_ANSI_V, fallback: "v"), modifierFlags: [.command])
  }

  func testCaptureServiceCards() throws {
    for (name, flags) in [
      ("ask-permission", ["--ui-testing-service-cards"]),
      ("ask-queued", ["--ui-testing-service-cards", "--ui-testing-queue"]),
      ("ask-error", ["--ui-testing-service-cards", "--ui-testing-error"]),
    ] {
      openPanel(flags)
      Thread.sleep(forTimeInterval: 1.2)
      try save(XCUIScreen.main.screenshot(), as: name)
      app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }
  }

  func testCaptureFirstScreenDrafts() throws {
    openPanel([])
    Thread.sleep(forTimeInterval: 1.0)
    try save(XCUIScreen.main.screenshot(), as: "ask-empty")

    askInput.click()
    paste("fix the failing tests")
    Thread.sleep(forTimeInterval: 1.8)
    try save(XCUIScreen.main.screenshot(), as: "ask-draft-key-hints")

    paste(" — and then read every warning the build prints, explain which ones matter, "
      + "fix those, and leave a short note in the chat about the ones you chose to keep.")
    Thread.sleep(forTimeInterval: 1.8)
    try save(XCUIScreen.main.screenshot(), as: "ask-draft-grown")
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
  }

  func testCaptureChatComposerWithDraft() throws {
    for (name, flags) in [
      ("chat-composer-draft", ["--ui-testing-chat"]),
      ("chat-thinking-draft", ["--ui-testing-chat", "--ui-testing-thinking"]),
    ] {
      openPanel(flags)
      Thread.sleep(forTimeInterval: 0.8)
      paste("and compare it with the GUI")
      Thread.sleep(forTimeInterval: 1.8)
      try save(XCUIScreen.main.screenshot(), as: name)
      app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }
  }
}
