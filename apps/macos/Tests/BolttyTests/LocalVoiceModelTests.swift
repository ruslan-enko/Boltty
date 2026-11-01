import XCTest
@testable import Boltty

final class LocalVoiceModelTests: XCTestCase {
  func testEveryCatalogModelIsPinnedAndWellFormed() {
    for model in LocalVoiceCatalog.all {
      XCTAssertTrue(model.isWellFormed, "\(model.id)")
      XCTAssertEqual(model.revision.count, 40, "a commit, not a branch: \(model.id)")
      XCTAssertTrue(model.revision.allSatisfy(\.isHexDigit))
      XCTAssertEqual(Set(model.files.map(\.path)).count, model.files.count, "no file twice: \(model.id)")
    }
    XCTAssertEqual(Set(LocalVoiceCatalog.all.map(\.id)), Set(LocalVoiceModel.ID.allCases))
  }

  func testTheSizesAreWhatSettingsWillSay() {
    // Measured on Hugging Face when pinned (2026-11-01). A new revision that
    // moves these far is a different download to ask the person for.
    XCTAssertEqual(Double(LocalVoiceCatalog.parakeetUltra.size), 632_162_964, accuracy: 1_000_000)
    XCTAssertEqual(Double(LocalVoiceCatalog.supertonic3.size), 267_820_864, accuracy: 1_000_000)
  }

  func testTheSourceIsTheFileAtThePinnedRevision() {
    let file = LocalVoiceModel.File(path: "voice styles/M1.json", size: 1, sha256: digest("a"))
    let model = sample(files: [file])
    XCTAssertEqual(
      model.source(of: file).absoluteString,
      "https://huggingface.co/Org/repo/resolve/\(model.revision)/voice%20styles/M1.json"
    )
  }

  func testTheFolderNameCarriesTheRevision() {
    XCTAssertEqual(sample(files: []).folderName, "supertonic-3-0123456789ab")
  }

  func testAPathThatCouldLeaveTheFolderIsRefused() {
    for path in ["../escape", "a/../../b", "/etc/passwd", "", "a//b", "./a"] {
      let model = sample(files: [.init(path: path, size: 1, sha256: digest("a"))])
      XCTAssertFalse(model.isWellFormed, path)
    }
  }

  func testADigestThatIsNotSHA256IsRefused() {
    let model = sample(files: [.init(path: "a", size: 1, sha256: "abc")])
    XCTAssertFalse(model.isWellFormed)
  }

  private func sample(files: [LocalVoiceModel.File]) -> LocalVoiceModel {
    LocalVoiceModel(
      id: .supertonic3, name: "Sample", repository: "Org/repo",
      revision: "0123456789abcdef0123456789abcdef01234567",
      licence: .init(name: "MIT", url: URL(string: "https://example.com")!), files: files)
  }

  private func digest(_ text: String) -> String {
    String(repeating: "0", count: 63) + text
  }
}
