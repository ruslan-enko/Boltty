import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Boltty

@MainActor
final class ChipInteractionTests: XCTestCase {
  private func makeField() -> PromptTextView {
    let (scrollView, textView) = PromptTextView.makeInScrollView()
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: PromptTextView.lineHeight)
    scrollView.layoutSubtreeIfNeeded()
    return textView
  }

  private func fileChip(_ path: String) -> PromptAttachment {
    PromptAttachment.file(URL(fileURLWithPath: path))
  }

  // MARK: - Deletion (D14)

  func testBackspaceRemovesAWholeChipInOnePress() {
    let field = makeField()
    field.insertChips([fileChip("/x/clip.mov")])
    field.insertPlainText("in mp4")
    field.setSelectedRange(NSRange(location: 1, length: 0))

    field.deleteBackward(nil)

    XCTAssertTrue(field.draft.attachments.isEmpty, "one press, no half-deleted capsule")
    XCTAssertEqual(field.draft.typedText, " in mp4")
  }

  func testASecondBackspaceTakesTheCharacterBeforeIt() {
    let field = makeField()
    field.insertPlainText("ab")
    field.insertChips([fileChip("/x/clip.mov")])
    field.setSelectedRange(NSRange(location: 4, length: 0))

    field.deleteBackward(nil)
    field.deleteBackward(nil)

    XCTAssertEqual(field.draft.typedText, "ab ")
    XCTAssertTrue(field.draft.attachments.isEmpty)
  }

  func testACapsuleIsOneCharacterSoArrowKeysStepOverItInOnePress() {
    let field = makeField()
    field.insertChips([fileChip("/x/a-very-long-recording-name.mov")])
    field.setSelectedRange(NSRange(location: 0, length: 0))

    field.moveRight(nil)

    XCTAssertEqual(
      field.selectedRange().location,
      1,
      "the label's length must not become the number of key presses"
    )
  }

  // MARK: - Hover (D14)

  func testAFileChipShowsItsWholePathBecauseTheLabelNeverCarriesIt() {
    let path = "/Users/e/clips/a-very-long-recording-name-from-the-camera.mov"
    let chip = fileChip(path)
    XCTAssertFalse(chip.displayLabel().contains("recording"), "the label is a kind and a number")
    XCTAssertEqual(chip.tooltip, path)
  }

  func testFilelessChipsShowWhatTheyAreAndHowBigTheyAre() {
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

  // MARK: - Entrance (D16)

  func testTheEntranceCurveStartsAtZeroAndLandsExactlyOnOne() {
    let duration = AgentPaletteMetrics.chipAppearDuration
    XCTAssertEqual(ChipEntranceAnimator.progress(elapsed: 0, duration: duration), 0)
    XCTAssertEqual(ChipEntranceAnimator.progress(elapsed: duration, duration: duration), 1)
    XCTAssertEqual(ChipEntranceAnimator.progress(elapsed: duration * 2, duration: duration), 1)
  }

  func testTheCurveEasesOutRatherThanRunningLinearly() {
    let duration = AgentPaletteMetrics.chipAppearDuration
    let half = ChipEntranceAnimator.progress(elapsed: duration / 2, duration: duration)
    XCTAssertGreaterThan(half, 0.5, "most of the distance is covered early")
    XCTAssertLessThan(half, 1)
  }

  func testAZeroDurationCannotDivideByZero() {
    XCTAssertEqual(ChipEntranceAnimator.progress(elapsed: 0, duration: 0), 1)
  }

  func testAFreshlyInsertedChipStartsSmallUnlessMotionIsReduced() throws {
    let field = makeField()
    field.insertChips([fileChip("/x/clip.mov")])

    let attachment = try XCTUnwrap(
      field.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil)
        as? PromptChipAttachment
    )
    let cell = try XCTUnwrap(attachment.attachmentCell as? PromptChipCell)
    let expected: CGFloat = MotionPreferences.reduceMotion ? 1 : 0
    XCTAssertEqual(cell.appearProgress, expected)
  }

  func testAChipDrawnAtFullProgressIsFullSize() {
    XCTAssertEqual(PromptChipCell.entranceScale(for: 1), 1)
    XCTAssertLessThan(PromptChipCell.entranceScale(for: 0), 1)
  }

  func testAnEntranceLandsWithNoScreenToDriveIt() throws {
    let field = makeField()
    field.insertChips([fileChip("/x/clip.mov")])
    XCTAssertNil(field.window, "precondition: nothing to drive a display link")

    RunLoop.main.run(
      until: Date().addingTimeInterval(AgentPaletteMetrics.chipAppearDuration + 0.3)
    )

    let attachment = try XCTUnwrap(
      field.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil)
        as? PromptChipAttachment
    )
    let cell = try XCTUnwrap(attachment.attachmentCell as? PromptChipCell)
    XCTAssertEqual(cell.appearProgress, 1, "the chip never became visible")
    XCTAssertTrue(
      field.entranceAnimatorsForTesting.allSatisfy(\.isFinished),
      "an unfinished animator is a timer or display link still scheduled on the main run loop"
    )
  }
}

