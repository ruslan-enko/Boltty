import Foundation

struct ComposerToken: Equatable {
  let range: NSRange
  let query: String

  static let queryLimit = 80

  static func mention(in text: String, caret: Int) -> ComposerToken? {
    guard let token = word(ending: caret, in: text as NSString, sign: 0x40) else { return nil }
    let string = text as NSString
    if token.range.location > 0, let before = UnicodeScalar(string.character(at: token.range.location - 1)),
       !CharacterSet.whitespacesAndNewlines.contains(before) {
      return nil
    }
    return token
  }

  static func command(in text: String, caret: Int) -> ComposerToken? {
    guard let token = word(ending: caret, in: text as NSString, sign: 0x2F),
          token.range.location == 0
    else { return nil }
    return token
  }

  private static func word(ending caret: Int, in string: NSString, sign: unichar) -> ComposerToken? {
    guard caret >= 1, caret <= string.length else { return nil }
    var index = caret - 1
    while index >= 0 {
      let unit = string.character(at: index)
      if unit == sign {
        let query = string.substring(with: NSRange(location: index + 1, length: caret - index - 1))
        guard query.count <= queryLimit else { return nil }
        return ComposerToken(range: NSRange(location: index, length: caret - index), query: query)
      }
      if let scalar = UnicodeScalar(unit), CharacterSet.whitespacesAndNewlines.contains(scalar) {
        return nil
      }
      index -= 1
    }
    return nil
  }
}
