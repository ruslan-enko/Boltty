import CoreML
import Foundation

final class ParakeetTranscriber: @unchecked Sendable {
  enum Failure: LocalizedError {
    case missing(String)
    case stage(String, String)

    var errorDescription: String? {
      switch self {
      case let .missing(file): "Parakeet is missing \(file)."
      case let .stage(stage, reason): "Parakeet's \(stage) failed: \(reason)"
      }
    }
  }

  static let sampleRate = 16_000
  static let windowSamples = 240_000
  static let frameSamples = 1_280
  static let contextFrames = 20

  private let preprocessor: MLModel
  private let encoder: MLModel
  private let decoder: MLModel
  private let joint: MLModel
  private let vocabulary: [Int: String]
  private static let encoderSize = 1_024
  private static let decoderSize = 640
  private static let layers = 2

  init(folder: URL) throws {
    func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
      let url = folder.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.missing(name) }
      let options = MLModelConfiguration()
      options.computeUnits = units
      return try MLModel(contentsOf: url, configuration: options)
    }
    preprocessor = try load("Preprocessor.mlmodelc", .cpuOnly)
    encoder = try load("Encoder.mlmodelc", .cpuAndNeuralEngine)
    decoder = try load("Decoder.mlmodelc", .cpuAndNeuralEngine)
    joint = try load("JointDecisionv3.mlmodelc", .cpuAndNeuralEngine)
    let url = folder.appendingPathComponent("parakeet_vocab.json")
    guard let data = try? Data(contentsOf: url),
          let pieces = try? JSONDecoder().decode([String: String].self, from: data)
    else { throw Failure.missing("parakeet_vocab.json") }
    vocabulary = Dictionary(uniqueKeysWithValues: pieces.compactMap { key, value in
      Int(key).map { ($0, value) }
    })
  }

  func transcribe(_ samples: [Float]) throws -> String {
    Self.text(of: try tokens(in: samples), vocabulary: vocabulary)
  }

  func tokens(in samples: [Float]) throws -> [ParakeetTDT<[Float]>.Token] {
    guard samples.count >= Self.frameSamples else { return [] }
    var frames: MLMultiArray?
    let tdt = ParakeetTDT<[Float]>(
      predict: { [self] token, state in try predict(token, state) },
      joint: { [self] frame, projection in try decide(frames!, frame, projection) })
    var memory = try tdt.start(from: [Float](repeating: 0, count: 2 * Self.layers * Self.decoderSize))
    var tokens: [ParakeetTDT<[Float]>.Token] = []
    var position = 0
    while true {
      let first = max(0, position - Self.contextFrames)
      let start = first * Self.frameSamples
      let window = Array(samples[start..<min(samples.count, start + Self.windowSamples)])
      let last = start + Self.windowSamples >= samples.count
      let (encoded, valid) = try encode(window)
      frames = encoded
      let heard = min(valid, (window.count + Self.frameSamples - 1) / Self.frameSamples)
      let end = last ? heard : max(position - first + 1, heard - Self.contextFrames)
      let result = try tdt.decode(
        from: position - first, to: end, offset: first, last: last, memory: &memory)
      tokens += result.tokens
      if last { break }
      position = max(first + result.reached, position + 1)
    }
    return tokens
  }

  static func text(of tokens: [ParakeetTDT<[Float]>.Token], vocabulary: [Int: String]) -> String {
    tokens.compactMap { vocabulary[$0.id] }
      .filter { !($0.hasPrefix("<") && $0.hasSuffix(">")) }
      .joined()
      .replacingOccurrences(of: "\u{2581}", with: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  // MARK: - Stages

  private func encode(_ window: [Float]) throws -> (MLMultiArray, Int) {
    var padded = window
    padded += [Float](repeating: 0, count: Self.windowSamples - window.count)
    let audio = try MLArrays.floats(padded, shape: [1, Self.windowSamples])
    let length = try MLArrays.ints([Int32(window.count)], shape: [1])
    let mel = try run("preprocessor", preprocessor, ["audio_signal": audio, "audio_length": length])
    guard let features = mel.featureValue(for: "mel")?.multiArrayValue,
          let melLength = mel.featureValue(for: "mel_length")?.multiArrayValue
    else { throw Failure.stage("preprocessor", "no mel") }
    let encoded = try run("encoder", encoder, ["mel": features, "mel_length": melLength])
    guard let frames = encoded.featureValue(for: "encoder")?.multiArrayValue,
          let count = encoded.featureValue(for: "encoder_length")?.multiArrayValue
    else { throw Failure.stage("encoder", "no frames") }
    return (frames, count[0].intValue)
  }

  private func predict(_ token: Int, _ state: [Float]) throws -> (projection: [Float], state: [Float]) {
    let half = Self.layers * Self.decoderSize
    let output = try run("decoder", decoder, [
      "targets": try MLArrays.ints([Int32(token)], shape: [1, 1]),
      "target_length": try MLArrays.ints([1], shape: [1]),
      "h_in": try MLArrays.floats(Array(state[..<half]), shape: [Self.layers, 1, Self.decoderSize]),
      "c_in": try MLArrays.floats(Array(state[half...]), shape: [Self.layers, 1, Self.decoderSize]),
    ])
    guard let projection = output.featureValue(for: "decoder")?.multiArrayValue,
          let h = output.featureValue(for: "h_out")?.multiArrayValue,
          let c = output.featureValue(for: "c_out")?.multiArrayValue
    else { throw Failure.stage("decoder", "no output") }
    return (MLArrays.values(projection), MLArrays.values(h) + MLArrays.values(c))
  }

  private func decide(
    _ frames: MLMultiArray, _ frame: Int, _ projection: [Float]
  ) throws -> ParakeetTDT<[Float]>.Decision {
    let output = try run("joint", joint, [
      "encoder_step": try MLArrays.floats(Self.column(frames, frame), shape: [1, Self.encoderSize, 1]),
      "decoder_step": try MLArrays.floats(projection, shape: [1, Self.decoderSize, 1]),
    ])
    guard let token = output.featureValue(for: "token_id")?.multiArrayValue,
          let duration = output.featureValue(for: "duration")?.multiArrayValue
    else { throw Failure.stage("joint", "no decision") }
    return .init(token: token[0].intValue, duration: duration[0].intValue)
  }

  private func run(
    _ stage: String, _ model: MLModel, _ inputs: [String: MLMultiArray]
  ) throws -> MLFeatureProvider {
    do {
      return try model.prediction(from: MLDictionaryFeatureProvider(
        dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) }))
    } catch {
      throw Failure.stage(stage, error.localizedDescription)
    }
  }

  // MARK: - Arrays

  private static func column(_ frames: MLMultiArray, _ index: Int) -> [Float] {
    let strides = frames.strides.map(\.intValue)
    let count = frames.shape[1].intValue
    let frame = min(index, frames.shape[2].intValue - 1)
    switch frames.dataType {
    case .float16:
      let source = frames.dataPointer.bindMemory(to: UInt16.self, capacity: frames.count)
      let bits = (0..<count).map { source[$0 * strides[1] + frame * strides[2]] }
      return bits.withUnsafeBufferPointer(MLArrays.halves)
    default:
      let source = frames.dataPointer.bindMemory(to: Float.self, capacity: frames.count)
      return (0..<count).map { source[$0 * strides[1] + frame * strides[2]] }
    }
  }
}
