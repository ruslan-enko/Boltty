import Foundation

enum RecentFolders {
  static let limit = 5

  static func list(
    _ places: [(path: String, touched: Date)],
    home: String,
    limit: Int = limit,
    exists: (String) -> Bool
  ) -> [String] {
    var newest: [String: Date] = [:]
    for place in places {
      let path = standardized(place.path)
      guard !path.isEmpty, path != standardized(home) else { continue }
      if let seen = newest[path], seen >= place.touched { continue }
      newest[path] = place.touched
    }
    var out: [String] = []
    for (path, _) in newest.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
      guard out.count < limit else { break }
      if exists(path) { out.append(path) }
    }
    return out
  }

  static func offered(recent: [String], current: String, home: String, limit: Int = limit) -> [String] {
    let current = standardized(current)
    guard !current.isEmpty, current != standardized(home), !recent.contains(current) else {
      return Array(recent.prefix(limit))
    }
    return Array(([current] + recent).prefix(limit))
  }

  static func titles(for paths: [String]) -> [String] {
    let names = paths.map(Self.name(of:))
    var count: [String: Int] = [:]
    for each in names { count[each, default: 0] += 1 }
    return zip(paths, names).map { path, own in
      guard count[own, default: 0] > 1 else { return own }
      let parent = Self.name(of: (path as NSString).deletingLastPathComponent)
      return parent.isEmpty ? own : "\(own) — \(parent)"
    }
  }

  static func name(of path: String) -> String {
    let name = (path as NSString).lastPathComponent
    return name.isEmpty ? path : name
  }

  static func standardized(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    return (trimmed as NSString).standardizingPath
  }
}
