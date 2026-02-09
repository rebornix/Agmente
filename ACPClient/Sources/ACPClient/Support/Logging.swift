import Foundation

public protocol ACPLogger {
    func info(_ message: String)
    func error(_ message: String)
}

public struct NoOpLogger: ACPLogger {
    public init() {}
    public func info(_ message: String) {}
    public func error(_ message: String) {}
}

public struct PrintLogger: ACPLogger {
    public init() {}
    public func info(_ message: String) {
        print("[ACP][INFO] \(message)")
    }

    public func error(_ message: String) {
        print("[ACP][ERROR] \(message)")
    }
}