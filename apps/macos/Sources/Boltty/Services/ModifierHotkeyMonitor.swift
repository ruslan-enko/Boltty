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

/// Ask Boltty's chord: three modifiers held with nothing else. Held for `holdDelay`
/// it begins; let go it ends; a key, a click or a fourth modifier while held
/// cancels it. A quick press never begins, so the ⌃⌥⌘ chords of other apps
/// (window managers) pass by untouched. Listen-only, like the launch chord.
/// Escape pressed alone is told (`onEscape`), so an answer can be called off;
/// that is the one key it reads by its code, and only to compare with Escape.
final class ModifierHoldMonitor: @unchecked Sendable {
  static let holdDelay: TimeInterval = 0.25
  static let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

  enum State: Equatable {
    case idle
    case arming(Int)
    case holding
    /// Something else was pressed; nothing happens until every modifier is up.
    case spent
  }

  var onBegin: (() -> Void)?
  var onEnd: (() -> Void)?
  var onCancel: (() -> Void)?
  /// Escape with no modifier held, outside a hold.
  var onEscape: (() -> Void)?
  var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private(set) var state: State = .idle
  private var target: CGEventFlags = []
  private var generation = 0
  private var held: CGEventFlags = []
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?

  init(chord: CGEventFlags) {
    target = chord.intersection(Self.relevant)
  }

  deinit { stop() }

  var isRunning: Bool { tap != nil }

  func start() -> HotkeyAvailability {
    stop()
    guard ModifierHotkeyMonitor.hasAccess else { return .needsInputMonitoring }
    let mask: CGEventMask = [
      CGEventType.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ].reduce(0) { $0 | (1 << $1.rawValue) }
    let callback: CGEventTapCallBack = { _, type, event, userInfo in
      if let userInfo {
        Unmanaged<ModifierHoldMonitor>.fromOpaque(userInfo).takeUnretainedValue()
          .handle(type, event)
      }
      return Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
      eventsOfInterest: mask, callback: callback,
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
    if state == .holding { onCancel?() }
    state = .idle
    held = []
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
    }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    tap = nil
    source = nil
  }

  private func handle(_ type: CGEventType, _ event: CGEvent) {
    switch type {
    case .flagsChanged:
      modifiers(event.flags.intersection(Self.relevant))
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      if state == .holding { onCancel?() }
      held = CGEventSource.flagsState(.combinedSessionState).intersection(Self.relevant)
      state = held.isEmpty ? .idle : .spent
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    case .keyDown where held.isEmpty && state == .idle
      && event.getIntegerValueField(.keyboardEventKeycode) == 53:
      onEscape?()
    default:
      otherInput()
    }
  }

  /// The modifiers now held.
  func modifiers(_ now: CGEventFlags) {
    held = now
    if now.isEmpty {
      if state == .holding { onEnd?() }
      state = .idle
      return
    }
    switch state {
    case .spent:
      return
    case .holding:
      guard now != target else { return }
      // Letting go of one of the three is letting go; adding a fourth is not Ask Boltty.
      if target.isSuperset(of: now) { onEnd?() } else { onCancel?() }
      state = .spent
    case .idle, .arming:
      if now == target {
        guard case .idle = state else { return }
        generation += 1
        let armed = generation
        state = .arming(armed)
        schedule(Self.holdDelay) { [weak self] in
          guard let self, self.state == .arming(armed), self.held == self.target else { return }
          self.state = .holding
          self.onBegin?()
        }
      } else if target.isSuperset(of: now) {
        state = .idle
      } else {
        state = .spent
      }
    }
  }

  /// A key or a click.
  func otherInput() {
    switch state {
    case .holding:
      onCancel?()
      state = .spent
    case .arming:
      state = .spent
    case .idle:
      if !held.isEmpty { state = .spent }
    case .spent:
      break
    }
  }
}
