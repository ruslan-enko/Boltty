import Carbon.HIToolbox
import Foundation

enum UITestKeyboard {
  static func key(_ keyCode: Int, fallback: String) -> String {
    guard
      let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let rawLayoutData = TISGetInputSourceProperty(
        inputSource,
        kTISPropertyUnicodeKeyLayoutData
      )
    else { return fallback }

    let layoutData = unsafeBitCast(rawLayoutData, to: CFData.self)
    guard let layoutBytes = CFDataGetBytePtr(layoutData) else { return fallback }

    var deadKeyState: UInt32 = 0
    var characters = [UniChar](repeating: 0, count: 4)
    var characterCount = 0
    let status = UCKeyTranslate(
      UnsafeRawPointer(layoutBytes).assumingMemoryBound(to: UCKeyboardLayout.self),
      UInt16(keyCode),
      UInt16(kUCKeyActionDown),
      0,
      UInt32(LMGetKbdType()),
      OptionBits(kUCKeyTranslateNoDeadKeysBit),
      &deadKeyState,
      characters.count,
      &characterCount,
      &characters
    )
    guard status == noErr, characterCount > 0 else { return fallback }
    return String(utf16CodeUnits: characters, count: characterCount)
  }
}
