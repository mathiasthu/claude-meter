import SwiftUI
import AppKit

/// Renders every style in every state, light and dark, to a PNG.
///
/// These are states you cannot reach on demand from real data — you cannot ask
/// the account to be at 92%, or the daemon to have died an hour ago — so the
/// only way to review the set is to synthesise it. It also renders offscreen,
/// which means it works without screen-recording permission.
///
/// `ClaudeMeter --render-grid <path.png>`
enum RenderGrid {

    /// ImageRenderer is main-actor isolated; the caller is already on the main
    /// thread, so this just makes that explicit.
    @MainActor
    static func run(to path: String) -> Bool {
        let renderer = ImageRenderer(content: Sheet())
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Synthetic input for one cell. `many` is a modifier rather than a state,
    /// so it gets its own column with three sessions in it.
    static func input(_ state: MeterState, many: Bool = false) -> AvatarInput {
        let now = Date().timeIntervalSince1970
        let pct: Double = {
            switch state {
            case .calm: return 32
            case .focused: return 62
            case .strained: return 78
            case .critical: return 92
            case .stale: return 62
            default: return 32
            }
        }()
        var i = AvatarInput(
            state: state,
            percentage: state == .noData || state == .empty ? nil : pct,
            fiveHour: state == .noData || state == .empty ? nil : pct,
            fiveHourResetsAt: now + 11_220,
            sevenDay: state == .noData || state == .empty ? nil : pct * 0.6,
            context: state == .empty ? nil : pct * 0.8,
            sessions: state == .empty ? [] : [pct],
            age: state == .stale ? 5_400 : (state == .asleep ? 2_400 : 12),
            // Frozen: an animated style must be legible in its still frame,
            // and a still sheet is what gets reviewed.
            motionAllowed: false)
        if many { i.sessions = [pct, max(0, pct - 25), max(0, pct - 48)] }
        return i
    }

    // MARK: - Sheet

    struct Sheet: View {
        private var columns: [(String, AvatarInput)] {
            MeterState.allCases.map { ($0.label, RenderGrid.input($0)) }
                + [("Many", RenderGrid.input(.strained, many: true))]
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("claude-meter — avatar states")
                        .font(.system(size: 22, weight: .bold))
                    Text("Every style in every state, light over dark. Animations frozen.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                ForEach(AvatarStyleID.allCases) { style in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(style.displayName).font(.system(size: 15, weight: .semibold))
                            Text("\(Int(style.naturalSize.width))×\(Int(style.naturalSize.height)) pt")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(Array(columns.enumerated()), id: \.offset) { _, col in
                                VStack(spacing: 5) {
                                    Text(col.0.uppercased())
                                        .font(.system(size: 8, weight: .semibold))
                                        .tracking(0.6)
                                        .foregroundColor(.secondary)
                                    Cell(style: style, input: col.1, scheme: .light)
                                    Cell(style: style, input: col.1, scheme: .dark)
                                }
                            }
                        }
                    }
                }

                MenubarRow()
            }
            .padding(28)
            .background(Color(nsColor: NSColor(hex: 0xF5F5F7)))
            .environment(\.colorScheme, .light)
            .fixedSize()
        }
    }

    private struct Cell: View {
        let style: AvatarStyleID
        let input: AvatarInput
        let scheme: ColorScheme

        var body: some View {
            ZStack {
                LinearGradient(
                    colors: scheme == .light
                        ? [Color(nsColor: NSColor(hex: 0xE2E7EE)), Color(nsColor: NSColor(hex: 0xC9D2DC))]
                        : [Color(nsColor: NSColor(hex: 0x3D434C)), Color(nsColor: NSColor(hex: 0x22262C))],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                // Padding rather than a fixed width: the pill grows with its
                // text, and a constant-width cell was clipping its right end.
                ScaledAvatar(style: style, input: input)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 76)
            }
            .frame(height: 68)
            .fixedSize(horizontal: true, vertical: false)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .environment(\.colorScheme, scheme)
        }
    }

    /// The 16×16 mark is drawn with AppKit rather than SwiftUI, so it is
    /// checked separately — at menubar size, on menubar backgrounds.
    private struct MenubarRow: View {
        private let cases: [(String, MeterState, Double?)] = [
            ("Calm", .calm, 32), ("Focused", .focused, 62), ("Strained", .strained, 78),
            ("Critical", .critical, 92), ("Stale", .stale, 62),
            ("Asleep", .asleep, nil), ("No data", .noData, nil), ("Empty", .empty, nil),
        ]

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Menubar mark").font(.system(size: 15, weight: .semibold))
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(cases.enumerated()), id: \.offset) { _, c in
                        VStack(spacing: 5) {
                            Text(c.0.uppercased())
                                .font(.system(size: 8, weight: .semibold))
                                .tracking(0.6).foregroundColor(.secondary)
                            bar(c.1, c.2, dark: false)
                            bar(c.1, c.2, dark: true)
                        }
                    }
                }
            }
        }

        private func bar(_ state: MeterState, _ pct: Double?, dark: Bool) -> some View {
            HStack(spacing: 4) {
                Image(nsImage: MenubarIcon.image(state: state, percentage: pct,
                                                 thresholds: .default))
                Text(title(state, pct))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(dark ? .white : .black)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color(nsColor: NSColor(hex: dark ? 0x242428 : 0xF6F6F8)))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .environment(\.colorScheme, dark ? .dark : .light)
        }

        private func title(_ state: MeterState, _ pct: Double?) -> String {
            guard let pct else { return "—" }
            if state == .stale { return "5h \(Int(pct))% · 1h ago" }
            return "5h \(Int(pct))% · 3h07m"
        }
    }
}
