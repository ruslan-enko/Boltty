import XCTest
@testable import Boltty

final class AppIconChoiceTests: XCTestCase {
  func testNothingStoredOrAnUnknownNameIsTheDefault() {
    let defaults = isolatedDefaults("boltty.tests.appIcon")
    XCTAssertEqual(AppIconChoice.stored(defaults: defaults), .standard)
    defaults.set("retired", forKey: AppIconChoice.storageKey)
    XCTAssertEqual(AppIconChoice.stored(defaults: defaults), .standard)
    defaults.set("sunset", forKey: AppIconChoice.storageKey)
    XCTAssertEqual(AppIconChoice.stored(defaults: defaults), .sunset)
  }

  func testEveryChoiceHasItsPictureInTheBundle() {
    for choice in AppIconChoice.allCases {
      XCTAssertNotNil(choice.picture, choice.rawValue)
    }
  }
}
