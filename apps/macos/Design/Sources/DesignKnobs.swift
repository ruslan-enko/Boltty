import AppKit

/// A `live(…)` value as its source line writes it.
struct DesignKnob: Sendable {
  let key: String
  let owner: String
  let name: String
  let file: URL
  let expression: String
  let setting: LiveSetting
  let isTime: Bool

  static func parse(_ expression: String) -> LiveSetting? {
    let text = expression.trimmingCharacters(in: .whitespaces)
    if let value = Double(text) { return .number(value) }
    if let match = text.wholeMatch(
      of: /NSColor\(oklch: ([0-9.]+), ([0-9.]+), ([0-9.]+)(?:, alpha: ([0-9.]+))?\)/),
      let l = Double(match.1), let c = Double(match.2), let h = Double(match.3) {
      return .colour(OKLCH(l, c, h), alpha: match.4.flatMap { Double($0) } ?? 1)
    }
    if let match = text.wholeMatch(of: /NSColor\.(white|black)(?:\.withAlphaComponent\(([0-9.]+)\))?/) {
      return .colour(OKLCH(match.1 == "white" ? 1 : 0, 0, 0), alpha: match.2.flatMap { Double($0) } ?? 1)
    }
    return nil
  }

  static func source(of setting: LiveSetting) -> String {
    switch setting {
    case .number(let value):
      return number(value)
    case .colour(let value, let alpha):
      let opacity = number(alpha)
      if value.c < 0.0005, value.l >= 0.9995 || value.l <= 0.0005 {
        let name = value.l > 0.5 ? "white" : "black"
        return "NSColor.\(name)" + (alpha < 1 ? ".withAlphaComponent(\(opacity))" : "")
      }
      let parts = "\(number(value.l)), \(number(value.c)), \(number(value.h))"
      return "NSColor(oklch: \(parts)" + (alpha < 1 ? ", alpha: \(opacity))" : ")")
    }
  }

  static func number(_ value: Double) -> String {
    let text = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    let trimmed = text.replacing(/\.?0+$/, with: "")
    return trimmed == "-0" ? "0" : trimmed
  }

  static func find(in text: String, file: URL) -> [DesignKnob] {
    var owner = ""
    var knobs: [DesignKnob] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if let match = line.firstMatch(of: /^(?:[a-z@]+ )*(?:enum|struct|class|extension) (\w+)/) {
        owner = String(match.1)
      }
      guard line.contains("live("), let match = line.wholeMatch(of: declaration),
            let setting = parse(String(match.output.2))
      else { continue }
      let name = String(match.output.1)
      knobs.append(DesignKnob(
        key: LiveValues.key(file: file.lastPathComponent, name: name), owner: owner, name: name, file: file,
        expression: String(match.output.2), setting: setting, isTime: line.contains(": TimeInterval")
          || line.contains(": CFTimeInterval")))
    }
    return knobs
  }

  nonisolated(unsafe) private static let declaration =
    /\s+(?:private )?static var (\w+): \w+ \{ live\((.+)\) \}\s*/

  /// `text` with this knob's value written as `setting`; `nil` when its line no longer reads as it did.
  func write(_ setting: LiveSetting, into text: String) -> String? {
    let before = "static var \(name): "
    let old = "{ live(\(expression)) }"
    let lines = text.components(separatedBy: "\n")
    let places = lines.indices.filter { lines[$0].contains(before) && lines[$0].contains(old) }
    guard places.count == 1, let place = places.first else { return nil }
    var out = lines
    out[place] = lines[place].replacingOccurrences(of: old, with: "{ live(\(Self.source(of: setting))) }")
    return out.joined(separator: "\n")
  }
}

/// The knobs, what was changed on them, and the source they are saved to.
@MainActor
final class DesignKnobStore {
  private(set) var knobs: [DesignKnob] = []
  private(set) var changes: [String: LiveSetting] = [:]
  private let files: [URL]
  private var texts: [URL: String] = [:]

  init(files: [URL]? = nil) {
    self.files = files ?? (FileManager.default.enumerator(
      at: DesignSources.root.appendingPathComponent("UI"), includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter { $0.pathExtension == "swift" && !$0.path.contains("/UI/Design/") && $0.lastPathComponent != "LiveValue.swift" }
      .filter { (try? String(contentsOf: $0, encoding: .utf8))?.contains("live(") == true } ?? [])
    readSource()
  }

  func current(_ knob: DesignKnob) -> LiveSetting { changes[knob.key] ?? knob.setting }

  /// The source as it is now is the truth, whatever this build was compiled with.
  /// Returns whether it changed. A change made here to a value the source changed too gives way.
  @discardableResult
  func readSource() -> Bool {
    var fresh: [URL: String] = [:]
    for file in files { fresh[file] = try? String(contentsOf: file, encoding: .utf8) }
    guard fresh != texts else { return false }
    texts = fresh
    let old = Dictionary(knobs.map { ($0.key, $0.setting) }, uniquingKeysWith: { first, _ in first })
    knobs = files.flatMap { file in fresh[file].map { DesignKnob.find(in: $0, file: file) } ?? [] }
    for knob in knobs {
      if let before = old[knob.key], before != knob.setting { changes[knob.key] = nil }
      LiveValues.shared.set(current(knob), for: knob.key)
    }
    let keys = Set(knobs.map(\.key))
    changes = changes.filter { keys.contains($0.key) }
    return true
  }

  func set(_ setting: LiveSetting, for knob: DesignKnob) {
    changes[knob.key] = setting == knob.setting ? nil : setting
    LiveValues.shared.set(setting, for: knob.key)
  }

  func revertAll() {
    changes = [:]
    for knob in knobs { LiveValues.shared.set(knob.setting, for: knob.key) }
  }

  struct SaveError: Error, Equatable {
    let message: String
  }

  /// All the changes or, when any cannot be placed, none.
  func save() throws {
    var written: [URL: String] = [:]
    for knob in knobs {
      guard let setting = changes[knob.key] else { continue }
      let text = try written[knob.file] ?? String(contentsOf: knob.file, encoding: .utf8)
      guard let next = knob.write(setting, into: text) else {
        throw SaveError(message: "\(knob.name) in \(knob.file.lastPathComponent) changed since it was read. Nothing was saved.")
      }
      written[knob.file] = next
    }
    for (file, text) in written { try text.write(to: file, atomically: true, encoding: .utf8) }
    changes = [:]
    readSource()
  }
}
