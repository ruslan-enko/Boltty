import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct MacApp: Equatable, Sendable {
  let pid: pid_t
  let name: String
  let bundleID: String?

  var key: String { bundleID ?? name }
}

struct MacReading: @unchecked Sendable {
  var text: String
  var picture: Data?
}

enum MacControlError: Error, Equatable {
  case refused(String)
}

// Every Accessibility call blocks on another app's answer: all of them run on this queue.
final class MacControl: @unchecked Sendable {
  private let queue = DispatchQueue(label: "boltty.computer-use", qos: .userInitiated)
  private var elements: [pid_t: [AXUIElement]] = [:]
  private var geometry: [pid_t: Geometry] = [:]

  private struct Geometry {
    var window: CGRect
    var factor: CGFloat
  }

  static let pictureLongSide: CGFloat = 1280
  static let elementLimit = 500
  static let settle: TimeInterval = 0.45

  static let refusedBundles: Set<String> = [
    "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
    "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
    "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password",
    "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.lastpass.LastPass",
    "com.apple.systempreferences", "com.apple.ScriptEditor2", "com.apple.Automator",
    "com.apple.shortcuts", "com.apple.SecurityAgent", "com.apple.loginwindow",
  ]

  static func isRefused(_ bundleID: String?) -> Bool {
    guard let bundleID else { return false }
    return refusedBundles.contains(bundleID) || bundleID.hasPrefix("com.boltty.")
  }

  static var isTrusted: Bool { AXIsProcessTrusted() }

  static func askForTrust() {
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
  }


