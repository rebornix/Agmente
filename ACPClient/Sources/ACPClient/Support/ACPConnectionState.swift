public enum ACPConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(Error)

    public static func == (lhs: ACPConnectionState, rhs: ACPConnectionState) -> Bool {
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