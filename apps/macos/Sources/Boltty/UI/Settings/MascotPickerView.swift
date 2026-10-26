import AppKit
import SwiftUI

struct MascotFace: NSViewRepresentable {
  var look: MascotLook
  var emotion: MascotEmotion = .curious
  /// Seeds the face's own motion: faces that share it move as one.
  var identity: UUID = MascotStill.identity
  /// A link of its own at the display's rate — for a face that is the
  /// thing being looked at (the setup card's); the shared clock is 60 Hz.
  var ownsDisplayLink = false
  /// Each change pokes the face once.
  var pokes = 0
  /// Pixels per point, when not the screen's: a big face that is one of
  /// several live ones draws under Retina, where it costs least.
  var renderScale: CGFloat? = nil

  final class Coordinator {
    var pokes = 0
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> MascotNSView {
    let view = MascotNSView(conversationID: identity, look: look)
    view.reduceMotion = MotionPreferences.reduceMotion
    view.ownsDisplayLink = ownsDisplayLink
    view.renderScale = renderScale
    view.emotion = emotion
    context.coordinator.pokes = pokes
    return view
  }

  func updateNSView(_ view: MascotNSView, context: Context) {
    let isNewLook = view.look != look
    view.apply(look: look)
    view.emotion = emotion
    if isNewLook || context.coordinator.pokes != pokes { view.poke() }
    context.coordinator.pokes = pokes
  }
}

struct MascotStill: View {
  let look: MascotLook
  let size: CGFloat
  @Environment(\.displayScale) private var displayScale

  static var identity: UUID { MascotSnapshotCache.identity }

  var body: some View {
    Group {
      if let image = Self.image(look, size: size, scale: displayScale) {
        Image(decorative: image, scale: displayScale)
          .resizable()
          .interpolation(.high)
      } else {
        Color.clear
      }
    }
    .frame(width: size, height: size)
  }

  @MainActor
  static func image(_ look: MascotLook, size: CGFloat, scale: CGFloat) -> CGImage? {
    MascotSnapshotCache.image(look, size: size, scale: scale)
  }
}

struct MascotPickerButton: View {
  @ObservedObject var model: BolttyAISettingsModel
  let agent: AgentId
  @State private var isOpen = false
  @State private var isHovered = false

