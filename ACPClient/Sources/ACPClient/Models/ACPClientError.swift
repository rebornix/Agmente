import Foundation

public enum ACPClientError: Error {
    case disconnected
    case encodingFailed
    case decodingFailed
    case notImplemented
}