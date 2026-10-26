import Combine
import Foundation
@preconcurrency import UserNotifications

@MainActor
final class SystemAttentionNotificationService: NSObject, UNUserNotificationCenterDelegate {
  nonisolated private static let sessionIDKey = "boltty.session-id"
  nonisolated private static let categoryID = "boltty.agent.attention"
  nonisolated private static let replyActionID = "boltty.agent.reply"
  nonisolated private static let openActionID = "boltty.agent.open"
  /// One line of title and one of status, as a banner reads best. Claude's own
  /// cap is 100 for both; their body is a short fixed sentence, ours a status.
  nonisolated static let titleLimit = 50
  nonisolated static let bodyLimit = 100
  private let center: UNUserNotificationCenter
  var onActivateSession: ((UUID) -> Void)?
  var onReplyToSession: ((UUID, String) -> Void)?
  var sound: ((SystemAttentionNotification.Kind) -> UNNotificationSound?)?

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
    super.init()
    center.delegate = self
    center.setNotificationCategories([Self.category])
  }

  nonisolated private static var category: UNNotificationCategory {
    let reply = UNTextInputNotificationAction(
      identifier: replyActionID,
      title: "Reply",
      options: [],
      textInputButtonTitle: "Send",
      textInputPlaceholder: "Reply to this chat"
    )
    let open = UNNotificationAction(
      identifier: openActionID,
      title: "Open",
      options: [.foreground]
    )
    return UNNotificationCategory(
      identifier: categoryID,
      actions: [reply, open],
      intentIdentifiers: [],
      options: []
    )
  }

  func deliver(_ notification: SystemAttentionNotification) {
    let content = UNMutableNotificationContent()
    content.title = DisplayTextSanitizer.truncate(notification.title, limit: Self.titleLimit)
    content.body = DisplayTextSanitizer.truncate(notification.body, limit: Self.bodyLimit)
    if let sound {
      content.sound = sound(notification.kind)
    } else {
      content.sound = .default
    }
    content.threadIdentifier = "boltty.agent.\(notification.sessionID.uuidString)"
    content.categoryIdentifier = Self.categoryID
    content.userInfo = [Self.sessionIDKey: notification.sessionID.uuidString]
    let identifier = "boltty.attention.\(notification.sessionID.uuidString)"
    let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

    Task { [center] in
      let settings = await center.notificationSettings()
      let authorized: Bool
      switch settings.authorizationStatus {
      case .authorized, .provisional, .ephemeral:
        authorized = true
      case .notDetermined:
        authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
      case .denied:
        authorized = false
      @unknown default:
        authorized = false
      }
      guard authorized else { return }
      center.removeDeliveredNotifications(withIdentifiers: [identifier])
      try? await center.add(request)
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let rawID = response.notification.request.content.userInfo[Self.sessionIDKey] as? String
    let sessionID = rawID.flatMap(UUID.init(uuidString:))
    let typed = (response as? UNTextInputNotificationResponse)?.userText
    let identifier = response.actionIdentifier
    completionHandler()
    guard let sessionID else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      if identifier == Self.replyActionID, let typed, !typed.isEmpty {
        self.onReplyToSession?(sessionID, typed)
      } else {
        self.onActivateSession?(sessionID)
      }
    }
  }
}
