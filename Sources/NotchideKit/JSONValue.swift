import Foundation

/// A `Sendable` value representing an arbitrary JSON value.
///
/// Used to model `tool_input` (and any other free-form field) from Claude Code
/// hook payloads, which do not have a fixed schema across tools. Conforms to
/// `Codable` so it round-trips through `JSONEncoder`/`JSONDecoder`.
public enum JSONValue: Sendable, Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // Order matters: try Bool before Double so `true`/`false` do not get
        // coerced into numbers by strict decoders.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    // MARK: - Convenience accessors

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        // Non-trapping: `Int(Double)` crashes on NaN/inf/out-of-range, so use
        // `Int(exactly:)` which returns nil for any value that has no exact Int
        // representation (NaN, ±inf, or magnitudes beyond Int's range).
        guard let value = doubleValue else { return nil }
        return Int(exactly: value.rounded())
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Object member access. Returns `nil` for non-objects or missing keys.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Array element access. Returns `nil` for non-arrays or out-of-bounds indices.
    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, index >= 0, index < array.count else { return nil }
        return array[index]
    }

    /// A flat string form of a scalar value (string/number/bool), for rendering.
    var scalarString: String? {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            // Render integral doubles without a trailing ".0".
            if value == value.rounded() && abs(value) < 1e15 {
                return String(Int(value))
            }
            return String(value)
        case .null, .array, .object:
            return nil
        }
    }

    /// Renders a tool invocation as a human-readable command string.
    ///
    /// For a `Bash` tool with `{"command":"rm -rf build/"}` this returns
    /// `"rm -rf build/"`. For file tools it returns `"<Tool> <path>"`, and for
    /// anything else a compact `Tool(key=value, …)` form.
    public func humanReadableCommand(toolName: String) -> String? {
        guard case .object(let object) = self else { return nil }
        switch toolName {
        case "Bash":
            return object["command"]?.stringValue
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
            if let path = object["file_path"]?.stringValue ?? object["notebook_path"]?.stringValue {
                return "\(toolName) \(path)"
            }
            return toolName
        default:
            let parts = object.keys.sorted().compactMap { key -> String? in
                guard let value = object[key]?.scalarString else { return nil }
                return "\(key)=\(value)"
            }
            return parts.isEmpty ? toolName : "\(toolName)(\(parts.joined(separator: ", ")))"
        }
    }
}
