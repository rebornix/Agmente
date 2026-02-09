import Foundation

public extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        if case .number(let number) = self { return String(number) }
        if case .bool(let flag) = self { return flag ? "true" : "false" }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}