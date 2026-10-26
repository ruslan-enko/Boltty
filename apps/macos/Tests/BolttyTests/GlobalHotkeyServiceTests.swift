import Carbon
import XCTest

@testable import Boltty

final class GlobalHotkeyServiceTests: XCTestCase {
  private static let rare = HotkeyBinding(
    keyCode: UInt32(kVK_ANSI_Q),
    carbonModifiers: UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey) | UInt32(shiftKey)
  )
  private static let rarer = HotkeyBinding(
    keyCode: UInt32(kVK_ANSI_M),
    carbonModifiers: UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey) | UInt32(shiftKey)
  )

  private var holder: GlobalHotkeyService?

  override func tearDown() {
    holder?.stop()
    holder = nil
    super.tearDown()
  }

  func testRegisteringAFreeChordSucceedsAndStopReleasesIt() {
    let service = GlobalHotkeyService {}
    holder = service

    XCTAssertEqual(service.register(Self.rare), .free)
    XCTAssertTrue(service.isRunning)

    service.stop()
    XCTAssertFalse(service.isRunning)
    XCTAssertEqual(service.probe(Self.rare), .free)
  }

  func testProbingTwiceDoesNotMakeTheChordTaken() {
    let service = GlobalHotkeyService {}
    holder = service

    XCTAssertEqual(service.probe(Self.rare), .free)
    XCTAssertEqual(service.probe(Self.rare), .free)
  }

  func testProbingAChordTheProcessHoldsReportsTaken() {
    let service = GlobalHotkeyService {}
    holder = service

    XCTAssertEqual(service.register(Self.rare), .free)
    XCTAssertEqual(service.probe(Self.rare), .taken)
  }

  func testASecondRegistrationOfTheSameChordIsRefusedAsTaken() {
    let first = GlobalHotkeyService {}
    let second = GlobalHotkeyService {}
    holder = first

    XCTAssertEqual(first.register(Self.rare), .free)
    XCTAssertEqual(second.register(Self.rare), .taken)
    XCTAssertFalse(second.isRunning)
  }

  func testRegistrationDoesNotFireTheCallback() {
    let fired = Counter()
    let service = GlobalHotkeyService { fired.increment() }
    holder = service

    XCTAssertEqual(service.register(Self.rare), .free)
    XCTAssertEqual(fired.value, 0)
  }

  func testUpdateSwapsRatherThanAccumulates() {
    let service = GlobalHotkeyService {}
    holder = service

    XCTAssertEqual(service.register(Self.rare), .free)
    XCTAssertEqual(service.updateHotkey(Self.rarer), .free)
    XCTAssertEqual(service.probe(Self.rare), .free)
    XCTAssertEqual(service.probe(Self.rarer), .taken)
  }

  func testUpdateOnAnUnregisteredServiceRegisters() {
    let service = GlobalHotkeyService {}
    holder = service

    XCTAssertEqual(service.updateHotkey(Self.rare), .free)
    XCTAssertTrue(service.isRunning)
  }

  func testRegisteringTwiceKeepsOneChord() {
    let service = GlobalHotkeyService {}
    holder = service

    XCTAssertEqual(service.register(Self.rare), .free)
    XCTAssertEqual(service.register(Self.rare), .free)
    service.stop()
    XCTAssertEqual(service.probe(Self.rare), .free)
  }

  func testStopOnAnUnregisteredServiceIsHarmless() {
    let service = GlobalHotkeyService {}
    service.stop()
    XCTAssertFalse(service.isRunning)
  }

  func testTakingOverKeepsTheStandInUntilTheTapHolds() {
    let service = GlobalHotkeyService {}
    holder = service

    XCTAssertEqual(service.register(Self.rare), .free)
    let availability = service.takeOver(with: .optionCommand)
    XCTAssertTrue(service.isRunning)
    if availability.isFree {
      XCTAssertEqual(service.probe(Self.rare), .free, "the tap holds, so the stand-in is let go")
    } else {
      XCTAssertEqual(availability, .needsInputMonitoring)
      XCTAssertEqual(service.probe(Self.rare), .taken, "a refused tap must not cost the stand-in")
    }
  }

  func testTakingOverWithAKeyedChordChangesNothing() {
    let service = GlobalHotkeyService {}
    holder = service

    XCTAssertEqual(service.register(Self.rare), .free)
    XCTAssertEqual(service.takeOver(with: Self.rarer), .failed(status: -1))
    XCTAssertEqual(service.probe(Self.rare), .taken)
    XCTAssertEqual(service.probe(Self.rarer), .free)
  }

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
      lock.lock()
      count += 1
      lock.unlock()
    }
    var value: Int {
      lock.lock()
      defer { lock.unlock() }
      return count
    }
  }

  // MARK: - Availability

  func testAvailabilityMapsCarbonStatus() {
    XCTAssertEqual(HotkeyAvailability(status: noErr), .free)
    XCTAssertEqual(HotkeyAvailability(status: OSStatus(eventHotKeyExistsErr)), .taken)
    XCTAssertEqual(HotkeyAvailability(status: -1), .failed(status: -1))
  }

  func testTheTwoRefusalsAreDistinguished() {
    let binding = HotkeyBinding(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(controlKey))
    XCTAssertTrue(HotkeyAvailability.taken.takenSentence(for: binding).contains("another app"))
    XCTAssertTrue(HotkeyAvailability.failed(status: -1).takenSentence(for: binding).contains("could not"))
  }
}
