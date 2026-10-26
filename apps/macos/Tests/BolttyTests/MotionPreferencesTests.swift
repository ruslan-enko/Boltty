import AppKit
import XCTest
@testable import Boltty

@MainActor
final class MotionPreferencesTests: XCTestCase {
  func testTheVocabularyIsOrderedAndShort() {
    XCTAssertLessThan(Motion.quick, Motion.standard)
    XCTAssertLessThanOrEqual(Motion.standard, 0.2)
  }

  func testThePressSpringSettlesWithoutOvershoot() {
    XCTAssertEqual(Motion.pressSpring.bounce, 0)
    let spring = CASpringAnimation(
      perceptualDuration: Motion.pressSpring.duration, bounce: Motion.pressSpring.bounce
    )
    let ratio = spring.damping / (2 * (spring.stiffness * spring.mass).squareRoot())
    XCTAssertGreaterThanOrEqual(ratio, 0.99, "critically damped")
    XCTAssertLessThan(spring.settlingDuration, 0.6)
  }

  func testRefreshingReduceMotionReturnsTheSystemAnswerAndCachesIt() {
    let system = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    XCTAssertEqual(MotionPreferences.refreshReduceMotion(), system)
    XCTAssertEqual(MotionPreferences.reduceMotion, system, "the cache agrees after a refresh")
  }

  func testAMascotOnScreenCorrectsItselfWhenReduceMotionChanges() {
    let mascot = MascotNSView(conversationID: UUID())
    mascot.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
    hostOffscreen(mascot)

    let system = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    mascot.reduceMotion = !system

    NSWorkspace.shared.notificationCenter.post(
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil
    )

    XCTAssertEqual(
      mascot.reduceMotion, system,
      "the face reads the setting itself instead of waiting to be told"
    )
  }

  private func hostOffscreen(_ view: NSView) {
    let window = NSWindow(
      contentRect: view.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.setFrame(
      NSRect(x: -20_000, y: -20_000, width: view.frame.width, height: view.frame.height),
      display: false
    )
    window.orderFrontRegardless()
    addTeardownBlock { MainActor.assumeIsolated { window.close() } }
  }
}

@MainActor
final class PaletteInkTests: XCTestCase {
  func testTheFillsAreTheSystemsDarkFills() {
    let pairs: [(NSColor, NSColor)] = [
      (PaletteInk.fill, .systemFill),
      (PaletteInk.secondaryFill, .secondarySystemFill),
      (PaletteInk.tertiaryFill, .tertiarySystemFill),
    ]
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
      for (ours, system) in pairs {
        let resolved = system.usingColorSpace(.sRGB)!
        XCTAssertEqual(ours.alphaComponent, resolved.alphaComponent, accuracy: 0.005)
        XCTAssertEqual(resolved.whiteComponentOrRed, 1, accuracy: 0.01)
      }
    }
  }

  func testTextIsTheLiveLabelColours() {
    XCTAssertEqual(PaletteInk.primary, .labelColor)
    XCTAssertEqual(PaletteInk.secondary, .secondaryLabelColor)
    XCTAssertEqual(PaletteInk.tertiary, .tertiaryLabelColor)
  }
}

private extension NSColor {
  var whiteComponentOrRed: CGFloat { redComponent }
}

@MainActor
final class PressFeedbackTests: XCTestCase {
  private func centre(of layer: CALayer) -> CGPoint {
    let t = layer.transform
    let mid = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
    return CGPoint(x: t.m11 * mid.x + t.m41, y: t.m22 * mid.y + t.m42)
  }

  func testACentredScaleKeepsTheMiddleWhereItWas() {
    let size = CGSize(width: 490, height: 54)
    let t = Motion.centredScale(0.9, size: size)
    XCTAssertEqual(t.m11 * size.width / 2 + t.m41, size.width / 2, accuracy: 0.001)
    XCTAssertEqual(t.m22 * size.height / 2 + t.m42, size.height / 2, accuracy: 0.001)
    XCTAssertEqual(t.m11, 0.9, accuracy: 0.0001)
  }

