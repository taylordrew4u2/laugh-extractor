import Foundation
import AVFoundation

enum ExportError: LocalizedError {
    case emptySegment
    case encoderUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptySegment:
            return "One of the segments had no audio in it."
        case .encoderUnavailable:
            return "Couldn't create the AAC encoder."
        case .exportFailed(let detail):
            return "Export failed: \(detail)"
        }
    }
}

enum Exporter {

    /// Long enough to kill the click at a cut point, short enough to be inaudible.
    static let fadeSeconds: Double = 0.02

    /// Slices the master buffer at each segment's timestamps and writes one file
    /// per burst. Encoding, if any, happens here and nowhere else.
    static func export(segments: [LaughSegment],
                       masterURL: URL,
                       outputDirectory: URL,
                       format: ExportFormat,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        guard !segments.isEmpty else { return [] }

        let padding = String(segments.count).count
        var written: [URL] = []

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaughExtractor-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        for (offset, segment) in segments.enumerated() {
            try Task.checkCancellation()

            let name = "laugh_" + String(format: "%0\(padding)d", offset + 1)
            let destination = outputDirectory.appendingPathComponent("\(name).\(format.fileExtension)")

            // Slice straight out of the lossless master.
            let sourceFile = try AVAudioFile(forReading: masterURL)
            let buffer = try slice(segment: segment, from: sourceFile)
            applyFades(to: buffer, sampleRate: sourceFile.processingFormat.sampleRate)

            switch format {
            case .wav:
                try writeWAV(buffer, fileFormat: sourceFile.fileFormat, to: destination)
            case .m4a:
                // AVAssetExportSession needs a file on disk to read from, so the
                // slice lands as a temporary WAV before it's encoded to AAC.
                let intermediate = scratch.appendingPathComponent("\(name).wav")
                try writeWAV(buffer, fileFormat: sourceFile.fileFormat, to: intermediate)
                try await encodeM4A(from: intermediate, to: destination)
            }

            written.append(destination)
            progress(Double(offset + 1) / Double(segments.count))
        }

        return written
    }

    // MARK: - Slicing

    private static func slice(segment: LaughSegment, from file: AVAudioFile) throws -> AVAudioPCMBuffer {
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = max(0, AVAudioFramePosition(segment.startSeconds * sampleRate))
        let endFrame = min(file.length, AVAudioFramePosition(segment.endSeconds * sampleRate))
        guard endFrame > startFrame else { throw ExportError.emptySegment }

        let frameCount = AVAudioFrameCount(endFrame - startFrame)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw ExportError.emptySegment
        }
        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: frameCount)
        guard buffer.frameLength > 0 else { throw ExportError.emptySegment }
        return buffer
    }

    /// Linear fade in and out, so the cut points don't click.
    static func applyFades(to buffer: AVAudioPCMBuffer, sampleRate: Double) {
        guard let channels = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let frameStride = buffer.stride
        // Never fade more than half the clip in from each end.
        let fadeFrames = min(Int(fadeSeconds * sampleRate), frameLength / 2)
        guard fadeFrames > 0 else { return }

        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for i in 0..<fadeFrames {
                let gain = Float(i) / Float(fadeFrames)
                samples[i * frameStride] *= gain
                samples[(frameLength - 1 - i) * frameStride] *= gain
            }
        }
    }

    // MARK: - Writing

    /// Straight PCM passthrough — the sample values are untouched.
    private static func writeWAV(_ buffer: AVAudioPCMBuffer,
                                 fileFormat: AVAudioFormat,
                                 to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        // Scoped to this function on purpose: AVAudioFile finalises the header
        // when it deallocates, so it has to be gone before anyone reads the file.
        let file = try AVAudioFile(forWriting: url,
                                   settings: fileFormat.settings,
                                   commonFormat: buffer.format.commonFormat,
                                   interleaved: buffer.format.isInterleaved)
        try file.write(from: buffer)
    }

    private static func encodeM4A(from source: URL, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.encoderUnavailable
        }

        if #available(macOS 15.0, *) {
            try await session.export(to: destination, as: .m4a)
        } else {
            session.outputURL = destination
            session.outputFileType = .m4a
            await session.export()
            switch session.status {
            case .completed:
                break
            case .cancelled:
                throw CancellationError()
            default:
                throw ExportError.exportFailed(session.error?.localizedDescription ?? "unknown")
            }
        }
    }
}

/// Remembers the user's chosen output folder across launches.
///
/// The app is sandboxed, so the folder URL alone isn't enough — access has to be
/// re-acquired from a security-scoped bookmark on every launch.
enum OutputFolderStore {

    private static let key = "outputFolderBookmark"

    static func save(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Returns the folder with access already started. The caller owns the
    /// matching `stopAccessingSecurityScopedResource()`.
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource() else { return nil }
        if isStale { save(url) }
        return url
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
