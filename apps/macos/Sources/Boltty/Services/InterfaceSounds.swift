import AVFoundation
import AudioToolbox
import AppKit
@preconcurrency import UserNotifications

@MainActor
final class InterfaceSounds {
  static let sendVariantNames = ["send-1", "send-2", "send-3"]
  /// The first run's show: the faces' voices (one variant a face), the
  /// air of something flying by, a scene's run of notes, a typed key —
  /// five of each.
  enum FaceSound: String, CaseIterable {
    case hum, whoosh, run, tap
    static let variants = 5
    var names: [String] { (1...Self.variants).map { "\(rawValue)-\($0)" } }
  }
  /// The show's music, under all of it: AAC, forty seconds — longer than a
  /// system sound may be, so it plays through a player of its own.
  static let musicName = "show-music"
  static let doneName = "done"
  static let attentionName = "attention"
  static let fileExtension = "wav"

  private let isEnabled: () -> Bool
  private let bundle: Bundle
  private var music: AVAudioPlayer?
  private let sendSounds: [SystemSoundID]
  private let faceSounds: [FaceSound: [SystemSoundID]]
  private var lastSend: Int?

  init(bundle: Bundle = .main, isEnabled: @escaping () -> Bool) {
    self.isEnabled = isEnabled
    self.bundle = bundle
    sendSounds = Self.systemSounds(Self.sendVariantNames, in: bundle)
    faceSounds = Dictionary(uniqueKeysWithValues: FaceSound.allCases.map {
      ($0, Self.systemSounds($0.names, in: bundle))
    })
  }

  deinit {
    (sendSounds + faceSounds.values.flatMap { $0 }).forEach { AudioServicesDisposeSystemSoundID($0) }
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

  /// The show's music, from its start.
  func startMusic() {
    guard isEnabled(), music == nil,
          let url = bundle.url(forResource: Self.musicName, withExtension: "m4a"),
          let player = try? AVAudioPlayer(contentsOf: url)
    else { return }
    player.volume = 0.8
    player.play()
    music = player
  }

  /// Out over `fade` seconds, then let go.
  func stopMusic(fade: TimeInterval) {
    guard let music else { return }
    music.setVolume(0, fadeDuration: fade)
    DispatchQueue.main.asyncAfter(deadline: .now() + fade) { [weak self] in
      guard let self, self.music === music else { return }
      music.stop()
      self.music = nil
    }
  }

  /// Face `index` of the first run lands, exclaims or flies off.
  func playFace(_ sound: FaceSound, _ index: Int) {
    guard isEnabled(), let sounds = faceSounds[sound], !sounds.isEmpty else { return }
    AudioServicesPlaySystemSound(sounds[index % sounds.count])
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
