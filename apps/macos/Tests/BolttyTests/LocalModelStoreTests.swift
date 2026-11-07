import CryptoKit
import XCTest
@testable import Boltty

@MainActor
final class LocalModelStoreTests: XCTestCase {
  private var root: URL!
  private var fetcher: FakeModelFetcher!
  private var model: LocalVoiceModel!
  private let preparedFolders = PreparedFolders()
  private var prepared: [URL] { preparedFolders.urls }

  override func setUp() async throws {
    try await super.setUp()
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-models-tests-\(UUID().uuidString)")
    fetcher = FakeModelFetcher(bodies: [
      "a.json": Data("{\"a\":1}".utf8),
      "Model.mlmodelc/weights/weight.bin": Data(repeating: 7, count: 4096),
      "Model.mlmodelc/model.mil": Data("program".utf8),
    ])
    model = LocalVoiceModel(
      id: .supertonic3, name: "Supertonic", repository: "Org/repo",
      revision: "0123456789abcdef0123456789abcdef01234567",
      licence: .init(name: "MIT", url: URL(string: "https://example.com")!),
      files: ["a.json", "Model.mlmodelc/model.mil", "Model.mlmodelc/weights/weight.bin"].map { path in
        let body = fetcher.bodies[path]!
        return .init(path: path, size: Int64(body.count), sha256: SHA256.hash(data: body).hex)
      })
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: root)
    try await super.tearDown()
  }

  func testNothingIsInstalledAtFirst() {
    let store = makeStore()
    XCTAssertEqual(store.state(of: .supertonic3), .notInstalled)
    XCTAssertNil(store.folder(of: .supertonic3))
  }

  func testInstallingDownloadsChecksPreparesAndIsReady() async throws {
    let store = makeStore()
    var seen: [LocalModelStore.State] = []
    let watch = store.$states.sink { seen.append($0[.supertonic3] ?? .notInstalled) }
    defer { watch.cancel() }

    await store.install(.supertonic3)

    XCTAssertEqual(store.state(of: .supertonic3), .ready)
    let folder = try XCTUnwrap(store.folder(of: .supertonic3))
    XCTAssertEqual(folder.lastPathComponent, model.folderName)
    XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Model.mlmodelc/model.mil")), Data("program".utf8))
    XCTAssertEqual(prepared, [folder], "Core ML compiles once, right after the download")
    XCTAssertTrue(seen.contains { if case .downloading = $0 { true } else { false } })
    XCTAssertTrue(seen.contains(.preparing))
    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path), "the half-made folder is gone")
  }

  func testAFileThatDoesNotMatchItsDigestInstallsNothing() async {
    fetcher.bodies["a.json"] = Data("{\"a\":2}".utf8)
    let store = makeStore()

    await store.install(.supertonic3)

    guard case let .failed(message) = store.state(of: .supertonic3) else {
      return XCTFail("expected a failure, got \(store.state(of: .supertonic3))")
    }
    XCTAssertTrue(message.contains("checksum"), message)
    XCTAssertNil(store.folder(of: .supertonic3))
    XCTAssertTrue(prepared.isEmpty)
  }

  func testADownloadThatStopsHalfwayResumesWithWhatIsMissing() async {
    fetcher.failing = ["Model.mlmodelc/weights/weight.bin"]
    let store = makeStore()
    await store.install(.supertonic3)
    guard case .failed = store.state(of: .supertonic3) else { return XCTFail("the first try should fail") }

    fetcher.failing = []
    fetcher.requested = []
    await store.install(.supertonic3)

    XCTAssertEqual(store.state(of: .supertonic3), .ready)
    XCTAssertEqual(fetcher.requested, ["Model.mlmodelc/weights/weight.bin"], "files already checked are not fetched again")
  }

  func testATransientFailureIsRetried() async {
    fetcher.failuresLeft = ["a.json": 2]
    let store = makeStore()

    await store.install(.supertonic3)

    XCTAssertEqual(store.state(of: .supertonic3), .ready)
  }

  func testAStoreOpenedAgainFindsTheModelReady() async {
    await makeStore().install(.supertonic3)
    let again = makeStore()
    XCTAssertEqual(again.state(of: .supertonic3), .ready)
    XCTAssertNotNil(again.folder(of: .supertonic3))
  }

  func testAFolderMissingAFileIsNotReady() async throws {
    await makeStore().install(.supertonic3)
    try FileManager.default.removeItem(at: root.appendingPathComponent(model.folderName).appendingPathComponent("a.json"))

    let again = makeStore()
    XCTAssertEqual(again.state(of: .supertonic3), .notInstalled)

    fetcher.requested = []
    await again.install(.supertonic3)
    XCTAssertEqual(again.state(of: .supertonic3), .ready)
    XCTAssertEqual(fetcher.requested, ["a.json"])
  }

  func testRemovingDeletesTheFolder() async {
    let store = makeStore()
    await store.install(.supertonic3)

    store.remove(.supertonic3)

    XCTAssertEqual(store.state(of: .supertonic3), .notInstalled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(model.folderName).path))
  }

  func testAnotherRevisionLeftOnDiskIsCleared() throws {
    let old = root.appendingPathComponent("supertonic-3-ffffffffffff")
    let oldPartial = root.appendingPathComponent("supertonic-3-eeeeeeeeeeee.partial")
    let unknown = root.appendingPathComponent("something-else")
    for folder in [old, oldPartial, unknown] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    _ = makeStore()

    XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldPartial.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path), "only Boltty's own model folders are touched")
  }

  func testASecondCopyDownloadsAndDeletesNothing() async throws {
    let old = root.appendingPathComponent("supertonic-3-ffffffffffff")
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    let store = makeStore(canWrite: false)

    await store.install(.supertonic3)

    guard case let .failed(message) = store.state(of: .supertonic3) else { return XCTFail("a second copy must refuse") }
    XCTAssertTrue(message.contains("Another Boltty"), message)
    XCTAssertTrue(fetcher.requested.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
  }

  func testTooLittleDiskSpaceIsSaidBeforeDownloading() async {
    let store = makeStore(freeSpace: model.size)

    await store.install(.supertonic3)

    guard case let .failed(message) = store.state(of: .supertonic3) else { return XCTFail("expected a refusal") }
    XCTAssertTrue(message.contains("space"), message)
    XCTAssertTrue(fetcher.requested.isEmpty)
  }

  func testAModelThatDoesNotLoadOnThisMacIsNotKept() async {
    let store = makeStore(prepare: { _ in throw CocoaError(.fileReadCorruptFile) })

    await store.install(.supertonic3)

    guard case .failed = store.state(of: .supertonic3) else { return XCTFail("expected a failure") }
    XCTAssertNil(store.folder(of: .supertonic3))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(model.folderName).path))
  }

  func testCancellingStopsAndKeepsWhatWasChecked() async {
    fetcher.delay = 0.2
    let store = makeStore()
    let install = Task { await store.install(.supertonic3) }
    try? await Task.sleep(nanoseconds: 50_000_000)

    store.cancel(.supertonic3)
    await install.value

    XCTAssertEqual(store.state(of: .supertonic3), .notInstalled)
    XCTAssertNil(store.folder(of: .supertonic3))
  }

  func testInstallingTwiceAtOnceDownloadsOnce() async {
    let store = makeStore()
    async let first: Void = store.install(.supertonic3)
    async let second: Void = store.install(.supertonic3)
    _ = await (first, second)

    XCTAssertEqual(fetcher.requested.count, model.files.count)
    XCTAssertEqual(prepared.count, 1)
  }

  // MARK: - Support

  private var partial: URL { root.appendingPathComponent(model.folderName + ".partial") }

  private func makeStore(
    canWrite: Bool = true,
    freeSpace: Int64? = nil,
    prepare: (@Sendable (URL) throws -> Void)? = nil
  ) -> LocalModelStore {
    let record = preparedFolders
    return LocalModelStore(
      root: root, models: [model], fetcher: fetcher,
      prepare: prepare ?? { record.add($0) },
      freeSpace: { _ in freeSpace },
      canWrite: { canWrite })
  }
}

