import AppKit
import Carbon
import SwiftUI

enum ShortcutRecorderMetrics {
  static let width: CGFloat = 116
}

struct ShortcutRecorderCapsule: View {
  let display: String
  let isEnabled: Bool
  let accessibilityName: String
  var accessibilityIdentifier: String?
  var isConflicting = false
  var isRowHovered = false
  var canClear = false
  var isInline = false
  let onEvent: (NSEvent) -> Bool
  var onRestoreDefault: (() -> Void)?

  var status: (text: String, isWarning: Bool)? = nil

  @State private var isRecording = false
  @State private var isRestoreHovered = false

  var body: some View {
    HStack(spacing: 8) {
      if let status {
        Text(status.text)
          .font(BolttyInterfaceTypography.callout)
          .foregroundStyle(status.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
          .lineLimit(1)
          .fixedSize()
          .transition(.opacity)
      }
      restoreButton
      RecorderButton(
        display: display,
        isRecording: isRecording,
        isEnabled: isEnabled,
        isConflicting: isConflicting,
        isInline: isInline,
        accessibilityName: accessibilityName,
        accessibilityIdentifier: accessibilityIdentifier,
        help: isRecording
          ? (canClear
              ? "Type the new shortcut. Esc cancels, Delete removes it."
              : "Type the new shortcut, or press Esc to cancel.")
          : "Click to change this shortcut",
        onArm: { isRecording = true },
        onEvent: handle(event:),
        onCancel: { isRecording = false }
      )
      .frame(width: ShortcutRecorderMetrics.width)
      .fixedSize(horizontal: false, vertical: true)
    }
    .animation(SettingsMotion.quick, value: isRowHovered)
    .animation(SettingsMotion.quick, value: status?.text)
    .onChange(of: isEnabled) { _, enabled in
      if !enabled { isRecording = false }
    }
    // While recording, chords are data: without this the menu takes them first.
    .onChange(of: isRecording) { _, recording in
      BolttyShortcutRouter.setSuspended(recording)
    }
    .onDisappear {
      BolttyShortcutRouter.setSuspended(false)
    }
  }

  // The slot is always laid out and only fades: inserting the button on hover
  // shoved the capsule sideways under the pointer.
  private var restoreButton: some View {
    let isShown = onRestoreDefault != nil && (isRowHovered || isRecording)
    return Button {
      isRecording = false
      onRestoreDefault?()
    } label: {
      RestoreGlyph()
    }
    .buttonStyle(SettingsPressStyle())
    .foregroundStyle(isRestoreHovered ? .primary : .secondary)
    .onHover { isRestoreHovered = $0 && isShown }
    .disabled(!isEnabled || !isShown)
    .opacity(isShown ? 1 : 0)
    .allowsHitTesting(isShown)
    .accessibilityHidden(!isShown)
    .help("Restore the default shortcut")
    .accessibilityLabel("Restore default shortcut for \(accessibilityName)")
  }

  private func handle(event: NSEvent) {
    if event.keyCode == UInt16(kVK_Escape), event.hasNoChordModifiers {
      isRecording = false
      return
    }
    if onEvent(event) {
      isRecording = false
    }
  }
}

extension NSEvent {
  var hasNoChordModifiers: Bool {
    modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .intersection([.command, .option, .control, .shift])
      .isEmpty
  }
}

// MARK: - AppKit

private struct RecorderButton: NSViewRepresentable {
  let display: String
  let isRecording: Bool
  let isEnabled: Bool
  let isConflicting: Bool
  let isInline: Bool
  let accessibilityName: String
  let accessibilityIdentifier: String?
  let help: String
  let onArm: () -> Void
  let onEvent: (NSEvent) -> Void
  let onCancel: () -> Void

  func makeNSView(context: Context) -> ShortcutRecorderButton {
    let view = ShortcutRecorderButton()
    apply(to: view)
    return view
  }

  func updateNSView(_ view: ShortcutRecorderButton, context: Context) {
    apply(to: view)

    guard let window = view.window else { return }
    if isRecording {
      DispatchQueue.main.async { [weak view] in
        guard let view, view.isRecording, let window = view.window else { return }
        if window.firstResponder !== view { window.makeFirstResponder(view) }
      }
    } else if window.firstResponder === view {
      window.makeFirstResponder(nil)
    }
  }

