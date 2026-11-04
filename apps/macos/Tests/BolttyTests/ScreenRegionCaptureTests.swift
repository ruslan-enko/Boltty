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

  // MARK: - What of the screen goes

  private func frozen(_ windows: [FrozenScreen.Window]) throws -> FrozenScreen {
    let context = try XCTUnwrap(CGContext(
      data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return FrozenScreen(
      image: try XCTUnwrap(context.makeImage()),
      displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      windows: windows)
  }

  func testOnlyTheWindowUnderTheRegionIsShownAndTheOneOverItStaysHidden() throws {
    let bank = CGRect(x: 600, y: 100, width: 300, height: 300)
    let notes = CGRect(x: 100, y: 100, width: 600, height: 500)
    let screen = try frozen([
      FrozenScreen.Window(frame: bank, app: "Bank", title: nil, pid: 1),
      FrozenScreen.Window(frame: notes, app: "Notes", title: nil, pid: 2),
    ])
    let region = CGRect(x: 200, y: 200, width: 100, height: 100)

    let layers = screen.layers(showing: region)

    XCTAssertEqual(layers.first, ScreenLayer(frame: notes, isShown: true), "the back window first")
    XCTAssertEqual(layers.dropFirst().first, ScreenLayer(frame: bank, isShown: false),
                   "lying over the shown window, it is painted out over it")
    XCTAssertEqual(layers.last, ScreenLayer(frame: region, isShown: true), "the region always, and last")
  }

  func testTheMenuBarAndWhatTheWindowHasOpenGoWithIt() throws {
    let bar = CGRect(x: 0, y: 0, width: 1000, height: 37)
    let menu = CGRect(x: 120, y: 37, width: 200, height: 300)
    let other = CGRect(x: 800, y: 500, width: 100, height: 100)
    let notes = CGRect(x: 100, y: 100, width: 600, height: 500)
    let screen = try frozen([
      FrozenScreen.Window(frame: bar, app: "Window Server", title: "Menubar", pid: 9, layer: 24),
      FrozenScreen.Window(frame: menu, app: "Notes", title: nil, pid: 2, layer: 101),
      FrozenScreen.Window(frame: other, app: "Mail", title: nil, pid: 3, layer: 101),
      FrozenScreen.Window(frame: notes, app: "Notes", title: nil, pid: 2),
    ])

    let layers = screen.layers(showing: CGRect(x: 400, y: 400, width: 50, height: 50))

    XCTAssertTrue(layers.contains(ScreenLayer(frame: bar, isShown: true)))
    XCTAssertTrue(layers.contains(ScreenLayer(frame: menu, isShown: true)))
    XCTAssertTrue(layers.contains(ScreenLayer(frame: other, isShown: false)), "another app's is painted out")
  }

  func testARegionOnTheDesktopShowsOnlyItself() throws {
    let notes = CGRect(x: 100, y: 100, width: 300, height: 300)
    let screen = try frozen([FrozenScreen.Window(frame: notes, app: "Notes", title: nil, pid: 2)])
    let region = CGRect(x: 700, y: 500, width: 100, height: 100)

    let layers = screen.layers(showing: region)

    XCTAssertEqual(layers.first, ScreenLayer(frame: notes, isShown: false))
    XCTAssertEqual(layers.last, ScreenLayer(frame: region, isShown: true))
    XCTAssertEqual(screen.finderSpot(at: CGPoint(x: 750, y: 550)), .desktop)
  }

  func testAWindowAsBigAsTheScreenAboveTheOthersIsNotTheMenuBarOrAWindow() throws {
    let bar = CGRect(x: 0, y: 0, width: 1000, height: 37)
    let clear = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let screen = try frozen([
      FrozenScreen.Window(frame: clear, app: "Screenshot", title: nil, pid: 8, layer: 24),
      FrozenScreen.Window(frame: bar, app: "Window Server", title: "Menubar", pid: 9, layer: 24),
    ])

    let layers = screen.layers(showing: CGRect(x: 400, y: 400, width: 50, height: 50))

    XCTAssertFalse(layers.contains { $0.frame == clear })
    XCTAssertTrue(layers.contains(ScreenLayer(frame: bar, isShown: true)))
    XCTAssertNil(screen.finderSpot(at: CGPoint(x: 400, y: 10)), "the menu bar is not the desktop")
  }

  private let finderLines = [
    "/Users/me/Desktop/",
    "w\t0\t0\t500\t500\tfalse\t\tRecents",
    "w\t100\t100\t900\t700\ttrue\t/Users/me/Hidden/\tDownloads",
    "w\t100\t100\t900\t700\tfalse\t/Users/me/Downloads/\tDownloads",
    "s\t/Users/me/Downloads/a.pdf",
    "s\t/Users/me/Documents/b.pdf",
  ]

  func testAPlaceIsTheWindowOfThatNameAtThatPointAndOnlyWhatIsSelectedInIt() {
    XCTAssertEqual(
      FinderSelectionService.parsePlace(
        finderLines, for: .window(middle: CGPoint(x: 300, y: 300), title: "Downloads")),
      FinderPlace(folder: "/Users/me/Downloads/", selected: ["a.pdf"]),
      "not Recents in front of it, nor one minimized")
    XCTAssertEqual(
      FinderSelectionService.parsePlace(finderLines, for: .desktop)?.folder, "/Users/me/Desktop/")
    XCTAssertNil(FinderSelectionService.parsePlace([], for: .desktop))
  }

  func testAWindowThatShowsNoFolderIsNoPlaceNotTheOneBehindIt() {
    XCTAssertNil(FinderSelectionService.parsePlace(
      finderLines, for: .window(middle: CGPoint(x: 300, y: 300), title: "Recents")))
    XCTAssertNil(FinderSelectionService.parsePlace(
      finderLines, for: .window(middle: CGPoint(x: 950, y: 750), title: nil)),
      "nor is a place nobody lists")
  }
}
