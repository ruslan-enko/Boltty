import Accelerate
import CoreML
import Foundation

/// Moving numbers in and out of Core ML's arrays, for the local voices.
enum MLArrays {
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
      let source = array.dataPointer.bindMemory(to: UInt16.self, capacity: count)
      return halves(UnsafeBufferPointer(start: source, count: count))
    case .double:
      let source = array.dataPointer.bindMemory(to: Double.self, capacity: count)
      return (0..<count).map { Float(source[$0]) }
    default:
      return (0..<count).map { array[$0].floatValue }
    }
  }

  /// Half floats, given as their bits, as Float. Not through `Float16`: Swift
  /// has no such type on Intel, and the release is universal.
  static func halves(_ bits: UnsafeBufferPointer<UInt16>) -> [Float] {
    guard let base = bits.baseAddress, !bits.isEmpty else { return [] }
    var out = [Float](repeating: 0, count: bits.count)
    out.withUnsafeMutableBufferPointer { target in
      var source = vImage_Buffer(
        data: UnsafeMutableRawPointer(mutating: base), height: 1,
        width: vImagePixelCount(bits.count), rowBytes: bits.count * MemoryLayout<UInt16>.size)
      var destination = vImage_Buffer(
        data: target.baseAddress, height: 1,
        width: vImagePixelCount(bits.count), rowBytes: bits.count * MemoryLayout<Float>.size)
      _ = vImageConvert_Planar16FtoPlanarF(&source, &destination, vImage_Flags(kvImageNoFlags))
    }
    return out
  }
}
