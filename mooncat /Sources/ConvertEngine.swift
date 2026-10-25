import AppKit
import Foundation
import PDFKit
import QuickLookThumbnailing

struct ConvertOptions {
    /// 0.1 ... 1.0, used for JPEG, HEIC and JPEG 2000 output.
    var quality: Double = 0.9
}

/// The single entry point for every conversion. See `Fmt.targets(from:)` for what is supported.
enum Converter {
    /// How many conversions the matrix defines. Changing the matrix means changing this on purpose.
    static let expectedPairCount = 244

    static func selfCheck() {
        let n = Fmt.allPairs.count
        if n == expectedPairCount {
            Log.info("Converters: \(n) conversions available.")
        } else {
            Log.error("Converters: matrix has \(n) pairs, expected \(expectedPairCount).")
        }
    }

    // MARK: What this Mac can do

    /// False when the system has no encoder for this output (HEIC or JPEG 2000 on an unusual setup).
    static func canWrite(_ f: Fmt) -> Bool {
        if Fmt.imageWritable.contains(f) { return ImageConv.canWrite(f) }
        return true
    }

    /// False when the system has no decoder for this input (WebP before macOS 14, for example).
    static func canRead(_ f: Fmt) -> Bool {
        if f.family == .image { return ImageConv.canRead(f) }
        return true
    }

    // MARK: Converting

    /// Converts one file. Returns the files created (several when a PDF or document becomes
    /// one picture per page). Nothing is ever overwritten: a taken name gets " 2", " 3"...
    static func convert(_ src: URL, to dst: Fmt, into dir: URL, options: ConvertOptions = ConvertOptions()) async throws -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue else {
            throw ConvertError.message("\(src.lastPathComponent) is not a file.")
        }
        guard let s = Fmt.from(url: src) else {
            throw ConvertError.message("I don't know how to read “.\(src.pathExtension)” files.")
        }
        guard Fmt.targets(from: s).contains(dst) else {
            throw ConvertError.message("\(s.label) can't be turned into \(dst.label).")
        }
        guard canRead(s) else { throw ConvertError.message("This Mac can't read \(s.label) files.") }
        guard canWrite(dst) else { throw ConvertError.message("This Mac can't create \(dst.label) files.") }

        let work = fm.temporaryDirectory.appendingPathComponent("mooncat-convert-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let base = src.deletingPathExtension().lastPathComponent
        let produced = try await run(src, from: s, to: dst, base: base, work: work, options: options)
        guard !produced.isEmpty else { throw ConvertError.message("Nothing was produced.") }

        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var finals: [URL] = []
        for p in produced {
            let target = uniqueURL(dir, p.lastPathComponent)
            try fm.moveItem(at: p, to: target)
            finals.append(target)
        }
        return finals
    }

    static func uniqueURL(_ dir: URL, _ name: String) -> URL {
        let fm = FileManager.default
        let first = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: first.path) { return first }
        let ext = first.pathExtension
        let stem = first.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    // MARK: Dispatch

    private static func run(_ src: URL, from s: Fmt, to dst: Fmt, base: String, work: URL,
                            options: ConvertOptions) async throws -> [URL] {
        let out = work.appendingPathComponent("\(base).\(dst.ext)")
        switch s.family {

        case .image:
            let img = try ImageConv.load(src)
            switch dst {
            case .pdf:
                try ImageConv.makePDF(from: img, to: out)
            case .pptx:
                let photo: Set<Fmt> = [.jpg, .heic, .jp2, .tiff, .bmp]
                let (data, ext) = try ImageConv.embeddableData(img, preferJPEG: photo.contains(s))
                try Pptx.writeImage(data: data, ext: ext, pixelWidth: img.width, pixelHeight: img.height, to: out)
            case .txt:
                try ImageConv.ocr(img).write(to: out, atomically: true, encoding: .utf8)
            default:
                try ImageConv.write(img, as: dst, to: out, quality: options.quality)
            }
            return [out]

        case .document:
            if Fmt.imageWritable.contains(dst) {
                return try await documentToImages(src, from: s, to: dst, base: base, work: work, options: options)
            }
            if s == .pdf && dst == .pptx {
                try Pptx.writeText(try Docs.pdfSections(src), to: out)
                return [out]
            }
            try onMain {
                let attr = try Docs.read(src, as: s)
                try Docs.write(attr, as: dst, to: out, name: base)
            }
            return [out]

        case .data:
            let rows = try Tables.read(src, as: s)
            try Tables.write(rows, as: dst, to: out, name: base)
            return [out]

        case .audio:
            try MediaConv.transcode(src, to: dst, out: out)
            return [out]

        case .video:
            switch dst.family {
            case .video:
                try await MediaConv.exportVideo(src, to: dst, out: out)
            case .audio:
                try await MediaConv.extractAudio(src, to: dst, out: out, work: work)
            default:
                if dst == .gif {
                    try await MediaConv.makeGIF(src, out: out)
                } else {
                    let frame = try await MediaConv.frame(src)
                    try ImageConv.write(frame, as: dst, to: out, quality: options.quality)
                }
            }
            return [out]
        }
    }

    // MARK: Documents and PDFs as pictures

    private static func documentToImages(_ src: URL, from s: Fmt, to dst: Fmt, base: String, work: URL,
                                         options: ConvertOptions) async throws -> [URL] {
        // A PowerPoint file looks best as the picture macOS itself draws for its first slide.
        if s == .pptx, let thumb = await thumbnail(of: src) {
            let out = work.appendingPathComponent("\(base).\(dst.ext)")
            try ImageConv.write(thumb, as: dst, to: out, quality: options.quality)
            return [out]
        }
        var pdfURL = src
        if s != .pdf {
            // Lay the text out as a PDF first, then draw its pages.
            pdfURL = work.appendingPathComponent("\(base)-layout.pdf")
            try onMain {
                let attr = try Docs.read(src, as: s)
                try Docs.write(attr, as: .pdf, to: pdfURL, name: base)
            }
        }
        guard let doc = PDFDocument(url: pdfURL) else {
            throw ConvertError.message("Could not open \(src.lastPathComponent).")
        }
        if doc.isLocked { throw ConvertError.message("This PDF is password protected.") }
        if doc.pageCount == 0 { throw ConvertError.message("Could not turn \(src.lastPathComponent) into pages.") }
        var urls: [URL] = []
        for i in 0..<doc.pageCount {
            let name = doc.pageCount == 1 ? "\(base).\(dst.ext)" : "\(base)-\(i + 1).\(dst.ext)"
            let out = work.appendingPathComponent(name)
            let img = try ImageConv.render(doc: doc, page: i)
            try ImageConv.write(img, as: dst, to: out, quality: options.quality)
            urls.append(out)
        }
        return urls
    }

    private static func thumbnail(of url: URL) async -> CGImage? {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 1600, height: 1200),
                                               scale: 1, representationTypes: .thumbnail)
        return await withCheckedContinuation { (c: CheckedContinuation<CGImage?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                c.resume(returning: rep?.cgImage)
            }
        }
    }
}
