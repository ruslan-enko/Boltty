import AppKit

@MainActor
final class FinderSelectionService {
  nonisolated static let finderBundleID = "com.apple.finder"

  enum Authorization: Equatable {
    case notDetermined
    case authorized
    case denied
  }

  var readSelection: (@Sendable () async -> [URL])?
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
    guard authorization() != .denied else { return [] }
    return await Task.detached(priority: .userInitiated) {
      Self.runAppleScript()
    }.value
  }

  nonisolated private static func runAppleScript() -> [URL] {
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
    guard let script = NSAppleScript(source: source) else { return [] }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    guard error == nil, let text = result.stringValue else { return [] }
    return text
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .map { URL(fileURLWithPath: $0) }
  }
}
