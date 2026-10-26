import Foundation
import XCTest

enum TestDefaults {
  static let folder = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("boltty-test-defaults", isDirectory: true)

  static func suite(_ name: String) -> String {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent(name).path
  }

  static func discard(_ suite: String) {
    UserDefaults().removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(atPath: suite + ".plist")
  }
}

extension XCTestCase {
  func isolatedDefaults(_ prefix: String = "boltty.tests") -> UserDefaults {
    isolatedDefaults(named: "\(prefix).\(UUID().uuidString)")
  }

  func isolatedDefaults(named name: String) -> UserDefaults {
    let suite = TestDefaults.suite(name)
    TestDefaults.discard(suite)
    addTeardownBlock { TestDefaults.discard(suite) }
    return UserDefaults(suiteName: suite)!
  }
}
