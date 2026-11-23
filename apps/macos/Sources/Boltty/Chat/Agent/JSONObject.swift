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

  /// A tool's result as words: pictures come as base64 among the text blocks.
  func toolOutput(_ key: String) -> String? {
    let blocks = (raw[key] as? [[String: Any]]) ?? (raw[key] as? [String: Any])?["content"] as? [[String: Any]]
    guard let blocks, !blocks.isEmpty else { return rendered(key) }
    return blocks.map { block in
      if let text = block["text"] as? String { return text }
      return "[\(block["type"] as? String ?? "content")]"
    }.joined(separator: "\n")
  }

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
