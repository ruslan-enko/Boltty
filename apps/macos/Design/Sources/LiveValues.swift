import AppKit

enum LiveSetting: Equatable, Sendable {
  case number(Double)
  case colour(OKLCH, alpha: Double)
}

final class LiveValues: @unchecked Sendable {
  static let shared = LiveValues()

  private let lock = NSLock()
  private var settings: [String: LiveSetting] = [:]
  private var seen: Set<String> = []

  static func key(file: String, name: String) -> String {
    "\(file[(file.lastIndex(of: "/").map(file.index(after:)) ?? file.startIndex)...]).\(name)"
  }

  func value<Value>(file: String, name: String) -> Value? {
    let key = Self.key(file: file, name: name)
    let setting = lock.withLock {
      seen.insert(key)
      return settings[key]
    }
    switch setting {
    case .number(let number):
      return Value.self == CGFloat.self ? CGFloat(number) as? Value : number as? Value
    case .colour(let colour, let alpha):
      return colour.color(alpha: alpha) as? Value
    case nil:
      return nil
    }
  }

  func set(_ setting: LiveSetting?, for key: String) { lock.withLock { settings[key] = setting } }

  func takeSeen() -> Set<String> {
    lock.withLock {
      defer { seen = [] }
      return seen
    }
  }
}
