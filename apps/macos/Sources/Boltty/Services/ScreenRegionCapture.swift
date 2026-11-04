import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

enum ScreenRegionCapture {
  enum Failure: Error, Equatable {
    case notAllowed
    case noDisplay
    case failed
  }

  static let screenLongEdge: CGFloat = 1568
  static let regionLongEdge: CGFloat = 2048
  static let outlineWidth: CGFloat = 4
  static let outlineColor = "#FF3B30"
  /// What stands where the rest of the screen was.
  static let hiddenColor = "#1C1C1E"
  static let recognizedTextByteLimit = PromptExpansion.inlineTextByteLimit

  @MainActor
  static func ensureAccess() -> Bool {
    CGPreflightScreenCaptureAccess() || LiveAccess.requestScreenRecording()
  }

  static func freeze(displayID: CGDirectDisplayID) async throws -> FrozenScreen {
    let (image, displayFrame) = try await captureDisplay(displayID)
    return FrozenScreen(image: image, displayFrame: displayFrame, windows: windowList())
  }

  static func selection(
    _ frame: CGRect,
    in frozen: FrozenScreen,
    primaryScreenHeight: CGFloat
  ) throws -> ScreenSelection {
    let region = flipped(frame, primaryScreenHeight: primaryScreenHeight)
    let image = frozen.image
    let pixels = pixelRect(
      of: region, in: frozen.displayFrame, imageSize: CGSize(width: image.width, height: image.height))
    guard !pixels.isEmpty, let crop = image.cropping(to: pixels) else { throw Failure.failed }
    // Asked about all of it, all of it goes. Otherwise only what the question
    // is about: an area of one window is no reason to send the others.
    let isWholeScreen = region.insetBy(dx: -1, dy: -1).contains(frozen.displayFrame)
    let layers = isWholeScreen ? nil : frozen.layers(showing: region).map { layer in
      ScreenLayer(
        frame: pixelRect(
          of: layer.frame, in: frozen.displayFrame,
          imageSize: CGSize(width: image.width, height: image.height)),
        isShown: layer.isShown)
    }
    guard
      let regionImage = scaled(crop, longEdge: regionLongEdge, outlining: nil),
      let screenImage = scaled(image, longEdge: screenLongEdge, outlining: pixels, showing: layers),
      let regionData = png(regionImage),
      let screenData = png(screenImage)
    else { throw Failure.failed }

    return ScreenSelection(
      region: regionData,
      screen: screenData,
      frame: frame,
      context: frozen.context(at: CGPoint(x: region.midX, y: region.midY)),
      recognizedText: recognizedText(in: crop),
      finderSpot: frozen.finderSpot(at: CGPoint(x: region.midX, y: region.midY))
    )
  }

  // MARK: - Geometry

  static func flipped(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
    CGRect(
      x: rect.minX,
      y: primaryScreenHeight - rect.maxY,
      width: rect.width,
      height: rect.height
    )
  }

  static func pixelRect(of region: CGRect, in displayFrame: CGRect, imageSize: CGSize) -> CGRect {
    guard displayFrame.width > 0, displayFrame.height > 0 else { return .zero }
    let scaleX = imageSize.width / displayFrame.width
    let scaleY = imageSize.height / displayFrame.height
    let local = CGRect(
      x: (region.minX - displayFrame.minX) * scaleX,
      y: (region.minY - displayFrame.minY) * scaleY,
      width: region.width * scaleX,
      height: region.height * scaleY
    ).integral
    return local.intersection(CGRect(origin: .zero, size: imageSize))
  }

  static func contextLine(app: String?, window: String?) -> String? {
    let app = app?.trimmingCharacters(in: .whitespacesAndNewlines)
    let window = window?.trimmingCharacters(in: .whitespacesAndNewlines)
    switch (app.flatMap { $0.isEmpty ? nil : $0 }, window.flatMap { $0.isEmpty ? nil : $0 }) {
    case let (app?, window?) where window != app: return "\(app) — “\(window)”"
    case let (app?, _): return app
    case let (nil, window?): return "“\(window)”"
    case (nil, nil): return nil
    }
  }

  // MARK: - Capture

