import AppKit
import Foundation

/// Tables: CSV, TSV, JSON, XLSX and XML records. Everything goes through `[[String]]`,
/// first row = column names.
enum Tables {
    // MARK: Reading

    static func read(_ url: URL, as f: Fmt) throws -> [[String]] {
        switch f {
        case .csv: return normalized(CSV.parse(try Docs.readString(url), delimiter: CSV.sniffDelimiter(try Docs.readString(url))))
        case .tsv: return normalized(CSV.parse(try Docs.readString(url), delimiter: "\t"))
        case .json: return try JSONTable.read(try Docs.readString(url))
        case .xlsx: return normalized(try Xlsx.read(url))
        case .xml: return try XMLTable.read(try Data(contentsOf: url))
        default: throw ConvertError.message("\(f.label) is not a table format.")
        }
    }

    /// Drops empty trailing rows and makes every row the same width.
    static func normalized(_ rows: [[String]]) -> [[String]] {
        var r = rows
        while let last = r.last, last.allSatisfy({ $0.isEmpty }) { r.removeLast() }
        let width = r.map { $0.count }.max() ?? 0
        return r.map { $0 + [String](repeating: "", count: width - $0.count) }
    }

    // MARK: Writing

    static func write(_ rows: [[String]], as f: Fmt, to url: URL, name: String) throws {
        if rows.isEmpty { throw ConvertError.message("There is no data in this file.") }
        switch f {
        case .csv: try CSV.render(rows, delimiter: ",").write(to: url, atomically: true, encoding: .utf8)
        case .tsv: try CSV.render(rows, delimiter: "\t").write(to: url, atomically: true, encoding: .utf8)
        case .json: try JSONTable.render(rows).write(to: url, atomically: true, encoding: .utf8)
        case .xlsx: try Xlsx.write(rows, to: url)
        case .xml: try XMLTable.render(rows).write(to: url, atomically: true, encoding: .utf8)
        case .html: try html(rows, title: name).write(to: url, atomically: true, encoding: .utf8)
        case .md: try markdown(rows).write(to: url, atomically: true, encoding: .utf8)
        case .pdf:
            let attr = try onMain { () -> NSAttributedString in
                guard let data = html(rows, title: name).data(using: .utf8) else {
                    throw ConvertError.message("Could not lay out the table.")
                }
                return try NSAttributedString(data: data, options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
            }
            let wide = (rows.first?.count ?? 0) > 6
            try onMain { try Docs.printPDF(attr, to: url, landscape: wide) }
        default: throw ConvertError.message("\(f.label) is not a table format.")
        }
    }

    static func html(_ rows: [[String]], title: String) -> String {
        var s = "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>\(xmlEscape(title))</title>\n"
        s += "<style>body{font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:12px;color:#000}"
        s += "table{border-collapse:collapse}th,td{border:1px solid #bbb;padding:4px 8px;text-align:left;vertical-align:top}"
        s += "th{background:#eee}</style></head><body>\n<table>\n"
        for (i, row) in rows.enumerated() {
            let open = i == 0 ? "<th>" : "<td>"
            let close = i == 0 ? "</th>" : "</td>"
            var line = "<tr>"
            for cell in row {
                let text = xmlEscape(cell).replacingOccurrences(of: "\n", with: "<br>")
                line += open + text + close
            }
            s += line + "</tr>\n"
        }
        s += "</table>\n</body></html>\n"
        return s
    }

    static func markdown(_ rows: [[String]]) -> String {
        func cell(_ s: String) -> String {
            return s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }
        guard let head = rows.first else { return "" }
        var s = "| " + head.map(cell).joined(separator: " | ") + " |\n"
        s += "| " + head.map { _ in "---" }.joined(separator: " | ") + " |\n"
        for row in rows.dropFirst() { s += "| " + row.map(cell).joined(separator: " | ") + " |\n" }
        return s
    }
}

// MARK: - CSV / TSV

enum CSV {
    /// Picks comma, semicolon or tab by counting them in the first line.
    static func sniffDelimiter(_ text: String) -> Character {
        let first = text.unicodeScalars.prefix { $0 != "\n" && $0 != "\r" }
        let commas = first.filter { $0 == "," }.count
        let semis = first.filter { $0 == ";" }.count
        let tabs = first.filter { $0 == "\t" }.count
        if tabs > commas && tabs > semis { return "\t" }
        if semis > commas { return ";" }
        return ","
    }

