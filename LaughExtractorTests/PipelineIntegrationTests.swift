import XCTest
import AVFoundation
@testable import LaughExtractor

/// Exercises the real framework path — AVFoundation decode, AVAudioConverter
/// resampling, SoundAnalysis inference, and export — against audio generated at
/// runtime.
///
/// These can't prove detection *accuracy* (that needs real laughter), but they
/// prove the plumbing works end to end, which unit tests on `Segmenter` cannot.
final class PipelineIntegrationTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaughExtractorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// Writes a 16-bit stereo WAV, the way a real source file would be.
    /// `amplitude` of 0 gives digital silence.
    private func makeWAV(seconds: Double,
                         sampleRate: Double = 44_100,
                         channels: AVAudioChannelCount = 2,
                         amplitude: Float = 0.25,
                         name: String = "source.wav") throws -> URL {
        let url = scratch.appendingPathComponent(name)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: channels) else {
            throw XCTSkip("Couldn't build a source format")
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])

        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount

        // Deterministic pseudo-noise — no Random, so failures reproduce.
        var state: UInt32 = 0x1234_5678
        for channel in 0..<Int(channels) {
            let samples = try XCTUnwrap(buffer.floatChannelData)[channel]
            for i in 0..<Int(frameCount) {
                state = state &* 1_664_525 &+ 1_013_904_223
                let unit = Float(state >> 8) / Float(1 << 24) * 2 - 1
                samples[i] = unit * amplitude
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// Re-encodes to AAC in an .m4a container — the realistic "dropped in an
    /// MP4" decode path, rather than the easy PCM one.
    private func makeCompressed(from wav: URL) async throws -> URL {
        let url = scratch.appendingPathComponent("source.m4a")
        let session = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: wav),
                                                         presetName: AVAssetExportPresetAppleM4A))
        if #available(macOS 15.0, *) {
            try await session.export(to: url, as: .m4a)
        } else {
            session.outputURL = url
            session.outputFileType = .m4a
            await session.export()
            XCTAssertEqual(session.status, .completed, "\(session.error?.localizedDescription ?? "")")
        }
        return url
    }

    private func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: - Extraction

    func testExtractProducesLosslessMasterAndSixteenKilohertzMonoAnalysis() async throws {
        let source = try makeWAV(seconds: 3)
        let audio = try await AudioExtractor.extract(from: source) { _ in }
        defer { AudioExtractor.cleanUp(audio) }

        XCTAssertEqual(audio.sampleRate, 44_100, "master must keep the native rate")
        XCTAssertEqual(audio.channelCount, 2, "master must keep the native channel count")
        XCTAssertEqual(audio.duration, 3, accuracy: 0.05)

        let master = try AVAudioFile(forReading: audio.masterURL)
        XCTAssertEqual(master.processingFormat.sampleRate, 44_100)
        XCTAssertEqual(master.processingFormat.channelCount, 2)
        XCTAssertEqual(try duration(of: audio.masterURL), 3, accuracy: 0.05)

        // SoundAnalysis needs mono at 16 kHz; drift here would misplace every clip.
        let analysis = try AVAudioFile(forReading: audio.analysisURL)
        XCTAssertEqual(analysis.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(analysis.processingFormat.channelCount, 1)
        XCTAssertEqual(try duration(of: audio.analysisURL), 3, accuracy: 0.05,
                       "resampled length must track the source, or timestamps drift")

        // One peak per 20 ms.
        XCTAssertEqual(Double(audio.waveformPeaks.count), 3 / 0.02, accuracy: 10)
        XCTAssertGreaterThan(try XCTUnwrap(audio.waveformPeaks.max()), 0,
                             "waveform should not be flat for audible input")
    }

    func testExtractDecodesCompressedAudio() async throws {
        let source = try await makeCompressed(from: try makeWAV(seconds: 2))
        let audio = try await AudioExtractor.extract(from: source) { _ in }
        defer { AudioExtractor.cleanUp(audio) }

        XCTAssertEqual(audio.duration, 2, accuracy: 0.15)
        XCTAssertEqual(try duration(of: audio.analysisURL), 2, accuracy: 0.15)
        XCTAssertGreaterThan(audio.waveformPeaks.count, 50)
    }

    func testExtractRejectsAFileWithNoAudioTrack() async throws {
        let bogus = scratch.appendingPathComponent("notaudio.mp4")
        try Data("this is not a movie".utf8).write(to: bogus)
        do {
            _ = try await AudioExtractor.extract(from: bogus) { _ in }
            XCTFail("Expected extraction to fail on a file with no audio track")
        } catch {
            // Any thrown error is fine; the point is it doesn't crash or hang.
        }
    }

    // MARK: - Classification

    func testAnalyzeProducesFramesOnTheExpectedWindowGrid() async throws {
        let audio = try await AudioExtractor.extract(from: try makeWAV(seconds: 4)) { _ in }
        defer { AudioExtractor.cleanUp(audio) }

        let result = try await LaughDetector.analyze(analysisFileURL: audio.analysisURL) { _ in }

        XCTAssertFalse(result.frames.isEmpty, "the classifier produced no windows at all")
        XCTAssertEqual(result.windowDuration, 0.975, accuracy: 0.2,
                       "window should be at or near the classifier minimum")
        // 0.9 overlap is what buys the ~97 ms resolution a 500 ms clip needs.
        XCTAssertEqual(result.hopDuration, result.windowDuration * 0.1, accuracy: 0.0001)
        XCTAssertLessThan(result.hopDuration, 0.2, "hop too coarse for a 500 ms minimum")

        // Frames must be ordered and cover most of the file.
        let starts = result.frames.map(\.startTime)
        XCTAssertEqual(starts, starts.sorted(), "frames must be in time order")
        XCTAssertGreaterThan(try XCTUnwrap(starts.last), 2.0, "frames stop well short of the end")

        for frame in result.frames {
            XCTAssert((0...1).contains(frame.laughScore), "laugh score out of range")
            XCTAssert((0...1).contains(frame.speechScore), "speech score out of range")
            XCTAssert((0...1).contains(frame.applauseScore), "applause score out of range")
        }
    }

    func testSilenceYieldsNoLaughSegments() async throws {
        let source = try makeWAV(seconds: 4, amplitude: 0, name: "silence.wav")
        let audio = try await AudioExtractor.extract(from: source) { _ in }
        defer { AudioExtractor.cleanUp(audio) }

        let result = try await LaughDetector.analyze(analysisFileURL: audio.analysisURL) { _ in }
        let segments = Segmenter.segments(from: result.frames,
                                          windowDuration: result.windowDuration,
                                          hopDuration: result.hopDuration,
                                          config: .default)
        XCTAssertTrue(segments.isEmpty, "digital silence must not register as laughter")
    }

    // MARK: - Export

    func testExportWritesPlayableClipsInBothFormats() async throws {
        let audio = try await AudioExtractor.extract(from: try makeWAV(seconds: 3)) { _ in }
        defer { AudioExtractor.cleanUp(audio) }

        // A synthetic burst, so the test doesn't depend on detecting anything.
        let segment = LaughSegment(index: 1, startSeconds: 0.5, endSeconds: 1.7,
                                   meanLaugh: 0.9, meanSpeech: 0.01,
                                   meanApplause: 0, peakLaugh: 0.95)

        for format in ExportFormat.allCases {
            let outputDirectory = scratch.appendingPathComponent(format.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

            let written = try await Exporter.export(segments: [segment],
                                                    masterURL: audio.masterURL,
                                                    outputDirectory: outputDirectory,
                                                    format: format) { _ in }

            XCTAssertEqual(written.count, 1)
            let file = try XCTUnwrap(written.first)
            XCTAssertEqual(file.lastPathComponent, "laugh_1.\(format.fileExtension)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

            // It has to be real, readable audio of roughly the right length.
            let clip = try AVAudioFile(forReading: file)
            XCTAssertEqual(try duration(of: file), 1.2, accuracy: 0.15,
                           "\(format.displayName) clip is the wrong length")

            if format == .wav {
                // WAV is the lossless path: rate and channels must match the master.
                XCTAssertEqual(clip.processingFormat.sampleRate, audio.sampleRate)
                XCTAssertEqual(Int(clip.processingFormat.channelCount), audio.channelCount)
            }
        }
    }

    func testExportZeroPadsFilenamesToTheDigitWidthOfTheCount() async throws {
        let audio = try await AudioExtractor.extract(from: try makeWAV(seconds: 3)) { _ in }
        defer { AudioExtractor.cleanUp(audio) }

        // Ten segments means two digits, so the first must be laugh_01, not laugh_1.
        let segments = (0..<10).map { i in
            LaughSegment(index: i + 1,
                         startSeconds: 0.1 + Double(i) * 0.25,
                         endSeconds: 0.1 + Double(i) * 0.25 + 0.2,
                         meanLaugh: 0.9, meanSpeech: 0.01, meanApplause: 0, peakLaugh: 0.9)
        }
        let outputDirectory = scratch.appendingPathComponent("padded", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let written = try await Exporter.export(segments: segments,
                                                masterURL: audio.masterURL,
                                                outputDirectory: outputDirectory,
                                                format: .wav) { _ in }

        XCTAssertEqual(written.count, 10)
        XCTAssertEqual(written.first?.lastPathComponent, "laugh_01.wav")
        XCTAssertEqual(written.last?.lastPathComponent, "laugh_10.wav")
    }

    func testExportAppliesFadesSoClipsDoNotClick() async throws {
        let audio = try await AudioExtractor.extract(from: try makeWAV(seconds: 3)) { _ in }
        defer { AudioExtractor.cleanUp(audio) }

        let outputDirectory = scratch.appendingPathComponent("fade", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let written = try await Exporter.export(
            segments: [LaughSegment(index: 1, startSeconds: 0.5, endSeconds: 1.7,
                                    meanLaugh: 0.9, meanSpeech: 0.01,
                                    meanApplause: 0, peakLaugh: 0.9)],
            masterURL: audio.masterURL,
            outputDirectory: outputDirectory,
            format: .wav) { _ in }

        let clip = try AVAudioFile(forReading: try XCTUnwrap(written.first))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: clip.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(clip.length)))
        try clip.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]

        // The very first sample is multiplied by a gain of zero.
        XCTAssertEqual(samples[0], 0, accuracy: 1e-6, "no fade in — clips will click")
        XCTAssertEqual(samples[Int(buffer.frameLength) - 1], 0, accuracy: 1e-6,
                       "no fade out — clips will click")
        // …but the middle is untouched.
        let mid = Int(buffer.frameLength) / 2
        XCTAssertGreaterThan(abs(samples[mid]), 0, "fade should not flatten the whole clip")
    }
}
