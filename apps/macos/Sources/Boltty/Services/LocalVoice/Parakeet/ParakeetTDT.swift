import Foundation

struct ParakeetTDT<State> {
  struct Decision: Equatable {
    var token: Int
    var duration: Int
  }

  struct Token: Equatable {
    var id: Int
    var frame: Int
  }

  struct Memory {
    var state: State
    var projection: [Float]
  }

  static var blank: Int { 8192 }
  static var durations: [Int] { [0, 1, 2, 3, 4] }
  static var tailSteps: Int { 10 }
  static var tailBlanks: Int { 5 }

  let predict: (_ token: Int, _ state: State) throws -> (projection: [Float], state: State)
  let joint: (_ frame: Int, _ projection: [Float]) throws -> Decision

  func start(from state: State) throws -> Memory {
    let primed = try predict(Self.blank, state)
    return Memory(state: primed.state, projection: primed.projection)
  }

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
