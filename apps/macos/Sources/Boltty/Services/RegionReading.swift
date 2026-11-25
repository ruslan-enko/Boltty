import Foundation

/// One region's pictures and the words on it, read from the moment it is drawn.
@MainActor
final class RegionReading {
  let frame: CGRect
  private let cut: Task<ScreenCut?, Never>
  private let words: Task<ScreenTextReader.Words?, Never>

  init(
    of frame: CGRect, primaryScreenHeight: CGFloat, readsLabels: Bool,
    from frozen: @escaping @MainActor () async -> FrozenScreen?
  ) {
    self.frame = frame
    let cut = Task { () -> ScreenCut? in
      guard let frozen = await frozen(), !Task.isCancelled else { return nil }
      return await Task.detached(priority: .userInitiated) {
        try? ScreenRegionCapture.cut(frame, in: frozen, primaryScreenHeight: primaryScreenHeight)
      }.value
    }
    self.cut = cut
    words = Task {
      guard let cut = await cut.value, !Task.isCancelled else { return nil }
      return await ScreenTextReader.words(in: cut, readsLabels: readsLabels)
    }
  }

  func selection(waitingForWords seconds: TimeInterval) async -> ScreenSelection? {
    guard var selection = await cut.value?.selection else { return nil }
    if let words = await Deadline.value(of: words, within: seconds) ?? nil {
      selection.recognizedText = words.text
      selection.labels = words.labels
    }
    return selection
  }

  func cancel() {
    cut.cancel()
    words.cancel()
  }
}
