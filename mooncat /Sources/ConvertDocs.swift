import AppKit
import Foundation
import PDFKit

/// Runs `work` on the main thread. AppKit's document import/export and text layout want it.
func onMain<T>(_ work: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try work() }
    return try DispatchQueue.main.sync(execute: work)
}

/// Text documents. `NSAttributedString` is the common middle step, so formatting survives
/// as far as each format can hold it.
enum Docs {
    static let bodySize: CGFloat = 12

    static func bodyFont() -> NSFont { return NSFont.systemFont(ofSize: bodySize) }

    // MARK: Reading

    static func read(_ url: URL, as f: Fmt) throws -> NSAttributedString {
        switch f {
        case .txt:
            return plain(try readString(url))
        case .md:
            return Markdown.parse(try readString(url))
        case .rtf:
            return try attributed(url, .rtf)
        case .html:
            return try attributed(url, .html)
        case .docx:
            return try attributed(url, .officeOpenXML)
        case .odt:
            return try attributed(url, .openDocument)
        case .pdf:
            guard let doc = PDFDocument(url: url) else {
                throw ConvertError.message("Could not open \(url.lastPathComponent) as a PDF.")
            }
            if doc.isLocked { throw ConvertError.message("This PDF is password protected.") }
            let text = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                throw ConvertError.message("This PDF has no selectable text (it may be a scan). Convert it to images first, then read the text from those.")
            }
            return plain(text)
        case .pptx:
            let slides = try Pptx.readText(url)
            return fromSections(slides)
        default:
            throw ConvertError.message("\(f.label) is not a text document.")
        }
    }

    static func readString(_ url: URL) throws -> String {
        var enc: String.Encoding = .utf8
        if let s = try? String(contentsOf: url, usedEncoding: &enc) { return s }
        let data = try Data(contentsOf: url)
        let hasBOM = data.count >= 2 && ((data[0] == 0xFF && data[1] == 0xFE) || (data[0] == 0xFE && data[1] == 0xFF))
        if hasBOM, let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        throw ConvertError.message("Could not work out the text encoding of \(url.lastPathComponent).")
    }

    private static func attributed(_ url: URL, _ type: NSAttributedString.DocumentType) throws -> NSAttributedString {
        var opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        if type == .html { opts[.characterEncoding] = String.Encoding.utf8.rawValue }
        do {
            return try NSAttributedString(url: url, options: opts, documentAttributes: nil)
        } catch {
            throw ConvertError.message("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    static func plain(_ s: String) -> NSAttributedString {
        return NSAttributedString(string: s, attributes: [.font: bodyFont(), .foregroundColor: NSColor.black])
    }

    // MARK: Writing

    static func write(_ a: NSAttributedString, as f: Fmt, to url: URL, name: String, landscape: Bool = false) throws {
        let full = NSRange(location: 0, length: a.length)
        switch f {
        case .txt:
            try cleanText(a.string).write(to: url, atomically: true, encoding: .utf8)
        case .md:
            try Markdown.render(a).write(to: url, atomically: true, encoding: .utf8)
        case .rtf:
            try a.data(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: url)
        case .html:
            let d = try a.data(from: full, documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue])
            try d.write(to: url)
        case .docx:
            try a.data(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: url)
        case .odt:
            try a.data(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.openDocument]).write(to: url)
        case .pdf:
            try printPDF(a, to: url, landscape: landscape)
        case .pptx:
            try Pptx.writeText(sections(from: a, title: name), to: url)
        default:
            throw ConvertError.message("\(f.label) is not a text document.")
        }
    }

    /// Plain text without the placeholder characters that stand in for pictures.
    static func cleanText(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\u{FFFC}", with: "")
        t = t.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n\n")
        t = t.replacingOccurrences(of: "\u{0C}", with: "\n")
        if !t.hasSuffix("\n") { t += "\n" }
        return t
    }

    // MARK: Paragraph structure (used for Markdown and slides)

    struct Para {
        var text: String
        var headingLevel: Int     // 0 = not a heading
        var isBullet: Bool
        var isMono: Bool
        var range: NSRange
    }

    /// The most common font size, weighted by characters. That is "body text".
    static func dominantSize(_ a: NSAttributedString) -> CGFloat {
        var weight: [CGFloat: Int] = [:]
        a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length), options: []) { v, r, _ in
            let size = (v as? NSFont)?.pointSize ?? bodySize
            weight[round(size * 2) / 2, default: 0] += r.length
        }
        return weight.max { $0.value < $1.value }?.key ?? bodySize
    }

    static func paragraphs(_ a: NSAttributedString) -> [Para] {
        let ns = a.string as NSString
        let body = dominantSize(a)
        var out: [Para] = []
        var loc = 0
        while loc < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            if pr.length == 0 { break }
            var contentRange = pr
            while contentRange.length > 0 {
                let c = ns.character(at: contentRange.location + contentRange.length - 1)
                if c == 10 || c == 13 || c == 0x2028 || c == 0x2029 { contentRange.length -= 1 } else { break }
            }
            let raw = ns.substring(with: contentRange).replacingOccurrences(of: "\u{FFFC}", with: "")
            loc = NSMaxRange(pr)
            var text = raw.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { out.append(Para(text: "", headingLevel: 0, isBullet: false, isMono: false, range: contentRange)); continue }

            var maxSize: CGFloat = 0
            var allBold = true
            var allMono = true
            var chars = 0
            a.enumerateAttribute(.font, in: contentRange, options: []) { v, r, _ in
                let font = (v as? NSFont) ?? bodyFont()
                maxSize = max(maxSize, font.pointSize)
                let traits = NSFontManager.shared.traits(of: font)
                if !traits.contains(.boldFontMask) { allBold = false }
                if !font.isFixedPitch { allMono = false }
                chars += r.length
            }
            var level = 0
            if maxSize >= body * 1.7 { level = 1 }
            else if maxSize >= body * 1.35 { level = 2 }
            else if maxSize >= body * 1.15 { level = 3 }
            else if allBold && text.count <= 70 && !text.hasSuffix(".") && !text.hasSuffix(":") { level = 3 }

            var bullet = false
            if let r = text.range(of: "^(\\u2022|\\u25E6|\\u25AA|\\u2023|\\u2043|[-*\\u2013])\\s+", options: .regularExpression) {
                bullet = true
                text = String(text[r.upperBound...])
            } else if let r = text.range(of: "^\\d+[.)]\\s+", options: .regularExpression) {
                bullet = true
                text = String(text[r.upperBound...])
            }
            if bullet { level = 0 }
            out.append(Para(text: text, headingLevel: level, isBullet: bullet, isMono: allMono && !bullet, range: contentRange))
        }
        return out
    }

    /// Slides: a new slide starts at every heading; text before the first heading goes under `title`.
    static func sections(from a: NSAttributedString, title: String) -> [TextSlide] {
        var result: [TextSlide] = []
        var cur = TextSlide(title: title, lines: [])
        var started = false
        for p in paragraphs(a) {
            if p.text.isEmpty { continue }
            if p.headingLevel > 0 && p.headingLevel <= 3 && p.text.count <= 120 {
                if started || !cur.lines.isEmpty { result.append(cur) }
                cur = TextSlide(title: p.text, lines: [])
                started = true
            } else {
                cur.lines.append(p.isBullet ? "\u{2022}  " + p.text : p.text)
            }
        }
        if started || !cur.lines.isEmpty || result.isEmpty { result.append(cur) }
        return result
    }

    static func fromSections(_ slides: [TextSlide]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let titleFont = NSFont.systemFont(ofSize: 20, weight: .bold)
        for s in slides {
            out.append(NSAttributedString(string: s.title + "\n", attributes: [.font: titleFont, .foregroundColor: NSColor.black]))
            for l in s.lines {
                out.append(NSAttributedString(string: l + "\n", attributes: [.font: bodyFont(), .foregroundColor: NSColor.black]))
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont()]))
        }
        return out
    }

    /// One slide per PDF page when the source is a PDF.
    static func pdfSections(_ url: URL) throws -> [TextSlide] {
        guard let doc = PDFDocument(url: url) else { throw ConvertError.message("Could not open the PDF.") }
        var out: [TextSlide] = []
        for i in 0..<doc.pageCount {
            let text = doc.page(at: i)?.string ?? ""
            let lines = text.split(whereSeparator: { $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            out.append(TextSlide(title: "Page \(i + 1)", lines: lines))
        }
        if out.allSatisfy({ $0.lines.isEmpty }) {
            throw ConvertError.message("This PDF has no selectable text (it may be a scan).")
        }
        return out
    }

    // MARK: PDF output

    static func printPDF(_ source: NSAttributedString, to url: URL, landscape: Bool) throws {
        let metric = Locale.current.usesMetricSystem
        var pw: CGFloat = metric ? 595 : 612
        var ph: CGFloat = metric ? 842 : 792
        if landscape { swap(&pw, &ph) }
        let margin: CGFloat = 54

        // Anything with no colour set is drawn black, so dark mode cannot make white-on-white pages.
        let attr = NSMutableAttributedString(attributedString: source)
        attr.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attr.length), options: []) { v, r, _ in
            if v == nil { attr.addAttribute(.foregroundColor, value: NSColor.black, range: r) }
        }

        let storage = NSTextStorage(attributedString: attr)
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let area = CGSize(width: pw - 2 * margin, height: ph - 2 * margin)
        var containers: [NSTextContainer] = []
        repeat {
            let tc = NSTextContainer(size: area)
            tc.lineFragmentPadding = 0
            lm.addTextContainer(tc)
            containers.append(tc)
            _ = lm.glyphRange(for: tc)    // lays this page out
        } while NSMaxRange(lm.glyphRange(for: containers[containers.count - 1])) < lm.numberOfGlyphs
                && containers.count < 3000

        var box = CGRect(x: 0, y: 0, width: pw, height: ph)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw ConvertError.message("Could not create the PDF.")
        }
        for tc in containers {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: ph)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let glyphs = lm.glyphRange(for: tc)
            let origin = NSPoint(x: margin, y: margin)
            lm.drawBackground(forGlyphRange: glyphs, at: origin)
            lm.drawGlyphs(forGlyphRange: glyphs, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}

