import AppKit

enum HexColor {
  static func nsColor(_ hex: String) -> NSColor {
    var hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") { hex = String(hex.dropFirst()) }
    guard hex.count == 6, let value = UInt64(hex, radix: 16) else {
      return NSColor.windowBackgroundColor
    }
    return NSColor(
      srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: 1
    )
  }
}
