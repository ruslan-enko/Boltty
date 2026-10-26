import UniformTypeIdentifiers
import XCTest
@testable import Boltty

final class PromptAttachmentStoreTests: XCTestCase {
  private var directory: URL!
  private var store: PromptAttachmentStore!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-pasteboard-tests-\(UUID().uuidString)")
    store = PromptAttachmentStore(directory: directory)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  func testImageBytesLandOnDiskWithAMeaningfulExtension() throws {
    let bytes = Data([0x89, 0x50, 0x4E, 0x47])
    let attachment = PromptAttachment(
      kind: .image,
      payload: .imageData(bytes, type: .png),
      label: "image1"
    )

    let url = try store.fileURL(for: attachment)
    XCTAssertEqual(url.pathExtension, "png", "the agent decides what to do from the extension")
    XCTAssertEqual(try Data(contentsOf: url), bytes)
  }

  func testOversizedTextIsWrittenAsUTF8Text() throws {
    let text = String(repeating: "рядок\n", count: 100)
    let attachment = PromptAttachment(kind: .text, payload: .text(text), label: "text1")

    let url = try store.fileURL(for: attachment)
    XCTAssertEqual(url.pathExtension, "txt")
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
  }

  func testAFileAlreadyOnDiskIsHandedBackUntouched() throws {
    let existing = URL(fileURLWithPath: "/x/clip.mov")
    let attachment = PromptAttachment.file(existing)
    XCTAssertEqual(try store.fileURL(for: attachment), existing)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.path),
      "nothing to write means the directory is not even created"
    )
  }

  func testWritingTheSameAttachmentTwiceKeepsOneFile() throws {
    let attachment = PromptAttachment(
      kind: .image,
      payload: .imageData(Data([0x01]), type: .png),
      label: "image1"
    )

    let first = try store.fileURL(for: attachment)
    let second = try store.fileURL(for: attachment)
    XCTAssertEqual(first, second)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).count,
      1
    )
  }

  func testTwoChipsWithTheSameNameDoNotCollide() throws {
    let make = {
      PromptAttachment(kind: .image, payload: .imageData(Data([0x01]), type: .png), label: "image1")
    }
    let first = try store.fileURL(for: make())
    let second = try store.fileURL(for: make())
    XCTAssertNotEqual(first, second, "identity is the chip, not its generated name")
  }

  func testAWriteFailureSurfacesAsSomethingTheUserCanRead() {
    let blocker = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-blocker-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: blocker.path, contents: Data())
    defer { try? FileManager.default.removeItem(at: blocker) }

    let blocked = PromptAttachmentStore(directory: blocker.appendingPathComponent("inside"))
    let attachment = PromptAttachment(
      kind: .image,
      payload: .imageData(Data([0x01]), type: .png),
      label: "image1"
    )

    XCTAssertThrowsError(try blocked.fileURL(for: attachment)) { error in
      XCTAssertEqual(
        error as? PromptExpansionError,
        .attachmentUnavailable("image1")
      )
    }
  }

  // MARK: - Cleanup (D11)

  func testOnlyEntriesPastTheAgeLimitAreRemoved() throws {
    let now = Date()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let stale = try write("stale.png", modified: now.addingTimeInterval(-8 * 24 * 3600))
    let fresh = try write("fresh.png", modified: now.addingTimeInterval(-6 * 24 * 3600))

    XCTAssertEqual(store.purgeExpired(now: now), 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
  }

  func testPurgingAMissingDirectoryIsNotAnError() {
    XCTAssertEqual(store.purgeExpired(now: Date()), 0)
  }

  private func write(_ name: String, modified: Date) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data([0x01]).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    return url
  }
}
