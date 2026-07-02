import Foundation

/// An opaque JSON value carried by transport-native send actions (`wsReplay` frame,
/// `restReissue` body). The server reconstructs these from redacted capture; the client
/// re-serializes them verbatim for injection. Kept minimal and self-contained so the kit
/// has no dependency on the app's JSON type.
public enum BrowserJSONValue: Codable, Equatable, Sendable {
    case string(String)
    /// Integral JSON numbers. Decoded before `.number` so 64-bit ids (epoch-nanosecond
    /// timestamps, snowflake ids) survive the round trip — routing them through Double
    /// corrupts anything above 2^53.
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case object([String: BrowserJSONValue])
    case array([BrowserJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([BrowserJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: BrowserJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    /// Compact JSON string, or nil when serialization fails. Transport frames/bodies are
    /// always objects, which encode cleanly at the top level.
    public func serializedJSONString() -> String? {
        guard
            let data = try? JSONEncoder().encode(self),
            let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }
}
