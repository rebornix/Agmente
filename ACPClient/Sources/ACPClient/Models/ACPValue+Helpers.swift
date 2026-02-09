import ACP
import Foundation

public extension ACP.Value {
    var numberValue: Double? {
        if case .double(let value) = self { return value }
        if case .int(let value) = self { return Double(value) }
        return nil
    }
}