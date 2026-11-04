import Foundation
@testable import LockInCore

/// Checks JSON against the schemas in `Schemas/`, so the files Lock In writes are held to what the schemas promise.
/// It supports only the keywords those schemas use, and reports any other keyword rather than ignoring it.
/// It also records which declared properties some document actually contained, so tests can check the schema
/// has no properties the app never writes (a misspelt key would otherwise go unnoticed).
final class SchemaValidator {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Schemas")
    private var documents: [String: [String: Any]] = [:]
    private(set) var declared = Set<String>()
    private(set) var seen = Set<String>()
    private static let annotations: Set<String> = ["$schema", "$id", "title", "description", "$comment", "$defs"]

    /// Errors for `json` against the schema file `name`, e.g. "session-v1.schema.json".
    func errors(_ json: Data, against name: String) throws -> [String] {
        var errors: [String] = []
        let value = try JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed])
        try check(value, schema: document(name), location: name + "#", path: "$", errors: &errors)
        return errors
    }

    /// Properties the schemas declare that no checked document contained.
    var unseen: [String] { declared.subtracting(seen).sorted() }

    private func document(_ name: String) throws -> [String: Any] {
        if let cached = documents[name] { return cached }
        let data = try Data(contentsOf: Self.directory.appendingPathComponent(name))
        guard let schema = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Unsupported("\(name) isn't an object") }
        documents[name] = schema
        return schema
    }

    private func check(_ value: Any, schema: [String: Any], location: String, path: String, errors: inout [String]) throws {
        func fail(_ message: String) { errors.append("\(path): \(message)") }
        for (keyword, rule) in schema {
            switch keyword {
            case _ where Self.annotations.contains(keyword):
                continue
            case "$ref":
                guard let ref = rule as? String else { throw Unsupported("$ref at \(location)") }
                let parts = ref.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let name = parts[0].isEmpty ? String(location.prefix { $0 != "#" }) : parts[0]
                var target: Any = try document(name)
                for key in parts.count > 1 ? parts[1].split(separator: "/").map(String.init) : [] {
                    guard let next = (target as? [String: Any])?[key] else { throw Unsupported("unresolvable $ref \(ref)") }
                    target = next
                }
                guard let resolved = target as? [String: Any] else { throw Unsupported("$ref \(ref) isn't a schema") }
                try check(value, schema: resolved, location: name + "#" + (parts.count > 1 ? parts[1] : ""), path: path, errors: &errors)
            case "type":
                let types = (rule as? [String]) ?? [rule as? String].compactMap { $0 }
                if !types.contains(where: { Self.matches(value, type: $0) }) { fail("expected \(types.joined(separator: " or "))") }
            case "const":
                if !Self.equal(value, rule) { fail("expected \(rule)") }
            case "enum":
                guard let options = rule as? [Any] else { throw Unsupported("enum at \(location)") }
                if !options.contains(where: { Self.equal(value, $0) }) { fail("\(value) isn't one of \(options)") }
            case "required":
                guard let object = value as? [String: Any] else { continue }
                for name in rule as? [String] ?? [] where object[name] == nil { fail("missing \(name)") }
            case "properties":
                guard let properties = rule as? [String: [String: Any]] else { throw Unsupported("properties at \(location)") }
                for name in properties.keys { declared.insert("\(location)/properties/\(name)") }
                guard let object = value as? [String: Any] else { continue }
                for (name, sub) in properties {
                    guard let child = object[name] else { continue }
                    seen.insert("\(location)/properties/\(name)")
                    try check(child, schema: sub, location: "\(location)/properties/\(name)", path: "\(path).\(name)", errors: &errors)
                }
            case "additionalProperties":
                guard let object = value as? [String: Any] else { continue }
                let known = Set((schema["properties"] as? [String: Any])?.keys.map { $0 } ?? [])
                for (name, child) in object where !known.contains(name) {
                    if let allowed = rule as? Bool {
                        if !allowed { fail("unexpected property \(name)") }
                    } else if let sub = rule as? [String: Any] {
                        try check(child, schema: sub, location: "\(location)/additionalProperties", path: "\(path).\(name)", errors: &errors)
                    } else { throw Unsupported("additionalProperties at \(location)") }
                }
            case "items":
                guard let sub = rule as? [String: Any] else { throw Unsupported("items at \(location)") }
                guard let array = value as? [Any] else { continue }
                for (index, item) in array.enumerated() {
                    try check(item, schema: sub, location: "\(location)/items", path: "\(path)[\(index)]", errors: &errors)
                }
            case "minItems":
                if let array = value as? [Any], let minimum = rule as? Int, array.count < minimum { fail("needs at least \(minimum) items") }
            case "minimum":
                if let number = Self.number(value), let minimum = rule as? Double, number < minimum { fail("below \(minimum)") }
            case "minLength":
                if let text = value as? String, let minimum = rule as? Int, text.count < minimum { fail("shorter than \(minimum)") }
            case "pattern":
                guard let pattern = rule as? String else { throw Unsupported("pattern at \(location)") }
                if let text = value as? String, text.range(of: pattern, options: .regularExpression) == nil { fail("doesn't match \(pattern)") }
            case "format":
                guard let text = value as? String else { continue }
                switch rule as? String {
                case "uuid": if UUID(uuidString: text) == nil { fail("not a UUID") }
                case "date-time": if Timestamp.date(text) == nil { fail("not a date-time") }
                default: throw Unsupported("format \(rule)")
                }
            default:
                throw Unsupported("keyword \(keyword) at \(location)")
            }
        }
    }

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
    private static func number(_ value: Any) -> Double? { isBool(value) ? nil : (value as? NSNumber)?.doubleValue }
    private static func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String
        case "boolean": return isBool(value)
        case "number": return number(value) != nil
        case "integer": return number(value).map { $0 == $0.rounded() } ?? false
        case "null": return value is NSNull
        default: return false
        }
    }
    private static func equal(_ a: Any, _ b: Any) -> Bool {
        if isBool(a) != isBool(b) { return false }
        guard let a = a as? NSObject, let b = b as? NSObject else { return false }
        return a.isEqual(b)
    }

    struct Unsupported: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = "Schema validator: \(description)" }
    }
}
