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
  func testGrokAsksWhateverThePersonsConfigSays() {
    let arguments = ACPAgent.grok.arguments
    XCTAssertEqual(arguments, ["--permission-mode", "default", "agent", "stdio"])
    let flag = arguments.firstIndex(of: "--permission-mode")!
    XCTAssertLessThan(flag, arguments.firstIndex(of: "agent")!, "the flag is global: after `agent`, grok refuses it")
  }

  func testAPermissionIsItsKindAndItsCommandNotItsTitle() {
    let command = "ssh zima 'free -h; df -h'"
    let asked = ACPClient.permissionSubject(of: JSONObject([
      "kind": "execute", "title": "Execute `\(command)`", "rawInput": ["command": command],
    ]))
    XCTAssertEqual(asked.action, "execute")
    XCTAssertEqual(asked.resources, [command])
    XCTAssertEqual(PermissionSentence.sentence(action: asked.action, resources: asked.resources), "Run this command?")

    let edit = ACPClient.permissionSubject(of: JSONObject([
      "kind": "edit", "title": "Edit notes.md", "locations": [["path": "/tmp/notes.md"]],
    ]))
    XCTAssertEqual(edit.resources, ["/tmp/notes.md"])

    let picture = ACPClient.permissionSubject(of: JSONObject([
      "kind": "other", "title": "imagine: a red circle",
      "_meta": ["x.ai/tool": ["name": "image_gen", "label": "Generate Image"]],
    ]))
    XCTAssertEqual(picture.action, "Generate Image")
    XCTAssertEqual(picture.resources, ["imagine: a red circle"])
  }

  func testOnlyPicturesAreRememberedForTheChat() {
    func tool(_ name: String) -> JSONObject {
      JSONObject(["kind": "other", "_meta": ["x.ai/tool": ["name": name]]])
    }
    XCTAssertTrue(ACPClient.makesPicture(tool("image_gen")))
    XCTAssertTrue(ACPClient.makesPicture(tool("image_edit")))
    XCTAssertFalse(ACPClient.makesPicture(tool("reference_to_video")))
    XCTAssertFalse(ACPClient.makesPicture(JSONObject(["kind": "other", "title": "image_gen"])))
  }

  func testAllowIsNeverSentAsARefusal() {
    let offered: [PermissionDecision: String] = [.once: "allow-once", .reject: "reject-once"]
    XCTAssertEqual(ACPClient.option(for: .always, among: offered), "allow-once")
    XCTAssertNil(ACPClient.option(for: .once, among: [.reject: "reject-once"]))
  }
}
