import Foundation

struct VoiceSilenceWatcher {
  var threshold: TimeInterval
  var envelope: VoiceLevelEnvelope

  private(set) var hasHeardSpeech = false
  private(set) var silenceBegan: TimeInterval?

  init(
    threshold: TimeInterval = AgentPaletteMetrics.voiceSilenceSubmitDelay,
    envelope: VoiceLevelEnvelope = VoiceLevelEnvelope()
  ) {
    self.threshold = threshold
    self.envelope = envelope
  }

  mutating func accept(level: CGFloat, now: TimeInterval) -> Bool {
    let isSpeech = envelope.gated(level) > 0
    guard !isSpeech else {
      hasHeardSpeech = true
      silenceBegan = nil
      return false
    }
    guard hasHeardSpeech else { return false }
    guard let began = silenceBegan else {
      silenceBegan = now
      return false
    }
    return now - began >= threshold
  }

  func progress(now: TimeInterval) -> CGFloat {
    guard hasHeardSpeech, let began = silenceBegan, threshold > 0 else { return 0 }
    return min(1, max(0, CGFloat((now - began) / threshold)))
  }

  mutating func reset() {
    hasHeardSpeech = false
    silenceBegan = nil
    envelope.reset()
  }
}