final class FakeModelFetcher: LocalModelFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var _bodies: [String: Data]
  private var _requested: [String] = []
  var failing: Set<String> = []
  var failuresLeft: [String: Int] = [:]
  var delay: TimeInterval = 0

  init(bodies: [String: Data]) { _bodies = bodies }

  var bodies: [String: Data] {
    get { lock.withLock { _bodies } }
    set { lock.withLock { _bodies = newValue } }
  }

  var requested: [String] {
    get { lock.withLock { _requested } }
    set { lock.withLock { _requested = newValue } }
  }

  func fetch(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
    let path = url.pathComponents.drop { $0 != "resolve" }.dropFirst(2).joined(separator: "/")
    lock.withLock { _requested.append(path) }
    if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
    let failNow: Bool = lock.withLock {
      if let left = failuresLeft[path], left > 0 { failuresLeft[path] = left - 1; return true }
      return failing.contains(path)
    }
    if failNow { throw URLError(.networkConnectionLost) }
    guard let body = bodies[path] else { throw URLError(.fileDoesNotExist) }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try body.write(to: file)
    progress(Int64(body.count))
    return file
  }
}

private final class PreparedFolders: @unchecked Sendable {
  private let lock = NSLock()
  private var added: [URL] = []
  var urls: [URL] { lock.withLock { added } }
  func add(_ url: URL) { lock.withLock { added.append(url) } }
}

private extension SHA256.Digest {
  var hex: String { map { String(format: "%02x", $0) }.joined() }
}
