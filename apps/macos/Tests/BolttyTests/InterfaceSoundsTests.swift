import AudioToolbox
import XCTest

@testable import Boltty

@MainActor
final class InterfaceSoundsTests: XCTestCase {
  private var everyName: [String] {
    InterfaceSounds.sendVariantNames + [InterfaceSounds.doneName, InterfaceSounds.attentionName]
  }

  func testEverySoundShipsAtTheTopOfTheBundle() {
    for name in everyName {
      XCTAssertNotNil(
        Bundle.main.url(forResource: name, withExtension: InterfaceSounds.fileExtension),
        "\(name).\(InterfaceSounds.fileExtension) is not in the app bundle"
      )
    }
  }

  func testEverySoundIsShortLinearPCM() throws {
    for name in everyName {
      let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: InterfaceSounds.fileExtension))
      var file: AudioFileID?
      XCTAssertEqual(AudioFileOpenURL(url as CFURL, .readPermission, 0, &file), noErr)
      let audio = try XCTUnwrap(file)
      defer { AudioFileClose(audio) }

      var format = AudioStreamBasicDescription()
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      XCTAssertEqual(AudioFileGetProperty(audio, kAudioFilePropertyDataFormat, &size, &format), noErr)
      XCTAssertEqual(format.mFormatID, kAudioFormatLinearPCM, name)

      var seconds: Float64 = 0
      size = UInt32(MemoryLayout<Float64>.size)
      XCTAssertEqual(AudioFileGetProperty(audio, kAudioFilePropertyEstimatedDuration, &size, &seconds), noErr)
      XCTAssertGreaterThan(seconds, 0.05, name)
      XCTAssertLessThan(seconds, 3, name)
    }
  }

  func testTheSendVariantIsNeverTheOnePlayedLast() {
    for last in 0..<3 {
      for draw in 0..<2 {
        let next = InterfaceSounds.nextVariant(after: last, count: 3, random: { _ in draw })
        XCTAssertNotEqual(next, last)
        XCTAssertTrue((0..<3).contains(next))
      }
    }
    for last in 0..<3 {
      let reached = Set((0..<2).map { draw in
        InterfaceSounds.nextVariant(after: last, count: 3, random: { _ in draw })
      })
      XCTAssertEqual(reached, Set(0..<3).subtracting([last]))
    }
  }

  func testTheFirstSendAndASingleVariantDrawFreely() {
    XCTAssertEqual(InterfaceSounds.nextVariant(after: nil, count: 3, random: { _ in 2 }), 2)
    XCTAssertEqual(InterfaceSounds.nextVariant(after: 0, count: 1, random: { _ in 0 }), 0)
  }

  func testBannersAreSilentWhileSoundsAreOff() {
    var enabled = true
    let sounds = InterfaceSounds(isEnabled: { enabled })
    XCTAssertNotNil(sounds.notificationSound(for: .finished))
    XCTAssertNotNil(sounds.notificationSound(for: .needsYou))

    enabled = false
    XCTAssertNil(sounds.notificationSound(for: .finished))
    XCTAssertNil(sounds.notificationSound(for: .needsYou))
  }
}
