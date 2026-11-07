import CoreGraphics
import Foundation

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
  var finderSpot: FinderSpot? = nil
}
