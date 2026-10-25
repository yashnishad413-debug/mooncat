import AVFoundation
import AppKit
import Foundation
import ImageIO

/// Sound and movies, using the codecs built into macOS.
enum MediaConv {
    // MARK: Audio -> audio

    static func audioSettings(for f: Fmt, sampleRate: Double, channels: Int) -> [String: Any] {
        switch f {
        case .wav, .caf, .aiff:
            return [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: f == .aiff,
                    AVLinearPCMIsNonInterleaved: false]
        case .m4a:
            return [AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: min(channels, 2),
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        default: // flac
            return [AVFormatIDKey: kAudioFormatFLAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 16]
        }
    }

    /// Decodes `src` (any audio file, or the sound track of a movie) and writes `out` in the new format.
    /// The output must end in the right extension: AVAudioFile picks the container from it.
    static func transcode(_ src: URL, to f: Fmt, out: URL) throws {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: src) }
        catch { throw ConvertError.message("Could not read sound from \(src.lastPathComponent).") }
        let sr = input.fileFormat.sampleRate
        let ch = max(1, Int(input.fileFormat.channelCount))
        var settings = audioSettings(for: f, sampleRate: sr, channels: ch)
        if f == .m4a && ch > 2 { settings[AVNumberOfChannelsKey] = 2 }
        try write(input: input, settings: settings, to: out)
    }

    /// Kept in its own function so the output file is closed (and finalised) before it returns.
    private static func write(input: AVAudioFile, settings: [String: Any], to out: URL) throws {
        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: out, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw ConvertError.message("This Mac could not create that audio format (\(error.localizedDescription)).")
        }
        let format = input.processingFormat
        // When the file has more channels than the output (m4a is capped at 2) the formats differ.
        let converter: AVAudioConverter? = format == output.processingFormat ? nil
            : AVAudioConverter(from: format, to: output.processingFormat)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768) else {
            throw ConvertError.message("Not enough memory to convert this audio.")
        }
        while input.framePosition < input.length {
            try input.read(into: inBuf)
            if inBuf.frameLength == 0 { break }
            if let conv = converter {
                guard let outBuf = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: inBuf.frameLength) else { break }
                var supplied = false
                var err: NSError?
                conv.convert(to: outBuf, error: &err) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true
                    status.pointee = .haveData
                    return inBuf
                }
                if let err = err { throw err }
                try output.write(from: outBuf)
            } else {
                try output.write(from: inBuf)
            }
        }
    }

    // MARK: Video -> video

    static func exportVideo(_ src: URL, to f: Fmt, out: URL) async throws {
        let asset = AVURLAsset(url: src)
        let type: AVFileType = f == .mp4 ? .mp4 : (f == .mov ? .mov : .m4v)
        // Passthrough keeps the picture untouched when the new container can hold it;
        // otherwise fall back to a re-encode.
        var lastError: Error?
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            guard session.supportedFileTypes.contains(type) else { continue }
            try? FileManager.default.removeItem(at: out)
            session.outputURL = out
            session.outputFileType = type
            session.shouldOptimizeForNetworkUse = true
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { c.resume() }
            }
            if session.status == .completed { return }
            lastError = session.error
        }
        try? FileManager.default.removeItem(at: out)
        throw ConvertError.message("The movie could not be converted\(lastError.map { ": " + $0.localizedDescription } ?? ".")")
    }

    // MARK: Video -> audio

    static func extractAudio(_ src: URL, to f: Fmt, out: URL, work: URL) async throws {
        let asset = AVURLAsset(url: src)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        if tracks.isEmpty { throw ConvertError.message("This movie has no sound.") }
        do {
            try transcode(src, to: f, out: out)
        } catch {
            // Some movies cannot be opened as audio directly. Export the sound as AAC first.
            let temp = work.appendingPathComponent("sound-\(UUID().uuidString).m4a")
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw error }
            session.outputURL = temp
            session.outputFileType = .m4a
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { c.resume() }
            }
            guard session.status == .completed else { throw error }
            try? FileManager.default.removeItem(at: out)
            if f == .m4a { try FileManager.default.moveItem(at: temp, to: out) }
            else { try transcode(temp, to: f, out: out) }
        }
    }

    // MARK: Video -> pictures

    static func frame(_ src: URL) async throws -> CGImage {
        let asset = AVURLAsset(url: src)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        let at = seconds.isFinite && seconds > 0 ? min(1.0, seconds / 2) : 0
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        do {
            return try await gen.image(at: CMTime(seconds: at, preferredTimescale: 600)).image
        } catch {
            throw ConvertError.message("Could not grab a picture from \(src.lastPathComponent).")
        }
    }

    /// First ten seconds at ten pictures a second, at most 480 pixels wide. Keeps GIFs a sane size.
    static func makeGIF(_ src: URL, out: URL) async throws {
        let asset = AVURLAsset(url: src)
        let duration = try await asset.load(.duration)
        let total = CMTimeGetSeconds(duration)
        guard total.isFinite, total > 0 else { throw ConvertError.message("This movie has no length.") }
        let fps = 10.0
        let frames = max(1, Int(min(total, 10.0) * fps))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 20)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 20)

        var images: [CGImage] = []
        for i in 0..<frames {
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let img = try? await gen.image(at: t).image { images.append(img) }
        }
        guard !images.isEmpty,
              let dest = CGImageDestinationCreateWithURL(out as CFURL, "com.compuserve.gif" as CFString, images.count, nil) else {
            throw ConvertError.message("Could not build the GIF from this movie.")
        }
        let fileProps = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 1.0 / fps]]
        for img in images { CGImageDestinationAddImage(dest, img, frameProps as CFDictionary) }
        guard CGImageDestinationFinalize(dest) else {
            throw ConvertError.message("Could not build the GIF from this movie.")
        }
    }
}
