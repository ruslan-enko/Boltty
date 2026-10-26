import Foundation

struct JSONObject: @unchecked Sendable {
  let raw: [String: Any]

  init(_ raw: [String: Any]) { self.raw = raw }

  init?(line: String) {
    guard let data = line.data(using: .utf8) else { return nil }
    self.init(line: data)
  }

  init?(line: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    else { return nil }
    self.raw = object
  }

  subscript(key: String) -> Any? { raw[key] }

  func string(_ key: String) -> String? { raw[key] as? String }
  func bool(_ key: String) -> Bool? { raw[key] as? Bool }
  func int(_ key: String) -> Int? { (raw[key] as? NSNumber)?.intValue }
  func double(_ key: String) -> Double? { (raw[key] as? NSNumber)?.doubleValue }

  func object(_ key: String) -> JSONObject? {
    (raw[key] as? [String: Any]).map(JSONObject.init)
  }

  func array(_ key: String) -> [JSONObject] {
    (raw[key] as? [[String: Any]])?.map(JSONObject.init) ?? []
  }

  func strings(_ key: String) -> [String] { raw[key] as? [String] ?? [] }

  func rendered(_ key: String) -> String? {
    guard let value = raw[key] else { return nil }
    if let text = value as? String { return text }
    if let number = value as? NSNumber { return number.stringValue }
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else { return String(describing: value) }
    return text
  }

  static func encode(_ value: [String: Any]) -> String? {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value),
          let text = String(data: data, encoding: .utf8)
    else { return nil }
    return text
  }
}
