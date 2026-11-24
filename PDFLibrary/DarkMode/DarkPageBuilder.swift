import CoreGraphics
import Foundation

/// Builds a one-page PDF, in memory, that draws a source page with recolored text.
///
/// The page's resources (fonts, images, artwork, form XObjects) are copied object for object from the source
/// through Core Graphics' PDF object model. Only content streams change: the page's own and those of form
/// XObjects, rewritten by `TextRecolorRewriter`. The source file is never modified.
struct DarkPageBuilder {
    enum Outcome {
        /// `scanLike`: the page draws an image but no PDF text, so any text on it is part of the image
        /// and keeps its original colors.
        case derived(Data, scanLike: Bool)
        /// The page uses something this renderer can't reproduce faithfully; draw the original page.
        case unsupported(String)
    }

    static func build(page: CGPDFPage) -> Outcome {
        guard let pageDict = page.dictionary else { return .unsupported("The page has no dictionary.") }
        var writer = ObjectWriter()
        let resources = inherited("Resources", in: pageDict).flatMap(dictionaryValue)
        let mediaBox = page.getBoxRect(.mediaBox)
        let cropBox = page.getBoxRect(.cropBox)

        let contents = pageContents(pageDict)
        let rewriter = TextRecolorRewriter(
            resolveColorSpace: { ColorSpaceResolver.resolve($0, resources: resources) },
            pageBox: cropBox)
        let rewritten: TextRecolorRewriter.Result
        do {
            rewritten = try rewriter.rewrite(contents)
        } catch {
            return .unsupported("The page's drawing instructions couldn't be read.")
        }

        writer.pageResources = resources
        let resourcesData = resources.map { writer.serialize(dictionary: $0, depth: 0) } ?? Data("<<>>".utf8)
        if let problem = writer.unsupported { return .unsupported(problem) }
        let scanLike = !rewritten.hasVisibleText && !writer.formsHaveVisibleText && writer.sawImage

        let contentsNumber = writer.addStream(dictionary: Data(), data: rewritten.data)
        var pageObject = Data("<< /Type /Page /Parent 2 0 R".utf8)
        pageObject.append(Data(" /MediaBox \(rectArray(mediaBox)) /CropBox \(rectArray(cropBox))".utf8))
        pageObject.append(Data(" /Resources ".utf8))
        pageObject.append(resourcesData)
        if let group = dictionaryObject("Group", in: pageDict) {
            pageObject.append(Data(" /Group ".utf8))
            pageObject.append(writer.serialize(object: group, depth: 0))
        }
        pageObject.append(Data(" /Contents \(contentsNumber) 0 R >>".utf8))
        return .derived(writer.document(pageObject: pageObject), scanLike: scanLike)
    }

    // MARK: Page helpers

    private static func rectArray(_ r: CGRect) -> String {
        "[\(ObjectWriter.number(r.minX)) \(ObjectWriter.number(r.minY)) \(ObjectWriter.number(r.maxX)) \(ObjectWriter.number(r.maxY))]"
    }

    /// Page attributes like Resources can be inherited from the page tree.
    private static func inherited(_ key: String, in dict: CGPDFDictionaryRef) -> CGPDFObjectRef? {
        var current: CGPDFDictionaryRef? = dict
        var depth = 0
        while let d = current, depth < 32 {
            var object: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(d, key, &object), let object { return object }
            var parent: CGPDFDictionaryRef?
            current = CGPDFDictionaryGetDictionary(d, "Parent", &parent) ? parent : nil
            depth += 1
        }
        return nil
    }

    private static func dictionaryValue(_ object: CGPDFObjectRef) -> CGPDFDictionaryRef? {
        var dict: CGPDFDictionaryRef?
        return CGPDFObjectGetValue(object, .dictionary, &dict) ? dict : nil
    }

