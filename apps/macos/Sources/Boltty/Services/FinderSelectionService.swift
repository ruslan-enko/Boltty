import AppKit
import os

struct FinderPlace: Equatable, Sendable {
  var folder: String
  var selected: [String] = []
}

@MainActor
final class FinderSelectionService {
  nonisolated static let finderBundleID = "com.apple.finder"
  static let answerDeadline: TimeInterval = 1.5
  static let consentDeadline: TimeInterval = 30
  nonisolated static let selectedLimit = 30

  enum Authorization: Equatable {
    case notDetermined
    case authorized
    case denied
  }

  var readSelection: (@Sendable () async -> [URL])?
  var readFrontFolder: (@Sendable () async -> String?)?
  var authorizationProvider: (() -> Authorization)?

  func authorization() -> Authorization {
    if let authorizationProvider { return authorizationProvider() }
    var address = AEAddressDesc()
    let bundleID = Self.finderBundleID
    let created: OSStatus = bundleID.withCString { pointer in
      OSStatus(AECreateDesc(
        AEKeyword(typeApplicationBundleID),
        pointer,
        bundleID.utf8.count,
        &address
      ))
    }
    guard created == noErr else { return .denied }
    defer { AEDisposeDesc(&address) }

    switch AEDeterminePermissionToAutomateTarget(
      &address,
      AEEventClass(typeWildCard),
      AEEventID(typeWildCard),
      false
    ) {
    case noErr: return .authorized
    case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
    case OSStatus(procNotFound): return .notDetermined
    default: return .denied
    }
  }

  func selection() async -> [URL] {
    if let readSelection { return await readSelection() }
    guard let deadline = deadline() else { return [] }
    return await Self.answer(within: deadline) { Self.runSelectionScript(within: deadline) } ?? []
  }

  func place(of spot: FinderSpot) async -> FinderPlace? {
    guard let deadline = deadline() else { return nil }
    return await Self.answer(within: deadline) {
      Self.parsePlace(Self.run(Self.placeScript, within: deadline), for: spot)
    }
  }

  func frontFolder() async -> String? {
    if let readFrontFolder { return await readFrontFolder() }
    guard let deadline = deadline() else { return nil }
    return await Self.answer(within: deadline) {
      Self.run(Self.frontFolderScript, within: deadline).first.map { URL(fileURLWithPath: $0).path }
    }
  }

  private func deadline() -> TimeInterval? {
    switch authorization() {
    case .authorized: Self.answerDeadline
    case .notDetermined: Self.consentDeadline
    case .denied: nil
    }
  }

  nonisolated private static func answer<Value: Sendable>(
    within deadline: TimeInterval, _ read: @escaping @Sendable () -> Value?
  ) async -> Value? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
      let answered = OSAllocatedUnfairLock(initialState: false)
      let finish: @Sendable (Value?) -> Void = { value in
        guard answered.withLock({ was in defer { was = true }; return !was }) else { return }
        continuation.resume(returning: value)
      }
      DispatchQueue.global(qos: .userInitiated).async { finish(read()) }
      DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { finish(nil) }
    }
  }

  /// The desktop's folder; then each window, front to back; then the selection.
  /// Read here and judged in `parsePlace`, so a folder's name is never part of a
  /// script.
  nonisolated private static let placeScript = """
    tell application id "\(finderBundleID)"
      if not running then return ""
      set out to POSIX path of (desktop as alias) & linefeed
      repeat with window_ in (every Finder window)
        set here to ""
        try
          set here to POSIX path of (target of window_ as alias)
        end try
        set box to bounds of window_
        set out to out & "w" & tab & ((item 1 of box) as text) & tab & ((item 2 of box) as text) & tab & ((item 3 of box) as text) & tab & ((item 4 of box) as text) & tab & ((collapsed of window_) as text) & tab & here & tab & (name of window_) & linefeed
      end repeat
      repeat with item_ in (get selection)
        try
          set out to out & "s" & tab & POSIX path of (item_ as alias) & linefeed
        end try
      end repeat
      return out
    end tell
    """

  nonisolated static func parsePlace(_ lines: [String], for spot: FinderSpot) -> FinderPlace? {
    guard let desktop = lines.first else { return nil }
    let rows = lines.dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    let folder: String
    switch spot {
    case .desktop:
      folder = desktop
    case let .window(middle, title):
      let window = rows.first { row in
        guard row.count >= 8, row[0] == "w", row[5] == "false",
              let left = Double(row[1]), let top = Double(row[2]),
              let right = Double(row[3]), let bottom = Double(row[4]),
              CGRect(x: left, y: top, width: right - left, height: bottom - top).contains(middle)
        else { return false }
        return title == nil || row[7...].joined(separator: "\t") == title
      }
      guard let path = window?[6], !path.isEmpty else { return nil }
      folder = path
    }
    let selected = rows
      .filter { $0.count == 2 && $0[0] == "s" && $0[1].hasPrefix(folder) && $0[1] != folder }
      .map { String($0[1].dropFirst(folder.count)) }
    return FinderPlace(folder: folder, selected: Array(selected.prefix(selectedLimit)))
  }

  nonisolated private static let frontFolderScript = """
    tell application id "\(finderBundleID)"
      if not running then return ""
      return POSIX path of (insertion location as alias)
    end tell
    """

  nonisolated private static func runSelectionScript(within deadline: TimeInterval) -> [URL] {
    let source = """
    tell application id "\(finderBundleID)"
      if not running then return ""
      set out to ""
      repeat with item_ in (get selection)
        set out to out & POSIX path of (item_ as alias) & linefeed
      end repeat
      return out
    end tell
    """
    return run(source, within: deadline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .map { URL(fileURLWithPath: $0) }
  }

  /// Runs an AppleScript, whose lines come back. It gives up with the caller, or
  /// a Finder that does not answer would hold its thread for Apple's two minutes.
  nonisolated private static func run(_ source: String, within deadline: TimeInterval) -> [String] {
    let timed = "with timeout of \(Int(deadline.rounded(.up))) seconds\n\(source)\nend timeout"
    guard let script = NSAppleScript(source: timed) else { return [] }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    guard error == nil, let text = result.stringValue else { return [] }
    return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
  }
}
