import CoreGraphics
import Foundation

struct ScreenSelection: Sendable, Equatable, Codable {
  var region: Data
  var screen: Data
  var frame: CGRect
  var context: String?
  var recognizedText: String?
}