    private static func dictionaryObject(_ key: String, in dict: CGPDFDictionaryRef) -> CGPDFObjectRef? {
        var object: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dict, key, &object) ? object : nil
    }

    private static func pageContents(_ dict: CGPDFDictionaryRef) -> Data {
        var stream: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(dict, "Contents", &stream), let stream {
            return decoded(stream) ?? Data()
        }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dict, "Contents", &array), let array else { return Data() }
        var data = Data()
        for i in 0..<CGPDFArrayGetCount(array) {
            var part: CGPDFStreamRef?
            if CGPDFArrayGetStream(array, i, &part), let part, let bytes = decoded(part) {
                data.append(bytes)
                data.append(0x0A)
            }
        }
        return data
    }

    static func decoded(_ stream: CGPDFStreamRef) -> Data? {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format), format == .raw else { return nil }
        return data as Data
    }
}

/// Resolves named color spaces in a resource dictionary.
enum ColorSpaceResolver {
    static func resolve(_ name: String, resources: CGPDFDictionaryRef?) -> ColorSpaceKind {
        if let device = ColorSpaceKind.device(name) { return device }
        guard let resources else { return .other(components: 1) }
        var spaces: CGPDFDictionaryRef?
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetDictionary(resources, "ColorSpace", &spaces), let spaces,
              CGPDFDictionaryGetObject(spaces, name, &object), let object else { return .other(components: 1) }
        return kind(of: object)
    }

    private static func kind(of object: CGPDFObjectRef) -> ColorSpaceKind {
        var namePtr: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .name, &namePtr), let namePtr {
            return ColorSpaceKind.device(String(cString: namePtr)) ?? .other(components: 1)
        }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &array), let array else { return .other(components: 1) }
        var familyPtr: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(array, 0, &familyPtr), let familyPtr else { return .other(components: 1) }
        switch String(cString: familyPtr) {
        case "ICCBased":
            var stream: CGPDFStreamRef?
            guard CGPDFArrayGetStream(array, 1, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else {
                return .other(components: 1)
            }
            var n: CGPDFInteger = 0
            CGPDFDictionaryGetInteger(dict, "N", &n)
            switch n {
            case 1: return .gray
            case 3: return .rgb
            case 4: return .cmyk
            default: return .other(components: Int(n))
            }
        case "CalGray": return .gray
        case "CalRGB": return .rgb
        case "Pattern": return .pattern
        case "Lab": return .other(components: 3)
        default: return .other(components: 1)  // Separation, DeviceN, Indexed: color not derivable here
        }
    }
}

/// Serializes Core Graphics PDF objects into a new PDF file.
private struct ObjectWriter {
    var objects: [Int: Data] = [:]
    var nextNumber = 4  // 1 catalog, 2 pages, 3 page
    var streamNumbers: [UnsafeRawPointer: Int] = [:]
    var ancestors: Set<UnsafeRawPointer> = []
    var unsupported: String?
    var formsHaveVisibleText = false
    var sawImage = false
    var pageResources: CGPDFDictionaryRef?

    static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        var s = String(format: "%.6f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func name(_ raw: String) -> String {
        var out = "/"
        for byte in raw.utf8 {
            let regular = byte > 0x20 && byte < 0x7F && byte != UInt8(ascii: "#")
                && !ContentStreamLexer.isDelimiter(byte)
            out += regular ? String(UnicodeScalar(byte)) : String(format: "#%02X", byte)
        }
        return out
    }

    mutating func addStream(dictionary: Data, data: Data) -> Int {
        let number = nextNumber
        nextNumber += 1
        var object = Data("<<".utf8)
        object.append(dictionary)
        object.append(Data(" /Length \(data.count) >>\nstream\n".utf8))
        object.append(data)
        object.append(Data("\nendstream".utf8))
        objects[number] = object
        return number
    }

