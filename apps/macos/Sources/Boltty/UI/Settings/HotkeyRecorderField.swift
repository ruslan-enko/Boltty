import AppKit
import Carbon
import SwiftUI

struct HotkeyRecorderField: View {
  let binding: HotkeyBinding
  let isEnabled: Bool
  var isRowHovered = false
  var probe: (HotkeyBinding) -> HotkeyAvailability = { _ in .free }
  @Binding var problem: HotkeyProblem?
  let onRecord: (HotkeyBinding) -> Void
  var onRestoreDefault: () -> Void
  @State private var isSuggestionsHovered = false

  var body: some View {
    HStack(spacing: 6) {
      capsule
      suggestionsButton
    }
  }

  private var capsule: some View {
    ShortcutRecorderCapsule(
      display: display,
      isEnabled: isEnabled,
      accessibilityName: "Boltty AI shortcut",
      accessibilityIdentifier: "boltty.settings.hotkeyRecorder",
      isConflicting: problem?.isConflict == true,
      isRowHovered: isRowHovered,
      onEvent: handleEvent,
      onRestoreDefault: restoreControl
    )
  }

  private var restoreControl: (() -> Void)? {
    if binding == HotkeySuggestions.defaultBinding { return nil }
    return restoreDefault
  }

  private var display: String {
    problem?.attempted?.displayName ?? binding.displayName
  }

  private var suggestionsButton: some View {
    SettingsPopUpIndicator(symbol: "chevron.down", isHovered: isSuggestionsHovered)
      .contentShape(Circle())
      .onHover { isSuggestionsHovered = $0 && isEnabled }
      .overlay {
        SuggestionAnchor(
          suggestions: HotkeySuggestions.all,
          modifierOnly: HotkeySuggestions.modifierOnly,
          current: binding,
          probe: probe,
          isEnabled: isEnabled,
          onPick: choose
        )
      }
      .opacity(isEnabled ? 1 : 0.45)
      .help("Pick a shortcut")
      .accessibilityElement(children: .ignore)
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel("Choose a shortcut")
      .accessibilityIdentifier("boltty.settings.hotkeySuggestions")
  }

  private func choose(_ binding: HotkeyBinding) {
    if binding.isModifierOnly, !probe(binding).isFree {
      ModifierHotkeyMonitor.requestAccess()
    }
    problem = nil
    onRecord(binding)
  }

  private func restoreDefault() {
    problem = nil
    onRestoreDefault()
  }

  private func handleEvent(_ event: NSEvent) -> Bool {
    let recorded = HotkeyBinding(event: event)
    if let rejection = HotkeyValidation.reject(recorded) {
      problem = .rejected(rejection)
      return false
    }
    let availability = probe(recorded)
    guard availability.isFree else {
      problem = .unavailable(recorded, availability)
      return false
    }
    problem = nil
    onRecord(recorded)
    return true
  }
}

// MARK: - Menu chords

struct MenuShortcutRecorderField: View {
  let id: String
  let binding: ShortcutBinding
  var isConflicting = false
  var isRowHovered = false
  var canRestore = false
  let onRecord: (ShortcutBinding?) -> Void
  var onRestoreDefault: (() -> Void)?

  @State private var rejection: ShortcutBindingRejection?

  var body: some View {
    ShortcutRecorderCapsule(
      display: binding.isUnbound ? "" : binding.displayName,
      isEnabled: true,
      accessibilityName: "\(KeyboardShortcutCatalog.shortcut(for: id).title) shortcut",
      accessibilityIdentifier: "boltty.settings.shortcutRecorder.\(id)",
      isConflicting: isConflicting,
      isRowHovered: isRowHovered,
      canClear: true,
      isInline: true,
      onEvent: handleEvent,
      onRestoreDefault: canRestore ? onRestoreDefault : nil,
      status: rejection.map { (text: $0.message, isWarning: true) }
    )
  }

