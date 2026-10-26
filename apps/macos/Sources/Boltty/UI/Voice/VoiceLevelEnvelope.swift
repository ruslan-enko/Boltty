import Foundation

struct VoiceLevelEnvelope {
  var attack: CGFloat
  var release: CGFloat
  var gate: CGFloat
  var knee: CGFloat

  private(set) var level: CGFloat = 0

  init(
    attack: CGFloat = AgentPaletteMetrics.voiceGlowAttack,
    release: CGFloat = AgentPaletteMetrics.voiceGlowRelease,
    gate: CGFloat = AgentPaletteMetrics.voiceGlowGate,
    knee: CGFloat = AgentPaletteMetrics.voiceGlowGateKnee
  ) {
    self.attack = attack
    self.release = release
    self.gate = gate
    self.knee = knee
  }

  func gated(_ raw: CGFloat) -> CGFloat {
    let clamped = min(1, max(0, raw))
    guard knee > 0 else { return clamped <= gate ? 0 : clamped }
    let t = min(1, max(0, (clamped - gate) / knee))
    return clamped * (t * t * (3 - 2 * t))
  }

  @discardableResult
  mutating func accept(_ raw: CGFloat, dt: CGFloat) -> CGFloat {
    let target = gated(raw)
    let tau = target > level ? attack : release
    let alpha = 1 - exp(-max(0, dt) / max(0.001, tau))
    level += (target - level) * alpha
    level = min(1, max(0, level))
    return level
  }

  mutating func reset() {
    level = 0
  }

  mutating func settle(at value: CGFloat) {
    level = min(1, max(0, value))
  }
}
