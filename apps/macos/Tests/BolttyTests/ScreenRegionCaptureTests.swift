import XCTest
@testable import Boltty

final class ScreenRegionCaptureTests: XCTestCase {
  func testFlippingBetweenAppKitAndCoreGraphicsIsItsOwnInverse() {
    let appKit = CGRect(x: 100, y: 700, width: 300, height: 200)
    let flipped = ScreenRegionCapture.flipped(appKit, primaryScreenHeight: 1000)

    XCTAssertEqual(flipped, CGRect(x: 100, y: 100, width: 300, height: 200),
                   "a rectangle near the top in AppKit is near the top in Core Graphics")
    XCTAssertEqual(ScreenRegionCapture.flipped(flipped, primaryScreenHeight: 1000), appKit)
  }

  func testARegionLandsOnThePixelsOfItsDisplaysPicture() {
    let display = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    let region = CGRect(x: 1612, y: 50, width: 100.25, height: 40)

    let pixels = ScreenRegionCapture.pixelRect(
      of: region, in: display, imageSize: CGSize(width: 3840, height: 2160))

    XCTAssertEqual(pixels, CGRect(x: 200, y: 100, width: 201, height: 80))
  }

  func testARegionPastTheDisplaysEdgeIsCutToIt() {
    let display = CGRect(x: 0, y: 0, width: 100, height: 100)
    let pixels = ScreenRegionCapture.pixelRect(
      of: CGRect(x: 80, y: -10, width: 50, height: 30), in: display,
      imageSize: CGSize(width: 100, height: 100))

    XCTAssertEqual(pixels, CGRect(x: 80, y: 0, width: 20, height: 20))
  }

  func testTheContextSaysWhatIsKnownOnce() {
    XCTAssertEqual(ScreenRegionCapture.contextLine(app: "Figma", window: "Boltty"), "Figma — “Boltty”")
    XCTAssertEqual(ScreenRegionCapture.contextLine(app: "Finder", window: "Finder"), "Finder",
                   "a window named after its app is said once")
    XCTAssertEqual(ScreenRegionCapture.contextLine(app: "Safari", window: " "), "Safari")
    XCTAssertEqual(ScreenRegionCapture.contextLine(app: nil, window: "Notes"), "“Notes”")
    XCTAssertNil(ScreenRegionCapture.contextLine(app: nil, window: nil))
  }

  func testReadTextIsCutAtACharacterWithinItsBytes() {
    let cut = ScreenRegionCapture.truncated("Привіт, світ", toBytes: 10)

    XCTAssertLessThanOrEqual(cut.utf8.count, 10)
    XCTAssertEqual(cut, "При…")
    XCTAssertEqual(ScreenRegionCapture.truncated("short", toBytes: 10), "short")
  }

  func testASelectionIsCutFromTheFrozenScreen() throws {
    let context = try XCTUnwrap(CGContext(
      data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let display = CGRect(x: 0, y: 0, width: 100, height: 50)
    let frozen = FrozenScreen(
      image: try XCTUnwrap(context.makeImage()),
      displayFrame: display,
      windows: [
        FrozenScreen.Window(frame: CGRect(x: 0, y: 0, width: 40, height: 50), app: "Notes", title: "Todo"),
        FrozenScreen.Window(frame: display, app: "Finder", title: nil),
      ])

    let selection = try ScreenRegionCapture.selection(
      CGRect(x: 10, y: 10, width: 20, height: 10), in: frozen, primaryScreenHeight: 50)

    let region = try XCTUnwrap(NSBitmapImageRep(data: selection.region))
    XCTAssertEqual(region.pixelsWide, 40, "the picture's two pixels a point")
    XCTAssertEqual(region.pixelsHigh, 20)
    XCTAssertEqual(selection.context, "Notes — “Todo”", "the frontmost window under its centre")
    XCTAssertNil(selection.recognizedText, "a flat colour has no text to read")
    XCTAssertEqual(selection.frame, CGRect(x: 10, y: 10, width: 20, height: 10))
  }
}