  var body: some View {
    let look = model.mascotLook(for: agent)
    LabeledContent("Mascot") {
      Button {
        isOpen.toggle()
      } label: {
        HStack(spacing: 8) {
          MascotStill(look: look, size: 28)
          Text(look.displayName)
            .foregroundStyle(.primary)
          SettingsPopUpIndicator(isHovered: isHovered || isOpen)
            .padding(.trailing, 3.5)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(SettingsPressStyle())
      .onHover { isHovered = $0 }
      .popover(isPresented: $isOpen, arrowEdge: .trailing) {
        MascotPickerView(model: model, agent: agent)
      }
      .accessibilityLabel("Mascot for \(agent.displayName)")
      .accessibilityValue(look.displayName)
      .accessibilityIdentifier("boltty.settings.mascot.\(agent.rawValue)")
    }
  }
}

struct MascotPickerView: View {
  @ObservedObject var model: BolttyAISettingsModel
  let agent: AgentId

  private let shapeColumns = Array(repeating: GridItem(.fixed(60), spacing: 0), count: 5)
  private let gradientColumns = Array(repeating: GridItem(.fixed(37), spacing: 0), count: 8)

  var body: some View {
    let current = model.mascotLook(for: agent)
    VStack(spacing: 18) {
      VStack(spacing: 6) {
        MascotFace(look: current)
          .frame(width: 96, height: 96)
        Text(current.displayName)
          .font(BolttyInterfaceTypography.headline)
        Text("\(agent.displayName) wears this on its tab, above the prompt and in the notch.")
          .font(BolttyInterfaceTypography.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Shape")
          .font(BolttyInterfaceTypography.callout)
          .foregroundStyle(.secondary)
        LazyVGrid(columns: shapeColumns, alignment: .leading, spacing: 4) {
          ForEach(MascotShape.allCases) { shape in
            cell(
              MascotLook(shape: shape, palette: current.palette, finish: current.finish),
              name: shape.displayName,
              size: 46, identifier: "shape.\(shape.rawValue)", current: current
            )
          }
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Gradient")
          .font(BolttyInterfaceTypography.callout)
          .foregroundStyle(.secondary)
        LazyVGrid(columns: gradientColumns, alignment: .leading, spacing: 4) {
          ForEach(MascotPalette.catalog) { palette in
            cell(
              MascotLook(shape: current.shape, palette: palette, finish: current.finish),
              name: palette.displayName,
              size: 32, identifier: "gradient.\(palette.id)", current: current
            )
          }
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Finish")
          .font(BolttyInterfaceTypography.callout)
          .foregroundStyle(.secondary)
        HStack(spacing: 4) {
          ForEach(MascotFinish.allCases) { finish in
            cell(
              MascotLook(shape: current.shape, palette: current.palette, finish: finish),
              name: finish.displayName,
              size: 46, identifier: "finish.\(finish.rawValue)", current: current
            )
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack {
        Spacer()
        Button("Restore Default") {
          if let standard = MascotRoster.defaultLook(for: agent) {
            model.chooseMascot(standard, for: agent)
          }
        }
        .disabled(!canReset(current))
        .accessibilityIdentifier("boltty.settings.mascot.\(agent.rawValue).reset")
      }
    }
    .padding(20)
    .frame(width: 340)
  }

  private func canReset(_ current: MascotLook) -> Bool {
    guard let standard = MascotRoster.defaultLook(for: agent), standard != current else {
      return false
    }
    return model.mascotOwner(of: standard, besides: agent) == nil
  }

  @ViewBuilder
  private func cell(
    _ look: MascotLook, name: String, size: CGFloat, identifier: String, current: MascotLook
  ) -> some View {
    let owner = model.mascotOwner(of: look, besides: agent)
    MascotCell(
      look: look, name: name, size: size,
      isChosen: look == current,
      takenBy: owner.map(model.name(of:))
    ) {
      model.chooseMascot(look, for: agent)
    }
    .accessibilityIdentifier("boltty.settings.mascot.\(agent.rawValue).\(identifier)")
  }
}

private struct MascotCell: View {
  let look: MascotLook
  let name: String
  let size: CGFloat
  let isChosen: Bool
  let takenBy: String?
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      MascotStill(look: look, size: size)
        .opacity(takenBy == nil ? 1 : 0.3)
    }
    .buttonStyle(MascotCellStyle(isHovered: isHovered && takenBy == nil, isChosen: isChosen))
    .disabled(takenBy != nil)
    .onHover { isHovered = $0 }
    .help(takenBy.map { "\(name) — worn by \($0)" } ?? name)
    .accessibilityLabel(name)
    .accessibilityValue(isChosen ? "Selected" : takenBy.map { "Worn by \($0)" } ?? "")
  }
}

private struct MascotCellStyle: ButtonStyle {
  let isHovered: Bool
  let isChosen: Bool

  func makeBody(configuration: Configuration) -> some View {
    let isPressed = configuration.isPressed
    configuration.label
      .scaleEffect(
        isPressed && !MotionPreferences.reduceMotion ? AgentPaletteMetrics.controlPressedScale : 1
      )
      .animation(SettingsMotion.press, value: isPressed)
      .padding(3)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.primary.opacity(isPressed ? 0.14 : (isHovered ? 0.08 : 0)))
          .animation(isPressed ? nil : SettingsMotion.quick, value: isPressed)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(Color.accentColor, lineWidth: isChosen ? 2 : 0)
          .animation(SettingsMotion.quick, value: isChosen)
      )
      .contentShape(Rectangle())
  }
}
