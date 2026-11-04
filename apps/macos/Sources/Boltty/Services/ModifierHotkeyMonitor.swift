import AppKit
import Carbon
import CoreGraphics

final class ModifierHotkeyMonitor: @unchecked Sendable {
  static let maximumHold: TimeInterval = 1.0

  private static let relevant: CGEventFlags = [
    .maskCommand, .maskAlternate, .maskControl, .maskShift,
  ]

  private let onToggle: @Sendable () -> Void
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var target: CGEventFlags = []
  private var armedAt: TimeInterval?
  private var lastHeld: CGEventFlags = []
  private var spoiled = false
  var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

  func listenForTesting(_ binding: HotkeyBinding) {
    target = Self.flags(fromCarbon: binding.carbonModifiers)
    forgetTheKeyboard()
  }

  init(onToggle: @escaping @Sendable () -> Void) {
    self.onToggle = onToggle
  }

  deinit { stop() }

  // MARK: - Permission

  static var hasAccess: Bool { CGPreflightListenEventAccess() }

  static var availability: HotkeyAvailability {
    hasAccess ? .free : .needsInputMonitoring
  }

  private static let askedKey = "boltty.inputMonitoring.asked"

  static func requestAccess() {
    let defaults = UserDefaults.standard
    let askedBefore = defaults.bool(forKey: askedKey)
    defaults.set(true, forKey: askedKey)
    guard !CGRequestListenEventAccess(), askedBefore,
          let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    else { return }
    NSWorkspace.shared.open(pane)
  }

  // MARK: - Holding it

  func start(_ binding: HotkeyBinding) -> HotkeyAvailability {
    stop()
    guard binding.isModifierOnly else { return .failed(status: -1) }
    guard Self.hasAccess else { return .needsInputMonitoring }
    target = Self.flags(fromCarbon: binding.carbonModifiers)

    let mask: CGEventMask = [
      CGEventType.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ].reduce(0) { $0 | (1 << $1.rawValue) }
    let callback: CGEventTapCallBack = { _, type, event, userInfo in
      if let userInfo {
        Unmanaged<ModifierHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
          .handle(type, event)
      }
      return Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .tailAppendEventTap,
      options: .listenOnly,
      eventsOfInterest: mask,
      callback: callback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else { return .needsInputMonitoring }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    self.tap = tap
    self.source = source
    return .free
  }

  func stop() {
    forgetTheKeyboard()
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
    }
    if let source {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    tap = nil
    source = nil
  }

  var isRunning: Bool { tap != nil }

  // MARK: - Reading the keyboard

  func handle(_ type: CGEventType, _ event: CGEvent) {
    switch type {
    case .flagsChanged:
      let now = now()
      let held = event.flags.intersection(Self.relevant)
      lastHeld = held
      if held.isEmpty {
        if let armedAt, now - armedAt <= Self.maximumHold {
          DispatchQueue.main.async(execute: onToggle)
        }
        armedAt = nil
        spoiled = false
      } else if spoiled {
      } else if let armedAt, now - armedAt > Self.maximumHold {
        spoil()
      } else if held == target {
        armedAt = now
      } else if !target.contains(held) {
        spoil()
      }
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      forgetTheKeyboard()
      lastHeld = CGEventSource.flagsState(.combinedSessionState).intersection(Self.relevant)
      if !lastHeld.isEmpty { spoil() }
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    default:
      if !lastHeld.isEmpty || !event.flags.intersection(Self.relevant).isEmpty {
        spoil()
      }
    }
  }

  private func spoil() {
    armedAt = nil
    spoiled = true
  }

  private func forgetTheKeyboard() {
    armedAt = nil
    lastHeld = []
    spoiled = false
  }

  static func flags(fromCarbon modifiers: UInt32) -> CGEventFlags {
    var flags: CGEventFlags = []
    if modifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
    if modifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
    if modifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
    if modifiers & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
    return flags
  }
}
