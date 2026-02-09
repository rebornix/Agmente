import Foundation

public protocol AppServerLogger {
    func info(_ message: String)
    func error(_ message: String)
}

public struct AppServerNoOpLogger: AppServerLogger {
    public init() {}
    public func info(_ message: String) {}
    public func error(_ message: String) {}
}

public struct AppServerPrintLogger: AppServerLogger {
    public init() {}
    public func info(_ message: String) {
        print("[ASP][INFO] \(message)")
    }

    public func error(_ message: String) {
        print("[ASP][ERROR] \(message)")
    }
}