    mutating func serialize(object: CGPDFObjectRef, depth: Int) -> Data {
        guard depth < 64 else { return Data("null".utf8) }
        switch CGPDFObjectGetType(object) {
        case .null:
            return Data("null".utf8)
        case .boolean:
            var b: CGPDFBoolean = 0
            CGPDFObjectGetValue(object, .boolean, &b)
            return Data((b != 0 ? "true" : "false").utf8)
        case .integer:
            var i: CGPDFInteger = 0
            CGPDFObjectGetValue(object, .integer, &i)
            return Data(String(i).utf8)
        case .real:
            var r: CGPDFReal = 0
            CGPDFObjectGetValue(object, .real, &r)
            return Data(Self.number(Double(r)).utf8)
        case .name:
            var ptr: UnsafePointer<CChar>?
            CGPDFObjectGetValue(object, .name, &ptr)
            return Data(Self.name(ptr.map { String(cString: $0) } ?? "").utf8)
        case .string:
            var string: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &string), let string,
                  let bytes = CGPDFStringGetBytePtr(string) else { return Data("<>".utf8) }
            let buffer = UnsafeBufferPointer(start: bytes, count: CGPDFStringGetLength(string))
            return Data(("<" + buffer.map { String(format: "%02X", $0) }.joined() + ">").utf8)
        case .array:
            var array: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &array), let array else { return Data("[]".utf8) }
            return serialize(array: array, depth: depth)
        case .dictionary:
            var dict: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dict), let dict else { return Data("<<>>".utf8) }
            return serialize(dictionary: dict, depth: depth)
        case .stream:
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return Data("null".utf8) }
            return Data("\(serialize(stream: stream, depth: depth)) 0 R".utf8)
        @unknown default:
            return Data("null".utf8)
        }
    }

    mutating func serialize(array: CGPDFArrayRef, depth: Int) -> Data {
        let key = unsafeBitCast(array, to: UnsafeRawPointer.self)
        guard !ancestors.contains(key) else { return Data("null".utf8) }
        ancestors.insert(key)
        defer { ancestors.remove(key) }
        var out = Data("[".utf8)
        for i in 0..<CGPDFArrayGetCount(array) {
            var object: CGPDFObjectRef?
            if CGPDFArrayGetObject(array, i, &object), let object {
                out.append(serialize(object: object, depth: depth + 1))
            } else {
                out.append(Data("null".utf8))
            }
            out.append(0x20)
        }
        out.append(Data("]".utf8))
        return out
    }

    mutating func serialize(dictionary: CGPDFDictionaryRef, depth: Int, skip: Set<String> = []) -> Data {
        let key = unsafeBitCast(dictionary, to: UnsafeRawPointer.self)
        guard !ancestors.contains(key) else { return Data("null".utf8) }
        ancestors.insert(key)
        defer { ancestors.remove(key) }
        var entries: [(String, CGPDFObjectRef)] = []
        withUnsafeMutablePointer(to: &entries) { pointer in
            CGPDFDictionaryApplyBlock(dictionary, { key, value, info in
                info?.assumingMemoryBound(to: [(String, CGPDFObjectRef)].self).pointee.append((String(cString: key), value))
                return true
            }, pointer)
        }
        var out = Data("<<".utf8)
        for (name, value) in entries.sorted(by: { $0.0 < $1.0 }) where name != "Parent" && !skip.contains(name) {
            out.append(Data(" \(Self.name(name)) ".utf8))
            out.append(serialize(object: value, depth: depth + 1))
        }
        out.append(Data(" >>".utf8))
        return out
    }

    /// Writes a stream as an indirect object and returns its number. Shared streams (a font used by
    /// several forms) are written once.
    mutating func serialize(stream: CGPDFStreamRef, depth: Int) -> Int {
        let key = unsafeBitCast(stream, to: UnsafeRawPointer.self)
        if let number = streamNumbers[key] { return number }
        let number = nextNumber
        nextNumber += 1
        streamNumbers[key] = number

        guard let dict = CGPDFStreamGetDictionary(stream) else {
            objects[number] = Data("null".utf8)
            return number
        }
        let filters = Self.filterNames(dict)
        if Self.subtype(dict) == "Image" { sawImage = true }
        if filters.contains("JBIG2Decode") || filters.contains("CCITTFaxDecode") {
            unsupported = "This page has a fax-encoded image that forced dark mode can't redraw."
        }

        var format = CGPDFDataFormat.raw
        guard let cfData = CGPDFStreamCopyData(stream, &format) else {
            unsupported = "An embedded object couldn't be read."
            objects[number] = Data("null".utf8)
            return number
        }
        var data = cfData as Data
        var extra = ""
        var skip: Set<String> = ["Length", "Filter", "DecodeParms", "DL"]
        switch format {
        case .raw:
            if Self.isForm(dict) {
                data = rewriteForm(data, dict: dict)
            }
        case .jpegEncoded:
            extra = " /Filter /DCTDecode"
            if filters == ["DCTDecode"] { skip.remove("DecodeParms") }
        case .JPEG2000:
            extra = " /Filter /JPXDecode"
        @unknown default:
            unsupported = "An embedded object uses an unsupported encoding."
        }

        var dictData = serialize(dictionary: dict, depth: depth + 1, skip: skip)
        // Drop the closing ">>" from the serialized dictionary; addStream-style framing adds Length.
        dictData.removeLast(2)
        var object = dictData
        object.append(Data("\(extra) /Length \(data.count) >>\nstream\n".utf8))
        object.append(data)
        object.append(Data("\nendstream".utf8))
        objects[number] = object
        return number
    }

    private mutating func rewriteForm(_ data: Data, dict: CGPDFDictionaryRef) -> Data {
        var resources: CGPDFDictionaryRef?
        let formResources = CGPDFDictionaryGetDictionary(dict, "Resources", &resources) ? resources : pageResources
        let rewriter = TextRecolorRewriter(
            resolveColorSpace: { ColorSpaceResolver.resolve($0, resources: formResources) },
            pageBox: nil)
        guard let result = try? rewriter.rewrite(data) else {
            unsupported = "A drawing group on this page couldn't be read."
            return data
        }
        if result.hasVisibleText { formsHaveVisibleText = true }
        return result.data
    }

    private static func isForm(_ dict: CGPDFDictionaryRef) -> Bool {
        subtype(dict) == "Form"
    }

    private static func subtype(_ dict: CGPDFDictionaryRef) -> String? {
        var subtype: UnsafePointer<CChar>?
        return CGPDFDictionaryGetName(dict, "Subtype", &subtype) ? subtype.map { String(cString: $0) } : nil
    }

    private static func filterNames(_ dict: CGPDFDictionaryRef) -> [String] {
        var single: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dict, "Filter", &single), let single { return [String(cString: single)] }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dict, "Filter", &array), let array else { return [] }
        return (0..<CGPDFArrayGetCount(array)).compactMap { i in
            var name: UnsafePointer<CChar>?
            return CGPDFArrayGetName(array, i, &name) ? name.map { String(cString: $0) } : nil
        }
    }

    func document(pageObject: Data) -> Data {
        var all = objects
        all[1] = Data("<< /Type /Catalog /Pages 2 0 R >>".utf8)
        all[2] = Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8)
        all[3] = pageObject
        let count = nextNumber
        var out = Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets = [Int](repeating: 0, count: count)
        for number in 1..<count {
            offsets[number] = out.count
            out.append(Data("\(number) 0 obj\n".utf8))
            out.append(all[number] ?? Data("null".utf8))
            out.append(Data("\nendobj\n".utf8))
        }
        let xref = out.count
        out.append(Data("xref\n0 \(count)\n0000000000 65535 f \n".utf8))
        for number in 1..<count {
            out.append(Data(String(format: "%010d 00000 n \n", offsets[number]).utf8))
        }
        out.append(Data("trailer\n<< /Size \(count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return out
    }
}
