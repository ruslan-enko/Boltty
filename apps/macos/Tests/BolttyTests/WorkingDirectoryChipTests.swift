import XCTest
@testable import Boltty

final class WorkingDirectoryChipTests: XCTestCase {
  private func conversation(
    remoteSessionID: String? = nil,
    providerID: String = AgentId.opencode.rawValue,
    directory: String = "/Users/someone/Code/thing"
  ) -> Conversation {
    Conversation(
      providerID: providerID,
      remoteSessionID: remoteSessionID,
      title: "A chat",
      workingDirectory: directory
    )
  }

  func testANewPromptInheritsTheFolderAndCanStillChangeIt() {
    let chip = WorkingDirectoryChip.forNewPrompt(
      path: "/Users/someone/Code/thing",
      honoursWorkingDirectory: true
    )
    XCTAssertEqual(chip.path, "/Users/someone/Code/thing")
    XCTAssertTrue(chip.isEditable)
    XCTAssertNil(chip.warning)
  }

  func testTheFolderIsStillChangeableBeforeTheProviderHasASession() {
    let chip = WorkingDirectoryChip.forConversation(
      conversation(),
      honoursWorkingDirectory: true
    )
    XCTAssertTrue(chip.isEditable, "no remote session yet — the store would accept a change")
    XCTAssertTrue(chip.tooltip.contains("Click to choose"))
  }

  func testASessionFixesTheFolderAndTheChipSaysWhy() {
    let chip = WorkingDirectoryChip.forConversation(
      conversation(remoteSessionID: "ses_abc"),
      honoursWorkingDirectory: true
    )
    XCTAssertFalse(chip.isEditable, "setWorkingDirectory would refuse this silently")
    XCTAssertTrue(
      chip.tooltip.contains("Fixed when the conversation started"),
      "a lock with no reason reads as a bug: \(chip.tooltip)"
    )
    XCTAssertTrue(chip.tooltip.contains("A new chat can start somewhere else."))
    XCTAssertTrue(chip.accessibilityLabel.contains("fixed"))
  }

  func testAnAgentThatIgnoresTheFolderIsSaidToIgnoreIt() throws {
    let chip = WorkingDirectoryChip.forConversation(
      conversation(providerID: AgentId.antigravity.rawValue),
      honoursWorkingDirectory: false
    )
    let warning = try XCTUnwrap(chip.warning)
    XCTAssertFalse(warning.contains(AgentId.antigravity.shortDisplayName), warning)
    XCTAssertTrue(warning.lowercased().contains("land"), warning)
    XCTAssertTrue(chip.tooltip.contains(warning), "the warning has to be readable: \(chip.tooltip)")
  }

  func testAnAgentThatHonoursTheFolderCarriesNoWarning() {
    XCTAssertNil(
      WorkingDirectoryChip.forConversation(
        conversation(providerID: AgentId.claude.rawValue),
        honoursWorkingDirectory: true
      ).warning
    )
  }

  func testTheChipNamesTheFolderAndCallsTheDefaultHome() {
    let home = WorkingDirectoryResolver.homeDirectoryPath
    let homeChip = WorkingDirectoryChip.forNewPrompt(
      path: home,
      honoursWorkingDirectory: true
    )
    let moviesChip = WorkingDirectoryChip.forNewPrompt(
      path: home + "/Movies",
      honoursWorkingDirectory: true
    )
    XCTAssertEqual(homeChip.displayPath, "Home")
    XCTAssertEqual(moviesChip.displayPath, "Movies")
    XCTAssertEqual(moviesChip.tooltip.split(separator: "\n").first.map(String.init), home + "/Movies")
  }

  func testTheChipNamesAnyFolderButHome() {
    let home = WorkingDirectoryResolver.homeDirectoryPath
    XCTAssertTrue(WorkingDirectoryChip.forNewPrompt(path: home, honoursWorkingDirectory: true).isHome)
    XCTAssertNil(WorkingDirectoryChip.forNewPrompt(path: home, honoursWorkingDirectory: true).folderName)
    XCTAssertNil(WorkingDirectoryChip.forNewPrompt(path: " ", honoursWorkingDirectory: true).folderName)
    XCTAssertEqual(
      WorkingDirectoryChip.forNewPrompt(path: "/Users/someone/Code/boltty", honoursWorkingDirectory: true)
        .folderName, "boltty", "as it is on disk")
  }
}

