import ServiceManagement

/// "登录时打开": the app as a login item (`SMAppService.mainApp`). Started that way it stays in
/// the menu bar (`AppDelegate.launchedAsLoginItem`). The state lives with the system, not in
/// UserDefaults, so it is read again whenever settings show it.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var enabled = false
    /// Turned on, but the user switched it off in System Settings › General › Login Items.
    @Published private(set) var needsApproval = false
    @Published private(set) var error: String?

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func set(_ on: Bool) {
        error = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = error.localizedDescription
            debugLog("login item \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        refresh()
        if on && needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