  private static func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> (CGImage, CGRect) {
    let content: SCShareableContent
    do {
      content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    } catch {
      throw CGPreflightScreenCaptureAccess() ? Failure.failed : Failure.notAllowed
    }
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
      throw Failure.noDisplay
    }
    let pid = ProcessInfo.processInfo.processIdentifier
    let ours = content.applications.filter { $0.processID == pid }
    let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
    let configuration = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    configuration.width = Int((display.frame.width * scale).rounded())
    configuration.height = Int((display.frame.height * scale).rounded())
    configuration.showsCursor = false
    configuration.captureResolution = .best
    do {
      let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
      return (image, display.frame)
    } catch {
      throw CGPreflightScreenCaptureAccess() ? Failure.failed : Failure.notAllowed
    }
  }

  private static func windowList() -> [FrozenScreen.Window] {
    let pid = ProcessInfo.processInfo.processIdentifier
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
      ) as? [[String: Any]]
    else { return [] }
    return windows.compactMap { window in
      guard
        let owner = (window[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }), owner != pid,
        (window[kCGWindowAlpha as String] as? Double).map({ $0 > 0 }) != false,
        let bounds = window[kCGWindowBounds as String] as? NSDictionary,
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
      else { return nil }
      return FrozenScreen.Window(
        frame: rect,
        app: window[kCGWindowOwnerName as String] as? String,
        title: window[kCGWindowName as String] as? String,
        pid: owner,
        layer: window[kCGWindowLayer as String] as? Int ?? 0)
    }
  }

  // MARK: - Pictures

  private static func scaled(
    _ image: CGImage, longEdge: CGFloat, outlining: CGRect?, showing layers: [ScreenLayer]? = nil
  ) -> CGImage? {
    let source = CGSize(width: image.width, height: image.height)
    let scale = min(1, longEdge / max(source.width, source.height, 1))
    let size = CGSize(
      width: max(1, (source.width * scale).rounded()),
      height: max(1, (source.height * scale).rounded())
    )
    guard outlining != nil || scale < 1 else { return image }
    guard
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.interpolationQuality = .high
    let whole = CGRect(origin: .zero, size: size)
    if let layers {
      // Scaled once: each shown piece is then only a copy.
      let scaledImage = scaled(image, longEdge: longEdge, outlining: nil) ?? image
      context.setFillColor(HexColor.nsColor(hiddenColor).cgColor)
      context.fill(whole)
      for layer in layers {
        let box = CGRect(
          x: layer.frame.minX * scale,
          y: size.height - layer.frame.maxY * scale,
          width: layer.frame.width * scale,
          height: layer.frame.height * scale)
        if layer.isShown {
          context.saveGState()
          context.clip(to: box)
          context.draw(scaledImage, in: whole)
          context.restoreGState()
        } else {
          context.fill(box)
        }
      }
    } else {
      context.draw(image, in: whole)
    }
    if let outlining {
      let box = CGRect(
        x: outlining.minX * scale,
        y: size.height - outlining.maxY * scale,
        width: outlining.width * scale,
        height: outlining.height * scale
      ).insetBy(dx: -outlineWidth / 2, dy: -outlineWidth / 2)
      context.setStrokeColor(HexColor.nsColor(outlineColor).cgColor)
      context.setLineWidth(outlineWidth)
      context.stroke(box)
    }
    return context.makeImage()
  }

  private static func png(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }

  private static func recognizedText(in image: CGImage) -> String? {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = true
    guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
    let text = (request.results ?? [])
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return truncated(text, toBytes: recognizedTextByteLimit)
  }

  static func truncated(_ text: String, toBytes limit: Int) -> String {
    guard text.utf8.count > limit else { return text }
    var cut = ""
    var bytes = 0
    let budget = limit - "…".utf8.count
    for character in text {
      let size = String(character).utf8.count
      guard bytes + size <= budget else { break }
      cut.append(character)
      bytes += size
    }
    return cut + "…"
  }
}

/// One piece of the screen as it goes to an agent: drawn in order, shown as it
/// was or hidden.
struct ScreenLayer: Equatable, Sendable {
  var frame: CGRect
  var isShown: Bool
}

