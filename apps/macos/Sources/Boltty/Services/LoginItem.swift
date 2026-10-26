import Combine
import ServiceManagement

@MainActor
protocol LoginItemService: AnyObject {
  var status: SMAppService.Status { get }
  func register() throws
  func unregister() throws
}

extension SMAppService: LoginItemService {}

@MainActor
final class LoginItem: ObservableObject {
  enum Status: Equatable {
    case enabled
    case disabled
    case requiresApproval
  }

  @Published private(set) var status: Status = .disabled
  @Published private(set) var lastError: String?

  private let service: any LoginItemService

  init(service: any LoginItemService = SMAppService.mainApp) {
    self.service = service
    refresh()
  }

  var isOn: Bool { status != .disabled }

  func refresh() {
    switch service.status {
    case .enabled: status = .enabled
    case .requiresApproval: status = .requiresApproval
    case .notRegistered, .notFound: status = .disabled
    @unknown default: status = .disabled
    }
  }

  func setEnabled(_ enabled: Bool) {
    lastError = nil
    do {
      if enabled {
        try service.register()
      } else {
        try service.unregister()
      }
    } catch {
      lastError = error.localizedDescription
    }
    refresh()
  }

  func openSystemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
