// The greedy TDT loop is ported from FluidAudio's TdtDecoderV3
// (github.com/FluidInference/FluidAudio, Apache-2.0), which follows NVIDIA
// NeMo's greedy TDT decoding.

import Foundation

/// Greedy decoding for a token-and-duration transducer: at each encoder
/// frame the joint names a token (or blank) and how many frames to move on.
/// The predictor — an LSTM over the tokens said so far — only steps when a
/// real token is emitted.
///
/// The models are behind closures so the loop is tested without Core ML.
struct ParakeetTDT<State> {
  struct Decision: Equatable {
    var token: Int
    /// Frames to move on: 0 means "another token here".
    var duration: Int
  }

  struct Token: Equatable {
    var id: Int
    /// The encoder frame (80 ms each) it was emitted at, counted from the
    /// start of the audio.
    var frame: Int
  }

  /// The predictor's memory between windows of one take.
  struct Memory {
    var state: State
    /// The predictor's output for the last token, fed to the joint next.
    var projection: [Float]
  }

  static var blank: Int { 8192 }
  /// The duration head's bins are frame counts.
  static var durations: [Int] { [0, 1, 2, 3, 4] }
  /// After the last frame the joint is asked a few more times, near the
  /// end, for what it still holds (a closing word, the full stop), until it
  /// answers blank this often in a row.
  static var tailSteps: Int { 10 }
  static var tailBlanks: Int { 5 }

  /// Runs the predictor on `token` from `state`.
  let predict: (_ token: Int, _ state: State) throws -> (projection: [Float], state: State)
  /// Asks the joint about `frame` (local to the window) given the predictor's projection.
  let joint: (_ frame: Int, _ projection: [Float]) throws -> Decision

  /// A fresh predictor primed with blank, which is also start-of-sequence.
  func start(from state: State) throws -> Memory {
    let primed = try predict(Self.blank, state)
    return Memory(state: primed.state, projection: primed.projection)
  }

  /// Decodes local frames `from..<to` of a window starting at global frame
  /// `offset`. Returns the tokens and the local frame decoding reached, which
  /// can pass `to` by a jump. `last` is the take's last window: its tail is
  /// asked for what remains.
  func decode(
    from start: Int, to end: Int, offset: Int, last: Bool = false, memory: inout Memory
  ) throws -> (tokens: [Token], reached: Int) {
    var tokens: [Token] = []
    var time = start
    var lastEmission = -1
    while time < end {
      let decision = try joint(time, memory.projection)
      var duration = Self.frames(decision.duration)
      guard decision.token != Self.blank else {
        time += max(duration, 1)
        continue
      }
      // A second token at one frame moves on, so the loop cannot stall.
      if duration == 0, time == lastEmission { duration = 1 }
      lastEmission = time
      tokens.append(Token(id: decision.token, frame: time + offset))
      try step(decision.token, &memory)
      time += duration
    }
    guard last, end > 0 else { return (tokens, time) }
    var probe = min(time, end - 1)
    var blanks = 0
    for index in 0..<Self.tailSteps where blanks < Self.tailBlanks {
      let frame = [probe, end - 1, max(0, end - 2)][index % 3]
      let decision = try joint(frame, memory.projection)
      if decision.token == Self.blank {
        blanks += 1
      } else {
        blanks = 0
        tokens.append(Token(id: decision.token, frame: min(probe, end - 1) + offset))
        try step(decision.token, &memory)
      }
      probe = min(probe + max(1, Self.frames(decision.duration)), end - 1)
    }
    return (tokens, time)
  }

  private func step(_ token: Int, _ memory: inout Memory) throws {
    let next = try predict(token, memory.state)
    memory = Memory(state: next.state, projection: next.projection)
  }

  private static func frames(_ bin: Int) -> Int {
    durations.indices.contains(bin) ? durations[bin] : 1
  }
}
