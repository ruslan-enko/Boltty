import Foundation

@MainActor
final class BackgroundActivityAssertion {
  typealias Begin = (ProcessInfo.ActivityOptions, String) -> any NSObjectProtocol
  typealias End = (any NSObjectProtocol) -> Void

  static let reason = "Boltty's agents keep working in the background"
  static let options: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep

  private let begin: Begin
  private let end: End
  private var token: (any NSObjectProtocol)?

  var isHeld: Bool { token != nil }

  init(
    begin: @escaping Begin = { options, reason in
      ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
    },
    end: @escaping End = { token in
      ProcessInfo.processInfo.endActivity(token)
    }
  ) {
    self.begin = begin
    self.end = end
  }

  func setNeeded(_ needed: Bool) {
    if needed {
      guard token == nil else { return }
      token = begin(Self.options, Self.reason)
    } else {
      guard let held = token else { return }
      end(held)
      token = nil
    }
  }
}
