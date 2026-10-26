import AppKit
import AVFoundation
import Speech
import UserNotifications

enum AccessKind: String, CaseIterable, Identifiable, Sendable {
  case dictation
  case screen
  case notifications
  case finder

  var id: String { rawValue }

  var title: String {
    switch self {
    case .dictation: "Microphone"
    case .screen: "Screen Recording"
    case .notifications: "Notifications"
    case .finder: "Finder"
    }
  }

  var purpose: String {
    switch self {
    case .dictation: "Speak a prompt instead of typing it."
    case .screen: "Ask about a part of the screen you select."
    case .notifications: "Know when a reply is ready or an agent needs you."
    case .finder: "Talk about the files you have selected."
    }
  }

  var settingsPane: URL? {
    let anchor: String
    switch self {
    case .dictation: anchor = "com.apple.preference.security?Privacy_Microphone"
    case .screen: anchor = "com.apple.preference.security?Privacy_ScreenCapture"
    case .notifications: anchor = "com.apple.Notifications-Settings.extension"
    case .finder: anchor = "com.apple.preference.security?Privacy_Automation"
    }
    return URL(string: "x-apple.systempreferences:\(anchor)")
  }
}

enum AccessStatus: Equatable, Sendable {
  case notAsked
  case allowed
  case refused
}

@MainActor
struct AccessProbe {
  var status: (AccessKind) async -> AccessStatus
  var request: (AccessKind) async -> AccessStatus

  static var live: AccessProbe {
    AccessProbe(
      status: { kind in await LiveAccess.status(kind) },
      request: { kind in await LiveAccess.request(kind) }
    )
  }
}

@MainActor
enum LiveAccess {
  static let screenAskedKey = "boltty.screenRecording.asked"

  static func status(_ kind: AccessKind) async -> AccessStatus {
    switch kind {
    case .dictation:
      return dictationStatus()
    case .screen:
      if CGPreflightScreenCaptureAccess() { return .allowed }
      return UserDefaults.standard.bool(forKey: screenAskedKey) ? .refused : .notAsked
    case .notifications:
      switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
      case .authorized, .provisional, .ephemeral: return .allowed
      case .notDetermined: return .notAsked
      case .denied: return .refused
      @unknown default: return .refused
      }
    case .finder:
      switch FinderSelectionService().authorization() {
      case .authorized: return .allowed
      case .notDetermined: return .notAsked
      case .denied: return .refused
      }
    }
  }

  static func request(_ kind: AccessKind) async -> AccessStatus {
    switch kind {
    case .dictation:
      if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
      }
      if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
        await requestSpeechRecognition()
      }
    case .screen:
      _ = requestScreenRecording()
    case .notifications:
      _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    case .finder:
      await Task.detached(priority: .userInitiated) { askFinder() }.value
    }
    return await status(kind)
  }

  nonisolated private static func requestSpeechRecognition() async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      SFSpeechRecognizer.requestAuthorization { @Sendable _ in done.resume() }
    }
  }

  static func requestScreenRecording() -> Bool {
    UserDefaults.standard.set(true, forKey: screenAskedKey)
    return CGRequestScreenCaptureAccess()
  }

  private static func dictationStatus() -> AccessStatus {
    let microphone: AccessStatus = {
      switch AVCaptureDevice.authorizationStatus(for: .audio) {
      case .authorized: return .allowed
      case .notDetermined: return .notAsked
      default: return .refused
      }
    }()
    let speech: AccessStatus = {
      switch SFSpeechRecognizer.authorizationStatus() {
      case .authorized: return .allowed
      case .notDetermined: return .notAsked
      default: return .refused
      }
    }()
    return AccessStatus.combined([microphone, speech])
  }

  nonisolated private static func askFinder() {
    var address = AEAddressDesc()
    let bundleID = FinderSelectionService.finderBundleID
    let created: OSStatus = bundleID.withCString { pointer in
      OSStatus(AECreateDesc(AEKeyword(typeApplicationBundleID), pointer, bundleID.utf8.count, &address))
    }
    guard created == noErr else { return }
    defer { AEDisposeDesc(&address) }
    _ = AEDeterminePermissionToAutomateTarget(
      &address, AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
  }
}

extension AccessStatus {
  static func combined(_ parts: [AccessStatus]) -> AccessStatus {
    if parts.contains(.refused) { return .refused }
    if parts.allSatisfy({ $0 == .allowed }) { return .allowed }
    return .notAsked
  }
}
