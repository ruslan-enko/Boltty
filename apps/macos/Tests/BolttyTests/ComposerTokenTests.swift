import XCTest
@testable import Boltty

final class ComposerTokenTests: XCTestCase {
  func testAnAtStartingAWordOpensTheFileList() {
    let text = "look at @READ"
    let token = ComposerToken.mention(in: text, caret: (text as NSString).length)
    XCTAssertEqual(token, ComposerToken(range: NSRange(location: 8, length: 5), query: "READ"))
  }

  func testABareAtListsWithAnEmptyQuery() {
    XCTAssertEqual(ComposerToken.mention(in: "@", caret: 1)?.query, "")
  }

  func testAnAtInsideAWordIsAnAddressNotAFile() {
    let text = "write to me@site.com"
    XCTAssertNil(ComposerToken.mention(in: text, caret: (text as NSString).length))
  }

  func testASpaceAfterTheQueryEndsIt() {
    let text = "@notes and more"
    XCTAssertNil(ComposerToken.mention(in: text, caret: (text as NSString).length))
  }

  func testASlashOpensCommandsOnlyAsTheFirstCharacter() {
    XCTAssertEqual(ComposerToken.command(in: "/rev", caret: 4)?.query, "rev")
    XCTAssertNil(ComposerToken.command(in: "open src/main", caret: 13))
    XCTAssertNil(ComposerToken.command(in: " /rev", caret: 5))
  }

  func testTheCaretMustStandInTheWord() {
    XCTAssertNil(ComposerToken.command(in: "/review this", caret: 12))
    XCTAssertEqual(ComposerToken.command(in: "/review this", caret: 4)?.query, "rev")
  }
}

final class FileMentionTests: XCTestCase {
  private func candidate(_ path: String, modified: TimeInterval = 0) -> FileMention.Candidate {
    FileMention.Candidate(
      url: URL(fileURLWithPath: "/root/" + path), isDirectory: false, relativePath: path,
      modified: Date(timeIntervalSince1970: modified))
  }

  func testANameStartingWithTheQueryComesBeforeOneHoldingIt() {
    let ranked = FileMention.rank(
      [candidate("docs/my-config.md"), candidate("config.ts"), candidate("src/configure.swift")],
      query: "config", limit: 8)
    XCTAssertEqual(ranked.map(\.relativePath), ["config.ts", "src/configure.swift", "docs/my-config.md"])
  }

  func testLettersInOrderStillFind() {
    let ranked = FileMention.rank([candidate("AgentPaletteView.swift"), candidate("README.md")], query: "apv", limit: 8)
    XCTAssertEqual(ranked.map(\.relativePath), ["AgentPaletteView.swift"])
  }

  func testNoQueryListsTheNewestFirst() {
    let ranked = FileMention.rank([candidate("old", modified: 1), candidate("new", modified: 9)], query: "", limit: 1)
    XCTAssertEqual(ranked.map(\.relativePath), ["new"])
  }

  func testGitIgnoreTakesPlainNamesAndExtensionsOnly() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "# note\n.build/\n*.log\nsecrets.txt\nsrc/gen/*.swift\n!keep.log\n"
      .write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    let ignored = GitIgnoreNames.read(at: root)
    XCTAssertTrue(ignored.matches(".build", isDirectory: true))
    XCTAssertFalse(ignored.matches(".build", isDirectory: false))
    XCTAssertTrue(ignored.matches("debug.LOG", isDirectory: false))
    XCTAssertTrue(ignored.matches("secrets.txt", isDirectory: false))
    XCTAssertFalse(ignored.matches("main.swift", isDirectory: false))
  }

  func testHomeAndWhatHoldsItAreSpotlights() {
    XCTAssertTrue(FileMentionSearch.usesSpotlight(NSHomeDirectory()))
    XCTAssertTrue(FileMentionSearch.usesSpotlight("/"))
    XCTAssertFalse(FileMentionSearch.usesSpotlight(NSHomeDirectory() + "/Projects/app"))
  }

  func testLibraryAndDotFoldersAreOutOfSight() {
    let home = NSHomeDirectory()
    XCTAssertTrue(FolderWalk.isOutOfSight(home + "/Library/Caches/x", under: home))
    XCTAssertTrue(FolderWalk.isOutOfSight(home + "/.config/x", under: home))
    XCTAssertTrue(FolderWalk.isOutOfSight(home + "/p/node_modules/x", under: home))
    XCTAssertFalse(FolderWalk.isOutOfSight(home + "/Documents/report.pdf", under: home))
  }
}