  private func apply(to view: ShortcutRecorderButton) {
    view.onArm = onArm
    view.onEvent = onEvent
    view.onCancel = onCancel
    view.isEnabled = isEnabled
    view.chord = display
    view.isConflicting = isConflicting
    view.isInline = isInline
    view.isRecording = isRecording
    view.toolTip = help
    view.setAccessibilityLabel(accessibilityName)
    view.setAccessibilityValue(isRecording ? "Recording" : (display.isEmpty ? "None" : display))
    view.setAccessibilityHelp(help)
    view.setAccessibilityIdentifier(accessibilityIdentifier ?? "")
  }
}

final class ShortcutRecorderButton: NSButton {
  var onArm: (() -> Void)?
  var onEvent: ((NSEvent) -> Void)?
  var onCancel: (() -> Void)?

  var chord = "" {
    didSet { if chord != oldValue { refreshTitle() } }
  }
  var isConflicting = false {
    didSet { if isConflicting != oldValue { refreshTitle() } }
  }
  var isInline = false {
    didSet { if isInline != oldValue { refreshTitle() } }
  }
  var isRecording = false {
    didSet {
      guard isRecording != oldValue else { return }
      heldModifiers = []
      refreshTitle()
    }
  }
  override var isEnabled: Bool {
    didSet { if isEnabled != oldValue { refreshTitle() } }
  }

  private var heldModifiers: NSEvent.ModifierFlags = []

  static let unboundTitle = "—"
  static let recordingTitle = "Type Shortcut"

  var titleForTesting: String { attributedTitle.string }

  init() {
    super.init(frame: .zero)
    bezelStyle = .push
    controlSize = .regular
    setButtonType(.momentaryPushIn)
    target = self
    action = #selector(clicked)
    refreshTitle()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func clicked() {
    if isRecording {
      onCancel?()
    } else {
      onArm?()
    }
  }

  private func refreshTitle() {
    let title: String
    let ink: NSColor
    if isRecording {
      title = heldModifiers.isEmpty ? Self.recordingTitle : Self.glyphs(for: heldModifiers)
      ink = .alternateSelectedControlTextColor
    } else if chord.isEmpty || chord == "None" {
      title = Self.unboundTitle
      ink = .tertiaryLabelColor
    } else {
      title = chord
      ink = !isEnabled ? .disabledControlTextColor : (isConflicting ? .systemOrange : .labelColor)
    }
    bezelColor = isRecording ? .controlAccentColor : nil
    isBordered = !isInline || isRecording
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = isBordered ? .center : .right
    paragraph.lineBreakMode = .byTruncatingMiddle
    attributedTitle = NSAttributedString(string: title, attributes: [
      .font: roundedAppFont(size: NSFont.systemFontSize),
      .foregroundColor: ink,
      .paragraphStyle: paragraph,
    ])
  }

  static func glyphs(for flags: NSEvent.ModifierFlags) -> String {
    [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
      .filter { flags.contains($0.0) }
      .map(\.1)
      .joined()
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override var acceptsFirstResponder: Bool { isRecording || super.acceptsFirstResponder }

  override func keyDown(with event: NSEvent) {
    guard isRecording else {
      super.keyDown(with: event)
      return
    }
    onEvent?(event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard isRecording else { return super.performKeyEquivalent(with: event) }
    onEvent?(event)
    return true
  }

  override func flagsChanged(with event: NSEvent) {
    guard isRecording else {
      super.flagsChanged(with: event)
      return
    }
    heldModifiers = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .intersection([.command, .option, .control, .shift])
    refreshTitle()
  }

  override func resignFirstResponder() -> Bool {
    if isRecording {
      DispatchQueue.main.async { [weak self] in
        guard let self, self.isRecording else { return }
        guard self.window?.firstResponder !== self else { return }
        self.onCancel?()
      }
    }
    return super.resignFirstResponder()
  }
}

private struct RestoreGlyph: View {
  @Environment(\.settingsControlIsPressed) private var isPressed

  var body: some View {
    Image(systemName: "arrow.uturn.backward.circle.fill")
      .symbolRenderingMode(.hierarchical)
      .font(BolttyInterfaceTypography.fixed(size: 15))
      .opacity(isPressed ? 0.55 : 1)
      .animation(isPressed ? nil : SettingsMotion.quick, value: isPressed)
  }
}
