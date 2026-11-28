import AppKit

@MainActor
final class CopyConfirmation {
  static let shownFor: TimeInterval = 1.2

  private let show: (_ copied: Bool) -> Void
  private var reset: DispatchWorkItem?

  init(show: @escaping (_ copied: Bool) -> Void) {
    self.show = show
  }

  func copy(_ text: String) {
    guard !text.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    show(true)
    reset?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.show(false) }
    reset = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.shownFor, execute: work)
  }
}
