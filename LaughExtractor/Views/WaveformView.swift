import SwiftUI
import Accelerate

/// Full-width waveform with detected bursts highlighted.
///
/// This is how you eyeball whether detection is over- or under-firing without
/// listening to every clip.
struct WaveformView: View {
    let peaks: [Float]
    let hopSeconds: Double
    let duration: Double
    let segments: [LaughSegment]
    let playhead: Double?
    let onSeek: (Double) -> Void

    /// The peak array is the more reliable clock — asset duration can be a
    /// container estimate that disagrees with the decoded sample count.
    private var timeline: Double {
        max(0.001, duration, Double(peaks.count) * hopSeconds)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, Int(geometry.size.width))
            let height = geometry.size.height
            let downsampled = Self.downsample(peaks, to: width)
            let normalizer = max(0.05, downsampled.max() ?? 1)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    // Highlights first, so the waveform draws on top of them.
                    for segment in segments {
                        let x0 = size.width * segment.startSeconds / timeline
                        let x1 = size.width * segment.endSeconds / timeline
                        let rect = CGRect(x: x0, y: 0, width: max(2, x1 - x0), height: size.height)
                        context.fill(Path(rect), with: .color(.accentColor.opacity(0.28)))
                    }

                    var path = Path()
                    let midY = size.height / 2
                    for (i, value) in downsampled.enumerated() {
                        let x = CGFloat(i) + 0.5
                        let amplitude = CGFloat(value / normalizer) * midY
                        path.move(to: CGPoint(x: x, y: midY - amplitude))
                        path.addLine(to: CGPoint(x: x, y: midY + amplitude))
                    }
                    context.stroke(path, with: .color(.secondary.opacity(0.75)), lineWidth: 1)

                    if let playhead {
                        let x = size.width * playhead / timeline
                        var marker = Path()
                        marker.move(to: CGPoint(x: x, y: 0))
                        marker.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(marker, with: .color(.primary), lineWidth: 1.5)
                    }
                }
                .frame(height: height)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                onSeek(timeline * Double(location.x / geometry.size.width))
            }
        }
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Peak-preserving downsample to one value per pixel column.
    ///
    /// Averaging here would flatten short laughs into nothing, so each column
    /// keeps the loudest sample it covers.
    static func downsample(_ input: [Float], to columns: Int) -> [Float] {
        guard columns > 0 else { return [] }
        guard input.count > columns else { return input }

        var output = [Float](repeating: 0, count: columns)
        let bucket = Double(input.count) / Double(columns)

        input.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for column in 0..<columns {
                let start = Int(Double(column) * bucket)
                let end = min(input.count, max(start + 1, Int(Double(column + 1) * bucket)))
                var peak: Float = 0
                vDSP_maxmgv(base + start, 1, &peak, vDSP_Length(end - start))
                output[column] = peak
            }
        }
        return output
    }
}
