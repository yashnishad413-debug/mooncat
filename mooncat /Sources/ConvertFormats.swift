import Foundation

// MARK: - Formats and the conversion matrix
//
// The converters cover exactly the pairs listed by `Fmt.targets(from:)`. The count is
// 244 and `Converter.selfCheck()` logs it at launch so a change cannot slip by unnoticed.
//
//   image  -> other image, PDF, PPTX, TXT (text read from the picture with Vision)   83
//   PDF    -> text/office documents, images                                          14
//   doc    -> other documents, PNG, JPG (txt rtf html docx odt md pptx)              63
//   data   -> other data, HTML, Markdown, PDF (csv tsv json xlsx; xml -> data only)  32
//   audio  -> other audio                                                            25
//   video  -> other video, audio, GIF, PNG, JPG                                      27

enum ConvertError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

enum Fmt: String, CaseIterable {
    case png, jpg, gif, tiff, bmp, heic, jp2, webp, ico
    case pdf, txt, rtf, html, docx, odt, md, pptx
    case csv, tsv, json, xlsx, xml
    case mp3, m4a, wav, aiff, caf, flac
    case mp4, mov, m4v

    enum Family { case image, document, data, audio, video }

    var family: Family {
        switch self {
        case .png, .jpg, .gif, .tiff, .bmp, .heic, .jp2, .webp, .ico: return .image
        case .pdf, .txt, .rtf, .html, .docx, .odt, .md, .pptx: return .document
        case .csv, .tsv, .json, .xlsx, .xml: return .data
        case .mp3, .m4a, .wav, .aiff, .caf, .flac: return .audio
        case .mp4, .mov, .m4v: return .video
        }
    }

    /// File extension used for output files.
    var ext: String { return rawValue }

    var label: String {
        switch self {
        case .png: return "PNG image"
        case .jpg: return "JPEG image"
        case .gif: return "GIF image"
        case .tiff: return "TIFF image"
        case .bmp: return "BMP image"
        case .heic: return "HEIC image"
        case .jp2: return "JPEG 2000 image"
        case .webp: return "WebP image"
        case .ico: return "ICO icon"
        case .pdf: return "PDF document"
        case .txt: return "Plain text"
        case .rtf: return "Rich Text"
        case .html: return "Web page (HTML)"
        case .docx: return "Word document"
        case .odt: return "OpenDocument text"
        case .md: return "Markdown"
        case .pptx: return "PowerPoint"
        case .csv: return "CSV table"
        case .tsv: return "TSV table"
        case .json: return "JSON"
        case .xlsx: return "Excel workbook"
        case .xml: return "XML"
        case .mp3: return "MP3 audio"
        case .m4a: return "M4A audio (AAC)"
        case .wav: return "WAV audio"
        case .aiff: return "AIFF audio"
        case .caf: return "CAF audio"
        case .flac: return "FLAC audio"
        case .mp4: return "MP4 video"
        case .mov: return "QuickTime movie"
        case .m4v: return "M4V video"
        }
    }

    /// Works out the format from a file name. Returns nil for anything unsupported.
    static func from(url: URL) -> Fmt? {
        var e = url.pathExtension.lowercased()
        switch e {
        case "jpeg", "jpe", "jfif": e = "jpg"
        case "tif": e = "tiff"
        case "htm": e = "html"
        case "markdown", "mdown": e = "md"
        case "aif", "aifc": e = "aiff"
        case "j2k", "jpf": e = "jp2"
        case "heif": e = "heic"
        default: break
        }
        return Fmt(rawValue: e)
    }

    // MARK: The matrix

    static let imageWritable: [Fmt] = [.png, .jpg, .gif, .tiff, .bmp, .heic, .jp2]
    static let documents: [Fmt] = [.pdf, .txt, .rtf, .html, .docx, .odt, .md, .pptx]
    static let dataFormats: [Fmt] = [.csv, .tsv, .json, .xlsx, .xml]
    static let audioTargets: [Fmt] = [.m4a, .wav, .aiff, .caf, .flac]
    static let videoFormats: [Fmt] = [.mp4, .mov, .m4v]

    static func targets(from s: Fmt) -> [Fmt] {
        switch s.family {
        case .image:
            return imageWritable.filter { $0 != s } + [.pdf, .pptx, .txt]
        case .document:
            if s == .pdf {
                return documents.filter { $0 != .pdf } + imageWritable
            }
            return documents.filter { $0 != s } + [.png, .jpg]
        case .data:
            let others = dataFormats.filter { $0 != s }
            return s == .xml ? others : others + [.html, .md, .pdf]
        case .audio:
            return audioTargets.filter { $0 != s }
        case .video:
            return videoFormats.filter { $0 != s } + [.m4a, .wav, .aiff, .caf] + [.gif, .png, .jpg]
        }
    }

    /// Every supported (from, to) pair.
    static var allPairs: [(Fmt, Fmt)] {
        var out: [(Fmt, Fmt)] = []
        for s in Fmt.allCases { for t in targets(from: s) { out.append((s, t)) } }
        return out
    }
}
