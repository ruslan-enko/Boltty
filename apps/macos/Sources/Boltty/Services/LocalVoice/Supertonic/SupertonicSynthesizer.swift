// The inference flow is ported from FluidAudio's Supertonic3Synthesizer,
// Supertonic3LatentSampler and Supertonic3ModelStore
// (github.com/FluidInference/FluidAudio, Apache-2.0), which follow Supertone's
// reference implementation (github.com/supertone-inc/supertonic).

import CoreML
import Foundation

/// Supertonic-3 on Core ML: text in, 44.1 kHz mono samples out.
///
/// Four stages per pass: the duration predictor says how long the speech
/// runs, the text encoder embeds the characters, a vector estimator turns
/// noise into a latent in eight steps, and the vocoder makes the wave. The
/// estimator is the Neural Engine build, fixed at latent lengths 128, 256 and
/// 512; a pass is padded up to the smallest that holds it.
///
/// Loading and predicting block, so one of these lives on a serial queue
/// (`SupertonicSpeaker`) and is never touched from two threads.
final class SupertonicSynthesizer: @unchecked Sendable {
  enum Failure: LocalizedError {
    case missing(String)
    case badVoice(String)
    case stage(String, String)

    var errorDescription: String? {
      switch self {
      case let .missing(file): "Supertonic is missing \(file)."
      case let .badVoice(name): "Supertonic's voice \(name) could not be read."
      case let .stage(stage, reason): "Supertonic's \(stage) failed: \(reason)"
      }
    }
  }

  /// One of the ten presets: the speaker's timbre, as two style tensors.
  struct Voice {
    let name: String
    /// `[1, 50, 256]`, for the text encoder and the estimator.
    let ttl: MLMultiArray
    /// `[1, 8, 16]`, for the duration predictor.
    let dp: MLMultiArray
  }

  static let sampleRate = 44_100
  static let buckets = [128, 256, 512]
  static let steps = 8
  /// The reference's speed; Boltty's rate multiplies it.
  static let baseSpeed: Float = 1.05

  private let folder: URL
  private let indexer: [Int32]
  private let chunkSize: Int
  private let channels: Int
  private let durationPredictor: MLModel
  private let textEncoder: MLModel
  private let estimators: [Int: MLModel]
  private let vocoder: MLModel
  private var voices: [String: Voice] = [:]

