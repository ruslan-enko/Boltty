import AppKit
import XCTest
@testable import Boltty

final class PasteboardImageIngestTests: XCTestCase {
  private func makePasteboard(_ name: String = #function) -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name("boltty.tests.\(name)"))
    board.clearContents()
    return board
  }

  private func makeImageData() -> (tiff: Data, png: Data) {
    let image = NSImage(size: NSSize(width: 8, height: 8))
    image.lockFocus()
    NSColor.systemPink.setFill()
    NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    image.unlockFocus()
    let tiff = image.tiffRepresentation!
    let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    return (tiff, png)
  }

  func testPastedScreenshotBecomesAChip() throws {
    let board = makePasteboard()
    board.setData(makeImageData().tiff, forType: .tiff)

    let outcome = PasteboardIngest.read(board, into: PromptDraft())

    guard case let .attachments(chips) = outcome else {
      return XCTFail("expected a chip for pasted image data, got \(outcome)")
    }
    XCTAssertEqual(chips.count, 1)
  }

  func testPastedPNGDataBecomesAChip() throws {
    let board = makePasteboard()
    board.setData(makeImageData().png, forType: .png)

    let outcome = PasteboardIngest.read(board, into: PromptDraft())

    guard case let .attachments(chips) = outcome else {
      return XCTFail("expected a chip for pasted PNG data, got \(outcome)")
    }
    XCTAssertEqual(chips.count, 1)
  }
}

@MainActor
final class PromptPasteShortcutTests: XCTestCase {
  private func keyEvent(_ modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "v",
      charactersIgnoringModifiers: "v",
      isARepeat: false,
      keyCode: 9
    )!
  }

  func testCommandVReachesThePasteHandlerWithoutTheMenu() throws {
    let (_, field) = PromptTextView.makeInScrollView()
    var forcedPlainText: Bool?
    field.onPaste = { forcedPlainText = $0 }

    XCTAssertTrue(field.performKeyEquivalent(with: keyEvent([.command])))
    XCTAssertEqual(forcedPlainText, false)
  }

  func testCommandShiftVStillAsksForPlainText() throws {
    let (_, field) = PromptTextView.makeInScrollView()
    var forcedPlainText: Bool?
    field.onPaste = { forcedPlainText = $0 }

    XCTAssertTrue(field.performKeyEquivalent(with: keyEvent([.command, .shift])))
    XCTAssertEqual(forcedPlainText, true)
  }

  func testOtherCombinationsAreLeftAlone() throws {
    let (_, field) = PromptTextView.makeInScrollView()
    var pasted = false
    field.onPaste = { _ in pasted = true }

    _ = field.performKeyEquivalent(with: keyEvent([.command, .option]))
    _ = field.performKeyEquivalent(with: keyEvent([]))
    XCTAssertFalse(pasted)
  }
}
