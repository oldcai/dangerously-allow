import Foundation

/// A minimal typed JSON tree. Used to assemble the Messages API request body
/// without reaching for `[String: Any]` — every value stays typed, and the
/// whole request is deterministically encodable (with `.sortedKeys`) so tests
/// can assert on the exact bytes.
public indirect enum JSONValue: Encodable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .object(o): try c.encode(o)
        case let .array(a): try c.encode(a)
        case let .string(s): try c.encode(s)
        case let .int(i): try c.encode(i)
        case let .double(d): try c.encode(d)
        case let .bool(b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }

    /// Deterministic JSON encoding (sorted keys), ready for an HTTP body.
    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(self)
    }
}
