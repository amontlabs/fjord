import Foundation

// The Router's delivery engine is a port of poc/router (Python), which reads dicts everywhere. `JSON` holds any JSON value with
// Python's semantics where the port depends on them: `==` treats 1 and 1.0 (and True and 1) as equal and ignores key order,
// `get` returns nil for a missing key and for null alike (`dict.get`), objects keep insertion order, and `encoded()` writes what
// `json.dumps(value, ensure_ascii=False)` writes. Ports: Python dicts, lists, None, json.dumps / json.loads.

/// An insertion-ordered JSON object (a Python dict).
struct JSONObject: Sequence, Equatable, Hashable {
    private(set) var keys: [String] = []
    private var storage: [String: JSON] = [:]

    init() {}
    init(_ pairs: [(String, JSON)]) { for (k, v) in pairs { self[k] = v } }

    /// The value of a key, nil when the key is missing (null is `.null`, as `d[k]` would give None).
    subscript(key: String) -> JSON? {
        get { storage[key] }
        set {
            if let value = newValue {
                if storage.updateValue(value, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    var count: Int { keys.count }
    var isEmpty: Bool { keys.isEmpty }
    var values: [JSON] { keys.map { storage[$0]! } }
    var pairs: [(key: String, value: JSON)] { keys.map { ($0, storage[$0]!) } }
    func has(_ key: String) -> Bool { storage[key] != nil }
    /// `dict.get(key)`: nil for a missing key and for null alike.
    func get(_ key: String) -> JSON? { storage[key].flatMap { $0.isNull ? nil : $0 } }

    /// `dict.update(other)`: existing keys keep their place.
    mutating func update(_ other: JSONObject) { for (k, v) in other.pairs { self[k] = v } }
    /// `dict.pop(key, None)`.
    @discardableResult mutating func pop(_ key: String) -> JSON? { let old = storage[key]; self[key] = nil; return old }
    /// `dict.setdefault(key, value)`.
    @discardableResult mutating func setdefault(_ key: String, _ value: @autoclosure () -> JSON) -> JSON {
        if let have = storage[key] { return have }
        let new = value()
        self[key] = new
        return new
    }

    func makeIterator() -> IndexingIterator<[(key: String, value: JSON)]> { pairs.makeIterator() }

    static func == (a: JSONObject, b: JSONObject) -> Bool { a.storage == b.storage }
    func hash(into hasher: inout Hasher) { hasher.combine(count) }
}

enum JSON: Equatable, Hashable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
           ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) { self = .object(JSONObject(elements)) }

    init(_ value: String?) { self = value.map(JSON.string) ?? .null }
    init(_ value: Bool?) { self = value.map(JSON.bool) ?? .null }
    init(_ value: Int?) { self = value.map(JSON.int) ?? .null }
    init(_ value: Double?) { self = value.map(JSON.double) ?? .null }
    init(_ value: [String]?) { self = value.map { .array($0.map(JSON.string)) } ?? .null }

    static func obj(_ pairs: [(String, JSON)] = []) -> JSON { .object(JSONObject(pairs)) }
    static func strings(_ values: [String]) -> JSON { .array(values.map(JSON.string)) }

    // MARK: Python equality

    /// A number as Python compares it: True is 1, 1 equals 1.0.
    var numeric: Double? {
        switch self {
        case .bool(let b): return b ? 1 : 0
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.object(let x), .object(let y)): return x == y
        case (.int(let x), .int(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        default:
            if let x = a.numeric, let y = b.numeric { return x == y }
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .string(let s): hasher.combine(s)
        case .array(let a): hasher.combine(a.count)
        case .object(let o): hasher.combine(o.count)
        default: hasher.combine(numeric ?? 0)
        }
    }

    // MARK: Access

    var isNull: Bool { if case .null = self { return true } else { return false } }
    var asString: String? { if case .string(let s) = self { return s } else { return nil } }
    /// An int, not a bool (Python's `isinstance(x, int)` accepts a bool; `isPyInt` does).
    var asInt: Int? { if case .int(let i) = self { return i } else { return nil } }
    /// An int or a float, not a bool.
    var asDouble: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
    var asBool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    var asArray: [JSON]? { if case .array(let a) = self { return a } else { return nil } }
    var asObject: JSONObject? { if case .object(let o) = self { return o } else { return nil } }
    /// `isinstance(x, int)`: an int or a bool.
    var isPyInt: Bool {
        switch self {
        case .int, .bool: return true
        default: return false
        }
    }

    /// Python truthiness: None, False, 0, 0.0, "", [] and {} are false.
    var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    /// `d[key]`: nil when this isn't an object or the key is missing; a null value is `.null`.
    subscript(key: String) -> JSON? {
        get { if case .object(let o) = self { return o[key] } else { return nil } }
        set {
            guard case .object(var o) = self else { return }
            self = .null
            o[key] = newValue
            self = .object(o)
        }
    }

    /// `d[index]` on an array, nil out of range.
    subscript(index: Int) -> JSON? {
        guard case .array(let a) = self, index >= 0, index < a.count else { return nil }
        return a[index]
    }

    /// `d.get(key)`: nil for a missing key and for null alike.
    func get(_ key: String) -> JSON? {
        guard let v = self[key], !v.isNull else { return nil }
        return v
    }

    /// `key in d`.
    func has(_ key: String) -> Bool { self[key] != nil }

    /// The value at a path of keys, nil when any step is missing or isn't an object.
    func path(_ keys: String...) -> JSON? {
        var at: JSON? = self
        for k in keys { at = at?[k] }
        return at
    }

    // MARK: Encoding (json.dumps(value, ensure_ascii=False))

    /// Python's separators (", " and ": ") and escaping. `asciiOnly` is `ensure_ascii=True`.
    func encoded(asciiOnly: Bool = false) -> String {
        var out = ""
        write(&out, asciiOnly)
        return out
    }

    private func write(_ out: inout String, _ ascii: Bool) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d):
            if d.isNaN { out += "NaN" } else if d.isInfinite { out += d < 0 ? "-Infinity" : "Infinity" } else { out += pyFloat(d) }
        case .string(let s): JSON.writeString(s, &out, ascii)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += ", " }
                v.write(&out, ascii)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, pair) in o.pairs.enumerated() {
                if i > 0 { out += ", " }
                JSON.writeString(pair.key, &out, ascii)
                out += ": "
                pair.value.write(&out, ascii)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, _ out: inout String, _ ascii: Bool) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 || (ascii && u.value > 0x7E) {
                    if u.value > 0xFFFF {
                        let v = u.value - 0x10000
                        out += String(format: "\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
                    } else {
                        out += String(format: "\\u%04x", u.value)
                    }
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }

    // MARK: Python's str() and repr()

    /// `str(value)`.
    var pyStr: String {
        switch self {
        case .string(let s): return s
        default: return pyRepr
        }
    }

    /// `repr(value)`.
    var pyRepr: String {
        switch self {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return d.isNaN ? "nan" : d.isInfinite ? (d < 0 ? "-inf" : "inf") : pyFloat(d)
        case .string(let s): return JSON.reprString(s)
        case .array(let a): return "[" + a.map(\.pyRepr).joined(separator: ", ") + "]"
        case .object(let o): return "{" + o.pairs.map { JSON.reprString($0.key) + ": " + $0.value.pyRepr }.joined(separator: ", ") + "}"
        }
    }

    private static func reprString(_ s: String) -> String {
        let quote: Character = s.contains("'") && !s.contains("\"") ? "\"" : "'"
        var out = String(quote)
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if Character(u) == quote { out += "\\" + String(quote) }
                else if u.value < 0x20 || u.value == 0x7F { out += String(format: "\\x%02x", u.value) }
                else { out.unicodeScalars.append(u) }
            }
        }
        return out + String(quote)
    }

    // MARK: Parsing (json.loads)

    static func parse(_ text: String) throws -> JSON {
        var p = JSONParser(Array(text.utf8))
        let value = try p.value()
        p.skipSpace()
        guard p.at == p.bytes.count else { throw JSONError.invalid("extra data at \(p.at)") }
        return value
    }
}

