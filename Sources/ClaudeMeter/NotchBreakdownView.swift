import SwiftUI
import AppKit

/// The notch's popover: the three readings the strip draws, spelled out.
///
/// Built from the same `NotchData.readings` call the strip makes, which is the
/// structural guarantee that a ring and the row describing it can never
/// disagree — three rings and a list all deciding separately whether there is a
/// 7-day reading is exactly how a HUD ends up contradicting itself.
struct NotchBreakdownView: View {
    @ObservedObject var store: SnapshotStore
    @ObservedObject var settings: SettingsStore
    /// The ring that was clicked, marked in the list. A plain value rather than
    /// anything observable, so the offscreen renderers can pass a literal.
    var selected: NotchRing?
    var onOpenSettings: () -> Void = {}

    var body: some View {
        let readings = NotchData.readings(input)
        VStack(alignment: .leading, spacing: 10) {
            header
            divider
            VStack(alignment: .leading, spacing: 9) {
                ForEach(readings, id: \.ring) { row($0) }
            }
            divider
            footer(readings)
        }
        .padding(14)
        .frame(width: 296)
        // To the edges, not inside the padding: the popover's own window is
        // what shows through otherwise, and it is not this colour.
        .background(Tokens.notchSurfaceC)
        // The popover is pinned dark to match the strip it belongs to, so the
        // dynamic tokens have to resolve against that rather than the system.
        .environment(\.colorScheme, .dark)
    }

    /// The same input the strip is drawn from, plus the one thing the store
    /// cannot know: which ring the click landed on.
    private var input: AvatarInput {
        var i = store.avatarInput
        i.selectedRing = selected
        i.notchEdge = settings.notchEdge
        return i
    }

    private var header: some View {
        HStack(spacing: 8) {
            ClaudeAsterisk()
                .stroke(Tokens.brandOrangeC,
                        style: StrokeStyle(lineWidth: 1.15, lineCap: .round))
                .frame(width: 15, height: 15)
            Text("Claude usage").font(Typo.ui(12.5, .semibold))
            Spacer(minLength: 8)
            Text(store.newestAge.map { "updated \(Fmt.age($0)) ago" } ?? "no data")
                .font(Typo.mono(10))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private func row(_ r: NotchReading) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // The context row is titled with a session name, which can be
                // a sentence — truncated in the middle for the reason the
                // session list truncates there.
                Text(r.title)
                    .font(Typo.ui(12, .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(r.known ? "\(Fmt.percent(r.pct)) used" : "no reading")
                    .font(Typo.mono(11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            MeterBar(pct: r.pct, color: NotchData.color(r, settings.thresholds))
            Text(r.sub)
                .font(Typo.mono(10))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        // The clicked row is washed in the same colour as the halo under the
        // clicked ring, so one mark means "this is the one you hit" in both
        // places. Negative padding afterwards lets that wash run wider than the
        // text column without moving the text.
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(selected == r.ring ? Tokens.notchHaloC : .clear))
        .padding(.horizontal, -8)
    }

    private func footer(_ readings: [NotchReading]) -> some View {
        HStack(spacing: 12) {
            // With nothing to show, the hint has to be the one that says how to
            // get data rather than what to click. Same sentence the dropdown
            // uses, deliberately: two wordings for one situation is two things
            // to keep true.
            Text(readings.contains(where: \.known)
                 ? "Click a ring to jump to a window."
                 : "Send a message in a session to populate it.")
                .font(Typo.ui(11))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Button("Settings", action: onOpenSettings)
                .buttonStyle(.link)
                .font(Typo.ui(11))
        }
    }

    private var divider: some View {
        Rectangle().fill(Tokens.notchBorderC).frame(height: 1)
    }
}

/// The Claude asterisk, drawn rather than shipped as an asset so it inherits
/// whatever colour and size it is given.
struct ClaudeAsterisk: Shape {
    func path(in rect: CGRect) -> Path {
        // Authored on the 24-unit grid the brand mark uses.
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 24 * rect.width,
                    y: rect.minY + y / 24 * rect.height)
        }
        var path = Path()
        path.move(to: p(12, 3));    path.addLine(to: p(12, 21))
        path.move(to: p(4.2, 7.5)); path.addLine(to: p(19.8, 16.5))
        path.move(to: p(19.8, 7.5)); path.addLine(to: p(4.2, 16.5))
        return path
    }
}