  private func handleEvent(_ event: NSEvent) -> Bool {
    let bareDelete = (event.keyCode == UInt16(kVK_Delete)
      || event.keyCode == UInt16(kVK_ForwardDelete))
      && event.hasNoChordModifiers
    if bareDelete {
      rejection = nil
      onRecord(nil)
      return true
    }

    let recorded = ShortcutBinding(event: event)
    if let refused = ShortcutBindingValidation.reject(recorded) {
      rejection = refused
      return false
    }
    rejection = nil
    onRecord(recorded)
    return true
  }
}

// MARK: - The menu

private struct SuggestionAnchor: NSViewRepresentable {
  let suggestions: [HotkeySuggestions.Suggestion]
  let modifierOnly: [HotkeySuggestions.Suggestion]
  let current: HotkeyBinding
  let probe: (HotkeyBinding) -> HotkeyAvailability
  let isEnabled: Bool
  let onPick: (HotkeyBinding) -> Void

  func makeNSView(context: Context) -> AnchorView {
    let view = AnchorView()
    apply(to: view)
    return view
  }

  func updateNSView(_ view: AnchorView, context: Context) {
    apply(to: view)
  }

  private func apply(to view: AnchorView) {
    view.isEnabledForMenu = isEnabled
    view.didPick = onPick
    view.build = { [suggestions, modifierOnly, current, probe] anchor in
      Self.menu(
        suggestions: suggestions, modifierOnly: modifierOnly,
        current: current, probe: probe, target: anchor)
    }
  }

  private static func menu(
    suggestions: [HotkeySuggestions.Suggestion],
    modifierOnly: [HotkeySuggestions.Suggestion],
    current: HotkeyBinding,
    probe: (HotkeyBinding) -> HotkeyAvailability,
    target: AnchorView
  ) -> NSMenu {
    let menu = NSMenu()
    for suggestion in suggestions {
      let binding = suggestion.binding
      let rejection = HotkeyValidation.reject(binding)
      let availability = rejection == nil ? probe(binding) : .free
      let item = NSMenuItem(
        title: binding.displayName,
        action: #selector(AnchorView.pick(_:)),
        keyEquivalent: ""
      )
      item.target = target
      item.representedObject = Box(binding)
      item.state = binding == current ? .on : .off
      item.isEnabled = rejection == nil && availability.isFree
      item.toolTip = Self.reason(
        for: suggestion, rejection: rejection, availability: availability
      )
      menu.addItem(item)
    }
    if !modifierOnly.isEmpty { menu.addItem(.separator()) }
    for suggestion in modifierOnly {
      let binding = suggestion.binding
      let item = NSMenuItem(
        title: binding.displayName,
        action: #selector(AnchorView.pick(_:)),
        keyEquivalent: ""
      )
      item.target = target
      item.representedObject = Box(binding)
      item.state = binding == current ? .on : .off
      item.subtitle = probe(binding).isFree
        ? "Press together and let go"
        : "Press together and let go · needs Input Monitoring"
      item.toolTip = suggestion.rationale
      menu.addItem(item)
    }
    return menu
  }

  private static func reason(
    for suggestion: HotkeySuggestions.Suggestion,
    rejection: HotkeyRejection?,
    availability: HotkeyAvailability
  ) -> String {
    if let rejection { return rejection.message }
    switch availability {
    case .free: return suggestion.rationale
    case .taken: return "Already used by another app"
    case .failed: return "Carbon refused this chord"
    case .needsInputMonitoring: return "Needs Input Monitoring"
    }
  }

  final class Box: NSObject {
    let binding: HotkeyBinding
    init(_ binding: HotkeyBinding) { self.binding = binding }
  }

  final class AnchorView: NSView {
    var build: ((AnchorView) -> NSMenu)?
    var didPick: ((HotkeyBinding) -> Void)?
    var isEnabledForMenu = true

    override func mouseDown(with event: NSEvent) {
      present()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
      addCursorRect(bounds, cursor: .pointingHand)
    }

    override func accessibilityPerformPress() -> Bool {
      present()
      return true
    }

    private func present() {
      guard isEnabledForMenu, let menu = build?(self) else { return }
      menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.minY - 4), in: self)
    }

    @objc func pick(_ sender: NSMenuItem) {
      guard let box = sender.representedObject as? Box else { return }
      didPick?(box.binding)
    }
  }
}
