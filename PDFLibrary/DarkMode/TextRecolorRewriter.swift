import CoreGraphics
import Foundation

/// Colors used by forced dark mode.
enum DarkPalette {
    /// The reading surface behind every page.
    static let surface: (r: Double, g: Double, b: Double) = (0.11, 0.11, 0.12)
    static var surfaceColor: CGColor { CGColor(srgbRed: surface.r, green: surface.g, blue: surface.b, alpha: 1) }
    /// Text whose original color can't be resolved (patterns, spot colors).
    static let defaultText: (r: Double, g: Double, b: Double) = (0.9, 0.9, 0.9)

    /// Maps an original text color to one readable on the dark surface. Dark colors become light with the
    /// same hue (black → near-white, dark blue link → light blue). Colors that are already light stay as they are.
    static func textColor(fromRGB rgb: (Double, Double, Double)?) -> (r: Double, g: Double, b: Double) {
        guard let (r, g, b) = rgb else { return defaultText }
        let maxC = max(r, g, b), minC = min(r, g, b)
        let lightness = (maxC + minC) / 2
        if lightness >= 0.6 { return (r, g, b) }
        var hue = 0.0, saturation = 0.0
        let delta = maxC - minC
        if delta > 0.0001 {
            saturation = delta / (1 - abs(2 * lightness - 1))
            switch maxC {
            case r: hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            case g: hue = (b - r) / delta + 2
            default: hue = (r - g) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let newLightness = 0.92 - lightness * 0.45
        return hslToRGB(hue, min(1, saturation * 0.85), newLightness)
    }

    private static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (r: Double, g: Double, b: Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return (channel(h + 1 / 3), channel(h), channel(h - 1 / 3))
    }
}

/// What a named color space resource resolves to, as far as text recoloring needs.
enum ColorSpaceKind: Equatable {
    case gray, rgb, cmyk
    case other(components: Int)   // ICC with unusual N, Lab, Separation, DeviceN, Indexed
    case pattern

    static func device(_ name: String) -> ColorSpaceKind? {
        switch name {
        case "DeviceGray", "G", "CalGray": .gray
        case "DeviceRGB", "RGB", "CalRGB": .rgb
        case "DeviceCMYK", "CMYK": .cmyk
        case "Pattern": .pattern
        default: nil
        }
    }

    var initialComponents: [Double] {
        switch self {
        case .gray: [0]
        case .rgb: [0, 0, 0]
        case .cmyk: [0, 0, 0, 1]
        case .other(let n): Array(repeating: 0, count: n)
        case .pattern: []
        }
    }
}

struct TrackedColor {
    var space: ColorSpaceKind = .gray
    var components: [Double] = [0]
    /// The original operators that set this color (`cs` + `scn`, or `rg`, ...), for restoring it verbatim.
    var operators = Data()

    var rgb: (Double, Double, Double)? {
        let c = components
        switch space {
        case .gray where c.count >= 1: return (c[0], c[0], c[0])
        case .rgb where c.count >= 3: return (c[0], c[1], c[2])
        case .cmyk where c.count >= 4:
            return ((1 - c[0]) * (1 - c[3]), (1 - c[1]) * (1 - c[3]), (1 - c[2]) * (1 - c[3]))
        default: return nil
        }
    }
}

/// Rewrites one content stream so that text is drawn in a light color while every other construct —
/// images, vector artwork, shadings, image masks, annotations — keeps its original operators and colors.
///
/// It works on the PDF's drawing operators, not on pixels: inside each text object (`BT`…`ET`) color
/// operators are replaced with a contrast-adjusted color, and the original color state is restored after the
/// object so following artwork is untouched. Invisible text (render mode 3, e.g. the OCR layer of a scan)
/// stays invisible, and text that is part of an image stays part of the image.
struct TextRecolorRewriter {
    struct Result {
        var data: Data
        var hasVisibleText: Bool
        /// Draws an inline image (`BI`…`EI`).
        var drawsInlineImage: Bool
        /// Uses optional content (`/OC … BDC`), whose visibility lives in the source document's catalog.
        var usesOptionalContent: Bool
    }

    /// Resolves `/Name cs` color spaces against the stream's resources.
    var resolveColorSpace: (String) -> ColorSpaceKind
    /// Page box in default user space, used to recognise a full-page light background. Nil for form XObjects,
    /// whose coordinate system depends on where they are drawn.
    var pageBox: CGRect?

    private struct GraphicsState {
        var ctm = CGAffineTransform.identity
        var fill = TrackedColor()
        var stroke = TrackedColor()
        var renderMode = 0
        var clipped = false
    }

    /// `Tr` operand: an integer 0…7. Anything else is a malformed stream (the page falls back to original).
    private static func renderMode(_ op: ContentOperation) throws -> Int {
        guard let value = op.numbers.first, value.isFinite, value >= 0, value <= 7, value == value.rounded() else {
            throw ContentStreamError.malformed("invalid text render mode")
        }
        return Int(value)
    }

    func rewrite(_ data: Data) throws -> Result {
        var lexer = ContentStreamLexer(data)
        let ops = try lexer.operations()
        let src = lexer.source
        var out = Data(capacity: data.count + data.count / 8)
        var hasVisibleText = false
        var drawsInlineImage = false
        var usesOptionalContent = false
        /// Something has been painted; a later light rectangle is artwork, not the page background.
        var paintedSomething = false

        var gs = GraphicsState()
        var stack: [GraphicsState] = []

        // Text object state
        var inText = false
        var block = Data()
        var plainBlock = Data()   // the text object with its original colors
        var replay = Data()
        var blockUsesClip = false
        var colorsBeforeText = Data()
        var colorsBeforeTextKnown = true

        // Path buffering (page level, outside text) to recognise a full-page light background fill.
        var pathStart: Int?
        var pathOps: [ContentOperation] = []

        func raw(_ op: ContentOperation) -> Data {
            var d = Data(src[op.range])
            d.append(0x0A)
            return d
        }

        func colorOverride(fill: Bool) -> Data {
            let color = DarkPalette.textColor(fromRGB: (fill ? gs.fill : gs.stroke).rgb)
            return Data(String(format: "%.4f %.4f %.4f %@\n", color.r, color.g, color.b, fill ? "rg" : "RG").utf8)
        }

        func applyColorOp(_ op: ContentOperation) -> Bool? {
            // Returns true for a fill color change, false for stroke, nil if not a color operator.
            let bytes = raw(op)
            switch op.name {
            case "g": gs.fill = TrackedColor(space: .gray, components: op.numbers, operators: bytes); return true
            case "G": gs.stroke = TrackedColor(space: .gray, components: op.numbers, operators: bytes); return false
            case "rg": gs.fill = TrackedColor(space: .rgb, components: op.numbers, operators: bytes); return true
            case "RG": gs.stroke = TrackedColor(space: .rgb, components: op.numbers, operators: bytes); return false
            case "k": gs.fill = TrackedColor(space: .cmyk, components: op.numbers, operators: bytes); return true
            case "K": gs.stroke = TrackedColor(space: .cmyk, components: op.numbers, operators: bytes); return false
            case "cs", "CS":
                let space = op.lastName.map { ColorSpaceKind.device($0) ?? resolveColorSpace($0) } ?? .other(components: 1)
                let color = TrackedColor(space: space, components: space.initialComponents, operators: bytes)
                if op.name == "cs" { gs.fill = color; return true }
                gs.stroke = color
                return false
            case "sc", "scn", "SC", "SCN":
                let isFill = op.name == "sc" || op.name == "scn"
                var color = isFill ? gs.fill : gs.stroke
                if op.lastName != nil {
                    color.space = .pattern
                    color.components = []
                } else {
                    color.components = op.numbers
                }
                // Keep the color space operator in front so the replay is self-contained.
                if let csEnd = color.operators.lastRange(of: Data(isFill ? " cs\n".utf8 : " CS\n".utf8))?.upperBound {
                    color.operators = color.operators.prefix(upTo: csEnd) + bytes
                } else {
                    color.operators = bytes
                }
                if isFill { gs.fill = color } else { gs.stroke = color }
                return isFill
            default:
                return nil
            }
        }

        func flushPath(paint: ContentOperation?) {
            guard let start = pathStart else { return }
            let end = paint?.range.upperBound ?? pathOps.last?.range.upperBound ?? start
            var segment = Data(src[start..<end])
            segment.append(0x0A)
            let isBackground = paint.map {
                !paintedSomething && !gs.clipped && isFullPageLightBackground(pathOps, paint: $0, gs: gs)
            } ?? false
            if pathOps.contains(where: { $0.name == "W" || $0.name == "W*" }) { gs.clipped = true }
            if let paint, paint.name != "n" { paintedSomething = true }
            if isBackground {
                let s = DarkPalette.surface
                out.append(Data(String(format: "q %.4f %.4f %.4f rg\n", s.r, s.g, s.b).utf8))
                out.append(segment)
                out.append(Data("Q\n".utf8))
            } else {
                out.append(segment)
            }
            pathStart = nil
            pathOps = []
        }

        for op in ops {
            if inText {
                switch op.name {
                case "ET":
                    block.append(raw(op))
                    plainBlock.append(raw(op))
                    if blockUsesClip && !colorsBeforeTextKnown {
                        // Clipping text in a form XObject whose color is inherited from the caller: the color
                        // can't be restored after ET, so this text object keeps its original colors.
                        out.append(plainBlock)
                    } else if blockUsesClip {
                        // Text clipping must survive ET, so no q/Q: restore the colors from before BT, then
                        // replay the changes made inside the text object.
                        out.append(block)
                        out.append(colorsBeforeText)
                        out.append(replay)
                    } else {
                        out.append(Data("q\n".utf8))
                        out.append(block)
                        out.append(Data("Q\n".utf8))
                        out.append(replay)
                    }
                    inText = false
                case "Tj", "TJ", "'":
                    if gs.renderMode != 3 && gs.renderMode != 7 { hasVisibleText = true; paintedSomething = true }
                    block.append(raw(op))
                    plainBlock.append(raw(op))
                case "\"":
                    if gs.renderMode != 3 && gs.renderMode != 7 { hasVisibleText = true; paintedSomething = true }
                    block.append(raw(op))
                    plainBlock.append(raw(op))
                    let n = op.numbers
                    if n.count >= 2 {
                        replay.append(Data(String(format: "%f Tw %f Tc\n", n[0], n[1]).utf8))
                    }
                case "Tr":
                    gs.renderMode = try Self.renderMode(op)
                    if gs.renderMode >= 4 { blockUsesClip = true }
                    block.append(raw(op))
                    plainBlock.append(raw(op))
                    replay.append(raw(op))
                case "Tc", "Tw", "Tz", "TL", "Tf", "Ts", "w", "J", "j", "M", "d", "ri", "i", "gs":
                    block.append(raw(op))
                    plainBlock.append(raw(op))
                    replay.append(raw(op))
                default:
                    if op.name == "BDC", case .name("OC") = op.operands.first { usesOptionalContent = true }
                    plainBlock.append(raw(op))
                    if let isFill = applyColorOp(op) {
                        replay.append(raw(op))
                        block.append(colorOverride(fill: isFill))
                    } else {
                        block.append(raw(op))
                    }
                }
                continue
            }

            // Outside text objects.
            switch op.name {
            case "m", "l", "c", "v", "y", "h", "re", "W", "W*":
                if pathStart == nil { pathStart = op.range.lowerBound }
                pathOps.append(op)
                continue
            case "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n":
                if pathStart != nil {
                    flushPath(paint: op)
                    continue
                }
            default:
                // Any other operator ends a malformed path; emit it unchanged.
                if pathStart != nil { flushPath(paint: nil) }
            }

            switch op.name {
            case "BT":
                inText = true
                block = raw(op)
                plainBlock = raw(op)
                block.append(colorOverride(fill: true))
                block.append(colorOverride(fill: false))
                replay = Data()
                blockUsesClip = gs.renderMode >= 4
                // Page streams start black; form XObjects inherit an unknown color from their caller.
                colorsBeforeTextKnown = pageBox != nil || (!gs.fill.operators.isEmpty && !gs.stroke.operators.isEmpty)
                colorsBeforeText = (gs.fill.operators.isEmpty && pageBox != nil ? Data("0 g\n".utf8) : gs.fill.operators)
                    + (gs.stroke.operators.isEmpty && pageBox != nil ? Data("0 G\n".utf8) : gs.stroke.operators)
                continue
            case "q":
                stack.append(gs)
            case "Q":
                if let last = stack.popLast() { gs = last }
            case "cm":
                let n = op.numbers
                if n.count == 6 {
                    gs.ctm = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(gs.ctm)
                }
            case "Tr":
                gs.renderMode = try Self.renderMode(op)
            case "Do", "sh":
                paintedSomething = true
            case "BI":
                paintedSomething = true
                drawsInlineImage = true
            case "BDC":
                if case .name("OC") = op.operands.first { usesOptionalContent = true }
            default:
                _ = applyColorOp(op)
            }
            out.append(raw(op))
        }
        if pathStart != nil { flushPath(paint: nil) }
        if inText {
            // Unterminated text object: close it as viewers do.
            out.append(Data("q\n".utf8))
            out.append(block)
            out.append(Data("ET\nQ\n".utf8))
            out.append(replay)
        }
        return Result(data: out, hasVisibleText: hasVisibleText, drawsInlineImage: drawsInlineImage,
                      usesOptionalContent: usesOptionalContent)
    }

    /// A single rectangle, filled (not stroked) with a near-white color, covering most of the page: the
    /// document's own page background. It is painted as the dark surface so light text stays readable.
    private func isFullPageLightBackground(_ path: [ContentOperation], paint: ContentOperation, gs: GraphicsState) -> Bool {
        guard let pageBox, ["f", "F", "f*"].contains(paint.name),
              path.count == 1, path[0].name == "re", path[0].numbers.count == 4,
              let (r, g, b) = gs.fill.rgb, 0.2126 * r + 0.7152 * g + 0.0722 * b >= 0.9 else { return false }
        let n = path[0].numbers
        let rect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]).standardized.applying(gs.ctm)
        let covered = rect.intersection(pageBox)
        guard !covered.isNull, pageBox.width > 0, pageBox.height > 0 else { return false }
        return (covered.width * covered.height) / (pageBox.width * pageBox.height) >= 0.85
    }
}
