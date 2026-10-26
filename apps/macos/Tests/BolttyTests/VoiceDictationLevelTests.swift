import AVFoundation
import XCTest
@testable import Boltty

final class VoiceDictationLevelTests: XCTestCase {
  private func buffer(amplitude: Float, frames: AVAudioFrameCount = 1_024) throws -> AVAudioPCMBuffer {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let channel = try XCTUnwrap(buffer.floatChannelData?[0])
    for index in 0..<Int(frames) {
      channel[index] = amplitude * sinf(Float(index) * 0.05)
    }
    return buffer
  }

  func testSilenceReadsAsZero() throws {
    XCTAssertEqual(VoiceDictationService.loudness(of: try buffer(amplitude: 0)), 0, accuracy: 0.001)
  }

  func testRoomToneIsBelowTheFloor() throws {
    let level = VoiceDictationService.loudness(of: try buffer(amplitude: 0.0005))
    XCTAssertEqual(level, 0, accuracy: 0.001)
  }

  func testOrdinarySpeechUsesTheMiddleOfTheRange() throws {
    let level = VoiceDictationService.loudness(of: try buffer(amplitude: 0.1))
    XCTAssertGreaterThan(level, 0.3)
    XCTAssertLessThan(level, 0.8)
  }

  func testLoudSpeechApproachesOne() throws {
    let level = VoiceDictationService.loudness(of: try buffer(amplitude: 1))
    XCTAssertGreaterThan(level, 0.9)
    XCTAssertLessThanOrEqual(level, 1)
  }

  func testLevelRisesMonotonicallyWithAmplitude() throws {
    let levels = try [0.01, 0.05, 0.2, 0.5, 1.0].map {
      VoiceDictationService.loudness(of: try buffer(amplitude: Float($0)))
    }
    XCTAssertEqual(levels, levels.sorted())
  }
}
