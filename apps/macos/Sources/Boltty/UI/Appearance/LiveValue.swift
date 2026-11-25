@inline(__always)
func live<Value>(
  _ value: @autoclosure () -> Value, _ name: String = #function, file: String = #fileID
) -> Value {
  #if BOLTTY_DESIGN
  return LiveValues.shared.value(file: file, name: name) ?? value()
  #else
  return value()
  #endif
}
