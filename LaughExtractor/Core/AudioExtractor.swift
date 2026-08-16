import Foundation
import AVFoundation
import Accelerate
import UniformTypeIdentifiers

/// The result of decoding a video (or audio file) into the two buffers the rest
/// of the pipeline needs.
///
/// Both are on disk rather than in memory: an hour of 48 kHz stereo float is
/// ~700 MB, which is not something to hold just because the user dropped in a
/// long special.
struct ExtractedAudio: Sendable {
    let sourceURL: URL
    /// Native sample rate, native channel count, 32-bit float. Never resampled,
    /// never encoded. This is what gets sliced for output.
    let masterURL: URL
    /// 16 kHz mono, for SoundAnalysis only.
    let analysisURL: URL
    let sampleRate: Double
    let channelCount: Int
    let duration: Double
    /// One peak magnitude per `waveformHopSeconds`, for the visualiser.
    let waveformPeaks: [Float]
    let waveformHopSeconds: Double
    /// Delete this when the document is closed.
    let workingDirectory: URL
}

enum AudioExtractionError: LocalizedError {
    case noAudioTrack
    case unsupportedFormat
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "That file doesn't contain an audio track."
        case .unsupportedFormat:
            return "That file's audio format couldn't be decoded."
        case .readFailed(let detail):
            return "Couldn't read the audio: \(detail)"
        }
    }
}

enum AudioExtractor {

    /// SoundAnalysis wants mono, and 16 kHz keeps inference fast without
    /// costing accuracy on the laughter/speech classes.
    static let analysisSampleRate: Double = 16_000
    /// One waveform peak per 20 ms — fine enough to see individual laughs.
    static let waveformHopSeconds: Double = 0.02

    static let supportedContentTypes: [UTType] = [
        .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .mpeg4Audio, .movie, .audio,
    ]

    static func extract(from url: URL,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> ExtractedAudio {
        let asset = AVURLAsset(url: url)

        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioExtractionError.noAudioTrack
        }
        let duration = try await asset.load(.duration).seconds

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaughExtractor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let masterURL = workingDirectory.appendingPathComponent("master.wav")
        let analysisURL = workingDirectory.appendingPathComponent("analysis.wav")

        let reader = try AVAssetReader(asset: asset)
        // Decode straight to 32-bit float LPCM. Leaving sample rate and channel
        // count unset keeps the track's native values.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioExtractionError.unsupportedFormat }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioExtractionError.readFailed(reader.error?.localizedDescription ?? "unknown")
        }

        var sourceFormat: AVAudioFormat?
        var masterFile: AVAudioFile?
        var analysisFile: AVAudioFile?
        var masterConverter: AVAudioConverter?
        var analysisConverter: AVAudioConverter?

        var peaks: [Float] = []
        var peakAccumulator: Float = 0
        var peakFrameCount = 0
        let peakBucketFrames = Int(analysisSampleRate * waveformHopSeconds)

        var framesRead: Int64 = 0
        var lastReportedProgress = -1.0

