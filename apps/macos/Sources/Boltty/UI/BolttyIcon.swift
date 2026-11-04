import AppKit

/// Boltty's own icons. Nothing in the interface uses an SF Symbol but the Apple
/// mark in the first-run show's made-up menu bar.
///
/// Each is a file in `Resources/Icons`: a 16 × 16 grid, a 1.25 stroke, no hard
/// corner. An icon is sized by its box, not a font's point size, and its stroke
/// grows with the box, so a size here is a choice of weight too. As a rule the
/// box is about a fifth over the point size the symbol it replaced was set at,
/// since an icon's ink stops short of its box.
enum BolttyIcon: String, CaseIterable {
  case plus
  case xmark
  case check
  case stopFill = "stop-fill"
  case eye
  case copy
  case speaker
  case speakerFill = "speaker-fill"
  case mic
  case micFill = "mic-fill"
  case gear
  case folder
  case folderFill = "folder-fill"
  case lock
  case power
  case reload
  case sync
  case chevronRight = "chevron-right"
  case chevronLeft = "chevron-left"
  case chevronDown = "chevron-down"
  case chevronUp = "chevron-up"
  case chevronsUpDown = "chevrons-up-down"
  case arrowDown = "arrow-down"
  case arrowDownCircle = "arrow-down-circle"
  case arrowUpCircle = "arrow-up-circle"
  case compact
  case undoCircleFill = "undo-circle-fill"
  case circle
  case circleDashed = "circle-dashed"
  case circleDotted = "circle-dotted"
  case checkCircle = "check-circle"
  case checkCircleFill = "check-circle-fill"
  case warning
  case warningFill = "warning-fill"
  case bellBadge = "bell-badge"
  case bellBadgeFill = "bell-badge-fill"
  case bellSlash = "bell-slash"
  case brain
  case doc
  case photo
  case textScan = "text-scan"
  case link
  case terminal
  case chart
  case keyboard
  case speakingPerson = "speaking-person"
  case people
  case region
  case sparkles
  case film
  case waveform
  case music
  case pointerRays = "pointer-rays"
  case code
  case boltFill = "bolt-fill"
  case hexGrid = "hex-grid"
  case keyReturn = "key-return"
  case keyCommand = "key-command"
  case keyShift = "key-shift"
  case keyOption = "key-option"
  case keyControl = "key-control"
  case keyDelete = "key-delete"
  case keyTab = "key-tab"

  /// A template image, so a control's tint colours it as it would a symbol.
  /// Read from disk each time: a control asks only when it is made or changes,
  /// and an `NSImage` given a size is not one to share between controls.
  func image(size: CGFloat, description: String? = nil) -> NSImage? {
    guard
      let url = Bundle.main.url(forResource: rawValue, withExtension: "svg", subdirectory: "Icons"),
      let image = NSImage(contentsOf: url)
    else {
      assertionFailure("No icon \(rawValue) in Resources/Icons")
      return nil
    }
    image.size = NSSize(width: size, height: size)
    image.isTemplate = true
    image.accessibilityDescription = description
    return image
  }

  /// In a colour of its own, for where nothing tints it: text attachments draw
  /// their image as it is.
  func image(size: CGFloat, colour: NSColor) -> NSImage? {
    guard let template = image(size: size) else { return nil }
    let box = NSSize(width: size, height: size)
    return NSImage(size: box, flipped: false) { rect in
      template.draw(in: rect, from: .zero, operation: .sourceOver, fraction: colour.alphaComponent)
      colour.withAlphaComponent(1).set()
      rect.fill(using: .sourceAtop)
      return true
    }
  }
}
