import XCTest
@testable import Boltty

@MainActor
final class PaletteCornerScrollIndicatorTests: XCTestCase {
  private let shell = CGRect(x: 20, y: 20, width: 300, height: 400)
  private let corner: CGFloat = 39

  func testTheTrackFollowsTheShellsRightEdgeAndBothCorners() {
    let view = PaletteCornerScrollIndicator(frame: CGRect(x: 0, y: 0, width: 340, height: 440))
    view.place(in: shell, corner: corner, reading: .init(position: 0, proportion: 0.3))
    let inset = AgentPaletteMetrics.scrollIndicatorInset
    let track = view.thumbPathBoundsForTesting
    XCTAssertEqual(track.maxX, shell.maxX - inset, accuracy: 0.5, "the wall, inset")
    XCTAssertEqual(track.maxY, shell.maxY - inset, accuracy: 0.5, "round the top corner to the top")
    XCTAssertEqual(track.minY, shell.minY + inset, accuracy: 0.5, "and round the foot's to the foot")
    XCTAssertEqual(track.minX, shell.maxX - corner, accuracy: 0.5, "a quarter circle at each end")
  }

  func testUnderTheTabsTheTrackStartsBelowThemAndOnlyTheFootBends() {
    let view = PaletteCornerScrollIndicator(frame: .zero)
    view.place(in: shell, corner: corner, reading: .init(position: 0, proportion: 0.1), topClearance: 120)
    let track = view.thumbPathBoundsForTesting
    XCTAssertEqual(track.maxY, shell.maxY - 120, accuracy: 0.5)
    XCTAssertEqual(track.minY, shell.minY + AgentPaletteMetrics.scrollIndicatorInset, accuracy: 0.5)
  }

  func testTheThumbIsHalfACornerLongAndStandsInItAtEitherEnd() {
    let view = PaletteCornerScrollIndicator(frame: .zero)
    let radius = corner - AgentPaletteMetrics.scrollIndicatorInset
    let arc = CGFloat.pi / 4 * radius
    let track = CGFloat.pi * radius + (shell.height - 2 * corner)
    for proportion in [0.05, 0.5, 0.95] as [CGFloat] {
      view.place(in: shell, corner: corner, reading: .init(position: 0.3, proportion: proportion))
      let span = view.thumbStrokeForTesting.end - view.thumbStrokeForTesting.start
      XCTAssertEqual(span, arc / track, accuracy: 0.001, "the same length whatever the document's")
    }
    let diagonal = CGFloat.pi / 4 * radius
    view.place(in: shell, corner: corner, reading: .init(position: 0, proportion: 0.2))
    let topCentre = (view.thumbStrokeForTesting.start + view.thumbStrokeForTesting.end) / 2 * track
    XCTAssertEqual(topCentre, diagonal, accuracy: 0.5, "stops centred on the top corner's diagonal")
    view.place(in: shell, corner: corner, reading: .init(position: 1, proportion: 0.2))
    let footCentre = (view.thumbStrokeForTesting.start + view.thumbStrokeForTesting.end) / 2 * track
    XCTAssertEqual(footCentre, track - diagonal, accuracy: 0.5, "and on the foot's")
  }

  func testAScrollThatFitsHasNothingToIndicate() {
    let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
    scroll.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
    XCTAssertNil(PaletteCornerScrollIndicator.reading(of: scroll))
    scroll.documentView?.setFrameSize(CGSize(width: 200, height: 1200))
    let reading = PaletteCornerScrollIndicator.reading(of: scroll)
    XCTAssertEqual(reading?.proportion ?? 0, 0.25, accuracy: 0.01)
  }

  func testRenderTheCornerIndicator() throws {
    guard let directory = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set TEST_RUNNER_BOLTTY_CONTACT_SHEET=<dir> to render it")
    }
    let positions: [CGFloat] = [0, 0.5, 1]
    let size = CGSize(width: 360 * 3, height: 460)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor(white: 0.1, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    for (index, position) in positions.enumerated() {
      let rect = shell.offsetBy(dx: CGFloat(index) * 360, dy: 0)
      NSColor(white: 0.2, alpha: 1).setFill()
      NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()
      let view = PaletteCornerScrollIndicator(frame: CGRect(origin: .zero, size: size))
      view.place(in: rect, corner: corner, reading: .init(position: position, proportion: 0.3))
      view.flash()
      view.layer?.removeAllAnimations()
      view.layer?.sublayers?.forEach { $0.removeAllAnimations() }
      view.layer?.render(in: NSGraphicsContext.current!.cgContext)
    }
    image.unlockFocus()
    let data = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
      .representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("corner-scroll-indicator.png"))
  }
}
