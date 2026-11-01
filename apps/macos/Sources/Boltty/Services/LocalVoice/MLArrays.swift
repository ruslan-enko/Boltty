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
      let source = array.dataPointer.bindMemory(to: Float16.self, capacity: count)
      return (0..<count).map { Float(source[$0]) }
    case .double:
      let source = array.dataPointer.bindMemory(to: Double.self, capacity: count)
      return (0..<count).map { Float(source[$0]) }
    default:
      return (0..<count).map { array[$0].floatValue }
    }
  }
}