  /// Loads every stage. From Core ML's cache this takes about a second; the
  /// first load after a download compiles for the Neural Engine and takes
  /// longer, which is why the store does it once while "preparing".
  init(folder: URL) throws {
    self.folder = folder
    let config = try Self.config(in: folder)
    chunkSize = config.baseChunkSize * config.chunkCompress
    channels = config.latentDim * config.chunkCompress
    indexer = try Self.indexer(in: folder)
    let options = MLModelConfiguration()
    options.computeUnits = .cpuAndNeuralEngine
    func load(_ path: String) throws -> MLModel {
      let url = folder.appendingPathComponent(path)
      guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.missing(path) }
      return try MLModel(contentsOf: url, configuration: options)
    }
    durationPredictor = try load("DurationPredictor_v2.mlmodelc")
    textEncoder = try load("TextEncoder_v2.mlmodelc")
    vocoder = try load("Vocoder.mlmodelc")
    var estimators: [Int: MLModel] = [:]
    for bucket in Self.buckets {
      estimators[bucket] = try load(
        "VectorEstimatorVariants/VectorEstimator_v2_L\(bucket)_int8.mlmodelc")
    }
    self.estimators = estimators
  }

  /// The ten presets the model comes with, `F1`–`F5` and `M1`–`M5`.
  static let presets = ["F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5"]

  func voice(_ name: String) throws -> Voice {
    if let voice = voices[name] { return voice }
    guard Self.presets.contains(name) else { throw Failure.badVoice(name) }
    let url = folder.appendingPathComponent("voice_styles/\(name).json")
    guard
      let data = try? Data(contentsOf: url),
      let style = try? JSONDecoder().decode(Style.self, from: data),
      style.ttl.dims == [1, 50, 256], style.dp.dims == [1, 8, 16]
    else { throw Failure.badVoice(name) }
    let voice = Voice(
      name: name,
      ttl: try Self.floats(style.ttl.data.flatMap { $0.flatMap { $0 } }, shape: style.ttl.dims),
      dp: try Self.floats(style.dp.data.flatMap { $0.flatMap { $0 } }, shape: style.dp.dims))
    voices[name] = voice
    return voice
  }

  /// A piece of an answer — a sentence, usually — as one stretch of sound:
  /// cut into passes the window holds, and within a pass into runs of one
  /// script, joined without the silence each run ends on.
  func say(_ piece: String, language: String, voice: Voice, speed: Float) throws -> [Float] {
    var samples: [Float] = []
    for pass in SupertonicText.passes(piece, limit: SupertonicText.passLength(for: language)) {
      let runs = SupertonicText.runs(pass, language: language)
      var spoken: [Float] = []
      for (index, run) in runs.enumerated() {
        let last = index == runs.count - 1
        let tagged = SupertonicText.tagged(run.text, language: run.language, last: last)
        guard !tagged.isEmpty else { continue }
        let part = try synthesize(tagged: tagged, voice: voice, speed: speed)
        spoken += Self.joint(part, trimStart: index > 0, trimEnd: !last)
      }
      if !samples.isEmpty { samples += [Float](repeating: 0, count: Self.sampleRate / 20) }
      samples += spoken
    }
    return samples
  }

  /// A run cut at a joint keeps a breath of its quiet edge: 70 ms after the
  /// last sound, 15 ms before the first. Without the cut a word said in
  /// English stood between two pauses, pasted in.
  static func joint(_ samples: [Float], trimStart: Bool, trimEnd: Bool) -> [Float] {
    let quiet: Float = 0.02
    var end = samples.count
    var start = 0
    if trimEnd, let last = samples.lastIndex(where: { abs($0) > quiet }) {
      end = min(samples.count, last + 1 + sampleRate * 70 / 1000)
    }
    if trimStart, let first = samples.firstIndex(where: { abs($0) > quiet }) {
      start = max(0, first - sampleRate * 15 / 1000)
    }
    return start < end ? Array(samples[start..<end]) : []
  }

  /// One pass: `tagged` is `SupertonicText.tagged`'s output, at most a
  /// window long. `speed` divides the predicted duration.
  func synthesize(tagged: String, voice: Voice, speed: Float) throws -> [Float] {
    let (ids, maskValues) = SupertonicText.encode(tagged, indexer: indexer)
    let textIDs = try Self.ints(ids, shape: [1, SupertonicText.window])
    let textMask = try Self.floats(maskValues, shape: [1, 1, SupertonicText.window])

    let predicted = try predict("duration predictor", durationPredictor, [
      "text_ids": textIDs, "text_mask": textMask, "style_dp": voice.dp,
    ], output: "duration")
    let seconds = max(0.05, (Self.values(predicted).first ?? 0) / max(speed, 0.05))

    let textEmbedding = try predict("text encoder", textEncoder, [
      "text_ids": textIDs, "text_mask": textMask, "style_ttl": voice.ttl,
    ], output: "text_emb")

    let samples = Int(seconds * Float(Self.sampleRate))
    let length = max(1, (samples + chunkSize - 1) / chunkSize)
    guard let bucket = Self.buckets.first(where: { $0 >= length }), let estimator = estimators[bucket]
    else { throw Failure.stage("vector estimator", "\(length) is longer than the longest bucket") }

    var latent = try Self.floats(
      Self.noise(channels: channels, length: length, padded: bucket), shape: [1, channels, bucket])
    let latentMask = try Self.floats(
      (0..<bucket).map { $0 < length ? 1 : 0 }, shape: [1, 1, bucket])
    let total = try Self.floats([Float(Self.steps)], shape: [1])
    for step in 0..<Self.steps {
      latent = try predict("vector estimator", estimator, [
        "noisy_latent": latent, "text_emb": textEmbedding, "style_ttl": voice.ttl,
        "latent_mask": latentMask, "text_mask": textMask,
        "current_step": try Self.floats([Float(step)], shape: [1]), "total_step": total,
      ], output: "denoised_latent")
      if latent.dataType != .float32 || latent.count != channels * bucket || latent.shape.count != 3 {
        latent = try Self.floats(Self.values(latent), shape: [1, channels, bucket])
      }
    }

    // The vocoder takes any length: the padding goes before it.
    let trimmed = try Self.floats(
      Self.trim(Self.values(latent), channels: channels, from: bucket, to: length),
      shape: [1, channels, length])
    let wave = Self.values(try predict("vocoder", vocoder, ["latent": trimmed], output: "wav"))
    return Array(wave.prefix(min(wave.count, samples)))
  }

  // MARK: - Core ML

  private func predict(
    _ stage: String, _ model: MLModel, _ inputs: [String: MLMultiArray], output: String
  ) throws -> MLMultiArray {
    do {
      let provider = try MLDictionaryFeatureProvider(
        dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) })
      guard let value = try model.prediction(from: provider).featureValue(for: output)?.multiArrayValue
      else { throw Failure.stage(stage, "no \(output)") }
      return value
    } catch let failure as Failure {
      throw failure
    } catch {
      throw Failure.stage(stage, error.localizedDescription)
    }
  }

  static func floats(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
    let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
    precondition(array.count == values.count, "\(values.count) values for shape \(shape)")
    values.withUnsafeBufferPointer { source in
      array.dataPointer.bindMemory(to: Float.self, capacity: values.count)
        .update(from: source.baseAddress!, count: values.count)
    }
    return array
  }

  static func ints(_ values: [Int32], shape: [Int]) throws -> MLMultiArray {
    let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .int32)
    precondition(array.count == values.count, "\(values.count) values for shape \(shape)")
    values.withUnsafeBufferPointer { source in
      array.dataPointer.bindMemory(to: Int32.self, capacity: values.count)
        .update(from: source.baseAddress!, count: values.count)
    }
    return array
  }

  /// The array's contents as Float, whatever Core ML chose to store.
  static func values(_ array: MLMultiArray) -> [Float] {
    let count = array.count
    switch array.dataType {
    case .float32:
      return Array(UnsafeBufferPointer(
        start: array.dataPointer.bindMemory(to: Float.self, capacity: count), count: count))
    case .float16:
      let source = array.dataPointer.bindMemory(to: Float16.self, capacity: count)
      return (0..<count).map { Float(source[$0]) }
    case .double:
      let source = array.dataPointer.bindMemory(to: Double.self, capacity: count)
      return (0..<count).map { Float(source[$0]) }
    default:
      return (0..<count).map { array[$0].floatValue }
    }
  }

  // MARK: - The latent

  /// Gaussian noise for `length` frames of each channel, zero in the padding
  /// up to `padded` (Box–Muller, as the reference).
  static func noise(
    channels: Int, length: Int, padded: Int, uniform: () -> Float = { Float.random(in: 0..<1) }
  ) -> [Float] {
    var out = [Float](repeating: 0, count: channels * padded)
    for channel in 0..<channels {
      for frame in 0..<length {
        let u1 = max(uniform(), 1e-4)
        let u2 = uniform()
        out[channel * padded + frame] = sqrt(-2 * log(u1)) * cos(2 * Float.pi * u2)
      }
    }
    return out
  }

  /// Each channel's first `length` frames of a `[1, channels, from]` latent.
  static func trim(_ values: [Float], channels: Int, from: Int, to length: Int) -> [Float] {
    guard from > length else { return values }
    var out = [Float](repeating: 0, count: channels * length)
    for channel in 0..<channels {
      for frame in 0..<length { out[channel * length + frame] = values[channel * from + frame] }
    }
    return out
  }

  // MARK: - Files

  private struct Style: Decodable {
    struct Component: Decodable {
      let data: [[[Float]]]
      let dims: [Int]
    }
    let ttl: Component
    let dp: Component
    enum CodingKeys: String, CodingKey {
      case ttl = "style_ttl"
      case dp = "style_dp"
    }
  }

  private struct Config {
    var baseChunkSize = 512
    var chunkCompress = 6
    var latentDim = 24
  }

  /// `tts.json`'s few numbers the pipeline needs; the defaults are v1.7.3's.
  private static func config(in folder: URL) throws -> Config {
    let url = folder.appendingPathComponent("tts.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw Failure.missing("tts.json") }
    var config = Config()
    let ae = json["ae"] as? [String: Any]
    let ttl = json["ttl"] as? [String: Any]
    if let value = ae?["base_chunk_size"] as? Int { config.baseChunkSize = value }
    if let value = ttl?["chunk_compress_factor"] as? Int { config.chunkCompress = value }
    if let value = ttl?["latent_dim"] as? Int { config.latentDim = value }
    if let rate = ae?["sample_rate"] as? Int, rate != sampleRate {
      throw Failure.stage("configuration", "sample rate \(rate)")
    }
    return config
  }

  /// `unicode_indexer.json`: a token id per code point, -1 where none.
  private static func indexer(in folder: URL) throws -> [Int32] {
    let url = folder.appendingPathComponent("unicode_indexer.json")
    guard let data = try? Data(contentsOf: url),
          let ids = try? JSONDecoder().decode([Int64].self, from: data)
    else { throw Failure.missing("unicode_indexer.json") }
    return ids.map { Int32(clamping: $0) }
  }
}
