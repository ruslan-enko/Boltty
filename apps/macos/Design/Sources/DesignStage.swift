import AppKit

enum DesignGround: String, CaseIterable {
  case desktop = "Desktop"
  case white = "White"
  case grey = "Grey"
  case black = "Black"

  var colour: NSColor {
    switch self {
    case .desktop, .grey: NSColor(oklch: 0.5, 0, 0)
    case .white: .white
    case .black: .black
    }
  }
}

class DesignFlippedView: NSView {
  override var isFlipped: Bool { true }
}

final class DesignTile: DesignFlippedView {
  static let corner: CGFloat = 14
  private let sample: NSView

  init(_ specimen: DesignSpecimen, ground: DesignGround) {
    sample = specimen.view
    super.init(frame: .zero)
    if specimen.isDark { appearance = NSAppearance(named: .darkAqua) }
    wantsLayer = true
    layer?.masksToBounds = true
    if specimen.isDark {
      layer?.backgroundColor = ground.colour.cgColor
      if ground == .desktop, let picture = DesktopPicture.cached?.image {
        layer?.contents = picture
        layer?.contentsGravity = .resizeAspectFill
      }
    }
    addSubview(sample)
    if specimen.fills {
      sample.translatesAutoresizingMaskIntoConstraints = true
      sample.autoresizingMask = [.width, .height]
      sample.frame = bounds
      return
    }
    sample.translatesAutoresizingMaskIntoConstraints = false
    var constraints = [
      sample.centerXAnchor.constraint(equalTo: centerXAnchor),
      sample.centerYAnchor.constraint(equalTo: centerYAnchor),
    ]
    if let width = specimen.width { constraints.append(sample.widthAnchor.constraint(equalToConstant: width)) }
    if let height = specimen.height { constraints.append(sample.heightAnchor.constraint(equalToConstant: height)) }
    NSLayoutConstraint.activate(constraints)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layout() {
    super.layout()
    layer?.applyPaletteCorner(radius: Self.corner)
    if !sample.translatesAutoresizingMaskIntoConstraints { return }
    sample.frame = bounds
  }
}

@MainActor
struct DesignSpecimen {
  let name: String
  var note = ""
  let view: NSView
  var width: CGFloat?
  var height: CGFloat?
  var tile = CGSize(width: 180, height: 110)
  var isWide = false
  var fills = false
  var isDark = true
}

@MainActor
struct DesignSection {
  let title: String
  var note = ""
  let specimens: [DesignSpecimen]
}

final class DesignPageView: DesignFlippedView {
  private static let margin: CGFloat = 24
  private static let gap: CGFloat = 12
  private static let captionGap: CGFloat = 6

  private struct Cell {
    let specimen: DesignSpecimen
    let tile: DesignTile
    let name: NSTextField
    let note: NSTextField
  }
  private struct Block {
    let title: NSTextField
    let note: NSTextField
    let cells: [Cell]
  }
  private var blocks: [Block] = []

  init(sections: [DesignSection], ground: DesignGround) {
    super.init(frame: .zero)
    blocks = sections.map { section in
      Block(
        title: label(section.title, size: AgentPaletteMetrics.typeSecondary, weight: .semibold),
        note: label(section.note, size: AgentPaletteMetrics.typeMeta, ink: .secondaryLabelColor),
        cells: section.specimens.map { specimen in
          let tile = DesignTile(specimen, ground: ground)
          addSubview(tile)
          return Cell(
            specimen: specimen, tile: tile,
            name: label(specimen.name, size: AgentPaletteMetrics.typeMeta),
            note: label(specimen.note, size: AgentPaletteMetrics.typeFootnote, ink: .secondaryLabelColor))
        })
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func label(
    _ text: String, size: CGFloat, weight: NSFont.Weight = .regular, ink: NSColor = .labelColor
  ) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = roundedAppFont(size: size, weight: weight)
    field.textColor = ink
    field.isSelectable = true
    field.isHidden = text.isEmpty
    addSubview(field)
    return field
  }

  func arrange(width: CGFloat, viewport: CGFloat) -> CGFloat {
    let room = max(200, width - Self.margin * 2)
    var y = Self.margin
    for block in blocks {
      y = place(block.title, x: Self.margin, y: y, width: room)
      if !block.note.isHidden { y = place(block.note, x: Self.margin, y: y + 2, width: room) }
      y += block.title.isHidden ? 0 : Self.gap
      var x = Self.margin
      var rowHeight: CGFloat = 0
      for cell in block.cells {
        var size = cell.specimen.tile
        if cell.specimen.fills {
          size = CGSize(width: room, height: max(760, viewport - y - 50))
        } else if cell.specimen.isWide {
          size.width = room
        }
        size.width = min(size.width, room)
        if x > Self.margin, x + size.width > Self.margin + room {
          x = Self.margin
          y += rowHeight + Self.gap
          rowHeight = 0
        }
        cell.tile.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        var foot = place(cell.name, x: x, y: y + size.height + Self.captionGap, width: size.width)
        if !cell.note.isHidden { foot = place(cell.note, x: x, y: foot + 1, width: size.width) }
        rowHeight = max(rowHeight, foot - y)
        x += size.width + Self.gap
      }
      y += rowHeight + Self.margin
    }
    return y
  }

  private func place(_ field: NSTextField, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
    guard !field.isHidden else { return y }
    field.preferredMaxLayoutWidth = width
    let height = ceil(field.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
    field.frame = CGRect(x: x, y: y, width: width, height: height)
    return y + height
  }
}
