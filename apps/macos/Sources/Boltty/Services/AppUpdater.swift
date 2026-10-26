import AppKit
import Combine

@MainActor
final class AppUpdater: ObservableObject {
  struct Release: Equatable, Sendable {
    let version: String
    let pageURL: URL
  }

  enum Offer: Equatable {
    case check(enabled: Bool)
    case download(version: String)
  }

  enum CheckResult: Equatable {
    case upToDate
    case available(Release)
    case failed(String)
  }

  nonisolated static let repository = "ruslan-enko/boltty"
  nonisolated static let releasesURL = URL(string: "https://github.com/\(repository)/releases")!
  nonisolated static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
  static let checkInterval: TimeInterval = 24 * 60 * 60
  static let lastCheckKey = "boltty.updates.lastCheck"

  @Published private(set) var available: Release?
  @Published private(set) var isChecking = false
  @Published private(set) var lastUpdateCheckDate: Date?

  var offer: Offer {
    available.map { .download(version: $0.version) } ?? .check(enabled: !isChecking)
  }

  let currentVersion: String

  var checksAutomatically: @MainActor () -> Bool = { true }
  var onPresent: @MainActor () -> Void = {}
  var onDismiss: @MainActor () -> Void = {}
  var fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
    try await URLSession.shared.data(for: $0)
  }
  var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
  var presentResult: @MainActor (CheckResult, String) -> Bool = AppUpdater.alert

  private let defaults: UserDefaults
  private var timer: Timer?

  init(
    currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
    defaults: UserDefaults = .standard
  ) {
    self.currentVersion = currentVersion
    self.defaults = defaults
    lastUpdateCheckDate = defaults.object(forKey: Self.lastCheckKey) as? Date
  }

  func start() {
    guard timer == nil else { return }
    Task { await checkIfDue() }
    timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        Task { await self.checkIfDue() }
      }
    }
  }

  func isDue(now: Date = Date()) -> Bool {
    guard checksAutomatically() else { return false }
    guard let last = lastUpdateCheckDate else { return true }
    return now.timeIntervalSince(last) >= Self.checkInterval
  }

  func checkIfDue(now: Date = Date()) async {
    guard isDue(now: now), !isChecking else { return }
    await check()
  }

  func checkForUpdates() {
    if let available {
      openURL(available.pageURL)
      return
    }
    guard !isChecking else { return }
    Task {
      let result = await check()
      onPresent()
      if presentResult(result, currentVersion), case let .available(release) = result {
        openURL(release.pageURL)
      }
      onDismiss()
    }
  }

  @discardableResult
  func check(now: Date = Date()) async -> CheckResult {
    isChecking = true
    defer { isChecking = false }
    var request = URLRequest(url: Self.latestReleaseURL, timeoutInterval: 15)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("Boltty/\(currentVersion)", forHTTPHeaderField: "User-Agent")

    let result: CheckResult
    do {
      let (data, response) = try await fetch(request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      switch status {
      case 200:
        if let release = Self.release(from: data) {
          result = Self.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
        } else {
          result = .failed("GitHub answered with something that is not a release.")
        }
      case 404:
        result = .failed("No release of Boltty has been published yet.")
      default:
        result = .failed("GitHub answered \(status).")
      }
    } catch {
      result = .failed(error.localizedDescription)
    }

    switch result {
    case let .available(release):
      available = release
    case .upToDate:
      available = nil
    case .failed:
      break
    }
    if case .failed = result {} else {
      lastUpdateCheckDate = now
      defaults.set(now, forKey: Self.lastCheckKey)
    }
    return result
  }

  nonisolated static func release(from data: Data) -> Release? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tag = object["tag_name"] as? String,
          let page = (object["html_url"] as? String).flatMap(URL.init(string:)),
          object["draft"] as? Bool != true,
          object["prerelease"] as? Bool != true
    else { return nil }
    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    guard !version.isEmpty else { return nil }
    let pagePrefix = "https://github.com/\(repository)/releases/"
    let safePage = page.absoluteString.hasPrefix(pagePrefix) ? page : releasesURL
    return Release(version: version, pageURL: safePage)
  }

  nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
    func numbers(_ version: String) -> [Int] {
      version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
    let a = numbers(candidate), b = numbers(current)
    for index in 0..<max(a.count, b.count) {
      let x = index < a.count ? a[index] : 0
      let y = index < b.count ? b[index] : 0
      if x != y { return x > y }
    }
    return false
  }

  static func checkedPhrase(_ date: Date, now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate(
      Calendar.current.isDate(date, inSameDayAs: now) ? "jmm" : "d MMM jmm"
    )
    return formatter.string(from: date)
  }

  private static func alert(_ result: CheckResult, current: String) -> Bool {
    let alert = NSAlert()
    switch result {
    case let .available(release):
      alert.messageText = "Boltty \(release.version) is available"
      alert.informativeText = "You have \(current). Download it from its release page, quit Boltty from the menu bar, and drag the new one into Applications."
      alert.addButton(withTitle: "Download")
      alert.addButton(withTitle: "Later")
      return alert.runModal() == .alertFirstButtonReturn
    case .upToDate:
      alert.messageText = "Boltty is up to date"
      alert.informativeText = "\(current) is the newest release."
    case let .failed(reason):
      alert.alertStyle = .warning
      alert.messageText = "Couldn't check for updates"
      alert.informativeText = reason
    }
    alert.runModal()
    return false
  }
}
