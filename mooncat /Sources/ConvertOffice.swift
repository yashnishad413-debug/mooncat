import Foundation

// MARK: - Small helpers shared by the converters

enum Shell {
    /// Runs a system tool and returns what it printed. Used only for /usr/bin/zip and /usr/bin/unzip,
    /// which every Mac ships with.
    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = cwd
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ConvertError.message("\((exe as NSString).lastPathComponent) stopped with code \(p.terminationStatus).")
        }
        return data
    }
}

func xmlEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for u in s.unicodeScalars {
        switch u {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default:
            let v = u.value
            // XML 1.0 allows tab, newline, return and anything from space up (minus a few holes).
            if v == 9 || v == 10 || v == 13 || (v >= 0x20 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0xFFFD) || v >= 0x10000 {
                out.unicodeScalars.append(u)
            }
        }
    }
    return out
}

/// A zip package built in a temp folder and packed with /usr/bin/zip.
struct ZipPackage {
    private var files: [(String, Data)] = []

    mutating func add(_ path: String, _ text: String) { files.append((path, Data(text.utf8))) }
    mutating func add(_ path: String, data: Data) { files.append((path, data)) }

    func write(to url: URL) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mooncat-zip-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for (path, data) in files {
            let target = dir.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
        }
        try? fm.removeItem(at: url)
        try Shell.run("/usr/bin/zip", ["-X", "-D", "-q", "-r", url.path, "."], cwd: dir)
    }
}

enum ZipReader {
    static func entries(_ url: URL) throws -> [String] {
        let data = try Shell.run("/usr/bin/unzip", ["-Z1", url.path])
        return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
    }

    static func read(_ url: URL, _ entry: String) throws -> Data {
        // The brackets in names such as "[Content_Types].xml" are wildcards for unzip, so escape them.
        var safe = ""
        for ch in entry {
            if "[]*?\\".contains(ch) { safe.append("\\") }
            safe.append(ch)
        }
        return try Shell.run("/usr/bin/unzip", ["-p", url.path, safe])
    }
}

// MARK: - A tiny XML tree (used to read xlsx, pptx and plain XML data)

final class XNode {
    let name: String
    var attrs: [String: String]
    var children: [XNode] = []
    var text = ""
    init(name: String, attrs: [String: String]) { self.name = name; self.attrs = attrs }

    var localName: String {
        if let i = name.lastIndex(of: ":") { return String(name[name.index(after: i)...]) }
        return name
    }
    func firstChild(_ local: String) -> XNode? { return children.first { $0.localName == local } }
    func descendants(_ local: String) -> [XNode] {
        var out: [XNode] = []
        for c in children {
            if c.localName == local { out.append(c) }
            out += c.descendants(local)
        }
        return out
    }
}

final class XTreeBuilder: NSObject, XMLParserDelegate {
    private var stack: [XNode] = []
    private(set) var root: XNode?

    static func parse(_ data: Data) throws -> XNode {
        let b = XTreeBuilder()
        let p = XMLParser(data: data)
        p.delegate = b
        p.shouldProcessNamespaces = false
        guard p.parse(), let r = b.root else {
            throw ConvertError.message("The XML in this file could not be read.")
        }
        return r
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let n = XNode(name: elementName, attrs: attributeDict)
        if let top = stack.last { top.children.append(n) } else { root = n }
        stack.append(n)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        _ = stack.popLast()
    }
}

// MARK: - PPTX

/// One slide of text: a title and the lines under it.
struct TextSlide {
    var title: String
    var lines: [String]
}

enum Pptx {
    private static let nsA = "http://schemas.openxmlformats.org/drawingml/2006/main"
    private static let nsR = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let nsP = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let slideW = 12192000
    static let slideH = 6858000

    // MARK: Writing