  static func runningApps() -> [MacApp] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular && !$0.isTerminated }
      .map { MacApp(pid: $0.processIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "?", bundleID: $0.bundleIdentifier) }
  }

  static func find(_ wanted: String) -> MacApp? {
    let name = wanted.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let apps = runningApps()
    return apps.first { $0.bundleID?.lowercased() == name }
      ?? apps.first { $0.name.lowercased() == name }
      ?? apps.first { $0.name.lowercased().hasPrefix(name) }
  }

  static func applicationURL(named wanted: String) -> URL? {
    let name = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
      return url
    }
    let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                   NSHomeDirectory() + "/Applications", "/Applications/Utilities"]
    let file = name.hasSuffix(".app") ? name : name + ".app"
    for folder in folders {
      let url = URL(fileURLWithPath: folder).appendingPathComponent(file)
      if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    for folder in folders {
      let listed = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
      if let match = listed.first(where: { $0.lowercased() == file.lowercased() }) {
        return URL(fileURLWithPath: folder).appendingPathComponent(match)
      }
    }
    return nil
  }

  static func bundleID(of url: URL) -> String? { Bundle(url: url)?.bundleIdentifier }

  static func open(_ url: URL) async throws -> MacApp {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    let running = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    for _ in 0..<40 where !running.isFinishedLaunching {
      try? await Task.sleep(for: .milliseconds(100))
    }
    return MacApp(
      pid: running.processIdentifier, name: running.localizedName ?? url.deletingPathExtension().lastPathComponent,
      bundleID: running.bundleIdentifier)
  }


  func read(_ app: MacApp) async -> MacReading {
    let tree = await onQueue { self.readTree(app) }
    var picture: Data?
    var note = ""
    if let frame = tree.window {
      switch await Self.capture(pid: app.pid, frame: frame) {
      case let .success(shot):
        picture = shot.data
        let factor = shot.factor
        await onQueue { self.geometry[app.pid] = Geometry(window: frame, factor: factor) }
      case let .failure(reason):
        note = "\n\n" + reason.reason
      }
    }
    let (lines, header) = await onQueue { () -> ([String], String) in
      let factor = self.geometry[app.pid]?.factor ?? 1
      return (tree.lines(factor: factor), tree.header(app: app, factor: factor))
    }
    return MacReading(text: header + "\n" + lines.joined(separator: "\n") + note, picture: picture)
  }

  private struct Tree: @unchecked Sendable {
    var window: CGRect?
    var title: String?
    var focused: Int?
    var nodes: [Node]

    struct Node {
      var depth: Int
      var role: String
      var label: String
      var frame: CGRect?
      var pressable: Bool
    }

    func header(app: MacApp, factor: CGFloat) -> String {
      var line = "App: \(app.name)"
      if let bundle = app.bundleID { line += " (\(bundle))" }
      if let title, !title.isEmpty { line += "\nWindow: \(title)" }
      if let window {
        let width = Int((window.width * factor).rounded()), height = Int((window.height * factor).rounded())
        line += "\nThe picture is the window, \(width) × \(height); x and y below are in its pixels, from its top left."
      } else {
        line += "\nThis app has no window open."
      }
      if let focused { line += "\nFocused element: \(focused)" }
      line += "\nElements (index, role, words, x y width height):"
      return line
    }

    func lines(factor: CGFloat) -> [String] {
      nodes.enumerated().map { index, node in
        var line = String(repeating: "  ", count: min(node.depth, 12)) + "\(index) \(node.role)"
        if !node.label.isEmpty { line += " \(node.label)" }
        if let frame = node.frame, let window {
          let x = Int(((frame.minX - window.minX) * factor).rounded())
          let y = Int(((frame.minY - window.minY) * factor).rounded())
          line += " @ \(x) \(y) \(Int((frame.width * factor).rounded())) \(Int((frame.height * factor).rounded()))"
        }
        return line
      }
    }
  }

  private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]

  private static let shownRoles: Set<String> = [
    "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
    "AXMenuButton", "AXLink", "AXTab", "AXSlider", "AXComboBox", "AXSearchField", "AXStaticText",
    "AXHeading", "AXMenuItem", "AXMenuBarItem", "AXCell", "AXRow", "AXImage", "AXDisclosureTriangle",
    "AXIncrementor", "AXColorWell", "AXSwitch", "AXToggle", "AXSegmentedControl", "AXDateField",
  ]

  private func readTree(_ app: MacApp) -> Tree {
    let root = AXUIElementCreateApplication(app.pid)
    AXUIElementSetMessagingTimeout(root, 1.5)
    AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    let window: AXUIElement? = Self.attribute(root, kAXFocusedWindowAttribute)
      ?? Self.attribute(root, kAXMainWindowAttribute)
      ?? (Self.attribute(root, kAXWindowsAttribute) as [AXUIElement]?)?.first
    let focusedElement: AXUIElement? = Self.attribute(root, kAXFocusedUIElementAttribute)
    var tree = Tree(window: window.flatMap(Self.frame), title: window.flatMap { Self.attribute($0, kAXTitleAttribute) }, nodes: [])
    var found: [AXUIElement] = []
    func walk(_ element: AXUIElement, depth: Int) {
      guard found.count < Self.elementLimit, depth < 40 else { return }
      let role: String = Self.attribute(element, kAXRoleAttribute) ?? ""
      let frame = Self.frame(element)
      if let frame, frame.width < 1 || frame.height < 1, role != "AXWindow" { return }
      let label = Self.label(of: element, role: role)
      let actions = Self.actions(of: element)
      let shown = Self.shownRoles.contains(role) && (!label.isEmpty || !actions.isEmpty || role.hasSuffix("Field") || role == "AXTextArea")
      var childDepth = depth
      if shown {
        if let focusedElement, CFEqual(focusedElement, element) { tree.focused = found.count }
        tree.nodes.append(Tree.Node(
          depth: depth, role: role.replacingOccurrences(of: "AX", with: "").lowercased(),
          label: label, frame: frame, pressable: !actions.isEmpty))
        found.append(element)
        childDepth += 1
      }
      if role == "AXSecureTextField" { return }
      let children: [AXUIElement] = Self.attribute(element, kAXChildrenAttribute) ?? []
      for child in children { walk(child, depth: childDepth) }
    }
    if let window { walk(window, depth: 0) }
    if let menuBar: AXUIElement = Self.attribute(root, kAXMenuBarAttribute), found.count < Self.elementLimit {
      let items: [AXUIElement] = Self.attribute(menuBar, kAXChildrenAttribute) ?? []
      for item in items.dropFirst() {
        let title: String = Self.attribute(item, kAXTitleAttribute) ?? ""
        guard !title.isEmpty else { continue }
        tree.nodes.append(Tree.Node(depth: 0, role: "menu", label: "\"\(title)\"", frame: nil, pressable: true))
        found.append(item)
      }
    }
    elements[app.pid] = found
    return tree
  }

  private static func label(of element: AXUIElement, role: String) -> String {
    if role == "AXSecureTextField" { return "(password field: never typed into)" }
    var words: [String] = []
    for name in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute] {
      if let text: String = attribute(element, name), !text.isEmpty, !words.contains(text) { words.append(text) }
      if words.count == 2 { break }
    }
    var label = words.map { "\"\(clip($0, 90))\"" }.joined(separator: " ")
    if let value: AnyObject = attribute(element, kAXValueAttribute) {
      if let text = value as? String, !text.isEmpty, !words.contains(text) {
        label += (label.isEmpty ? "" : " ") + "value \"\(clip(text, 160))\""
      } else if let number = value as? NSNumber, role != "AXStaticText" {
        label += (label.isEmpty ? "" : " ") + "value \(number)"
      }
    }
    if let enabled: Bool = attribute(element, kAXEnabledAttribute), !enabled { label += " (disabled)" }
    return label
  }

  private static func clip(_ text: String, _ limit: Int) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
  }


  func click(_ app: MacApp, element index: Int?, at point: CGPoint?, right: Bool, count: Int) async throws -> String {
    try await onQueue {
      try self.ensureRunning(app)
      let target: AXUIElement
      let screenPoint: CGPoint
      if let index {
        target = try self.element(index, of: app)
        guard let frame = Self.frame(target) else { throw MacControlError.refused("Element \(index) has no place on the screen.") }
        screenPoint = CGPoint(x: frame.midX, y: frame.midY)
      } else if let point {
        screenPoint = try self.screenPoint(point, of: app)
        let root = AXUIElementCreateApplication(app.pid)
        var hit: AXUIElement?
        AXUIElementCopyElementAtPosition(root, Float(screenPoint.x), Float(screenPoint.y), &hit)
        guard let hit else { return try self.syntheticClick(app, at: screenPoint, right: right, count: count) }
        target = hit
      } else {
        throw MacControlError.refused("Give an element index or x and y.")
      }
      let role: String = Self.attribute(target, kAXRoleAttribute) ?? ""
      if count == 1, !right, Self.textRoles.contains(role),
         AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
        return "Put the caret in it."
      }
      if count == 1 {
        let wanted = right ? [kAXShowMenuAction] : [kAXPressAction, kAXConfirmAction, kAXPickAction, "AXOpen"]
        var current: AXUIElement? = target
        for _ in 0..<5 {
          guard let element = current else { break }
          let offered = Self.actions(of: element)
          if let action = wanted.first(where: offered.contains),
             AXUIElementPerformAction(element, action as CFString) == .success {
            return right ? "Opened its menu." : "Pressed."
          }
          current = Self.attribute(element, kAXParentAttribute)
        }
      }
      return try self.syntheticClick(app, at: screenPoint, right: right, count: count)
    }
  }

  private func syntheticClick(_ app: MacApp, at point: CGPoint, right: Bool, count: Int) throws -> String {
    NSRunningApplication(processIdentifier: app.pid)?.activate()
    Thread.sleep(forTimeInterval: 0.15)
    let back = CGEvent(source: nil)?.location
    let (down, up, button): (CGEventType, CGEventType, CGMouseButton) = right
      ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
    for click in 1...max(1, min(count, 3)) {
      for type in [down, up] {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
        event?.post(tap: .cghidEventTap)
      }
    }
    if let back { CGWarpMouseCursorPosition(back) }
    return "Clicked at the point (\(app.name) came to the front for it)."
  }

  func type(_ app: MacApp, text: String, into index: Int?) async throws -> String {
    try await onQueue {
      try self.ensureRunning(app)
      let root = AXUIElementCreateApplication(app.pid)
      if let index {
        let element = try self.element(index, of: app)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
      }
      let focused: AXUIElement? = Self.attribute(root, kAXFocusedUIElementAttribute)
      if let focused {
        let role: String = Self.attribute(focused, kAXRoleAttribute) ?? ""
        let subrole: String = Self.attribute(focused, kAXSubroleAttribute) ?? ""
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
          throw MacControlError.refused("That is a password field. Ask the person to type it themselves.")
        }
        let before: String? = Self.attribute(focused, kAXValueAttribute)
        if AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFString) == .success,
           let after: String = Self.attribute(focused, kAXValueAttribute), after != before, after.contains(text) {
          return "Typed."
        }
      }
      for chunk in Self.chunks(of: text) {
        let units = Array(chunk.utf16)
        for down in [true, false] {
          let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
          units.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
          event?.postToPid(app.pid)
        }
        Thread.sleep(forTimeInterval: 0.01)
      }
      return "Typed as keystrokes."
    }
  }

  private static func chunks(of text: String) -> [String] {
    var chunks: [String] = []
    var current = ""
    for character in text {
      if character == "\n" || character == "\r" {
        if !current.isEmpty { chunks.append(current) }
        chunks.append("\r")
        current = ""
        continue
      }
      current.append(character)
      if current.utf16.count >= 16 {
        chunks.append(current)
        current = ""
      }
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
  }

  func setValue(_ app: MacApp, element index: Int, value: String) async throws -> String {
    try await onQueue {
      try self.ensureRunning(app)
      let element = try self.element(index, of: app)
      let role: String = Self.attribute(element, kAXRoleAttribute) ?? ""
      if role == "AXSecureTextField" {
        throw MacControlError.refused("That is a password field. Ask the person to type it themselves.")
      }
      let current: AnyObject? = Self.attribute(element, kAXValueAttribute)
      let wanted: CFTypeRef = current is NSNumber ? (Double(value).map { NSNumber(value: $0) } ?? value as NSString) : value as NSString
      guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, wanted) == .success else {
        throw MacControlError.refused("\(app.name) did not take that value. Click the field and type instead.")
      }
      return "Set."
    }
  }

  func press(_ app: MacApp, keys: String) async throws -> String {
    guard let (code, flags) = Self.keyChord(keys) else {
      throw MacControlError.refused("Boltty does not know the key \"\(keys)\". Write keys like cmd+s, return, tab, escape, down, shift+tab.")
    }
    return try await onQueue {
      try self.ensureRunning(app)
      for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.postToPid(app.pid)
      }
      return "Pressed \(keys)."
    }
  }

  func scroll(_ app: MacApp, element index: Int?, at point: CGPoint?, direction: String, amount: Int) async throws -> String {
    try await onQueue {
      try self.ensureRunning(app)
      let screenPoint: CGPoint
      if let index, let frame = Self.frame(try self.element(index, of: app)) {
        screenPoint = CGPoint(x: frame.midX, y: frame.midY)
      } else if let point {
        screenPoint = try self.screenPoint(point, of: app)
      } else if let window = self.geometry[app.pid]?.window {
        screenPoint = CGPoint(x: window.midX, y: window.midY)
      } else {
        throw MacControlError.refused("Read the app first, then scroll at an element or a point.")
      }
      let lines = Int32(max(1, min(amount, 25)) * 3)
      let (dy, dx): (Int32, Int32) = switch direction.lowercased() {
      case "up": (lines, 0)
      case "left": (0, lines)
      case "right": (0, -lines)
      default: (-lines, 0)
      }
      let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
      event?.location = screenPoint
      event?.postToPid(app.pid)
      return "Scrolled \(direction)."
    }
  }


  private func ensureRunning(_ app: MacApp) throws {
    guard NSRunningApplication(processIdentifier: app.pid)?.isTerminated == false else {
      throw MacControlError.refused("\(app.name) is no longer running.")
    }
  }

  private func element(_ index: Int, of app: MacApp) throws -> AXUIElement {
    guard let found = elements[app.pid] else {
      throw MacControlError.refused("Read \(app.name) with get_app_state first: element numbers come from it.")
    }
    guard found.indices.contains(index) else {
      throw MacControlError.refused("There is no element \(index) in the last reading of \(app.name). Read it again.")
    }
    return found[index]
  }

  private func screenPoint(_ point: CGPoint, of app: MacApp) throws -> CGPoint {
    guard let shape = geometry[app.pid] else {
      throw MacControlError.refused("Read \(app.name) with get_app_state first: x and y are in its picture.")
    }
    return CGPoint(x: shape.window.minX + point.x / shape.factor, y: shape.window.minY + point.y / shape.factor)
  }

  private func onQueue<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result { try work() }) }
    }
  }

  private func onQueue<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: work()) }
    }
  }

  private static func attribute<Value>(_ element: AXUIElement, _ name: String) -> Value? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
    return value as? Value
  }

  private static func actions(of element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return (names as? [String]) ?? []
  }

  private static func frame(_ element: AXUIElement) -> CGRect? {
    guard let position: AXValue = attribute(element, kAXPositionAttribute),
          let size: AXValue = attribute(element, kAXSizeAttribute)
    else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
    return CGRect(origin: origin, size: extent)
  }


  private struct Shot: @unchecked Sendable {
    var data: Data
    var factor: CGFloat
  }

  private static func capture(pid: pid_t, frame: CGRect) async -> Result<Shot, CaptureFailure> {
    guard CGPreflightScreenCaptureAccess() else {
      return .failure(CaptureFailure("No picture: Boltty is not allowed to record the screen. Work from the elements."))
    }
    guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
          let window = content.windows
            .filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 })
            .min(by: { distance($0.frame, frame) < distance($1.frame, frame) })
    else {
      return .failure(CaptureFailure("No picture: the window is not on screen (minimised, or in another space)."))
    }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = SCStreamConfiguration()
    let pixels = CGFloat(filter.pointPixelScale)
    let factor = min(pixels, pictureLongSide / max(window.frame.width, window.frame.height, 1))
    configuration.width = max(1, Int((window.frame.width * factor).rounded()))
    configuration.height = max(1, Int((window.frame.height * factor).rounded()))
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
          let data = jpeg(image)
    else { return .failure(CaptureFailure("No picture: the window could not be captured.")) }
    return .success(Shot(data: data, factor: factor))
  }

  private struct CaptureFailure: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
  }

  private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
    abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
  }

  private static func jpeg(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }


  static func keyChord(_ written: String) -> (CGKeyCode, CGEventFlags)? {
    let parts = written.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
    guard let key = parts.last, !key.isEmpty else { return nil }
    var flags: CGEventFlags = []
    for modifier in parts.dropLast() {
      switch modifier {
      case "cmd", "command", "⌘", "meta", "super": flags.insert(.maskCommand)
      case "shift", "⇧": flags.insert(.maskShift)
      case "alt", "option", "opt", "⌥": flags.insert(.maskAlternate)
      case "ctrl", "control", "⌃": flags.insert(.maskControl)
      case "fn": flags.insert(.maskSecondaryFn)
      default: return nil
      }
    }
    guard let code = keyCodes[key] else { return nil }
    return (CGKeyCode(code), flags)
  }

  private static let keyCodes: [String: Int] = {
    var codes: [String: Int] = [
      "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space,
      "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
      "escape": kVK_Escape, "esc": kVK_Escape, "up": kVK_UpArrow, "down": kVK_DownArrow,
      "left": kVK_LeftArrow, "right": kVK_RightArrow, "home": kVK_Home, "end": kVK_End,
      "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
      "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
      ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
      "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
    ]
    let letters: [Int] = [
      kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
      kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P,
      kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
      kVK_ANSI_Y, kVK_ANSI_Z,
    ]
    for (offset, code) in letters.enumerated() {
      codes[String(UnicodeScalar(UInt8(97 + offset)))] = code
    }
    let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                  kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
    for (digit, code) in digits.enumerated() { codes["\(digit)"] = code }
    let functions = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
    for (offset, code) in functions.enumerated() { codes["f\(offset + 1)"] = code }
    return codes
  }()
}