struct FrozenScreen: @unchecked Sendable {
  struct Window: Equatable, Sendable {
    var frame: CGRect
    var app: String?
    var title: String?
    var pid: pid_t = 0
    /// 0 is an ordinary window; above it the menu bar, menus and floating panels.
    var layer = 0
  }

  /// The window server's level for the menu bar. Not all that stands there is
  /// the bar: the system's Screenshot keeps a window as big as the screen at it.
  static let menuBarLayer = 24
  static let menuBarTallest: CGFloat = 100
  /// Points tried across a region to find the windows it shows.
  static let regionSamples = 9

  var image: CGImage
  var displayFrame: CGRect
  var windows: [Window]

  func displayFrameInAppKit(primaryScreenHeight: CGFloat) -> CGRect {
    ScreenRegionCapture.flipped(displayFrame, primaryScreenHeight: primaryScreenHeight)
  }

  func context(at point: CGPoint) -> String? {
    window(at: point).flatMap { ScreenRegionCapture.contextLine(app: $0.app, window: $0.title) }
  }

  /// The ordinary window in front at `point`. Above them stand things that are
  /// not what anyone means, some as wide as the screen and clear.
  private func window(at point: CGPoint) -> Window? {
    windows.first { $0.layer == 0 && $0.frame.contains(point) }
  }

  /// Whether `point` is on a Finder window or on the desktop, which is Finder's.
  /// With no ordinary window there it is the desktop, unless it is the menu bar
  /// or some other small thing floating over it.
  func finderSpot(at point: CGPoint) -> FinderSpot? {
    if let window = window(at: point) {
      let isFinder = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier
        == FinderSelectionService.finderBundleID
      return isFinder ? .window(middle: point, title: window.title) : nil
    }
    return windows.contains { isFloating($0) && $0.frame.contains(point) } ? nil : .desktop
  }

  /// Above the ordinary windows, and not one as big as the screen: some are
  /// clear, and one would show or hide everything under it.
  private func isFloating(_ window: Window) -> Bool {
    let screen = displayFrame.width * displayFrame.height
    return window.layer > 0 && window.frame.width * window.frame.height < screen / 2
      && window.frame.intersects(displayFrame)
  }

  /// What of the screen goes with a question about `region`, in drawing order:
  /// the windows it shows, what those windows have open over them (a menu, a
  /// popover), the menu bar, where "where is Export?" is often answered, and
  /// the region itself. Everything else is painted out where it stands, so the
  /// picture keeps its coordinates for pointing and drawing, and a window
  /// lying over a shown one stays hidden, as does another app's banner.
  func layers(showing region: CGRect) -> [ScreenLayer] {
    let display = displayFrame
    let ordinary = windows.filter { $0.layer == 0 && $0.frame.intersects(display) }
    var shown = Set<Int>()
    let steps = Self.regionSamples - 1
    let area = region.insetBy(dx: min(1, region.width / 2), dy: min(1, region.height / 2))
    for row in 0...steps {
      for column in 0...steps {
        let point = CGPoint(
          x: area.minX + area.width * CGFloat(column) / CGFloat(steps),
          y: area.minY + area.height * CGFloat(row) / CGFloat(steps))
        if let front = ordinary.firstIndex(where: { $0.frame.contains(point) }) { shown.insert(front) }
      }
    }
    let owners = Set(shown.map { ordinary[$0].pid })
    // The list runs front to back; drawing runs back to front.
    var layers = ordinary.indices.reversed().map {
      ScreenLayer(frame: ordinary[$0].frame, isShown: shown.contains($0))
    }
    layers += windows
      .filter(isFloating)
      .reversed()
      .map { ScreenLayer(frame: $0.frame, isShown: owners.contains($0.pid)) }
    if let menuBar = windows.first(where: {
      $0.layer == Self.menuBarLayer && $0.frame.height < Self.menuBarTallest && $0.frame.intersects(display)
    }) {
      layers.append(ScreenLayer(frame: menuBar.frame, isShown: true))
    }
    layers.append(ScreenLayer(frame: region, isShown: true))
    return layers
  }
}

extension NSScreen {
  var displayID: CGDirectDisplayID? {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }
}
