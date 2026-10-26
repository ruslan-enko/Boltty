import Foundation

/// Not ISO8601DateFormatter: a formatter costs ~300 µs a stamp, this scan 0.1 µs.
enum ISO8601Stamp {
  static func date(from value: String) -> Date? {
    scan(value) ?? reference(value)
  }

  private static func scan(_ value: String) -> Date? {
    var year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0
    var yearDigits = 0, monthDigits = 0, dayDigits = 0
    var hourDigits = 0, minuteDigits = 0, secondDigits = 0
    var fraction = 0.0
    var scale = 0.1
    var fractionDigits = 0
    var field = 0
    var inFraction = false
    var closed = false

    for byte in value.utf8 {
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"):
        guard !closed else { return nil }
        let digit = Int(byte - UInt8(ascii: "0"))
        if inFraction {
          if scale > 1e-10 {
            fraction += Double(digit) * scale
            scale /= 10
          }
          fractionDigits += 1
          continue
        }
        switch field {
        case 0: year = year * 10 + digit; yearDigits += 1
        case 1: month = month * 10 + digit; monthDigits += 1
        case 2: day = day * 10 + digit; dayDigits += 1
        case 3: hour = hour * 10 + digit; hourDigits += 1
        case 4: minute = minute * 10 + digit; minuteDigits += 1
        default: second = second * 10 + digit; secondDigits += 1
        }
      case UInt8(ascii: "-") where field < 2 && !closed: field += 1
      case UInt8(ascii: "T") where field == 2 && !closed: field += 1
      case UInt8(ascii: ":") where (field == 3 || field == 4) && !closed: field += 1
      case UInt8(ascii: ".") where field == 5 && !inFraction && !closed: inFraction = true
      case UInt8(ascii: "Z") where !closed: closed = true
      default: return nil
      }
    }

    guard closed,
          !inFraction || fractionDigits > 0,
          yearDigits == 4, monthDigits == 2, dayDigits == 2,
          hourDigits == 2, minuteDigits == 2, secondDigits == 2,
          (1...12).contains(month), (1...31).contains(day),
          hour < 24, minute < 60, second < 60
    else { return nil }

    return Date(
      timeIntervalSince1970:
        Double(Self.daysSinceEpoch(year: year, month: month, day: day) * 86_400
               + hour * 3_600 + minute * 60 + second)
        + fraction
    )
  }

  private static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
    let shifted = year - (month <= 2 ? 1 : 0)
    let era = (shifted >= 0 ? shifted : shifted - 399) / 400
    let yearOfEra = shifted - era * 400
    let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  private static func reference(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let parsed = formatter.date(from: value) { return parsed }
    formatter.formatOptions = [.withInternetDateTime]
    if let parsed = formatter.date(from: value) { return parsed }
    guard let dot = value.firstIndex(of: "."),
          let zone = value[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" })
    else { return nil }
    return formatter.date(from: String(value[..<dot]) + String(value[zone...]))
  }
}
