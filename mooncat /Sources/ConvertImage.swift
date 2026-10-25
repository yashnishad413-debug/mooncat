import AppKit
import Foundation
import ImageIO
import PDFKit
import Vision

/// Pictures: image <-> image, image -> PDF, PDF -> images, text from pictures (OCR).
enum ImageConv {
    static let typeIDs: [Fmt: String] = [
        .png: "public.png", .jpg: "public.jpeg", .gif: "com.compuserve.gif",
        .tiff: "public.tiff", .bmp: "com.microsoft.bmp", .heic: "public.heic",
        .jp2: "public.jpeg-2000", .webp: "org.webmproject.webp", .ico: "com.microsoft.ico"
    ]

    static func canWrite(_ f: Fmt) -> Bool {
        guard let id = typeIDs[f] else { return false }
        let list = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return list.contains(id)
    }

    static func canRead(_ f: Fmt) -> Bool {
        guard let id = typeIDs[f] else { return false }
        let list = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        return list.contains(id)
    }

    // MARK: Reading and writing

    /// Loads the largest frame of an image with its EXIF rotation applied.
    static func load(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConvertError.message("Could not open \(url.lastPathComponent) as a picture.")
        }
        let count = min(CGImageSourceGetCount(src), 64)
        var bestIndex = 0
        var bestArea = -1
        var bestMax = 0
        for i in 0..<max(count, 1) {
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            if w * h > bestArea { bestArea = w * h; bestIndex = i; bestMax = max(w, h) }
        }
        if bestMax > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: bestMax
            ]
            if let t = CGImageSourceCreateThumbnailAtIndex(src, bestIndex, opts as CFDictionary) { return t }
        }
        if let img = CGImageSourceCreateImageAtIndex(src, bestIndex, nil) { return img }
        throw ConvertError.message("Could not decode \(url.lastPathComponent).")
    }

    /// JPEG and BMP have no transparency, so put the picture on white first.
    static func flattened(_ img: CGImage) -> CGImage {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
        let rect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(img, in: rect)
        return ctx.makeImage() ?? img
    }

    static func write(_ img: CGImage, as f: Fmt, to url: URL, quality: Double) throws {
        guard let id = typeIDs[f], canWrite(f) else {
            throw ConvertError.message("This Mac cannot create \(f.label) files.")
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, id as CFString, 1, nil) else {
            throw ConvertError.message("Could not create the \(f.label) file.")
        }
        var props: [CFString: Any] = [:]
        if f == .jpg || f == .heic || f == .jp2 {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        let toWrite = (f == .jpg || f == .bmp) ? flattened(img) : img
        CGImageDestinationAddImage(dest, toWrite, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ConvertError.message("Writing the \(f.label) file failed.")
        }
    }

    /// Encoded bytes for placing a picture inside a PPTX. Photos become JPEG, the rest PNG.
    static func embeddableData(_ img: CGImage, preferJPEG: Bool) throws -> (Data, String) {
        let fmt: Fmt = preferJPEG ? .jpg : .png
        let data = NSMutableData()
        guard let id = typeIDs[fmt],
              let dest = CGImageDestinationCreateWithData(data as CFMutableData, id as CFString, 1, nil) else {
            throw ConvertError.message("Could not prepare the picture.")
        }
        var props: [CFString: Any] = [:]
        if preferJPEG { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(dest, preferJPEG ? flattened(img) : img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.message("Could not prepare the picture.") }
        return (data as Data, fmt.ext)
    }

    // MARK: Image -> PDF

    static func makePDF(from img: CGImage, to url: URL) throws {
        // 72 points per inch is how big the picture would be at 72 dpi. Keep the long side
        // to about an A4 page so a phone photo does not become a 4000-point page.
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let scale = min(1, 842 / max(w, h))
        var page = CGRect(x: 0, y: 0, width: w * scale, height: h * scale)
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw ConvertError.message("Could not create the PDF.")
        }
        var defaultBox = page
        guard let ctx = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else {
            throw ConvertError.message("Could not create the PDF.")
        }
        let boxData = withUnsafeBytes(of: &page) { Data($0) }
        let info = [kCGPDFContextMediaBox as String: boxData] as CFDictionary
        ctx.beginPDFPage(info)
        ctx.draw(img, in: page)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    // MARK: PDF -> images

    /// One image per page, rendered at about 150 dpi.
    static func render(pdf url: URL, page index: Int, dpi: CGFloat = 150) throws -> CGImage {
        guard let doc = PDFDocument(url: url) else {
            throw ConvertError.message("Could not open \(url.lastPathComponent) as a PDF.")
        }
        return try render(doc: doc, page: index, dpi: dpi)
    }

    static func render(doc: PDFDocument, page index: Int, dpi: CGFloat = 150) throws -> CGImage {
        guard let page = doc.page(at: index), let ref = page.pageRef else {
            throw ConvertError.message("The PDF has no page \(index + 1).")
        }
        let box = ref.getBoxRect(.mediaBox)
        let scale = dpi / 72
        let rotated = ref.rotationAngle % 180 != 0
        let pw = rotated ? box.height : box.width
        let ph = rotated ? box.width : box.height
        let width = max(1, Int(pw * scale)), height = max(1, Int(ph * scale))
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConvertError.message("Not enough memory to draw page \(index + 1).")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Maps the media box (with the page's own rotation) onto the whole bitmap.
        ctx.concatenate(ref.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: width, height: height),
                                                rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(ref)
        guard let img = ctx.makeImage() else { throw ConvertError.message("Could not draw page \(index + 1).") }
        return img
    }

    static func pageCount(pdf url: URL) -> Int {
        return PDFDocument(url: url)?.pageCount ?? 0
    }

    // MARK: Pictures -> text

    static func ocr(_ img: CGImage) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        try handler.perform([req])
        let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConvertError.message("No readable text was found in the picture.")
        }
        return text + "\n"
    }
}
