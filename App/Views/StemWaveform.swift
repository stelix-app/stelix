// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import StelixCore
import SwiftUI

/// Waveform of a stem: symmetric peaks on a square-root scale (`Peaks.displayLevel`), position cursor,
/// click or drag to seek.
/// It sits directly on the panel background, without glass. No animation.
struct StemWaveform: View {
    let peaks: [Float]
    let progress: Double
    let color: Color
    let enabled: Bool
    let onSeek: (Double) -> Void

    static let height: CGFloat = 20

    /// Cursor position during the drag: the seek starts only at the end of the gesture.
    @State private var dragFraction: Double?
    private static let columnWidth: CGFloat = 2
    static let playedOpacity = 0.95
    static let unplayedOpacity = 0.45

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Canvas { context, size in
                let columns = max(Int(size.width / Self.columnWidth), 1)
                let split = min(max(dragFraction ?? progress, 0), 1) * size.width
                let midY = size.height / 2
                for column in 0..<columns {
                    let x = CGFloat(column) * Self.columnWidth
                    let peak = CGFloat(Peaks.displayLevel(Self.peak(in: peaks, column: column, of: columns)))
                    let half = max(peak * midY, 0.5)
                    let rect = CGRect(x: x, y: midY - half, width: Self.columnWidth - 1, height: half * 2)
                    let shading: GraphicsContext.Shading
                    // With the Mac in light mode 0.6/0.25 and .quaternary vanished on the background.
                    if !enabled {
                        shading = .style(.tertiary)
                    } else if x + Self.columnWidth / 2 <= split {
                        shading = .color(color.opacity(Self.playedOpacity))
                    } else {
                        shading = .color(color.opacity(Self.unplayedOpacity))
                    }
                    context.fill(Path(rect), with: shading)
                }
                let cursor = CGRect(x: min(max(split, 0), size.width - 1), y: 0, width: 1, height: size.height)
                context.fill(Path(cursor), with: .style(.primary))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0 else { return }
                        dragFraction = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { value in
                        dragFraction = nil
                        guard width > 0 else { return }
                        onSeek(min(max(value.location.x / width, 0), 1))
                    })
        }
        .frame(height: Self.height)
    }

    /// The maximum of the peaks (clamped to 0...1) that fall in the column.
    static func peak(in peaks: [Float], column: Int, of columns: Int) -> Float {
        guard !peaks.isEmpty else { return 0 }
        let lower = column * peaks.count / columns
        let upper = max((column + 1) * peaks.count / columns, lower + 1)
        var best: Float = 0
        for index in lower..<min(upper, peaks.count) { best = max(best, peaks[index]) }
        return min(max(best, 0), 1)
    }
}
