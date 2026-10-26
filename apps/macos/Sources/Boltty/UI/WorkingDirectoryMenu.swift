import AppKit

@MainActor
enum WorkingDirectoryMenu {
  static let noFolderTitle = "No Folder"
  static let recentTitle = "Recent"
  static let openFolderTitle = "Open Folder…"
  static let showInFinderTitle = "Show in Finder"
  static let copyPathTitle = "Copy Path"
  static let openOnGitHubTitle = "Open on GitHub"

  struct FolderActions {
    var gitHubURL: URL?
    var showInFinder: () -> Void
    var copyPath: () -> Void
    var openGitHub: () -> Void
  }

  static func make(
    current: String,
    home: String,
    recent: [String],
    canChoose: Bool = true,
    actions: FolderActions? = nil,
    choose: @escaping (String) -> Void,
    openFolder: @escaping () -> Void
  ) -> NSMenu {
    let menu = NSMenu(title: "Working Folder")
    menu.autoenablesItems = false

    if let actions {
      menu.addItem(WorkingDirectoryMenuItem(title: showInFinderTitle, handler: actions.showInFinder))
      menu.addItem(WorkingDirectoryMenuItem(title: copyPathTitle, handler: actions.copyPath))
      if let url = actions.gitHubURL {
        let github = WorkingDirectoryMenuItem(title: openOnGitHubTitle, handler: actions.openGitHub)
        github.toolTip = url.absoluteString
        menu.addItem(github)
      }
    }
    guard canChoose else { return menu }
    if actions != nil { menu.addItem(.separator()) }

    let here = RecentFolders.standardized(current)
    let atHome = here.isEmpty || here == RecentFolders.standardized(home)

    let none = WorkingDirectoryMenuItem(title: noFolderTitle) { choose(home) }
    none.state = atHome ? .on : .off
    none.toolTip = home
    menu.addItem(none)

    if !recent.isEmpty {
      menu.addItem(.separator())
      menu.addItem(.sectionHeader(title: recentTitle))
      for (path, title) in zip(recent, RecentFolders.titles(for: recent)) {
        let item = WorkingDirectoryMenuItem(title: title) { choose(path) }
        item.toolTip = path
        item.state = !atHome && RecentFolders.standardized(path) == here ? .on : .off
        menu.addItem(item)
      }
    }

    menu.addItem(.separator())
    menu.addItem(WorkingDirectoryMenuItem(title: openFolderTitle) { openFolder() })
    return menu
  }
}

final class WorkingDirectoryMenuItem: NSMenuItem {
  private let handler: () -> Void

  init(title: String, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(fire), keyEquivalent: "")
    target = self
  }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @objc private func fire() { handler() }
}
