import AudioToolbox
import AppKit
@preconcurrency import UserNotifications

@MainActor
final class InterfaceSounds {
  static let sendVariantNames = ["send-1", "send-2", "send-3"]
  static let humNames = (1...5).map { "hum-\($0)" }
  static let doneName = "done"
  static let attentionName = "attention"
  static let fileExtension = "wav"

  private let isEnabled: () -> Bool
  private let sendSounds: [SystemSoundID]
  private let humSounds: [SystemSoundID]
  private var lastSend: Int?

  init(bundle: Bundle = .main, isEnabled: @escaping () -> Bool) {
    self.isEnabled = isEnabled
    sendSounds = Self.systemSounds(Self.sendVariantNames, in: bundle)
    humSounds = Self.systemSounds(Self.humNames, in: bundle)
  }

  deinit {
    (sendSounds + humSounds).forEach { AudioServicesDisposeSystemSoundID($0) }
  }

  private static func systemSounds(_ names: [String], in bundle: Bundle) -> [SystemSoundID] {
    names.compactMap { name in
      guard let url = bundle.url(forResource: name, withExtension: fileExtension) else { return nil }
      var id: SystemSoundID = 0
      guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return nil }
      var isUISound: UInt32 = 1
      AudioServicesSetProperty(
        kAudioServicesPropertyIsUISound, UInt32(MemoryLayout<SystemSoundID>.size), &id,
        UInt32(MemoryLayout<UInt32>.size), &isUISound
      )
      return id
    }
  }

  func playHum(_ index: Int) {
    guard isEnabled(), !humSounds.isEmpty else { return }
    AudioServicesPlaySystemSound(humSounds[index % humSounds.count])
  }

  func playRefused() {
    guard isEnabled() else { return }
    NSSound.beep()
  }

  func playSend() {
    guard isEnabled(), !sendSounds.isEmpty else { return }
    let index = Self.nextVariant(after: lastSend, count: sendSounds.count)
    lastSend = index
    AudioServicesPlaySystemSound(sendSounds[index])
  }

  func notificationSound(for kind: SystemAttentionNotification.Kind) -> UNNotificationSound? {
    guard isEnabled() else { return nil }
    let name = switch kind {
    case .finished: Self.doneName
    case .needsYou: Self.attentionName
    }
    return UNNotificationSound(named: UNNotificationSoundName("\(name).\(Self.fileExtension)"))
  }

  static func nextVariant(
    after last: Int?, count: Int, random: (Range<Int>) -> Int = { Int.random(in: $0) }
  ) -> Int {
    guard count > 1, let last, (0..<count).contains(last) else { return random(0..<count) }
    let drawn = random(0..<(count - 1))
    return drawn >= last ? drawn + 1 : drawn
  }
}
