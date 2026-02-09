import ACP
import Foundation

struct ACPMessageFormatter {
    static func idString(_ id: ACP.ID) -> String {
        switch id {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .null: return "null"
        }
    }

    static func compact(_ value: any Encodable, encoder: JSONEncoder) -> String {
        let data = (try? encoder.encode(AnyEncodable(value))) ?? Data()
        return compact(data: data)
    }

    static func compact(_ value: ACP.Value, encoder: JSONEncoder) -> String {
        compact(data: (try? encoder.encode(value)) ?? Data())
    }

    static func compact(_ object: [String: ACP.Value], encoder: JSONEncoder) -> String {
        compact(.object(object), encoder: encoder)
    }

    static func compact(data: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data),
            let truncated = truncateBase64InJSON(json),
            let compact = try? JSONSerialization.data(withJSONObject: truncated),
            let string = String(data: compact, encoding: .utf8)
        else { return String(decoding: data, as: UTF8.self) }
        return string
    }

    private static func truncateBase64InJSON(_ json: Any) -> Any? {
        if let string = json as? String {
            if string.count > 128, string.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }) {
                return String(string.prefix(64)) + "…(truncated base64)"
            }
            return string
        }
        if let dict = json as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in dict {
                result[key] = truncateBase64InJSON(value)
            }
            return result
        }
        if let array = json as? [Any] {
            return array.map { truncateBase64InJSON($0) ?? $0 }
        }
        return json
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable

    init(_ value: any Encodable) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}