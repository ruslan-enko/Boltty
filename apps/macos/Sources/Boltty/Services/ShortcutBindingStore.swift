import AppKit
import Combine

@MainActor
final class ShortcutBindingStore: ObservableObject {
  static let overridesKey = "boltty.shortcutOverrides"

  @Published private(set) var overrides: [String: ShortcutBinding] = [:]

  private let defaults: UserDefaults
  private var boundItems: [(id: String, item: NSMenuItem)] = []

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.overrides = Self.load(from: defaults)
  }

  // MARK: - Reading

  func binding(for id: String) -> ShortcutBinding {
    if let override = overrides[id] { return override }
    return Self.defaultBinding(for: id)
  }

  static func defaultBinding(for id: String) -> ShortcutBinding {
    guard let entry = KeyboardShortcutCatalog.entry(for: id) else { return .unbound }
    return ShortcutBinding(
      keyEquivalent: entry.keyEquivalent ?? "",
      modifiers: entry.modifiers
    )
  }

  func isCustomized(_ id: String) -> Bool { overrides[id] != nil }

  // MARK: - Writing

  func setBinding(_ binding: ShortcutBinding?, for id: String) {
    if let binding, binding != Self.defaultBinding(for: id) {
      overrides[id] = binding
    } else {
      overrides.removeValue(forKey: id)
    }
    persist()
    applyToBoundItems()
  }

  func resetAll() {
    overrides.removeAll()
    persist()
    applyToBoundItems()
  }

  // MARK: - Menu wiring

  func bind(_ item: NSMenuItem, to id: String) {
    boundItems.removeAll { $0.item === item }
    boundItems.append((id, item))
    apply(binding(for: id), to: item)
  }

  var boundIDs: Set<String> { Set(boundItems.map(\.id)) }

  #if DEBUG
  func assertEveryCustomizableIDIsBound() {
    let missing = Set(KeyboardShortcutCatalog.customizableIDs).subtracting(boundIDs)
    assert(
      missing.isEmpty,
      "Settings lists shortcuts nothing consumes: \(missing.sorted().joined(separator: ", "))"
    )
  }
  #endif

  private func applyToBoundItems() {
    for entry in boundItems {
      apply(binding(for: entry.id), to: entry.item)
    }
  }

  private func apply(_ binding: ShortcutBinding, to item: NSMenuItem) {
    item.keyEquivalent = binding.keyEquivalent
    item.keyEquivalentModifierMask = binding.modifiers
  }

  // MARK: - Conflicts

  func conflicts() -> [ShortcutBinding: [String]] {
    var byBinding: [ShortcutBinding: [String]] = [:]
    for id in KeyboardShortcutCatalog.customizableIDs {
      let binding = binding(for: id)
      guard !binding.isUnbound else { continue }
      byBinding[binding, default: []].append(id)
    }
    return byBinding.filter { $0.value.count > 1 }
  }

  func conflictingIDs() -> Set<String> {
    Set(conflicts().values.flatMap { $0 })
  }

  // MARK: - Persistence

  private func persist() {
    let encoded = overrides.mapValues { "\($0.modifiers.rawValue):\($0.keyEquivalent)" }
    if encoded.isEmpty {
      defaults.removeObject(forKey: Self.overridesKey)
    } else {
      defaults.set(encoded, forKey: Self.overridesKey)
    }
  }

  private static func load(from defaults: UserDefaults) -> [String: ShortcutBinding] {
    guard let raw = defaults.dictionary(forKey: overridesKey) as? [String: String] else {
      return [:]
    }
    return raw.reduce(into: [:]) { result, pair in
      let parts = pair.value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2, let mask = UInt(parts[0]) else { return }
      result[pair.key] = ShortcutBinding(
        keyEquivalent: String(parts[1]),
        modifiers: NSEvent.ModifierFlags(rawValue: mask)
      )
    }
  }
}
