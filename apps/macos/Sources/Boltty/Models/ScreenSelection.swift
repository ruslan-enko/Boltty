import CoreGraphics
import Foundation

/// What of Finder a region lies over: a window, told by its name and a point in
/// it (window server coordinates), or the desktop.
enum FinderSpot: Codable, Equatable, Sendable {
  case desktop
  case window(middle: CGPoint, title: String?)
}

struct ScreenSelection: Sendable, Equatable, Codable {
  var region: Data
  var screen: Data
  var frame: CGRect
  var context: String?
  var recognizedText: String?
  /// Set when what is under the region's middle is Finder's.
  var finderSpot: FinderSpot? = nil
}
