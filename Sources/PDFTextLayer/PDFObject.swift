import Foundation

/// A PDF object as read from a file. Numbers, names and strings keep their original bytes, so an
/// object that is written back comes out the same as it went in.
public indirect enum PDFObject {
    case null
    case bool(Bool)
    case number(String)
    /// Name without the leading slash, with any #xx escapes left as they are
    case name(String)
    /// The whole string token, delimiters included: (…) or <…>
    case string([UInt8])
    case array([PDFObject])
    case dictionary(PDFDictionary)
    case reference(Int, Int)
    case stream(PDFDictionary, [UInt8])

    public var dictionary: PDFDictionary? {
        switch self {
        case .dictionary(let dict), .stream(let dict, _): return dict
        default: return nil
        }
    }

    public var array: [PDFObject]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var name: String? {
        if case .name(let name) = self { return name }
        return nil
    }

    public var integer: Int? {
        if case .number(let text) = self { return Int(text) ?? Double(text).map { Int($0) } }
        return nil
    }

    public var double: Double? {
        if case .number(let text) = self { return Double(text) }
        return nil
    }

    public var reference: (Int, Int)? {
        if case .reference(let number, let generation) = self { return (number, generation) }
        return nil
    }

    public static func int(_ value: Int) -> PDFObject { .number(String(value)) }

    public static func real(_ value: Double) -> PDFObject { .number(PDFObject.format(value)) }

    /// Literal string from text (only for plain ASCII)
    public static func text(_ value: String) -> PDFObject {
        var bytes: [UInt8] = [0x28]
        for byte in value.utf8 {
            if byte == 0x28 || byte == 0x29 || byte == 0x5C { bytes.append(0x5C) }
            bytes.append(byte)
        }
        bytes.append(0x29)
        return .string(bytes)
    }

    /// Up to 4 decimals with trailing zeros dropped
    public static func format(_ value: Double) -> String {
        if value.isNaN || value.isInfinite { return "0" }
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        if text == "-0" { text = "0" }
        return text
    }
}

/// Keeps the keys in the order they were read.
public struct PDFDictionary {
    public private(set) var entries: [(key: String, value: PDFObject)] = []

    public init(_ entries: [(String, PDFObject)] = []) {
        for (key, value) in entries { self[key] = value }
    }

    public subscript(key: String) -> PDFObject? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
            } else if let newValue {
                entries.append((key, newValue))
            }
        }
    }

    public var keys: [String] { entries.map(\.key) }
}

// MARK: - Writing

extension PDFObject {
    public func serialized() -> [UInt8] {
        var out: [UInt8] = []
        write(to: &out)
        return out
    }

    public func write(to out: inout [UInt8]) {
        switch self {
        case .null: out += Array("null".utf8)
        case .bool(let value): out += Array((value ? "true" : "false").utf8)
        case .number(let text): out += Array(text.utf8)
        case .name(let name):
            out.append(0x2F)
            out += Array(name.data(using: .isoLatin1) ?? Data(name.utf8))
        case .string(let bytes): out += bytes
        case .array(let items):
            out.append(0x5B)
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(0x20) }
                item.write(to: &out)
            }
            out.append(0x5D)
        case .dictionary(let dict):
            dict.write(to: &out)
        case .reference(let number, let generation):
            out += Array("\(number) \(generation) R".utf8)
        case .stream(var dict, let data):
            dict["Length"] = .int(data.count)
            dict.write(to: &out)
            out += Array("\nstream\n".utf8)
            out += data
            out += Array("\nendstream".utf8)
        }
    }
}

extension PDFDictionary {
    func write(to out: inout [UInt8]) {
        out += Array("<<".utf8)
        for (key, value) in entries {
            PDFObject.name(key).write(to: &out)
            out.append(0x20)
            value.write(to: &out)
            out.append(0x0A)
        }
        out += Array(">>".utf8)
    }
}