enum JSONError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { if case .invalid(let m) = self { return "invalid JSON: \(m)" } else { return "" } }
}

/// Python's float repr: the shortest text that reads back (Swift's description is the same, apart from the form of the exponent,
/// which both write as e+22 and e-05).
func pyFloat(_ d: Double) -> String { d.description }

private struct JSONParser {
    let bytes: [UInt8]
    var at = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func skipSpace() {
        while at < bytes.count, bytes[at] == 0x20 || bytes[at] == 0x09 || bytes[at] == 0x0A || bytes[at] == 0x0D { at += 1 }
    }

    func fail(_ what: String) -> JSONError { .invalid("\(what) at \(at)") }

    mutating func literal(_ word: String, _ value: JSON) throws -> JSON {
        let w = Array(word.utf8)
        guard at + w.count <= bytes.count, Array(bytes[at..<at + w.count]) == w else { throw fail("unexpected text") }
        at += w.count
        return value
    }

    mutating func value() throws -> JSON {
        skipSpace()
        guard at < bytes.count else { throw fail("unexpected end") }
        switch bytes[at] {
        case UInt8(ascii: "{"):
            at += 1
            var object = JSONObject()
            skipSpace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "}") { at += 1; return .object(object) }
            while true {
                skipSpace()
                guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else { throw fail("expected a key") }
                let key = try string()
                skipSpace()
                guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { throw fail("expected a colon") }
                at += 1
                object[key] = try value()
                skipSpace()
                guard at < bytes.count else { throw fail("unexpected end") }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                if bytes[at] == UInt8(ascii: "}") { at += 1; return .object(object) }
                throw fail("expected , or }")
            }
        case UInt8(ascii: "["):
            at += 1
            var items: [JSON] = []
            skipSpace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "]") { at += 1; return .array(items) }
            while true {
                items.append(try value())
                skipSpace()
                guard at < bytes.count else { throw fail("unexpected end") }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                if bytes[at] == UInt8(ascii: "]") { at += 1; return .array(items) }
                throw fail("expected , or ]")
            }
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): return try literal("true", .bool(true))
        case UInt8(ascii: "f"): return try literal("false", .bool(false))
        case UInt8(ascii: "n"): return try literal("null", .null)
        case UInt8(ascii: "N"): return try literal("NaN", .double(.nan))
        case UInt8(ascii: "I"): return try literal("Infinity", .double(.infinity))
        default: return try number()
        }
    }

    mutating func number() throws -> JSON {
        let start = at
        if at < bytes.count, bytes[at] == UInt8(ascii: "-") {
            at += 1
            if at < bytes.count, bytes[at] == UInt8(ascii: "I") { return try literal("Infinity", .double(-.infinity)) }
        }
        var digits = 0
        while at < bytes.count, (0x30...0x39).contains(bytes[at]) { at += 1; digits += 1 }
        guard digits > 0 else { throw fail("expected a value") }
        var integral = true
        if at < bytes.count, bytes[at] == UInt8(ascii: ".") {
            integral = false
            at += 1
            var frac = 0
            while at < bytes.count, (0x30...0x39).contains(bytes[at]) { at += 1; frac += 1 }
            guard frac > 0 else { throw fail("bad number") }
        }
        if at < bytes.count, bytes[at] == UInt8(ascii: "e") || bytes[at] == UInt8(ascii: "E") {
            integral = false
            at += 1
            if at < bytes.count, bytes[at] == UInt8(ascii: "+") || bytes[at] == UInt8(ascii: "-") { at += 1 }
            var exp = 0
            while at < bytes.count, (0x30...0x39).contains(bytes[at]) { at += 1; exp += 1 }
            guard exp > 0 else { throw fail("bad number") }
        }
        let text = String(decoding: bytes[start..<at], as: UTF8.self)
        if integral, let i = Int(text) { return .int(i) }
        guard let d = Double(text) else { throw fail("bad number") }
        return .double(d)
    }

    mutating func hex4() throws -> UInt32 {
        guard at + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[at..<at + 4], as: UTF8.self), radix: 16) else { throw fail("bad \\u escape") }
        at += 4
        return v
    }

    mutating func string() throws -> String {
        at += 1  // the opening quote
        var out: [UInt8] = []
        while true {
            guard at < bytes.count else { throw fail("unterminated string") }
            let b = bytes[at]
            at += 1
            if b == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
            if b < 0x20 { throw fail("control character in string") }
            guard b == UInt8(ascii: "\\") else { out.append(b); continue }
            guard at < bytes.count else { throw fail("unterminated string") }
            let e = bytes[at]
            at += 1
            switch e {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var code = try hex4()
                if (0xD800..<0xDC00).contains(code), at + 1 < bytes.count, bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u") {
                    let save = at
                    at += 2
                    let low = try hex4()
                    if (0xDC00..<0xE000).contains(low) { code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00) } else { at = save }
                }
                // A lone surrogate can't live in a Swift String: it becomes U+FFFD.
                out.append(contentsOf: Array(String(Unicode.Scalar(code) ?? "\u{FFFD}").utf8))
            default: throw fail("bad escape")
            }
        }
    }
}