    static func parse(_ input: String, delimiter: Character) -> [[String]] {
        var text = input
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var sawAny = false
        let chars = Array(text.unicodeScalars)
        let delim = delimiter.unicodeScalars.first!
        var i = 0
        func endField() { row.append(field); field = "" }
        func endRow() { endField(); rows.append(row); row = [] }
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.unicodeScalars.append(c); i += 1 }
                    else { inQuotes = false }
                } else { field.unicodeScalars.append(c) }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true; sawAny = true
            } else if c == delim {
                endField(); sawAny = true
            } else if c == "\n" || c == "\r" {
                if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                endRow(); sawAny = false
            } else {
                field.unicodeScalars.append(c); sawAny = true
            }
            i += 1
        }
        if sawAny || !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    static func render(_ rows: [[String]], delimiter: Character) -> String {
        let d = String(delimiter)
        var out = ""
        for row in rows {
            let cells = row.map { value -> String in
                if delimiter == "\t" {
                    return value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r\n", with: " ")
                        .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                }
                let hasSpecial = value.contains(delimiter) || value.contains("\"")
                let hasBreak = value.contains("\n") || value.contains("\r")
                let hasEdgeSpace = value.hasPrefix(" ") || value.hasSuffix(" ")
                let needsQuotes = hasSpecial || hasBreak || hasEdgeSpace
                if needsQuotes { return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                return value
            }
            out += cells.joined(separator: d) + "\n"
        }
        return out
    }
}

// MARK: - JSON (key order is kept, which JSONSerialization does not do)

indirect enum JV {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JV])
    case object([(String, JV)])
}

struct JSONParser {
    private let s: [UInt8]
    private var i = 0

    init(_ text: String) { s = Array(text.utf8) }

    static func parse(_ text: String) throws -> JV {
        var p = JSONParser(text)
        if p.s.count >= 3 && p.s[0] == 0xEF && p.s[1] == 0xBB && p.s[2] == 0xBF { p.i = 3 }
        p.skipSpace()
        let v = try p.value()
        p.skipSpace()
        if p.i != p.s.count { throw p.fail() }
        return v
    }

    private func fail() -> ConvertError { return ConvertError.message("This JSON file is not valid (problem near byte \(i)).") }

    private mutating func skipSpace() {
        while i < s.count, s[i] == 32 || s[i] == 9 || s[i] == 10 || s[i] == 13 { i += 1 }
    }

    private mutating func value() throws -> JV {
        skipSpace()
        guard i < s.count else { throw fail() }
        switch s[i] {
        case UInt8(ascii: "{"):
            i += 1
            var items: [(String, JV)] = []
            skipSpace()
            if i < s.count, s[i] == UInt8(ascii: "}") { i += 1; return .object(items) }
            while true {
                skipSpace()
                guard i < s.count, s[i] == UInt8(ascii: "\"") else { throw fail() }
                let k = try string()
                skipSpace()
                guard i < s.count, s[i] == UInt8(ascii: ":") else { throw fail() }
                i += 1
                items.append((k, try value()))
                skipSpace()
                guard i < s.count else { throw fail() }
                if s[i] == UInt8(ascii: ",") { i += 1; continue }
                if s[i] == UInt8(ascii: "}") { i += 1; return .object(items) }
                throw fail()
            }
        case UInt8(ascii: "["):
            i += 1
            var items: [JV] = []
            skipSpace()
            if i < s.count, s[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                items.append(try value())
                skipSpace()
                guard i < s.count else { throw fail() }
                if s[i] == UInt8(ascii: ",") { i += 1; continue }
                if s[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw fail()
            }
        case UInt8(ascii: "\""):
            return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default:
            let start = i
            while i < s.count, "+-0123456789.eE".utf8.contains(s[i]) { i += 1 }
            if start == i { throw fail() }
            return .number(String(decoding: s[start..<i], as: UTF8.self))
        }
    }

    private mutating func literal(_ word: String) throws {
        let w = Array(word.utf8)
        guard i + w.count <= s.count, Array(s[i..<(i + w.count)]) == w else { throw fail() }
        i += w.count
    }

    private mutating func string() throws -> String {
        i += 1    // opening quote
        var bytes: [UInt8] = []
        while i < s.count {
            let c = s[i]
            if c == UInt8(ascii: "\"") { i += 1; return String(decoding: bytes, as: UTF8.self) }
            if c == UInt8(ascii: "\\") {
                i += 1
                guard i < s.count else { throw fail() }
                let e = s[i]
                switch e {
                case UInt8(ascii: "n"): bytes.append(10)
                case UInt8(ascii: "t"): bytes.append(9)
                case UInt8(ascii: "r"): bytes.append(13)
                case UInt8(ascii: "b"): bytes.append(8)
                case UInt8(ascii: "f"): bytes.append(12)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if code >= 0xD800 && code < 0xDC00, i + 6 < s.count, s[i + 1] == UInt8(ascii: "\\"), s[i + 2] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        if low >= 0xDC00 && low <= 0xDFFF {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                    }
                    if let sc = Unicode.Scalar(code) { bytes.append(contentsOf: Array(String(Character(sc)).utf8)) }
                default: bytes.append(e)    // \" \\ \/
                }
                i += 1
            } else {
                bytes.append(c)
                i += 1
            }
        }
        throw fail()
    }

    /// Reads the four hex digits after "\u". Leaves `i` on the last digit.
    private mutating func hex4() throws -> UInt32 {
        guard i + 4 < s.count else { throw fail() }
        var v: UInt32 = 0
        for k in 1...4 {
            let c = s[i + k]
            var d: UInt32
            switch c {
            case 48...57: d = UInt32(c) - 48
            case 65...70: d = UInt32(c) - 55
            case 97...102: d = UInt32(c) - 87
            default: throw fail()
            }
            v = v * 16 + d
        }
        i += 4
        return v
    }
}

enum JSONTable {
    static func read(_ text: String) throws -> [[String]] {
        let root = try JSONParser.parse(text)
        switch root {
        case .array(let items):
            if items.isEmpty { throw ConvertError.message("The JSON array is empty.") }
            if items.allSatisfy({ if case .array = $0 { return true } else { return false } }) {
                return Tables.normalized(items.map { v in
                    if case .array(let cells) = v { return cells.map(flat) }
                    return []
                })
            }
            var columns: [String] = []
            var records: [[String: String]] = []
            for v in items {
                var rec: [String: String] = [:]
                if case .object(let pairs) = v {
                    for (k, val) in pairs {
                        if !columns.contains(k) { columns.append(k) }
                        rec[k] = flat(val)
                    }
                } else {
                    if !columns.contains("value") { columns.append("value") }
                    rec["value"] = flat(v)
                }
                records.append(rec)
            }
            return [columns] + records.map { r in columns.map { r[$0] ?? "" } }
        case .object(let pairs):
            // One record. If it has exactly one key holding an array of objects, use that instead.
            if pairs.count == 1, case .array = pairs[0].1 { return try read(render(pairs[0].1)) }
            return [pairs.map { $0.0 }, pairs.map { flat($0.1) }]
        default:
            return [["value"], [flat(root)]]
        }
    }

