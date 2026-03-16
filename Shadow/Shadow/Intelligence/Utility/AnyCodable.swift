import Foundation

/// Lightweight JSON value wrapper for tool schemas and arbitrary JSON payloads.
/// Supports null, bool, int, double, string, array, and dictionary.
enum AnyCodable: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodable])
    case dictionary([String: AnyCodable])
}

extension AnyCodable: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([AnyCodable].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: AnyCodable].self) {
            self = .dictionary(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable: unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let v):
            try container.encode(v)
        case .int(let v):
            try container.encode(v)
        case .double(let v):
            try container.encode(v)
        case .string(let v):
            try container.encode(v)
        case .array(let v):
            try container.encode(v)
        case .dictionary(let v):
            try container.encode(v)
        }
    }
}

extension AnyCodable: Hashable {
    func hash(into hasher: inout Hasher) {
        switch self {
        case .null:
            hasher.combine(0)
        case .bool(let v):
            hasher.combine(1)
            hasher.combine(v)
        case .int(let v):
            hasher.combine(2)
            hasher.combine(v)
        case .double(let v):
            hasher.combine(3)
            hasher.combine(v)
        case .string(let v):
            hasher.combine(4)
            hasher.combine(v)
        case .array(let v):
            hasher.combine(5)
            hasher.combine(v)
        case .dictionary(let v):
            hasher.combine(6)
            hasher.combine(v)
        }
    }
}
