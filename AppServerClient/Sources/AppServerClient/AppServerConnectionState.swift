public enum AppServerConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(Error)

    public static func == (lhs: AppServerConnectionState, rhs: AppServerConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected), (.connecting, .connecting), (.connected, .connected):
            return true
        case (.failed, .failed):
            return true
        default:
            return false
        }
    }
}