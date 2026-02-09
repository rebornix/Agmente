public enum AppServerClientError: Error, Equatable {
    case disconnected
    case encodingFailed
    case decodingFailed
}