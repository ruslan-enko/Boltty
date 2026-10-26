import AppKit
import XCTest
@testable import Boltty

@MainActor
final class AppPresenceTests: XCTestCase {
  private func makePresence() -> (
    presence: AppPresence,
    policies: () -> [NSApplication.ActivationPolicy],
    activations: () -> [Bool]
  ) {
    var policies: [NSApplication.ActivationPolicy] = []
    var activations: [Bool] = []
    let presence = AppPresence(
      applyPolicy: { policies.append($0) },
      setActive: { activations.append($0) }
    )
    return (presence, { policies }, { activations })
  }

  func testEnteringTrayOnlyDropsTheDockIconAndHandsBackTheMenuBar() {
    let (presence, policies, activations) = makePresence()

    presence.enterTrayOnly()

    XCTAssertTrue(presence.isTrayOnly)
    XCTAssertEqual(policies(), [.accessory])
    XCTAssertEqual(activations(), [false], "the menu bar must go to whatever is behind us")
  }

  func testComingBackIsARegularAppAgain() {
    let (presence, policies, activations) = makePresence()

    presence.enterTrayOnly()
    presence.enterForeground()

    XCTAssertFalse(presence.isTrayOnly)
    XCTAssertEqual(policies(), [.accessory, .regular])
    XCTAssertEqual(activations(), [false, true])
  }

  func testRepeatedCallsInTheSameStateChangeNothing() {
    let (presence, policies, _) = makePresence()

    presence.enterForeground()
    XCTAssertEqual(policies(), [], "launch is already a regular app")

    presence.enterTrayOnly()
    presence.enterTrayOnly()
    presence.enterForeground()
    presence.enterForeground()

    XCTAssertEqual(policies(), [.accessory, .regular])
  }

  func testTrayPresentationWaitsForTheNextRunLoopAfterRestoringRegularPolicy() {
    var scheduled: [() -> Void] = []
    var didPresent = false
    let presence = AppPresence(
      applyPolicy: { _ in },
      setActive: { _ in },
      scheduleOnNextRunLoop: { scheduled.append($0) }
    )
    presence.enterTrayOnly()

    presence.enterForeground { didPresent = true }

    XCTAssertFalse(didPresent)
    XCTAssertEqual(scheduled.count, 1)
    scheduled.first?()
    XCTAssertTrue(didPresent)
  }

  func testPresentationIsImmediateWhenTheAppIsAlreadyRegular() {
    var scheduled = 0
    var didPresent = false
    let presence = AppPresence(
      applyPolicy: { _ in },
      setActive: { _ in },
      scheduleOnNextRunLoop: { _ in scheduled += 1 }
    )

    presence.enterForeground { didPresent = true }

    XCTAssertTrue(didPresent)
    XCTAssertEqual(scheduled, 0)
  }
}

@MainActor
final class BackgroundActivityAssertionTests: XCTestCase {
  private final class Ledger {
    var begun: [(ProcessInfo.ActivityOptions, String)] = []
    var ended = 0
  }

  private func makeAssertion() -> (BackgroundActivityAssertion, Ledger) {
    let ledger = Ledger()
    let assertion = BackgroundActivityAssertion(
      begin: { options, reason in
        ledger.begun.append((options, reason))
        return NSObject()
      },
      end: { _ in ledger.ended += 1 }
    )
    return (assertion, ledger)
  }

  func testTheActivityIsHeldWhileSessionsExistAndReleasedWhenTheLastOneGoes() {
    let (assertion, ledger) = makeAssertion()

    assertion.setNeeded(true)
    XCTAssertTrue(assertion.isHeld)
    XCTAssertEqual(ledger.begun.count, 1)

    assertion.setNeeded(false)
    XCTAssertFalse(assertion.isHeld)
    XCTAssertEqual(ledger.ended, 1)
  }

  func testAskingTwiceTakesOneToken() {
    let (assertion, ledger) = makeAssertion()

    assertion.setNeeded(true)
    assertion.setNeeded(true)
    assertion.setNeeded(false)
    assertion.setNeeded(false)

    XCTAssertEqual(ledger.begun.count, 1)
    XCTAssertEqual(ledger.ended, 1)
  }

  func testTheActivityLeavesIdleSleepAlone() {
    let (assertion, ledger) = makeAssertion()

    assertion.setNeeded(true)

    let options = try? XCTUnwrap(ledger.begun.first?.0)
    XCTAssertEqual(options, .userInitiatedAllowingIdleSystemSleep)
    XCTAssertFalse(options?.contains(.idleSystemSleepDisabled) ?? true)
  }
}