// MARK: - Markdown

enum Markdown {
    private static func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false, mono: Bool = false) -> NSFont {
        var f: NSFont
        if mono { f = NSFont.monospacedSystemFont(ofSize: size - 1, weight: bold ? .bold : .regular) }
        else { f = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular) }
        if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    static func parse(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let sizes: [CGFloat] = [28, 22, 18, 16, 14, 13]
        var inCode = false
        let base = Docs.bodySize

        func para(indent: CGFloat = 0, firstIndent: CGFloat = 0, after: CGFloat = 6) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.headIndent = indent
            p.firstLineHeadIndent = firstIndent
            p.paragraphSpacing = after
            return p
        }

        for rawLine in lines {
            let line = rawLine
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inCode.toggle(); continue }
            if inCode {
                out.append(NSAttributedString(string: line + "\n", attributes: [
                    .font: font(base, mono: true), .foregroundColor: NSColor.black,
                    .paragraphStyle: para(indent: 12, firstIndent: 12, after: 0)]))
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { out.append(NSAttributedString(string: "\n", attributes: [.font: font(base * 0.5)])); continue }
            if trimmed.range(of: "^(-{3,}|\\*{3,}|_{3,})$", options: .regularExpression) != nil { continue }

            if let m = trimmed.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                let hashes = trimmed[m].filter { $0 == "#" }.count
                let body = String(trimmed[m.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                let ps = para(after: 8)
                ps.paragraphSpacingBefore = 8
                inline(body, size: sizes[hashes - 1], bold: true, into: out, style: ps)
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            var quoteText = trimmed
            if quoteText.hasPrefix(">") {
                quoteText = String(quoteText.dropFirst()).trimmingCharacters(in: .whitespaces)
                inline(quoteText, size: base, italic: true, into: out, style: para(indent: 18, firstIndent: 18))
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            let leading = line.prefix { $0 == " " || $0 == "\t" }.count
            let level = CGFloat(min(leading / 2, 4))
            if let m = trimmed.range(of: "^[-*+]\\s+", options: .regularExpression) {
                let item = String(trimmed[m.upperBound...])
                let ps = para(indent: 28 + level * 18, firstIndent: 12 + level * 18, after: 2)
                out.append(NSAttributedString(string: "\u{2022}\u{00A0}\u{00A0}", attributes: [.font: font(base), .foregroundColor: NSColor.black, .paragraphStyle: ps]))
                inline(item, size: base, into: out, style: ps)
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            if let m = trimmed.range(of: "^\\d+[.)]\\s+", options: .regularExpression) {
                let marker = String(trimmed[trimmed.startIndex..<m.upperBound]).trimmingCharacters(in: .whitespaces)
                let item = String(trimmed[m.upperBound...])
                let ps = para(indent: 32 + level * 18, firstIndent: 12 + level * 18, after: 2)
                out.append(NSAttributedString(string: marker + "\u{00A0}\u{00A0}", attributes: [.font: font(base), .foregroundColor: NSColor.black, .paragraphStyle: ps]))
                inline(item, size: base, into: out, style: ps)
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            inline(trimmed, size: base, into: out, style: para())
            out.append(NSAttributedString(string: "\n"))
        }
        return out
    }

    /// **bold**, *italic*, `code` and [links](url) inside one line.
    private static func inline(_ s: String, size: CGFloat, bold boldBase: Bool = false, italic italicBase: Bool = false,
                               into out: NSMutableAttributedString, style: NSParagraphStyle) {
        let chars = Array(s)
        var i = 0
        var bold = false, ital = false
        var buf = ""

        func flush() {
            if buf.isEmpty { return }
            out.append(NSAttributedString(string: buf, attributes: [
                .font: font(size, bold: bold || boldBase, italic: ital || italicBase),
                .foregroundColor: NSColor.black, .paragraphStyle: style]))
            buf = ""
        }
        func isWord(_ c: Character?) -> Bool { return c.map { $0.isLetter || $0.isNumber } ?? false }

        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            if c == "\\", let n = next, "\\`*_[]()#+-.!>".contains(n) { buf.append(n); i += 2; continue }
            if (c == "*" && next == "*") || (c == "_" && next == "_" && !isWord(prev) ) {
                flush(); bold.toggle(); i += 2; continue
            }
            if c == "*" || c == "_" {
                let opening = !ital
                let nextIsSpace = next == nil || next == " "
                let prevIsSpace = prev == nil || prev == " "
                var ok = opening ? !nextIsSpace : !prevIsSpace
                if c == "_" {
                    // Underscores inside words (snake_case) are not emphasis.
                    ok = opening ? (!isWord(prev) && isWord(next)) : (isWord(prev) && !isWord(next))
                }
                if ok { flush(); ital.toggle(); i += 1; continue }
            }
            if c == "`" {
                if let end = chars[(i + 1)...].firstIndex(of: "`") {
                    flush()
                    out.append(NSAttributedString(string: String(chars[(i + 1)..<end]), attributes: [
                        .font: font(size, mono: true), .foregroundColor: NSColor.black,
                        .backgroundColor: NSColor(white: 0.92, alpha: 1), .paragraphStyle: style]))
                    i = end + 1
                    continue
                }
            }
            if c == "[" {
                // [text](url)
                if let close = chars[(i + 1)...].firstIndex(of: "]"), close + 1 < chars.count, chars[close + 1] == "(",
                   let paren = chars[(close + 2)...].firstIndex(of: ")") {
                    flush()
                    let label = String(chars[(i + 1)..<close])
                    let urlText = String(chars[(close + 2)..<paren])
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: font(size, bold: bold || boldBase, italic: ital || italicBase),
                        .foregroundColor: NSColor.blue, .paragraphStyle: style,
                        .underlineStyle: NSUnderlineStyle.single.rawValue]
                    if let u = URL(string: urlText) { attrs[.link] = u }
                    out.append(NSAttributedString(string: label, attributes: attrs))
                    i = paren + 1
                    continue
                }
            }
            buf.append(c)
            i += 1
        }
        flush()
    }

    // MARK: Rendering to Markdown

    static func render(_ a: NSAttributedString) -> String {
        let paras = Docs.paragraphs(a)
        var blocks: [String] = []
        var codeLines: [String] = []
        var lastWasBullet = false

        func closeCode() {
            if !codeLines.isEmpty {
                blocks.append("```\n" + codeLines.joined(separator: "\n") + "\n```")
                codeLines = []
            }
        }
        let ns = a.string as NSString
        for p in paras {
            if p.text.isEmpty { closeCode(); lastWasBullet = false; continue }
            if p.isMono {
                codeLines.append(ns.substring(with: p.range).replacingOccurrences(of: "\u{FFFC}", with: ""))
                continue
            }
            closeCode()
            let body = inlineMarkdown(a, p)
            if p.headingLevel > 0 {
                blocks.append(String(repeating: "#", count: p.headingLevel) + " " + stripEmphasis(body))
                lastWasBullet = false
            } else if p.isBullet {
                let line = "- " + body
                if lastWasBullet, let last = blocks.last { blocks[blocks.count - 1] = last + "\n" + line }
                else { blocks.append(line) }
                lastWasBullet = true
            } else {
                blocks.append(body)
                lastWasBullet = false
            }
        }
        closeCode()
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func stripEmphasis(_ s: String) -> String {
        var t = s
        if t.hasPrefix("**") && t.hasSuffix("**") && t.count > 4 { t = String(t.dropFirst(2).dropLast(2)) }
        return t
    }

    /// The paragraph's text with bold, italic, code and links turned into Markdown marks.
    private static func inlineMarkdown(_ a: NSAttributedString, _ p: Docs.Para) -> String {
        let ns = a.string as NSString
        // Re-find the visible text inside the paragraph (bullet markers were trimmed from p.text).
        var range = p.range
        let raw = ns.substring(with: range)
        var out = ""
        var skip = 0
        if p.isBullet,
           let m = raw.range(of: "^\\s*(\\u2022|\\u25E6|\\u25AA|\\u2023|\\u2043|[-*\\u2013]|\\d+[.)])\\s+", options: .regularExpression) {
            skip = NSRange(m, in: raw).length
        }
        range.location += skip
        range.length -= skip
        if range.length <= 0 { return p.text }
        a.enumerateAttributes(in: range, options: []) { attrs, r, _ in
            var piece = ns.substring(with: r).replacingOccurrences(of: "\u{FFFC}", with: "")
                .replacingOccurrences(of: "\u{2028}", with: "  \n")
            if piece.isEmpty { return }
            let font = (attrs[.font] as? NSFont) ?? Docs.bodyFont()
            let traits = NSFontManager.shared.traits(of: font)
            let isMono = font.isFixedPitch
            if isMono {
                if !piece.trimmingCharacters(in: .whitespaces).isEmpty { piece = "`" + piece + "`" }
            } else {
                piece = piece.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "*", with: "\\*")
                    .replacingOccurrences(of: "`", with: "\\`")
            }
            let isBold = traits.contains(.boldFontMask) && p.headingLevel == 0
            let isItalic = traits.contains(.italicFontMask)
            let lead = piece.prefix { $0 == " " }
            let trail = piece.reversed().prefix { $0 == " " }
            let core = piece.trimmingCharacters(in: .whitespaces)
            if !core.isEmpty && !isMono {
                var marked = core
                if isItalic { marked = "*" + marked + "*" }
                if isBold { marked = "**" + marked + "**" }
                if let link = attrs[.link] {
                    let urlString = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                    if !urlString.isEmpty { marked = "[" + core + "](" + urlString + ")" }
                }
                piece = String(lead) + marked + String(String(trail.reversed()))
            }
            out += piece
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