final class RecentFoldersTests: XCTestCase {
  private let home = "/Users/someone"
  private func day(_ n: Double) -> Date { Date(timeIntervalSince1970: n * 86_400) }

  func testNewestFirstOnceEachWithoutHome() {
    let places: [(path: String, touched: Date)] = [
      ("/Users/someone/Code/boltty", day(3)),
      ("/Users/someone/Code/vdl", day(5)),
      ("/Users/someone/Code/boltty/", day(9)),
      (home, day(10)),
      ("", day(11)),
      ("/Users/someone/a", day(1)), ("/Users/someone/b", day(2)), ("/Users/someone/c", day(4)),
      ("/Users/someone/d", day(0.5)),
    ]
    XCTAssertEqual(
      RecentFolders.list(places, home: home) { _ in true },
      ["/Users/someone/Code/boltty", "/Users/someone/Code/vdl", "/Users/someone/c",
       "/Users/someone/b", "/Users/someone/a"])
  }

  func testAFolderThatIsGoneIsSkippedAndAskedOnlyUntilTheListIsFull() {
    var asked: [String] = []
    let places = (1...20).map { (path: "/p/\($0)", touched: day(Double($0))) }
    let list = RecentFolders.list(places, home: home, limit: 2) { path in
      asked.append(path)
      return path != "/p/20"
    }
    XCTAssertEqual(list, ["/p/19", "/p/18"])
    XCTAssertEqual(asked, ["/p/20", "/p/19", "/p/18"])
  }

  func testTheFolderInUseIsAlwaysOffered() {
    XCTAssertEqual(
      RecentFolders.offered(recent: ["/a", "/b"], current: "/c", home: home), ["/c", "/a", "/b"])
    XCTAssertEqual(RecentFolders.offered(recent: ["/a", "/b"], current: "/b", home: home), ["/a", "/b"])
    XCTAssertEqual(RecentFolders.offered(recent: ["/a"], current: home, home: home), ["/a"])
  }

  func testFoldersOfOneNameAreToldApart() {
    XCTAssertEqual(
      RecentFolders.titles(for: ["/w/work/app", "/w/personal/app", "/w/EXUA"]),
      ["app — work", "app — personal", "EXUA"])
  }
}


@MainActor
final class WorkingDirectoryMenuTests: XCTestCase {
  func testTheMenuIsNoFolderTheRecentFoldersAndOpenFolder() {
    var chosen: [String] = []
    var opened = 0
    let menu = WorkingDirectoryMenu.make(
      current: "/h/Code/vdl", home: "/h", recent: ["/h/Code/boltty", "/h/Code/vdl"],
      choose: { chosen.append($0) }, openFolder: { opened += 1 })

    XCTAssertEqual(menu.items.map(\.title),
                   ["No Folder", "", "Recent", "boltty", "vdl", "", "Open Folder…"])
    XCTAssertTrue(menu.items[1].isSeparatorItem)
    XCTAssertTrue(menu.items[2].isSectionHeader)
    XCTAssertEqual(menu.items.map(\.state), [.off, .off, .off, .off, .on, .off, .off],
                   "the folder in use is checked, and only it")
    XCTAssertEqual(menu.items[3].toolTip, "/h/Code/boltty", "the full path is the row's help")

    menu.performActionForItem(at: 0)
    menu.performActionForItem(at: 3)
    menu.performActionForItem(at: 6)
    XCTAssertEqual(chosen, ["/h", "/h/Code/boltty"], "No Folder is home")
    XCTAssertEqual(opened, 1)
  }

  func testAtHomeWithNothingRecentTheMenuIsNoFolderAndOpenFolder() {
    let menu = WorkingDirectoryMenu.make(
      current: "/h", home: "/h", recent: [], choose: { _ in }, openFolder: {})
    XCTAssertEqual(menu.items.map(\.title), ["No Folder", "", "Open Folder…"])
    XCTAssertEqual(menu.items[0].state, .on)
  }
}

