import SwiftUI
import AppKit

/// View-local state for the avatar card.
///
/// This exists instead of `@State` because SwiftUI's macro plugin
/// (`SwiftUIMacros`) is not present in either toolchain on this machine, and
/// `@State` is a macro in the current SDK -- it fails to compile with
/// "plugin for module 'SwiftUIMacros' not found". `@ObservedObject` is a plain
/// property wrapper, so it still works. Owned by AvatarPanel, which outlives
/// every re-render of the view.
@MainActor
final class AvatarUIState: ObservableObject {
    @Published var pulse = false
    @Published var hovering = false
}

/// The floating widget's contents: a face in a box, with the two numbers that
/// matter beside it. Deliberately small -- it lives on top of other windows
/// all day, so it has to be readable at a glance and ignorable otherwise.
struct AvatarFace: View {
    @ObservedObject var store: SnapshotStore
    @ObservedObject var ui: AvatarUIState
    var onClose: () -> Void = {}

    private var mood: Mood { store.mood }

    private var fiveHour: Double? {
        store.accountLimits?.limits.fiveHour?.usedPercentage
    }

    /// The fullest live session -- the one that will need /compact first.
    private var worstContext: Double? {
        store.liveSessions.compactMap { $0.context.usedPercentage }.max()
    }

    /// Shown in place of the context row when the newest snapshot is old
    /// enough that presenting its numbers as current would be a lie.
    private var staleNote: String? {
        guard let newest = store.sessions.map(\.age).min() else { return nil }
        guard newest >= Snapshot.Liveness.live else { return nil }
        return "\(Fmt.age(newest)) old"
    }

    /// Honour the system setting rather than animating unconditionally -- the
    /// alarmed state is the one that pulses, and it is also the one most
    /// likely to be irritating to someone who has asked for less motion.
    private var animates: Bool {
        mood.pulses && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        HStack(spacing: 12) {
            faceBox
            stats
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(mood.color.opacity(0.35), lineWidth: 1)
                )
        )
        .overlay(alignment: .topTrailing) {
            if ui.hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("Hide the avatar (reopen from the menubar)")
            }
        }
        .onHover { ui.hovering = $0 }
        .onAppear { syncPulse() }
        .onChange(of: mood.pulses) { syncPulse() }
    }

    private var faceBox: some View {
        Text(mood.face)
            .font(.system(size: 17, weight: .medium, design: .monospaced))
            .foregroundStyle(mood.color)
            .frame(width: 62, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(mood.color.opacity(0.5),
                            style: StrokeStyle(lineWidth: 1.2,
                                               dash: mood == .stale ? [2, 4] : []))
            )
            .opacity(ui.pulse ? 0.45 : 1)
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 3) {
            row(label: "5h", value: Fmt.percent(fiveHour), tint: Palette.tint(for: fiveHour))
            if let note = staleNote {
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            } else {
                row(label: "ctx", value: Fmt.percent(worstContext),
                    tint: Palette.tint(for: worstContext))
            }
        }
    }

    private func row(label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
        }
    }

    private func syncPulse() {
        guard animates else {
            // Leaving pulse true would freeze the card at 45% opacity when the
            // mood drops back out of alarmed.
            withAnimation(.easeInOut(duration: 0.2)) { ui.pulse = false }
            return
        }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            ui.pulse = true
        }
    }
}