    /// Text slides. Long sections are split so nothing runs off the bottom of a slide.
    static func writeText(_ sections: [TextSlide], to url: URL) throws {
        var slides: [String] = []
        for sec in sections {
            let pages = paginate(sec.lines)
            for (i, page) in pages.enumerated() {
                let title = i == 0 ? sec.title : sec.title + " (cont.)"
                slides.append(textSlideXML(title: title, lines: page))
            }
        }
        if slides.isEmpty { slides.append(textSlideXML(title: "", lines: [])) }
        try package(slideXML: slides, images: [:], to: url)
    }

    /// A picture on a 16:9 slide, scaled to fit.
    static func writeImage(data: Data, ext: String, pixelWidth: Int, pixelHeight: Int, to url: URL) throws {
        let w = Double(max(pixelWidth, 1)), h = Double(max(pixelHeight, 1))
        let scale = min(Double(slideW) / w, Double(slideH) / h)
        let cx = Int(w * scale), cy = Int(h * scale)
        let x = (slideW - cx) / 2, y = (slideH - cy) / 2
        let xml = slideShell(#"""
        <p:pic><p:nvPicPr><p:cNvPr id="2" name="Picture 1"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="\#(x)" y="\#(y)"/><a:ext cx="\#(cx)" cy="\#(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>
        """#)
        try package(slideXML: [xml], images: [1: (data, ext)], to: url)
    }

    /// Roughly 11 lines of body text fit on a slide; long lines count as more than one.
    static func paginate(_ lines: [String]) -> [[String]] {
        var pages: [[String]] = []
        var cur: [String] = []
        var used = 0
        for line in lines {
            let cost = max(1, (line.count + 84) / 85)
            if used + cost > 11 && !cur.isEmpty {
                pages.append(cur); cur = []; used = 0
            }
            cur.append(line)
            used += cost
        }
        if !cur.isEmpty || pages.isEmpty { pages.append(cur) }
        return pages
    }

    private static func slideShell(_ shapes: String) -> String {
        return #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="\#(nsA)" xmlns:r="\#(nsR)" xmlns:p="\#(nsP)"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\#(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """#
    }

    private static func textSlideXML(title: String, lines: [String]) -> String {
        var body = ""
        for l in lines {
            body += "<a:p><a:r><a:rPr lang=\"en-US\"/><a:t>\(xmlEscape(l))</a:t></a:r></a:p>"
        }
        if body.isEmpty { body = "<a:p><a:endParaRPr lang=\"en-US\"/></a:p>" }
        let titleRun = title.isEmpty ? "<a:p><a:endParaRPr lang=\"en-US\"/></a:p>"
            : "<a:p><a:r><a:rPr lang=\"en-US\"/><a:t>\(xmlEscape(title))</a:t></a:r></a:p>"
        let shapes = #"""
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>\#(titleRun)</p:txBody></p:sp><p:sp><p:nvSpPr><p:cNvPr id="3" name="Content 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph idx="1"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr><a:normAutofit/></a:bodyPr><a:lstStyle/>\#(body)</p:txBody></p:sp>
        """#
        return slideShell(shapes)
    }

    private static func package(slideXML: [String], images: [Int: (Data, String)], to url: URL) throws {
        var zip = ZipPackage()
        var overrides = ""
        var presRels = #"<Relationship Id="rId1" Type="\#(nsR)/slideMaster" Target="slideMasters/slideMaster1.xml"/>"#
        var sldIds = ""
        var exts = Set<String>()
        for (i, xml) in slideXML.enumerated() {
            let n = i + 1
            zip.add("ppt/slides/slide\(n).xml", xml)
            overrides += #"<Override PartName="/ppt/slides/slide\#(n).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#
            presRels += #"<Relationship Id="rId\#(n + 1)" Type="\#(nsR)/slide" Target="slides/slide\#(n).xml"/>"#
            sldIds += #"<p:sldId id="\#(255 + n)" r:id="rId\#(n + 1)"/>"#
            var rels = #"<Relationship Id="rId1" Type="\#(nsR)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>"#
            if let img = images[n] {
                rels += #"<Relationship Id="rId2" Type="\#(nsR)/image" Target="../media/image\#(n).\#(img.1)"/>"#
                zip.add("ppt/media/image\(n).\(img.1)", data: img.0)
                exts.insert(img.1)
            }
            zip.add("ppt/slides/_rels/slide\(n).xml.rels", relsXML(rels))
        }
        presRels += #"<Relationship Id="rId\#(slideXML.count + 2)" Type="\#(nsR)/theme" Target="theme/theme1.xml"/>"#

        var defaults = #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>"#
        if exts.contains("png") { defaults += #"<Default Extension="png" ContentType="image/png"/>"# }
        if exts.contains("jpg") { defaults += #"<Default Extension="jpg" ContentType="image/jpeg"/>"# }

        zip.add("[Content_Types].xml", #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\#(defaults)<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\#(overrides)</Types>
        """#)
        zip.add("_rels/.rels", relsXML(#"<Relationship Id="rId1" Type="\#(nsR)/officeDocument" Target="ppt/presentation.xml"/>"#))
        zip.add("ppt/presentation.xml", #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="\#(nsA)" xmlns:r="\#(nsR)" xmlns:p="\#(nsP)"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\#(sldIds)</p:sldIdLst><p:sldSz cx="\#(slideW)" cy="\#(slideH)"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
        """#)
        zip.add("ppt/_rels/presentation.xml.rels", relsXML(presRels))
        zip.add("ppt/slideMasters/slideMaster1.xml", masterXML)
        zip.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", relsXML(
            #"<Relationship Id="rId1" Type="\#(nsR)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="\#(nsR)/theme" Target="../theme/theme1.xml"/>"#))
        zip.add("ppt/slideLayouts/slideLayout1.xml", layoutXML)
        zip.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", relsXML(
            #"<Relationship Id="rId1" Type="\#(nsR)/slideMaster" Target="../slideMasters/slideMaster1.xml"/>"#))
        zip.add("ppt/theme/theme1.xml", themeXML)
        try zip.write(to: url)
    }

    private static func relsXML(_ inner: String) -> String {
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(inner)</Relationships>"
    }

    private static let masterXML = #"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr><p:sp><p:nvSpPr><p:cNvPr id="2" name="Title Placeholder 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="609600" y="365125"/><a:ext cx="10972800" cy="1143000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr vert="horz" lIns="91440" tIns="45720" rIns="91440" bIns="45720" rtlCol="0" anchor="ctr"><a:normAutofit/></a:bodyPr><a:lstStyle/><a:p><a:r><a:rPr lang="en-US"/><a:t>Click to edit title</a:t></a:r></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:cNvPr id="3" name="Text Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="609600" y="1600200"/><a:ext cx="10972800" cy="4800600"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr vert="horz" lIns="91440" tIns="45720" rIns="91440" bIns="45720" rtlCol="0"><a:normAutofit/></a:bodyPr><a:lstStyle/><a:p><a:pPr lvl="0"/><a:r><a:rPr lang="en-US"/><a:t>Click to edit text</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle><a:lvl1pPr algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1"><a:spcBef><a:spcPct val="0"/></a:spcBef><a:buNone/><a:defRPr sz="3600" b="1" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mj-lt"/><a:ea typeface="+mj-ea"/><a:cs typeface="+mj-cs"/></a:defRPr></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr marL="0" indent="0" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1"><a:spcBef><a:spcPts val="600"/></a:spcBef><a:buNone/><a:defRPr sz="2000" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:defPPr><a:defRPr lang="en-US"/></a:defPPr><a:lvl1pPr marL="0" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1"><a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>
    """#

    private static let layoutXML = #"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="obj" preserve="1"><p:cSld name="Title and Content"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr><p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US"/><a:t>Click to edit title</a:t></a:r></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:cNvPr id="3" name="Content Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph idx="1"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:pPr lvl="0"/><a:r><a:rPr lang="en-US"/><a:t>Click to edit text</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
    """#

    private static let themeXML = #"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="MoonCat"><a:themeElements><a:clrScheme name="MoonCat"><a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F2A44"/></a:dk2><a:lt2><a:srgbClr val="EEF0F5"/></a:lt2><a:accent1><a:srgbClr val="4F6BED"/></a:accent1><a:accent2><a:srgbClr val="F2994A"/></a:accent2><a:accent3><a:srgbClr val="27AE60"/></a:accent3><a:accent4><a:srgbClr val="9B51E0"/></a:accent4><a:accent5><a:srgbClr val="EB5757"/></a:accent5><a:accent6><a:srgbClr val="2D9CDB"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="MoonCat"><a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="MoonCat"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln><a:ln w="12700" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln><a:ln w="19050" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
    """#

    // MARK: Reading

    /// The text on every slide, in presentation order. The first title on a slide becomes its title.
    static func readText(_ url: URL) throws -> [TextSlide] {
        let paths = try slidePaths(url)
        if paths.isEmpty { throw ConvertError.message("This PowerPoint file has no slides.") }
        var out: [TextSlide] = []
        for (i, p) in paths.enumerated() {
            guard let data = try? ZipReader.read(url, p), let root = try? XTreeBuilder.parse(data) else { continue }
            var title = ""
            var lines: [String] = []
            collect(root, inTitle: false, title: &title, lines: &lines)
            out.append(TextSlide(title: title.isEmpty ? "Slide \(i + 1)" : title, lines: lines))
        }
        return out
    }

    private static func collect(_ node: XNode, inTitle: Bool, title: inout String, lines: inout [String]) {
        var isTitle = inTitle
        if node.localName == "sp" {
            for ph in node.descendants("ph") {
                let t = ph.attrs["type"] ?? ""
                if t == "title" || t == "ctrTitle" { isTitle = true }
            }
        }
        if node.localName == "p" {
            var s = ""
            gatherRuns(node, &s)
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if isTitle && title.isEmpty { title = trimmed } else { lines.append(trimmed) }
            }
            return
        }
        for c in node.children { collect(c, inTitle: isTitle, title: &title, lines: &lines) }
    }

    private static func gatherRuns(_ node: XNode, _ s: inout String) {
        for c in node.children {
            switch c.localName {
            case "t": s += c.text
            case "br": s += "\n"
            case "tab": s += "\t"
            default: gatherRuns(c, &s)
            }
        }
    }

    private static func slidePaths(_ url: URL) throws -> [String] {
        let all = try ZipReader.entries(url)
        var ordered: [String] = []
        if let presData = try? ZipReader.read(url, "ppt/presentation.xml"),
           let relData = try? ZipReader.read(url, "ppt/_rels/presentation.xml.rels"),
           let pres = try? XTreeBuilder.parse(presData), let rels = try? XTreeBuilder.parse(relData) {
            var target: [String: String] = [:]
            for r in rels.descendants("Relationship") {
                if let id = r.attrs["Id"], let t = r.attrs["Target"] { target[id] = t }
            }
            for s in pres.descendants("sldId") {
                guard let rid = s.attrs["r:id"], let t = target[rid] else { continue }
                let path = t.hasPrefix("/") ? String(t.dropFirst()) : "ppt/" + t
                if all.contains(path) { ordered.append(path) }
            }
        }
        if !ordered.isEmpty { return ordered }
        // Fallback: slide1.xml, slide2.xml ... in numeric order.
        let slides = all.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
        func num(_ s: String) -> Int {
            return Int(s.filter { $0.isNumber }) ?? 0
        }
        return slides.sorted { num($0) < num($1) }
    }
}

// MARK: - XLSX

enum Xlsx {
    private static let numberPattern = try! NSRegularExpression(pattern: "^-?(0|[1-9][0-9]{0,14})(\\.[0-9]+)?$")

    static func isNumber(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        return numberPattern.firstMatch(in: s, options: [], range: r) != nil
    }

    static func columnName(_ index: Int) -> String {
        var n = index
        var s = ""
        repeat {
            s = String(UnicodeScalar(UInt8(65 + n % 26))) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }

    static func write(_ rows: [[String]], to url: URL) throws {
        let rowLimit = 1_048_576
        let colLimit = 16_384
        let kept = rows.prefix(rowLimit)
        let colCount = min(kept.map { $0.count }.max() ?? 1, colLimit)
        var widths = [Int](repeating: 8, count: max(colCount, 1))
        var sheet = ""
        for (r, row) in kept.enumerated() {
            sheet += "<row r=\"\(r + 1)\">"
            for (c, value) in row.prefix(colCount).enumerated() {
                let ref = columnName(c) + String(r + 1)
                widths[c] = min(60, max(widths[c], value.count + 2))
                if value.isEmpty { continue }
                if r > 0 && isNumber(value) {
                    sheet += "<c r=\"\(ref)\"><v>\(value)</v></c>"
                } else {
                    let style = r == 0 ? " s=\"1\"" : ""
                    sheet += "<c r=\"\(ref)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
                }
            }
            sheet += "</row>"
        }
        var cols = "<cols>"
        for (i, w) in widths.enumerated() {
            cols += "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(w)\" customWidth=\"1\"/>"
        }
        cols += "</cols>"

        var zip = ZipPackage()
        zip.add("[Content_Types].xml", #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
        """#)
        zip.add("_rels/.rels", #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """#)
        zip.add("xl/workbook.xml", #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
        """#)
        zip.add("xl/_rels/workbook.xml.rels", #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """#)
        zip.add("xl/styles.xml", #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """#)
        zip.add("xl/worksheets/sheet1.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\(cols)<sheetData>\(sheet)</sheetData></worksheet>")
        try zip.write(to: url)
    }

    /// Reads the first sheet. Dates come through as Excel's serial numbers.
    static func read(_ url: URL) throws -> [[String]] {
        let all = try ZipReader.entries(url)
        var shared: [String] = []
        if all.contains("xl/sharedStrings.xml"),
           let d = try? ZipReader.read(url, "xl/sharedStrings.xml"),
           let root = try? XTreeBuilder.parse(d) {
            for si in root.children where si.localName == "si" {
                shared.append(si.descendants("t").map { $0.text }.joined())
            }
        }
        var sheetPath = "xl/worksheets/sheet1.xml"
        if !all.contains(sheetPath) {
            let sheets = all.filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }.sorted()
            guard let first = sheets.first else { throw ConvertError.message("This workbook has no sheets.") }
            sheetPath = first
        }
        let root = try XTreeBuilder.parse(try ZipReader.read(url, sheetPath))
        var rows: [[String]] = []
        for rowNode in root.descendants("row") {
            var row: [String] = []
            var next = 0
            for c in rowNode.children where c.localName == "c" {
                if let ref = c.attrs["r"] {
                    let idx = columnIndex(ref)
                    if idx >= next { while row.count < idx { row.append("") } }
                }
                let type = c.attrs["t"] ?? "n"
                var value = ""
                switch type {
                case "s":
                    if let v = c.firstChild("v"), let i = Int(v.text.trimmingCharacters(in: .whitespaces)),
                       i >= 0, i < shared.count { value = shared[i] }
                case "inlineStr":
                    value = c.descendants("t").map { $0.text }.joined()
                case "b":
                    value = (c.firstChild("v")?.text ?? "0") == "1" ? "TRUE" : "FALSE"
                default:
                    value = c.firstChild("v")?.text ?? ""
                }
                row.append(value)
                next = row.count
            }
            rows.append(row)
        }
        while let last = rows.last, last.allSatisfy({ $0.isEmpty }) { rows.removeLast() }
        if rows.isEmpty { throw ConvertError.message("The first sheet is empty.") }
        return rows
    }

    private static func columnIndex(_ ref: String) -> Int {
        var n = 0
        for u in ref.unicodeScalars {
            guard u.value >= 65 && u.value <= 90 else { break }
            n = n * 26 + Int(u.value - 64)
        }
        return max(n - 1, 0)
    }
}
