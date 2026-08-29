import SwiftUI

/// A percentage bar that reads as "unknown" when the value is missing —
/// a dashed empty track, never a 0% fill.
///
/// Lifted out of `SessionListView` the moment a second surface needed it. The
/// rule it encodes is the one this app is most likely to get wrong twice:
/// absence is not zero, so a reading nobody has ever sent must not be drawn as
/// a bar that happens to be empty.
struct MeterBar: View {
    let pct: Double?
    let color: Color
    var height: CGFloat = 5

    var body: some View {
        if let pct {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(color)
                        .frame(width: max(2, geo.size.width * min(1, pct / 100)))
                }
            }
            .frame(height: height)
        } else {
            Capsule()
                .strokeBorder(Tokens.dormantC, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: height)
        }
    }
}
