import AppKit
import SwiftUI

func roundedAppFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
  RoundedFontCache.shared.font(size: size, weight: weight)
}

private final class RoundedFontCache: @unchecked Sendable {
  static let shared = RoundedFontCache()

  private struct Key: Hashable {
    let size: CGFloat
    let weight: CGFloat
  }

  private let lock = NSLock()
  private var fonts: [Key: NSFont] = [:]

  func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let key = Key(size: size, weight: weight.rawValue)
    lock.lock()
    if let cached = fonts[key] {
      lock.unlock()
      return cached
    }
    lock.unlock()

    let resolved = Self.resolve(size: size, weight: weight)

    lock.lock()
    fonts[key] = resolved
    lock.unlock()
    return resolved
  }

  private static func resolve(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard
      let descriptor = base.fontDescriptor.withDesign(.rounded),
      let rounded = NSFont(descriptor: descriptor, size: size)
    else {
      return base
    }
    return rounded
  }
}

enum BolttyInterfaceTypography {
  static let body = Font.system(.body, design: .rounded)
  static let callout = Font.system(.callout, design: .rounded)
  static let headline = Font.system(.headline, design: .rounded)

  static func fixed(
    size: CGFloat,
    weight: Font.Weight = .regular
  ) -> Font {
    .system(size: size, weight: weight, design: .rounded)
  }
}
