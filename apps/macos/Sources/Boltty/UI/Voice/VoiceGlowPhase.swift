import Foundation

enum VoiceGlowPhase: Equatable {
  case idle
  case listening
  case processing
  case completed
  case cancelled
  case failed

  var isAnimating: Bool {
    switch self {
    case .listening, .processing: true
    case .idle, .completed, .cancelled, .failed: false
    }
  }

  var isVisible: Bool {
    switch self {
    case .listening, .processing, .completed: true
    case .idle, .cancelled, .failed: false
    }
  }

  var beamMorph: CGFloat {
    self == .processing ? 1 : 0
  }

  var fadeDuration: TimeInterval {
    switch self {
    case .idle: 0
    case .listening, .processing: AgentPaletteMetrics.voiceGlowFadeDuration
    case .completed: AgentPaletteMetrics.voiceGlowCompletedFadeDuration
    case .cancelled, .failed: AgentPaletteMetrics.voiceGlowAbortFadeDuration
    }
  }

  var releasesFrames: Bool { !isAnimating }
}
