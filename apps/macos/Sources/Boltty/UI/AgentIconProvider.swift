import AppKit

@MainActor
enum AgentIconProvider {
  private static var cache: [AgentId: NSImage] = [:]

  static func image(for agent: AgentId, bundle: Bundle = .main) -> NSImage {
    if let cached = cache[agent] { return cached }
    let image = makeImage(for: agent, bundle: bundle)
    cache[agent] = image
    return image
  }


  private static func makeImage(for agent: AgentId, bundle: Bundle) -> NSImage {
    if let url = bundle.url(
      forResource: agent.iconAssetName,
      withExtension: "svg",
      subdirectory: "AgentIcons"
    ), let image = NSImage(contentsOf: url) {
      image.isTemplate = true
      image.accessibilityDescription = agent.displayName
      return image
    }
    return BolttySFSymbolImage.make(
      name: agent.fallbackSymbolName,
      accessibilityDescription: agent.displayName
    )
  }
}

@MainActor
enum BolttySFSymbolImage {
  static func make(
    name: String,
    fallbackName: String? = nil,
    accessibilityDescription: String? = nil,
    pointSize: CGFloat = 18,
    weight: NSFont.Weight = .medium,
    palette: [NSColor] = [.systemBlue, .systemPurple, .systemPink]
  ) -> NSImage {
    _ = palette
    let source = NSImage(
      systemSymbolName: name,
      accessibilityDescription: accessibilityDescription
    ) ?? NSImage(
      systemSymbolName: fallbackName ?? "questionmark.circle.fill",
      accessibilityDescription: accessibilityDescription
    ) ?? NSImage(size: NSSize(width: pointSize, height: pointSize))

    let size = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    let image = source.withSymbolConfiguration(size) ?? source
    image.isTemplate = true
    return image
  }
}

// MARK: - Trimming

@MainActor
extension AgentIconProvider {
  private static var trimmedCache: [AgentId: NSImage] = [:]

  static func trimmedImage(for agent: AgentId, bundle: Bundle = .main) -> NSImage {
    if let cached = trimmedCache[agent] { return cached }
    let trimmed = trim(image(for: agent, bundle: bundle))
    trimmedCache[agent] = trimmed
    return trimmed
  }

  static func inkBounds(of image: NSImage, samples: Int = 128) -> CGRect? {
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: samples,
        pixelsHigh: samples,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ),
      let context = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: CGRect(x: 0, y: 0, width: samples, height: samples))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.bitmapData else { return nil }
    let stride = rep.bytesPerRow
    let perPixel = rep.samplesPerPixel
    var minX = samples, minY = samples, maxX = -1, maxY = -1
    for y in 0..<samples {
      for x in 0..<samples {
        guard data[y * stride + x * perPixel + 3] > 8 else { continue }
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
      }
    }
    guard maxX >= minX, maxY >= minY else { return nil }

    let span = CGFloat(samples)
    return CGRect(
      x: CGFloat(minX) / span,
      y: CGFloat(samples - 1 - maxY) / span,
      width: CGFloat(maxX - minX + 1) / span,
      height: CGFloat(maxY - minY + 1) / span
    )
  }

  private static func trim(_ image: NSImage) -> NSImage {
    guard
      let unit = inkBounds(of: image),
      unit.width < 0.99 || unit.height < 0.99
    else { return image }

    let source = CGRect(
      x: unit.minX * image.size.width,
      y: unit.minY * image.size.height,
      width: unit.width * image.size.width,
      height: unit.height * image.size.height
    )
    let trimmed = NSImage(size: source.size)
    trimmed.lockFocus()
    image.draw(
      in: CGRect(origin: .zero, size: source.size),
      from: source,
      operation: .sourceOver,
      fraction: 1
    )
    trimmed.unlockFocus()
    trimmed.isTemplate = true
    trimmed.accessibilityDescription = image.accessibilityDescription
    return trimmed
  }
}
