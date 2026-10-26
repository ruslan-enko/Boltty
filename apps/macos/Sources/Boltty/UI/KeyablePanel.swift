import AppKit

final class KeyablePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

final class PassivePanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Private API (CGSSetConnectionProperty): lets a non-frontmost app set the cursor.
@MainActor
enum BackgroundCursor {
  private static var isEnabled = false

  static func enable() {
    guard !isEnabled else { return }
    isEnabled = true
    typealias MainConnection = @convention(c) () -> Int32
    typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    guard
      let handle = dlopen(nil, RTLD_NOW),
      let main = dlsym(handle, "CGSMainConnectionID"),
      let set = dlsym(handle, "CGSSetConnectionProperty")
    else { return }
    let connection = unsafeBitCast(main, to: MainConnection.self)()
    _ = unsafeBitCast(set, to: SetProperty.self)(
      connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue
    )
  }
}
