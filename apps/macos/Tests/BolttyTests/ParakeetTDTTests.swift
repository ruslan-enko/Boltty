import XCTest
@testable import Boltty

final class ParakeetTDTTests: XCTestCase {
  typealias TDT = ParakeetTDT<Int>
  private let blank = TDT.blank

  /// A joint that answers from a script by frame; the predictor's state
  /// counts the tokens fed to it, and its projection carries that count.
  private func tdt(
    _ script: @escaping (_ frame: Int, _ said: Int) -> TDT.Decision, fed: @escaping (Int) -> Void = { _ in }
  ) -> TDT {
    TDT(
      predict: { token, state in
        fed(token)
        return ([Float(state + 1)], state + 1)
      },
      joint: { frame, projection in script(frame, Int(projection[0])) })
  }

  func testBlanksMoveOnAndTokensKeepTheirFrames() throws {
    let decoder = tdt { frame, _ in
      frame == 2 ? .init(token: 7, duration: 2) : .init(token: self.blank, duration: 1)
    }
    var memory = try decoder.start(from: 0)
    let result = try decoder.decode(from: 0, to: 6, offset: 100, memory: &memory)
    XCTAssertEqual(result.tokens, [.init(id: 7, frame: 102)])
    XCTAssertEqual(result.reached, 6)
  }

  func testTwoTokensCanShareAFrameButNotMore() throws {
    var asked: [Int] = []
    let decoder = tdt { frame, _ in
      asked.append(frame)
      return frame == 0 ? .init(token: 5, duration: 0) : .init(token: self.blank, duration: 4)
    }
    var memory = try decoder.start(from: 0)
    let result = try decoder.decode(from: 0, to: 3, offset: 0, memory: &memory)
    XCTAssertEqual(result.tokens.map(\.frame), [0, 0], "the second token at frame 0 moves on")
    XCTAssertEqual(asked.prefix(3), [0, 0, 1])
  }

  func testThePredictorStepsOnlyOnTokens() throws {
    var fed: [Int] = []
    let decoder = tdt({ frame, _ in
      frame.isMultiple(of: 2) ? .init(token: 40 + frame, duration: 1) : .init(token: self.blank, duration: 1)
    }, fed: { fed.append($0) })
    var memory = try decoder.start(from: 0)
    _ = try decoder.decode(from: 0, to: 5, offset: 0, memory: &memory)
    XCTAssertEqual(fed, [blank, 40, 42, 44], "primed with blank, then each token")
    XCTAssertEqual(memory.state, 4)
  }

  func testAJumpPastTheEndIsReported() throws {
    let decoder = tdt { _, _ in .init(token: self.blank, duration: 4) }
    var memory = try decoder.start(from: 0)
    XCTAssertEqual(try decoder.decode(from: 1, to: 6, offset: 0, memory: &memory).reached, 9)
  }

  func testTheLastWindowsTailIsAskedForWhatRemains() throws {
    // A jump from frame 0 passes the word at frame 3; only the tail finds it.
    let decoder = tdt { frame, said in
      frame >= 3 && said == 1 ? .init(token: 9, duration: 0) : .init(token: self.blank, duration: 4)
    }
    var memory = try decoder.start(from: 0)
    XCTAssertEqual(try decoder.decode(from: 0, to: 4, offset: 0, memory: &memory).tokens, [])
    memory = try decoder.start(from: 0)
    let closed = try decoder.decode(from: 0, to: 4, offset: 10, last: true, memory: &memory)
    XCTAssertEqual(closed.tokens, [.init(id: 9, frame: 13)])
  }

  func testTextJoinsPiecesAndDropsMarkers() {
    let vocabulary = [1: "<unk>", 2: "▁При", 3: "віт", 4: ",", 5: "▁Codex", 6: "<|endoftext|>"]
    let tokens = [2, 3, 4, 1, 5, 6].map { ParakeetTDT<[Float]>.Token(id: $0, frame: 0) }
    XCTAssertEqual(ParakeetTranscriber.text(of: tokens, vocabulary: vocabulary), "Привіт, Codex")
  }
}
