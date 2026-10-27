import ServiceManagement
import XCTest
@testable import Boltty

@MainActor
final class AppUpdaterTests: XCTestCase {
  private func releaseJSON(tag: String, draft: Bool = false, prerelease: Bool = false) -> Data {
    Data("""
    {"tag_name": "\(tag)", "html_url": "https://github.com/ruslan-enko/boltty/releases/tag/\(tag)",
     "draft": \(draft), "prerelease": \(prerelease)}
    """.utf8)
  }

  private func response(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: AppUpdater.latestReleaseURL, statusCode: status, httpVersion: nil, headerFields: nil)!
  }

  private func makeUpdater(
    current: String = "0.1.0",
    status: Int = 200,
    body: Data = Data()
  ) -> AppUpdater {
    let updater = AppUpdater(
      currentVersion: current,
      defaults: isolatedDefaults("boltty.tests.updater")
    )
    let reply = (body, response(status))
    updater.fetch = { _ in reply }
    return updater
  }

  // MARK: - What GitHub says

  func testALatestReleaseIsReadWithoutItsV() {
    let release = AppUpdater.release(from: releaseJSON(tag: "v0.2.0"))
    XCTAssertEqual(release?.version, "0.2.0")
    XCTAssertEqual(release?.pageURL.absoluteString, "https://github.com/ruslan-enko/boltty/releases/tag/v0.2.0")
  }

  func testDraftsAndPreReleasesAreNotOffered() {
    XCTAssertNil(AppUpdater.release(from: releaseJSON(tag: "v0.2.0", draft: true)))
    XCTAssertNil(AppUpdater.release(from: releaseJSON(tag: "v0.2.0", prerelease: true)))
    XCTAssertNil(AppUpdater.release(from: Data("not json".utf8)))
  }

  func testAPageOutsideTheReleasesIsNotOpened() {
    let foreign = Data("""
    {"tag_name": "v9.0.0", "html_url": "https://example.com/boltty.dmg", "draft": false, "prerelease": false}
    """.utf8)
    XCTAssertEqual(AppUpdater.release(from: foreign)?.pageURL, AppUpdater.releasesURL)
  }

  func testOnlyThisRepositorysImageAndChecksumMakeAReleaseInstallable() {
    let assets = Data("""
    {"tag_name": "v0.2.3", "html_url": "https://github.com/ruslan-enko/boltty/releases/tag/v0.2.3",
     "draft": false, "prerelease": false, "assets": [
      {"name": "Boltty.dmg", "browser_download_url": "https://github.com/ruslan-enko/Boltty/releases/download/v0.2.3/Boltty.dmg"},
      {"name": "Boltty.dmg.sha256", "browser_download_url": "https://github.com/ruslan-enko/Boltty/releases/download/v0.2.3/Boltty.dmg.sha256"}]}
    """.utf8)
    XCTAssertEqual(AppUpdater.release(from: assets)?.isInstallable, true)
    let foreign = Data("""
    {"tag_name": "v0.2.3", "html_url": "https://github.com/ruslan-enko/boltty/releases/tag/v0.2.3",
     "draft": false, "prerelease": false, "assets": [
      {"name": "Boltty.dmg", "browser_download_url": "https://example.com/Boltty.dmg"},
      {"name": "Boltty.dmg.sha256", "browser_download_url": "https://github.com/ruslan-enko/Boltty/releases/download/v0.2.3/Boltty.dmg.sha256"}]}
    """.utf8)
    XCTAssertEqual(AppUpdater.release(from: foreign)?.isInstallable, false)
    XCTAssertFalse(AppUpdater.release(from: releaseJSON(tag: "v0.2.3"))?.isInstallable ?? true)
  }

  func testAChecksumIsTheShasumLinesDigest() {
    let hex = String(repeating: "ab", count: 32)
    XCTAssertEqual(UpdateInstaller.checksum(in: "\(hex.uppercased())  Boltty.dmg\n"), hex)
    XCTAssertNil(UpdateInstaller.checksum(in: "not a digest  Boltty.dmg"))
    XCTAssertNil(UpdateInstaller.checksum(in: ""))
  }

  func testVersionsCompareNumberByNumber() {
    XCTAssertTrue(AppUpdater.isNewer("0.2.0", than: "0.1.0"))
    XCTAssertTrue(AppUpdater.isNewer("0.10.0", than: "0.9.2"), "not as text")
    XCTAssertFalse(AppUpdater.isNewer("1.0", than: "1.0.0"), "a missing number is 0")
    XCTAssertFalse(AppUpdater.isNewer("0.1.0", than: "0.1.0"))
    XCTAssertFalse(AppUpdater.isNewer("0.1.0", than: "0.2.0"))
  }

  // MARK: - A check

  func testANewerReleaseIsHeldAndOffered() async {
    let updater = makeUpdater(body: releaseJSON(tag: "v0.2.0"))
    let result = await updater.check()
    XCTAssertEqual(updater.available?.version, "0.2.0")
    XCTAssertEqual(updater.offer, .download(version: "0.2.0"))
    if case .available = result {} else { XCTFail("expected available, got \(result)") }
    XCTAssertNotNil(updater.lastUpdateCheckDate)
  }

  func testTheSameVersionIsUpToDate() async {
    let updater = makeUpdater(current: "0.2.0", body: releaseJSON(tag: "v0.2.0"))
    let result = await updater.check()
    XCTAssertEqual(result, .upToDate)
    XCTAssertNil(updater.available)
    XCTAssertEqual(updater.offer, .check(enabled: true))
  }

  func testNoReleaseIsSaidAndNotRememberedAsAChecks() async {
    let updater = makeUpdater(status: 404)
    let result = await updater.check()
    XCTAssertEqual(result, .failed("No release of Boltty has been published yet."))
    XCTAssertNil(updater.lastUpdateCheckDate, "a failed check is tried again, not in a day")
  }

  func testAFailedCheckKeepsWhatWasFound() async {
    let updater = makeUpdater(body: releaseJSON(tag: "v0.2.0"))
    await updater.check()
    let failing = response(500)
    updater.fetch = { _ in (Data(), failing) }
    let result = await updater.check()
    XCTAssertEqual(result, .failed("GitHub answered 500."))
    XCTAssertEqual(updater.available?.version, "0.2.0")
  }

  func testTheRequestNamesTheApp() async throws {
    let updater = makeUpdater(current: "0.1.0", body: releaseJSON(tag: "v0.1.0"))
    let seen = RequestBox()
    let reply = (releaseJSON(tag: "v0.1.0"), response(200))
    updater.fetch = { request in
      seen.set(request)
      return reply
    }
    await updater.check()
    let request = try XCTUnwrap(seen.request)
    XCTAssertEqual(request.url, AppUpdater.latestReleaseURL)
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Boltty/0.1.0")
  }

  // MARK: - Once a day, and only when switched on

  func testACheckIsDueOnceADay() async {
    let updater = makeUpdater(body: releaseJSON(tag: "v0.1.0"))
    XCTAssertTrue(updater.isDue(), "never checked")
    let then = Date()
    await updater.check(now: then)
    XCTAssertFalse(updater.isDue(now: then.addingTimeInterval(60 * 60)))
    XCTAssertTrue(updater.isDue(now: then.addingTimeInterval(AppUpdater.checkInterval)))
  }

  func testTurnedOffNothingIsDue() {
    let updater = makeUpdater()
    updater.checksAutomatically = { false }
    XCTAssertFalse(updater.isDue())
  }

  func testTheLastCheckOutlivesTheProcess() async {
    let defaults = isolatedDefaults("boltty.tests.updater.relaunch")
    let first = AppUpdater(currentVersion: "0.1.0", defaults: defaults)
    let reply = (releaseJSON(tag: "v0.1.0"), response(200))
    first.fetch = { _ in reply }
    await first.check()
    let second = AppUpdater(currentVersion: "0.1.0", defaults: defaults)
    XCTAssertNotNil(second.lastUpdateCheckDate)
    XCTAssertFalse(second.isDue())
  }

  // MARK: - Asked from the menu

  func testAFoundReleaseOpensItsPage() async {
    let updater = makeUpdater(body: releaseJSON(tag: "v0.2.0"))
    await updater.check()
    var opened: URL?
    updater.openURL = { opened = $0 }
    updater.fetch = { _ in XCTFail("no second check"); throw URLError(.badURL) }
    updater.checkForUpdates()
    XCTAssertEqual(opened?.absoluteString, "https://github.com/ruslan-enko/boltty/releases/tag/v0.2.0")
  }

  func testTheLastCheckIsSaidAsATimeTodayAndADateBefore() {
    let now = Date()
    let today = AppUpdater.checkedPhrase(now.addingTimeInterval(-60), now: now)
    let lastWeek = AppUpdater.checkedPhrase(now.addingTimeInterval(-7 * 86_400), now: now)
    XCTAssertFalse(today.isEmpty)
    XCTAssertFalse(lastWeek.isEmpty, "DateFormatter, never Date.FormatStyle's empty string")
    XCTAssertNotEqual(today, lastWeek)
  }
}

