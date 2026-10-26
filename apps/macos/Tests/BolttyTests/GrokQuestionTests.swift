import XCTest
@testable import Boltty

final class GrokQuestionTests: XCTestCase {
  private let parts: [(question: String, labels: [String], previews: [String: String], multiple: Bool)] = [
    ("Which store?", ["Keychain", "File"], ["Keychain": "macOS keychain"], false),
    ("Which tests?", ["Unit", "UI"], [:], true),
  ]

  func testChosenLabelsGoUnderTheirQuestion() throws {
    let result = ACPClient.askResult(parts, answers: [["Keychain"], ["Unit", "UI"]])
    XCTAssertEqual(result["outcome"] as? String, "accepted")
    let answers = try XCTUnwrap(result["answers"] as? [String: [String]])
    XCTAssertEqual(answers, ["Which store?": ["Keychain"], "Which tests?": ["Unit", "UI"]])
    let annotations = try XCTUnwrap(result["annotations"] as? [String: [String: String]])
    XCTAssertEqual(annotations["Which store?"]?["preview"], "macOS keychain", "a single choice carries its preview")
    XCTAssertNil(annotations["Which tests?"])
  }

  func testTypedWordsGoAsOtherWithNotes() throws {
    let result = ACPClient.askResult(parts, answers: [["a file in ~/.config"], []])
    let answers = try XCTUnwrap(result["answers"] as? [String: [String]])
    XCTAssertEqual(answers, ["Which store?": ["Other"]], "an unanswered part is left out")
    let annotations = try XCTUnwrap(result["annotations"] as? [String: [String: String]])
    XCTAssertEqual(annotations["Which store?"]?["notes"], "a file in ~/.config")
  }
}

final class GrokLaunchTests: XCTestCase {
  /// Measured on grok 1.0.60: with `[ui] permission_mode = "always-approve"`
  /// in the person's config, plain `grok agent stdio` wrote and ran without
  /// asking; `--permission-mode default` brings every ask back.
  func testGrokAsksWhateverThePersonsConfigSays() {
    let arguments = ACPAgent.grok.arguments
    XCTAssertEqual(arguments, ["--permission-mode", "default", "agent", "stdio"])
    let flag = arguments.firstIndex(of: "--permission-mode")!
    XCTAssertLessThan(flag, arguments.firstIndex(of: "agent")!, "the flag is global: after `agent`, grok refuses it")
  }
}
