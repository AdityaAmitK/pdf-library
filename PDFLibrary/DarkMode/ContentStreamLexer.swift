import Foundation

/// One content-stream operator with its operands, as a byte range of the source stream.
struct ContentOperation {
    enum Operand {
        case number(Double)
        case name(String)
        case other
    }

    var name: String
    var operands: [Operand]
    var range: Range<Int>

    var numbers: [Double] {
        operands.compactMap { if case .number(let n) = $0 { n } else { nil } }
    }

    var lastName: String? {
        if case .name(let n) = operands.last { n } else { nil }
    }
}

enum ContentStreamError: Error {
    case malformed(String)
}

/// A tokenizer for PDF content streams (ISO 32000-1 §7.2, §7.8.2, §8.9.7). It only classifies tokens;
/// callers copy the original bytes of every operation they don't change.
struct ContentStreamLexer {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var source: [UInt8] { bytes }

    mutating func operations() throws -> [ContentOperation] {
        var result: [ContentOperation] = []
        var operands: [ContentOperation.Operand] = []
        var operandStart: Int?

        while true {
            skipWhitespaceAndComments()
            guard index < bytes.count else { break }
            let start = index
            let byte = bytes[index]

            switch byte {
            case UInt8(ascii: "("):
                try skipLiteralString()
                operands.append(.other)
            case UInt8(ascii: "<"):
                if peek(1) == UInt8(ascii: "<") {
                    try skipDictionary()
                } else {
                    try skipHexString()
                }
                operands.append(.other)
            case UInt8(ascii: "["):
                try skipArray()
                operands.append(.other)
            case UInt8(ascii: "/"):
                operands.append(.name(readName()))
            case UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "]"), UInt8(ascii: ">"), UInt8(ascii: ")"):
                // Stray delimiter: tolerate it like viewers do.
                index += 1
                operands.append(.other)
            default:
                if Self.isNumberStart(byte) {
                    operands.append(.number(readNumber()))
                } else {
                    let word = readRegular()
                    if word.isEmpty {
                        index += 1
                        continue
                    }
                    switch word {
                    case "true", "false", "null":
                        operands.append(.other)
                    case "BI":
                        try skipInlineImage()
                        result.append(ContentOperation(name: "BI", operands: [], range: (operandStart ?? start)..<index))
                        operands = []
                        operandStart = nil
                        continue
                    default:
                        result.append(ContentOperation(name: word, operands: operands, range: (operandStart ?? start)..<index))
                        operands = []
                        operandStart = nil
                        continue
                    }
                }
            }
            if operandStart == nil { operandStart = start }
        }
        return result
    }

    // MARK: Token helpers

    private func peek(_ offset: Int) -> UInt8? {
        let i = index + offset
        return i < bytes.count ? bytes[i] : nil
    }

    static func isWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 || b == 0x0C || b == 0x00
    }

    static func isDelimiter(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"),
             UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
             UInt8(ascii: "/"), UInt8(ascii: "%"):
            true
        default:
            false
        }
    }

    private static func isNumberStart(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || b == UInt8(ascii: "+") || b == UInt8(ascii: "-") || b == UInt8(ascii: ".")
    }

    private mutating func skipWhitespaceAndComments() {
        while index < bytes.count {
            let b = bytes[index]
            if Self.isWhitespace(b) {
                index += 1
            } else if b == UInt8(ascii: "%") {
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
            } else {
                break
            }
        }
    }

    private mutating func readRegular() -> String {
        let start = index
        while index < bytes.count, !Self.isWhitespace(bytes[index]), !Self.isDelimiter(bytes[index]) { index += 1 }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func readName() -> String {
        index += 1  // "/"
        var out: [UInt8] = []
        while index < bytes.count, !Self.isWhitespace(bytes[index]), !Self.isDelimiter(bytes[index]) {
            if bytes[index] == UInt8(ascii: "#"), index + 2 < bytes.count,
               let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                out.append(value)
                index += 3
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private mutating func readNumber() -> Double {
        let start = index
        index += 1
        while index < bytes.count {
            let b = bytes[index]
            guard (b >= 0x30 && b <= 0x39) || b == UInt8(ascii: ".") || b == UInt8(ascii: "-") else { break }
            index += 1
        }
        return Double(String(decoding: bytes[start..<index], as: UTF8.self)) ?? 0
    }

    private mutating func skipLiteralString() throws {
        index += 1
        var depth = 1
        while index < bytes.count {
            let b = bytes[index]
            if b == UInt8(ascii: "\\") {
                index += 2
                continue
            }
            if b == UInt8(ascii: "(") { depth += 1 }
            if b == UInt8(ascii: ")") {
                depth -= 1
                if depth == 0 {
                    index += 1
                    return
                }
            }
            index += 1
        }
        throw ContentStreamError.malformed("unterminated string")
    }

    private mutating func skipHexString() throws {
        index += 1
        while index < bytes.count, bytes[index] != UInt8(ascii: ">") { index += 1 }
        guard index < bytes.count else { throw ContentStreamError.malformed("unterminated hex string") }
        index += 1
    }

    /// Skips any value: used inside arrays and dictionaries.
    private mutating func skipValue() throws {
        skipWhitespaceAndComments()
        guard index < bytes.count else { throw ContentStreamError.malformed("unexpected end") }
        switch bytes[index] {
        case UInt8(ascii: "("): try skipLiteralString()
        case UInt8(ascii: "<"):
            if peek(1) == UInt8(ascii: "<") { try skipDictionary() } else { try skipHexString() }
        case UInt8(ascii: "["): try skipArray()
        case UInt8(ascii: "/"): _ = readName()
        default:
            if readRegular().isEmpty { index += 1 }
        }
    }

    private mutating func skipArray() throws {
        index += 1
        while true {
            skipWhitespaceAndComments()
            guard index < bytes.count else { throw ContentStreamError.malformed("unterminated array") }
            if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return
            }
            try skipValue()
        }
    }

    private mutating func skipDictionary() throws {
        index += 2
        while true {
            skipWhitespaceAndComments()
            guard index < bytes.count else { throw ContentStreamError.malformed("unterminated dictionary") }
            if bytes[index] == UInt8(ascii: ">"), peek(1) == UInt8(ascii: ">") {
                index += 2
                return
            }
            try skipValue()
        }
    }

    /// `BI <key value pairs> ID <binary data> EI`. The data has no length, so find an `EI` that is
    /// surrounded by whitespace, as conforming readers do.
    private mutating func skipInlineImage() throws {
        while true {
            skipWhitespaceAndComments()
            guard index < bytes.count else { throw ContentStreamError.malformed("unterminated inline image") }
            if bytes[index] == UInt8(ascii: "I"), peek(1) == UInt8(ascii: "D"),
               peek(2).map(Self.isWhitespace) ?? false {
                index += 3
                break
            }
            try skipValue()
        }
        while index + 1 < bytes.count {
            if bytes[index] == UInt8(ascii: "E"), bytes[index + 1] == UInt8(ascii: "I"),
               index > 0, Self.isWhitespace(bytes[index - 1]),
               index + 2 >= bytes.count || Self.isWhitespace(bytes[index + 2]) || Self.isDelimiter(bytes[index + 2]) {
                index += 2
                return
            }
            index += 1
        }
        throw ContentStreamError.malformed("inline image without EI")
    }
}
