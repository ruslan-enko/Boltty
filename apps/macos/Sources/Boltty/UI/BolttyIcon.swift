import AppKit

enum BolttyIcon: String, CaseIterable {
  case plus
  case xmark
  case check
  case stop
  case eye
  case copy
  case speaker
  case mic
  case settings
  case folder
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
  case undoCircle = "undo-circle"
  case circle
  case circleDashed = "circle-dashed"
  case circleDotted = "circle-dotted"
  case checkCircle = "check-circle"
  case warning
  case bellBadge = "bell-badge"
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
  case bolt
  case hexGrid = "hex-grid"
  case keyReturn = "key-return"
  case keyCommand = "key-command"
  case keyShift = "key-shift"
  case keyOption = "key-option"
  case keyControl = "key-control"
  case keyDelete = "key-delete"
  case keyTab = "key-tab"

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

  func image(size: CGFloat, nudgedLeft nudge: CGFloat, description: String? = nil) -> NSImage? {
    guard let template = image(size: size) else { return nil }
    let box = NSSize(width: size + nudge * 2, height: size)
    let nudged = NSImage(size: box, flipped: false) { _ in
      template.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: .zero, operation: .sourceOver, fraction: 1)
      return true
    }
    nudged.isTemplate = true
    nudged.accessibilityDescription = description
    return nudged
  }

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