        defer { reader.cancelReading() }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()

            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
                continue
            }

            if sourceFormat == nil {
                let asbd = asbdPointer.pointee
                // The decoder hands us interleaved frames; AVAudioFile wants the
                // standard deinterleaved layout, so a converter sits between them.
                guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: asbd.mSampleRate,
                                                 channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
                                                 interleaved: true),
                      let masterFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                       sampleRate: asbd.mSampleRate,
                                                       channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
                                                       interleaved: false),
                      let analysisFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                         sampleRate: analysisSampleRate,
                                                         channels: 1,
                                                         interleaved: false) else {
                    throw AudioExtractionError.unsupportedFormat
                }
                sourceFormat = format

                masterFile = try AVAudioFile(forWriting: masterURL,
                                             settings: [
                                                AVFormatIDKey: kAudioFormatLinearPCM,
                                                AVSampleRateKey: format.sampleRate,
                                                AVNumberOfChannelsKey: format.channelCount,
                                                AVLinearPCMBitDepthKey: 32,
                                                AVLinearPCMIsFloatKey: true,
                                                AVLinearPCMIsBigEndianKey: false,
                                                AVLinearPCMIsNonInterleaved: false,
                                             ],
                                             commonFormat: .pcmFormatFloat32,
                                             interleaved: false)
                analysisFile = try AVAudioFile(forWriting: analysisURL,
                                               settings: [
                                                AVFormatIDKey: kAudioFormatLinearPCM,
                                                AVSampleRateKey: analysisSampleRate,
                                                AVNumberOfChannelsKey: 1,
                                                AVLinearPCMBitDepthKey: 32,
                                                AVLinearPCMIsFloatKey: true,
                                                AVLinearPCMIsBigEndianKey: false,
                                                AVLinearPCMIsNonInterleaved: false,
                                               ],
                                               commonFormat: .pcmFormatFloat32,
                                               interleaved: false)
                masterConverter = AVAudioConverter(from: format, to: masterFormat)
                analysisConverter = AVAudioConverter(from: format, to: analysisFormat)
                analysisConverter?.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
            }

            guard let format = sourceFormat,
                  let masterFile,
                  let analysisFile,
                  let masterConverter,
                  let analysisConverter else {
                throw AudioExtractionError.unsupportedFormat
            }

            guard let buffer = Self.makeBuffer(from: sampleBuffer, format: format) else { continue }

            // Deinterleave only — same rate, same channels, no quality loss.
            try Self.drain(converter: masterConverter,
                           input: buffer,
                           outputFormat: masterFile.processingFormat) { deinterleaved in
                try masterFile.write(from: deinterleaved)
            }

            // Resample to 16 kHz mono. One converter is kept alive across the
            // whole stream and fed with `.noDataNow` between chunks, so its
            // internal resampler state carries over and timing never drifts.
            try Self.drain(converter: analysisConverter,
                           input: buffer,
                           outputFormat: analysisFile.processingFormat) { monoBuffer in
                try analysisFile.write(from: monoBuffer)
                Self.accumulatePeaks(from: monoBuffer,
                                     bucketFrames: peakBucketFrames,
                                     accumulator: &peakAccumulator,
                                     frameCount: &peakFrameCount,
                                     peaks: &peaks)
            }

            framesRead += Int64(buffer.frameLength)
            if duration > 0 {
                let fraction = min(1.0, Double(framesRead) / (duration * format.sampleRate))
                if fraction - lastReportedProgress >= 0.01 {
                    lastReportedProgress = fraction
                    progress(fraction)
                }
            }
        }

        if reader.status == .failed {
            throw AudioExtractionError.readFailed(reader.error?.localizedDescription ?? "unknown")
        }

        guard let format = sourceFormat, analysisFile != nil else {
            throw AudioExtractionError.noAudioTrack
        }

        // Flush whatever the converters are still holding. The `file` bindings
        // are scoped to these blocks so nothing outlives the `= nil` below.
        if let masterConverter, let file = masterFile {
            try Self.drain(converter: masterConverter,
                           input: nil,
                           outputFormat: file.processingFormat) { deinterleaved in
                try file.write(from: deinterleaved)
            }
        }
        if let analysisConverter, let file = analysisFile {
            try Self.drain(converter: analysisConverter,
                           input: nil,
                           outputFormat: file.processingFormat) { monoBuffer in
                try file.write(from: monoBuffer)
                Self.accumulatePeaks(from: monoBuffer,
                                     bucketFrames: peakBucketFrames,
                                     accumulator: &peakAccumulator,
                                     frameCount: &peakFrameCount,
                                     peaks: &peaks)
            }
        }
        if peakFrameCount > 0 { peaks.append(peakAccumulator) }

        // AVAudioFile writes its header out when it deallocates, so both files
        // have to be released before anyone downstream opens them.
        masterFile = nil
        analysisFile = nil

        progress(1.0)

        return ExtractedAudio(sourceURL: url,
                              masterURL: masterURL,
                              analysisURL: analysisURL,
                              sampleRate: format.sampleRate,
                              channelCount: Int(format.channelCount),
                              duration: duration > 0 ? duration : Double(framesRead) / format.sampleRate,
                              waveformPeaks: peaks,
                              waveformHopSeconds: waveformHopSeconds,
                              workingDirectory: workingDirectory)
    }

    static func cleanUp(_ audio: ExtractedAudio) {
        try? FileManager.default.removeItem(at: audio.workingDirectory)
    }

    // MARK: - Plumbing

    /// Copies one `CMSampleBuffer` of interleaved float PCM into an `AVAudioPCMBuffer`.
    private static func makeBuffer(from sampleBuffer: CMSampleBuffer,
                                   format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, blockBuffer != nil,
              let source = audioBufferList.mBuffers.mData,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frameCount)),
              let destination = buffer.floatChannelData?[0] else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let byteCount = min(Int(audioBufferList.mBuffers.mDataByteSize),
                            frameCount * Int(format.channelCount) * MemoryLayout<Float>.size)
        memcpy(destination, source, byteCount)
        return buffer
    }

    /// Pulls every available output frame out of the converter for one input chunk.
    ///
    /// Passing `nil` as input signals end of stream and flushes the tail.
    private static func drain(converter: AVAudioConverter,
                              input: AVAudioPCMBuffer?,
                              outputFormat: AVAudioFormat,
                              handle: (AVAudioPCMBuffer) throws -> Void) throws {
        let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(max(4096, Double(input?.frameLength ?? 4096) * ratio + 1024))
        var consumed = false

        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if let input, !consumed {
                    consumed = true
                    inputStatus.pointee = .haveData
                    return input
                }
                // `.noDataNow` keeps the converter primed for the next chunk;
                // `.endOfStream` tells it to flush and stop.
                inputStatus.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }

            if let conversionError { throw conversionError }
            if output.frameLength > 0 { try handle(output) }

            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream, .error:
                return
            @unknown default:
                return
            }
        }
    }

    /// Rolling peak-per-bucket, computed on the mono stream so the waveform is
    /// cheap regardless of the source channel count.
    private static func accumulatePeaks(from buffer: AVAudioPCMBuffer,
                                        bucketFrames: Int,
                                        accumulator: inout Float,
                                        frameCount: inout Int,
                                        peaks: inout [Float]) {
        guard bucketFrames > 0, let samples = buffer.floatChannelData?[0] else { return }
        var offset = 0
        let total = Int(buffer.frameLength)

        while offset < total {
            let take = min(bucketFrames - frameCount, total - offset)
            var peak: Float = 0
            vDSP_maxmgv(samples + offset, 1, &peak, vDSP_Length(take))
            accumulator = max(accumulator, peak)
            frameCount += take
            offset += take

            if frameCount >= bucketFrames {
                peaks.append(accumulator)
                accumulator = 0
                frameCount = 0
            }
        }
    }
}
