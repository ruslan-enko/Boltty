import CoreText
import Foundation
import os
import Vision

/// The first accurate reading in a new build waits about 70 s for macOS to compile Vision's model
/// (27.2); the next take 0.2 s. So it is read ahead, on threads of its own, and never waited out.
enum ScreenTextReader {
  struct Words: Sendable, Equatable {
    var text: String?
    var labels: [ScreenText]?
  }

  static let labelLimit = 300
  static let textByteLimit = PromptExpansion.inlineTextByteLimit

  private static let queue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "com.boltty.screen-text"
    queue.maxConcurrentOperationCount = 2
    queue.qualityOfService = .userInitiated
    return queue
  }()

  @MainActor private static var isWarmedUp = false

  @MainActor
  static func warmUp() {
    guard !isWarmedUp, let sample = sample() else { return }
    isWarmedUp = true
    let operation = BlockOperation { _ = text(in: sample) }
    operation.qualityOfService = .utility
    queue.addOperation(operation)
  }

  static func words(in cut: ScreenCut, readsLabels: Bool) async -> Words {
    async let labels = readsLabels ? run { Self.labels(in: cut.screen) } : nil
    async let text = readsLabels && cut.isWholeScreen ? nil : run { Self.text(in: cut.area) ?? "" }
    let read = await Words(text: text, labels: labels)
    return Words(text: read.text.flatMap { $0.isEmpty ? nil : $0 }, labels: read.labels)
  }

  static func labels(of image: CGImage) async -> [ScreenText]? {
    await run { labels(in: image) }
  }

  private static func run<Value: Sendable>(_ read: @escaping @Sendable () -> Value) async -> Value? {
    let result = OSAllocatedUnfairLock<Value?>(initialState: nil)
    let operation = BlockOperation { let value = read(); result.withLock { $0 = value } }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
        // Called for a cancelled operation too, whose block never runs.
        operation.completionBlock = { continuation.resume(returning: result.withLock { $0 }) }
        queue.addOperation(operation)
      }
    } onCancel: {
      operation.cancel()
    }
  }

  static func labels(in image: CGImage) -> [ScreenText] {
    func thousandths(_ box: CGRect) -> CGRect {
      CGRect(x: box.minX * 1000, y: (1 - box.maxY) * 1000, width: box.width * 1000, height: box.height * 1000)
    }
    let lines = read(image, corrects: false).prefix(labelLimit).compactMap { observation -> ScreenText? in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      let string = candidate.string
      let words = string.split(whereSeparator: \.isWhitespace).compactMap { word -> ScreenText.Word? in
        guard let box = try? candidate.boundingBox(for: word.startIndex..<word.endIndex)?.boundingBox
        else { return nil }
        return ScreenText.Word(text: String(word), box: thousandths(box))
      }
      let text = string.trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { return nil }
      return ScreenText(text: text, box: thousandths(observation.boundingBox), words: words)
    }
    return lines.sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }
  }

  static func text(in image: CGImage) -> String? {
    let text = read(image, corrects: true)
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : truncated(text, toBytes: textByteLimit)
  }

  private static func read(_ image: CGImage, corrects: Bool) -> [VNRecognizedTextObservation] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = true
    request.usesLanguageCorrection = corrects
    guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
    return request.results ?? []
  }

  static func truncated(_ text: String, toBytes limit: Int) -> String {
    guard text.utf8.count > limit else { return text }
    var cut = ""
    var bytes = 0
    let budget = limit - "…".utf8.count
    for character in text {
      let size = String(character).utf8.count
      guard bytes + size <= budget else { break }
      cut.append(character)
      bytes += size
    }
    return cut + "…"
  }

  private static func sample() -> CGImage? {
    let size = CGSize(width: 320, height: 60)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let font = CTFontCreateUIFontForLanguage(.system, 26, nil)
    else { return nil }
    context.setFillColor(.white)
    context.fill(CGRect(origin: .zero, size: size))
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: "Ask about this", attributes: [.font: font]))
    context.textPosition = CGPoint(x: 16, y: 20)
    CTLineDraw(line, context)
    return context.makeImage()
  }
}
