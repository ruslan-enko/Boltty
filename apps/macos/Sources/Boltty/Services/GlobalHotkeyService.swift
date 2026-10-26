import Carbon
import Foundation

enum HotkeyAvailability: Equatable, Sendable {
  case free
  case taken
  case failed(status: Int32)
  case needsInputMonitoring

  init(status: OSStatus) {
    switch status {
    case noErr:
      self = .free
    default:
      self = status == OSStatus(eventHotKeyExistsErr) ? .taken : .failed(status: status)
    }
  }

  var isFree: Bool { self == .free }

  func takenSentence(for binding: HotkeyBinding) -> String {
    switch self {
    case .free:
      binding.displayName
    case .taken:
      "\(binding.displayName) is already used by another app."
    case .failed:
      "Boltty could not register \(binding.displayName)."
    case .needsInputMonitoring:
      "\(binding.displayName) needs Input Monitoring: allow Boltty in System Settings › Privacy & Security › Input Monitoring."
    }
  }
}

final class GlobalHotkeyService: @unchecked Sendable {
  private final class ToggleBox {
    let run: @Sendable () -> Void
    init(_ run: @escaping @Sendable () -> Void) { self.run = run }
  }

  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?
  private let onToggle: @Sendable () -> Void
  private var toggleBox: ToggleBox?
  private(set) var isRunning = false
  private lazy var modifierMonitor = ModifierHotkeyMonitor(onToggle: onToggle)

  private static let hotKeySignature: OSType = {
    let sig = "BltY"
    return OSType(sig.utf8.reduce(0) { ($0 << 8) | OSType($1) })
  }()

  private static let probeHotKeyID = EventHotKeyID(signature: hotKeySignature, id: 0xFFFF)

  init(onToggle: @escaping @Sendable () -> Void) {
    self.onToggle = onToggle
  }

  deinit {
    stop()
  }

  // MARK: - Asking before committing

  func probe(_ hotkey: HotkeyBinding) -> HotkeyAvailability {
    if hotkey.isModifierOnly { return ModifierHotkeyMonitor.availability }
    guard installHandler() else { return .failed(status: -1) }
    var scratch: EventHotKeyRef?
    let status = RegisterEventHotKey(
      hotkey.keyCode,
      hotkey.carbonModifiers,
      Self.probeHotKeyID,
      GetApplicationEventTarget(),
      0,
      &scratch
    )
    if let scratch {
      UnregisterEventHotKey(scratch)
    }
    return HotkeyAvailability(status: status)
  }

  // MARK: - Holding it

  @discardableResult
  func register(_ hotkey: HotkeyBinding) -> HotkeyAvailability {
    guard !isRunning else { return .free }
    if hotkey.isModifierOnly {
      let availability = modifierMonitor.start(hotkey)
      isRunning = availability.isFree
      return availability
    }
    guard installHandler() else { return .failed(status: -1) }

    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(
      hotkey.keyCode,
      hotkey.carbonModifiers,
      EventHotKeyID(signature: Self.hotKeySignature, id: 1),
      GetApplicationEventTarget(),
      0,
      &reference
    )
    let availability = HotkeyAvailability(status: status)
    if availability.isFree {
      hotKeyRef = reference
      isRunning = true
    }
    return availability
  }

  func stop() {
    unregisterHotkey()
    removeHandler()
  }

  @discardableResult
  func updateHotkey(_ hotkey: HotkeyBinding) -> HotkeyAvailability {
    unregisterHotkey()
    return register(hotkey)
  }

  @discardableResult
  func takeOver(with hotkey: HotkeyBinding) -> HotkeyAvailability {
    guard hotkey.isModifierOnly else { return .failed(status: -1) }
    let availability = modifierMonitor.start(hotkey)
    guard availability.isFree else { return availability }
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    isRunning = true
    return availability
  }

  // MARK: - Carbon plumbing

  private func unregisterHotkey() {
    modifierMonitor.stop()
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    isRunning = false
  }

  private func installHandler() -> Bool {
    if handlerRef != nil { return true }

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )

    let callback: @convention(c) (
      EventHandlerCallRef?,
      EventRef?,
      UnsafeMutableRawPointer?
    ) -> OSStatus = { _, event, userData in
      guard let userData, let event else { return noErr }
      let box = Unmanaged<ToggleBox>.fromOpaque(userData).takeUnretainedValue()
      var hotKeyID = EventHotKeyID()
      let err = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
      )
      guard err == noErr, hotKeyID.signature == GlobalHotkeyService.hotKeySignature else {
        return noErr
      }
      DispatchQueue.main.async(execute: box.run)
      return noErr
    }

    let box = ToggleBox(onToggle)
    guard InstallEventHandler(
      GetApplicationEventTarget(),
      callback,
      1,
      &eventType,
      Unmanaged.passUnretained(box).toOpaque(),
      &handlerRef
    ) == noErr else {
      return false
    }
    toggleBox = box
    return true
  }

  private func removeHandler() {
    if let handlerRef {
      RemoveEventHandler(handlerRef)
      self.handlerRef = nil
    }
    toggleBox = nil
  }
}