  func testAPressedGlyphButtonShrinksAboutItsCentre() throws {
    let button = PaletteIconButton(frame: NSRect(x: 0, y: 0, width: 44, height: 44))
    button.setPressedForTesting(true)
    let layer = try XCTUnwrap(button.layer)
    XCTAssertEqual(layer.transform.m11, AgentPaletteMetrics.controlPressedScale, accuracy: 0.0001)
    XCTAssertEqual(centre(of: layer).x, 22, accuracy: 0.001)
    XCTAssertEqual(centre(of: layer).y, 22, accuracy: 0.001)

    button.setPressedForTesting(false)
    XCTAssertTrue(CATransform3DIsIdentity(layer.transform))
  }

  func testAPressedGlassPillShrinksAsOnePiece() throws {
    let pill = GlassPillButton.titled("Retry")
    pill.frame = NSRect(x: 0, y: 0, width: 80, height: AgentPaletteMetrics.directoryChipHeight)
    pill.layoutSubtreeIfNeeded()
    XCTAssertTrue(pill.usesSystemGlassForTesting)
    XCTAssertTrue(pill.isCapsuleForTesting)
    pill.button.setPressedForTesting(true)

    XCTAssertTrue(CATransform3DIsIdentity(try XCTUnwrap(pill.button.layer).transform),
                  "no press of ours on top of the bezel's")
    XCTAssertTrue(pill.layer.map { CATransform3DIsIdentity($0.transform) } ?? true,
                  "nor on the pill around it")
  }

  func testADisabledGlassPillLooksDisabled() throws {
    let pill = GlassPillButton.titled("Retry")
    pill.button.isEnabled = false
    let colour = pill.button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil)
    XCTAssertEqual(colour as? NSColor, PaletteInk.tertiary)
  }

  func testAnOptionRowAnswersThePointer() {
    let row = BolttyAIOptionRow(
      option: .init(label: "Keep it", detail: nil), multiple: false
    )
    row.frame = NSRect(x: 0, y: 0, width: 400, height: 40)
    let resting = row.fillAlphaForTesting
    row.isHoveredForTesting = true
    let hovered = row.fillAlphaForTesting
    row.isFocused = true
    let lit = row.fillAlphaForTesting

    XCTAssertGreaterThan(hovered, resting)
    XCTAssertLessThan(hovered, lit)
  }

  func testAControlInAFadedSurfaceIgnoresThePointer() throws {
    let surface = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    let button = PaletteIconButton()
    button.frame = NSRect(x: 10, y: 10, width: 30, height: 30)
    surface.addSubview(button)
    surface.alphaValue = 0
    let event = try XCTUnwrap(NSEvent.enterExitEvent(
      with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))

    button.mouseEntered(with: event)
    XCTAssertFalse(button.isHoveredForTesting)

    surface.alphaValue = 1
    button.mouseEntered(with: event)
    XCTAssertTrue(button.isHoveredForTesting)
  }

  func testPressingAnOptionRowLightsItWithoutShrinkingItsWords() {
    let row = BolttyAIOptionRow(
      option: .init(label: "Keep it", detail: "and the sentence under it"), multiple: false
    )
    row.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
    let resting = row.fillAlphaForTesting
    row.isPressedForTesting = true

    XCTAssertGreaterThan(row.fillAlphaForTesting, resting)
    XCTAssertEqual(row.textScaleForTesting, 1)
    XCTAssertTrue(row.markUsesSystemControlForTesting)
  }

  func testAPressOnAnOptionsWordsReachesTheRow() {
    let row = BolttyAIOptionRow(
      option: .init(label: "Файл з правами 600", detail: "Окремий файл поза репозиторієм"),
      multiple: false
    )
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
    host.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      row.topAnchor.constraint(equalTo: host.topAnchor),
    ])
    host.layoutSubtreeIfNeeded()
    let words = NSPoint(x: row.frame.minX + 80, y: row.frame.midY)
    let mark = NSPoint(x: row.frame.minX + 24, y: row.frame.midY)

    XCTAssertTrue(host.hitTest(words) === row, "the words are the row's, not a field's")
    XCTAssertTrue(host.hitTest(mark) === row)
    XCTAssertFalse(row.wordsAreSelectableForTesting)
  }
}
