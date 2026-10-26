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
    guard
      let regionImage = scaled(crop, longEdge: regionLongEdge, outlining: nil),
      let screenImage = scaled(image, longEdge: screenLongEdge, outlining: pixels),
      let regionData = png(regionImage),
      let screenData = png(screenImage)
    else { throw Failure.failed }

    return ScreenSelection(
      region: regionData,
      screen: screenData,
      frame: frame,
      context: frozen.context(at: CGPoint(x: region.midX, y: region.midY)),
      recognizedText: recognizedText(in: crop)
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

  // MARK: - The whole screen, for Ask Boltty

  /// Radius of the ring Ask Boltty draws where the pointer is, in the sent picture's pixels.
  static let pointerRingRadius: CGFloat = 18

  /// The frozen screen as Ask Boltty sends it: the long edge at `screenLongEdge` (the
  /// size phase 0 measured pointing on), a red ring where the pointer was —
  /// "what is this?" points at something — the line the pointer traced while
  /// the chord was held, in the same red, and the window under the pointer.
  /// `pointer` and `trail` are in AppKit's global coordinates.
  static func wholeScreen(
    _ frozen: FrozenScreen, pointer: CGPoint?, trail: [CGPoint] = [], primaryScreenHeight: CGFloat
  ) -> (png: Data, size: CGSize, context: String?)? {
    let image = frozen.image
    let imageSize = CGSize(width: image.width, height: image.height)
    func cgPoint(_ point: CGPoint) -> CGPoint {
      flipped(CGRect(origin: point, size: .zero), primaryScreenHeight: primaryScreenHeight).origin
    }
    /// Unclipped: a trail may leave the screen and come back.
    func pixel(of point: CGPoint) -> CGPoint {
      let frame = frozen.displayFrame
      guard frame.width > 0, frame.height > 0 else { return .zero }
      return CGPoint(x: (point.x - frame.minX) * imageSize.width / frame.width,
                     y: (point.y - frame.minY) * imageSize.height / frame.height)
    }
    let flippedPointer = pointer.map(cgPoint)
    let ring = flippedPointer.flatMap { point -> CGPoint? in
      frozen.displayFrame.contains(point) ? pixel(of: point) : nil
    }
    let line = trail.map { pixel(of: cgPoint($0)) }
    guard let scaled = scaled(image, longEdge: screenLongEdge, outlining: nil, ringAt: ring,
                              trail: line),
          let data = png(scaled)
    else { return nil }
    let context = flippedPointer.flatMap { frozen.context(at: $0) } ?? frozen.windows.first
      .flatMap { contextLine(app: $0.app, window: $0.title) }
    return (data, CGSize(width: scaled.width, height: scaled.height), context)
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
        (window[kCGWindowLayer as String] as? Int) == 0,
        (window[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) != pid,
        let bounds = window[kCGWindowBounds as String] as? NSDictionary,
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
      else { return nil }
      return FrozenScreen.Window(
        frame: rect,
        app: window[kCGWindowOwnerName as String] as? String,
        title: window[kCGWindowName as String] as? String)
    }
  }

  // MARK: - Pictures

  private static func scaled(
    _ image: CGImage, longEdge: CGFloat, outlining: CGRect?, ringAt pointer: CGPoint? = nil,
    trail: [CGPoint] = []
  ) -> CGImage? {
    let source = CGSize(width: image.width, height: image.height)
    let scale = min(1, longEdge / max(source.width, source.height, 1))
    let size = CGSize(
      width: max(1, (source.width * scale).rounded()),
      height: max(1, (source.height * scale).rounded())
    )
    guard outlining != nil || pointer != nil || trail.count > 1 || scale < 1 else { return image }
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
    context.draw(image, in: CGRect(origin: .zero, size: size))
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
    if let pointer {
      let center = CGPoint(x: pointer.x * scale, y: size.height - pointer.y * scale)
      let ring = CGRect(x: center.x - pointerRingRadius, y: center.y - pointerRingRadius,
                        width: pointerRingRadius * 2, height: pointerRingRadius * 2)
      context.setStrokeColor(HexColor.nsColor(outlineColor).cgColor)
      context.setLineWidth(outlineWidth)
      context.strokeEllipse(in: ring)
    }
    if trail.count > 1 {
      context.setStrokeColor(HexColor.nsColor(outlineColor).cgColor)
      context.setLineWidth(outlineWidth)
      context.setLineCap(.round)
      context.setLineJoin(.round)
      context.addPath(SmoothLine.path(
        through: trail.map { CGPoint(x: $0.x * scale, y: size.height - $0.y * scale) }))
      context.strokePath()
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

struct FrozenScreen: @unchecked Sendable {
  struct Window: Equatable, Sendable {
    var frame: CGRect
    var app: String?
    var title: String?
  }

  var image: CGImage
  var displayFrame: CGRect
  var windows: [Window]

  func displayFrameInAppKit(primaryScreenHeight: CGFloat) -> CGRect {
    ScreenRegionCapture.flipped(displayFrame, primaryScreenHeight: primaryScreenHeight)
  }

  func context(at point: CGPoint) -> String? {
    windows.first { $0.frame.contains(point) }
      .flatMap { ScreenRegionCapture.contextLine(app: $0.app, window: $0.title) }
  }
}

extension NSScreen {
  var displayID: CGDirectDisplayID? {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }
}