private final class RequestBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: URLRequest?
  var request: URLRequest? { lock.withLock { stored } }
  func set(_ request: URLRequest) { lock.withLock { stored = request } }
}

@MainActor
final class LoginItemTests: XCTestCase {
  private final class FakeService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var refusal: Error?
    func register() throws {
      if let refusal { throw refusal }
      status = .enabled
    }
    func unregister() throws {
      if let refusal { throw refusal }
      status = .notRegistered
    }
  }

  func testSwitchingItOnAndOffGoesThroughTheSystem() {
    let service = FakeService()
    let item = LoginItem(service: service)
    XCTAssertFalse(item.isOn)

    item.setEnabled(true)
    XCTAssertEqual(item.status, .enabled)
    XCTAssertEqual(service.status, .enabled)

    item.setEnabled(false)
    XCTAssertEqual(item.status, .disabled)
  }

  func testNotFoundIsOffNotBroken() {
    let service = FakeService()
    service.status = .notFound
    XCTAssertEqual(LoginItem(service: service).status, .disabled)
  }

  func testAwaitingApprovalIsOnAndSaysSo() {
    let service = FakeService()
    service.status = .requiresApproval
    let item = LoginItem(service: service)
    XCTAssertEqual(item.status, .requiresApproval)
    XCTAssertTrue(item.isOn)
  }

  func testTheStatusIsReadAgainNotRemembered() {
    let service = FakeService()
    let item = LoginItem(service: service)
    item.setEnabled(true)
    service.status = .notRegistered
    item.refresh()
    XCTAssertFalse(item.isOn)
  }

  func testARefusalIsSaidInTheSystemsWords() {
    let service = FakeService()
    service.refusal = NSError(domain: "SMAppServiceErrorDomain", code: 1, userInfo: [
      NSLocalizedDescriptionKey: "Operation not permitted",
    ])
    let item = LoginItem(service: service)
    item.setEnabled(true)
    XCTAssertEqual(item.lastError, "Operation not permitted")
    XCTAssertFalse(item.isOn)

    service.refusal = nil
    item.setEnabled(true)
    XCTAssertNil(item.lastError, "a change that went through clears the last refusal")
  }
}