// MARK: Python helpers the port leans on

extension Sequence {
    /// `sorted(key=...)`: stable, as Python's is.
    func stableSorted<K: Comparable>(by key: (Element) -> K) -> [Element] {
        enumerated().map { ($0.offset, $0.element, key($0.element)) }
            .sorted { $0.2 != $1.2 ? $0.2 < $1.2 : $0.0 < $1.0 }.map(\.1)
    }
}

/// `max(items, key=key)`: the first of the largest.
func pyMaxBy<T>(_ items: [T], _ key: (T) -> Double) -> T? {
    var best: (T, Double)?
    for item in items {
        let k = key(item)
        if best == nil || k > best!.1 { best = (item, k) }
    }
    return best?.0
}

/// `max(a, b)` of two numbers: a unless b is larger.
func pyMax(_ a: JSON, _ b: JSON) -> JSON {
    guard let x = a.numeric, let y = b.numeric else { return a }
    return y > x ? b : a
}

/// `sorted(strings)`: by code point (UTF-8 order is code point order).
func pySorted(_ strings: [String]) -> [String] {
    strings.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
}

/// `text.startswith(prefix)`: by code points, with no canonical equivalence.
func pyStartsWith(_ text: String, _ prefix: String) -> Bool { Array(text.utf8).starts(with: Array(prefix.utf8)) }

/// `text[:n]`, by code points.
func pyPrefix(_ text: String, _ n: Int) -> String {
    var out = String.UnicodeScalarView()
    out.append(contentsOf: text.unicodeScalars.prefix(n))
    return String(out)
}

/// `text.split("/")` and the like: every piece, empty ones too.
func pySplit(_ text: String, _ separator: Character) -> [String] {
    text.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
}