    private static func render(_ v: JV) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return quote(s)
        case .array(let a): return "[" + a.map(render).joined(separator: ",") + "]"
        case .object(let o): return "{" + o.map { quote($0.0) + ":" + render($0.1) }.joined(separator: ",") + "}"
        }
    }

    /// A cell: strings as they are, nested values as compact JSON.
    private static func flat(_ v: JV) -> String {
        switch v {
        case .null: return ""
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        default: return render(v)
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) }
                else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    static func render(_ rows: [[String]]) -> String {
        guard let head = rows.first else { return "[]\n" }
        var names: [String] = []
        for (i, h) in head.enumerated() {
            var n = h.isEmpty ? "column\(i + 1)" : h
            while names.contains(n) { n += "_" }
            names.append(n)
        }
        var out = "[\n"
        for (r, row) in rows.dropFirst().enumerated() {
            let fields = names.enumerated().map { (i, n) -> String in
                let v = i < row.count ? row[i] : ""
                let value = Xlsx.isNumber(v) ? v : quote(v)
                return "    " + quote(n) + ": " + value
            }
            out += "  {\n" + fields.joined(separator: ",\n") + "\n  }" + (r < rows.count - 2 ? ",\n" : "\n")
        }
        return out + "]\n"
    }
}

// MARK: - XML records

enum XMLTable {
    /// Root > repeated record elements > one child per column (attributes become "@name" columns).
    static func read(_ data: Data) throws -> [[String]] {
        let root = try XTreeBuilder.parse(data)
        var records = root.children
        if records.isEmpty { throw ConvertError.message("This XML file has no records inside its root element.") }
        // <root><wrapper><record/>...</wrapper></root>: step in when there is a single wrapper.
        if records.count == 1, records[0].children.count > 1,
           Set(records[0].children.map { $0.name }).count == 1 {
            records = records[0].children
        }
        var columns: [String] = []
        var rows: [[String: String]] = []
        for rec in records {
            var row: [String: String] = [:]
            func put(_ k: String, _ v: String) {
                if !columns.contains(k) { columns.append(k) }
                row[k] = v
            }
            for (k, v) in rec.attrs.sorted(by: { $0.key < $1.key }) { put("@" + k, v) }
            if rec.children.isEmpty {
                put(rec.name, rec.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            for c in rec.children {
                let t = c.children.isEmpty ? c.text : flatten(c)
                put(c.name, t.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            rows.append(row)
        }
        return [columns] + rows.map { r in columns.map { r[$0] ?? "" } }
    }

    private static func flatten(_ n: XNode) -> String {
        if n.children.isEmpty { return n.text }
        return n.children.map { flatten($0) }.joined(separator: ", ")
    }

    static func tagName(_ s: String, fallback: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) || u == "_" || u == "-" || u == "." { out.unicodeScalars.append(u) }
            else { out += "_" }
        }
        if out.isEmpty { return fallback }
        if let f = out.unicodeScalars.first, !(CharacterSet.letters.contains(f) || f == "_") { out = "_" + out }
        if out.lowercased().hasPrefix("xml") { out = "_" + out }
        return out
    }

    static func render(_ rows: [[String]]) -> String {
        guard let head = rows.first else { return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rows/>\n" }
        var names: [String] = []
        for (i, h) in head.enumerated() {
            var n = tagName(h, fallback: "column\(i + 1)")
            while names.contains(n) { n += "_" }
            names.append(n)
        }
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rows>\n"
        for row in rows.dropFirst() {
            out += "  <row>\n"
            for (i, n) in names.enumerated() {
                let v = i < row.count ? row[i] : ""
                out += "    <\(n)>\(xmlEscape(v))</\(n)>\n"
            }
            out += "  </row>\n"
        }
        return out + "</rows>\n"
    }
}