@MainActor
final class WorkingDirectoryMenuActionsTests: XCTestCase {
  private func actions(
    gitHub: URL? = nil, record: @escaping (String) -> Void
  ) -> WorkingDirectoryMenu.FolderActions {
    WorkingDirectoryMenu.FolderActions(
      gitHubURL: gitHub,
      showInFinder: { record("finder") }, copyPath: { record("copy") },
      openGitHub: { record("github") })
  }

  func testTheActionsStandOverTheChoosing() {
    var done: [String] = []
    let menu = WorkingDirectoryMenu.make(
      current: "/h/boltty", home: "/h", recent: ["/h/boltty"],
      actions: actions(gitHub: URL(string: "https://github.com/o/boltty")) { done.append($0) },
      choose: { _ in }, openFolder: {})
    XCTAssertEqual(menu.items.map(\.title),
                   ["Show in Finder", "Copy Path", "Open on GitHub", "",
                    "No Folder", "", "Recent", "boltty", "", "Open Folder…"])
    for index in 0..<3 { menu.performActionForItem(at: index) }
    XCTAssertEqual(done, ["finder", "copy", "github"])
  }

  func testAFixedFolderIsActionsOnly() {
    let menu = WorkingDirectoryMenu.make(
      current: "/h/boltty", home: "/h", recent: [], canChoose: false,
      actions: actions { _ in }, choose: { _ in }, openFolder: {})
    XCTAssertEqual(menu.items.map(\.title), ["Show in Finder", "Copy Path"])
  }
}

final class GitRepositoryTests: XCTestCase {
  private func folder(_ files: [String: String]) throws -> String {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("git-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    for (path, text) in files {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return root.path
  }

  func testABranchAndItsGitHubPage() throws {
    let path = try folder([
      ".git/HEAD": "ref: refs/heads/main\n",
      ".git/config": """
        [core]
        \tbare = false
        [remote "upstream"]
        \turl = https://github.com/someone-else/boltty.git
        [remote "origin"]
        \turl = git@github.com:ruslan-enko/boltty.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """,
    ])
    let repository = try XCTUnwrap(GitRepository.read(at: path))
    XCTAssertEqual(repository.branch, "main")
    XCTAssertEqual(repository.gitHubURL?.absoluteString, "https://github.com/ruslan-enko/boltty",
                   "origin first, whatever the order")
  }

  func testAWorktreeReadsItsOwnHeadAndTheSharedConfig() throws {
    let main = try folder([
      ".git/config": "[remote \"origin\"]\n\turl = https://github.com/o/r\n",
      ".git/worktrees/feat/HEAD": "ref: refs/heads/feature/login\n",
      ".git/worktrees/feat/commondir": "../..\n",
    ])
    let tree = try folder([".git": "gitdir: \(main)/.git/worktrees/feat\n"])
    let repository = try XCTUnwrap(GitRepository.read(at: tree))
    XCTAssertEqual(repository.branch, "feature/login")
    XCTAssertEqual(repository.gitHubURL?.absoluteString, "https://github.com/o/r")
  }

  func testADetachedHeadIsItsCommitAndAFolderWithoutGitIsNone() throws {
    XCTAssertEqual(GitRepository.branch(fromHead: "3f2a1b2c9d0e8f7a6b5c4d3e2f1a0b9c8d7e6f5a\n"), "3f2a1b2")
    XCTAssertNil(GitRepository.read(at: try folder(["README.md": "hi"])))
  }

  func testTheShapesOfAGitHubRemote() {
    for remote in ["git@github.com:o/r.git", "https://github.com/o/r.git", "https://github.com/o/r",
                   "ssh://git@github.com/o/r.git", "https://github.com/o/r/"] {
      XCTAssertEqual(GitRepository.gitHubPage(fromRemote: remote)?.absoluteString,
                     "https://github.com/o/r", remote)
    }
    XCTAssertNil(GitRepository.gitHubPage(fromRemote: "git@gitlab.com:o/r.git"))
    XCTAssertNil(GitRepository.gitHubPage(fromRemote: "https://github.com/o"))
  }
}
