import CoreGraphics
import XCTest
@testable import Boltty

final class ModifierHoldMonitorTests: XCTestCase {
  private let chord: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
  private var monitor: ModifierHoldMonitor!
  private var pending: [() -> Void] = []
  private var events: [String] = []

  override func setUp() {
    monitor = ModifierHoldMonitor(chord: chord)
    monitor.schedule = { [unowned self] _, work in pending.append(work) }
    monitor.onBegin = { [unowned self] in events.append("begin") }
    monitor.onEnd = { [unowned self] in events.append("end") }
    monitor.onCancel = { [unowned self] in events.append("cancel") }
  }

  private func elapse() {
    let work = pending; pending = []
    work.forEach { $0() }
  }

  func testHeldItBeginsAndLetGoItEnds() {
    monitor.modifiers([.maskControl])
    monitor.modifiers([.maskControl, .maskAlternate])
    monitor.modifiers(chord)
    XCTAssertEqual(events, [], "nothing until it has been held")
    elapse()
    XCTAssertEqual(events, ["begin"])
    monitor.modifiers([.maskControl, .maskAlternate])
    XCTAssertEqual(events, ["begin", "end"])
    monitor.modifiers([])
    XCTAssertEqual(events, ["begin", "end"], "letting go of the rest ends nothing twice")
  }

  func testAQuickChordOfAnotherAppNeverBegins() {
    monitor.modifiers(chord)
    monitor.otherInput()
    elapse()
    monitor.modifiers([])
    XCTAssertEqual(events, [])
  }

  func testAKeyWhileHeldCancels() {
    monitor.modifiers(chord)
    elapse()
    monitor.otherInput()
    monitor.modifiers([])
    XCTAssertEqual(events, ["begin", "cancel"])
  }

  func testAFourthModifierCancels() {
    monitor.modifiers(chord)
    elapse()
    monitor.modifiers(chord.union(.maskShift))
    monitor.modifiers([])
    XCTAssertEqual(events, ["begin", "cancel"])
  }

  func testAModifierAboveTheChordFromTheStartIsNotAskBoltty() {
    monitor.modifiers([.maskShift])
    monitor.modifiers(chord.union(.maskShift))
    monitor.modifiers(chord)
    elapse()
    XCTAssertEqual(events, [], "spent until every modifier is up")
    monitor.modifiers([])
    monitor.modifiers(chord)
    elapse()
    XCTAssertEqual(events, ["begin"])
  }

  func testLettingGoBeforeTheDelayBeginsNothing() {
    monitor.modifiers(chord)
    monitor.modifiers([])
    elapse()
    XCTAssertEqual(events, [])
  }
}
