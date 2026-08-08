import SwiftUI
import AppKit

/// The menubar dropdown: account-wide rate limits on top, then one row per
/// session. Rate limits are shared across every session; context is not, which
/// is the whole reason the sessions are listed separately.
struct SessionListView: View {
    @ObservedObject var store: SnapshotStore
    @ObservedObject var settings: SettingsStore
    var onToggleAvatar: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    /// Beyond this the list stops being scannable, so the rest collapse into
    /// one row that still surfaces the number that matters.
    private static let visibleSessions = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            limits
            Divider()
            sessionSection
            Divider()
            footer
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 296)
        // Redrawn on the store's one-second tick, so countdowns and ages stay
        // honest with no file activity.
        .id(store.tick.timeIntervalSince1970.rounded())
    }

    // MARK: - Account windows

    @ViewBuilder
    private var limits: some View {
        if store.accountLimits != nil {
            VStack(alignment: .leading, spacing: 8) {
                window("5-hour window", store.fiveHour, store.fiveHourResetsAt,
                       hasReset: store.fiveHourHasReset)
                window("7-day window", store.sevenDay, store.sevenDayResetsAt,
                       hasReset: store.sevenDayHasReset)
            }
            // Old data is dimmed wholesale rather than relabelled per row.
            .opacity(store.state == .stale || store.state == .asleep ? 0.55 : 1)
        } else {
            // Claude Code only sends rate limits to Claude.ai subscribers, and
            // only once a session has had a response come back.
            VStack(alignment: .leading, spacing: 3) {
                Text("No limit data yet")
                    .font(Typo.ui(12, .semibold))
                Text("Send a message in a session to populate it.")
                    .font(Typo.ui(11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func window(_ title: String, _ pct: Double?, _ resetsAt: Double?,
                        hasReset: Bool) -> some View {
        let dormant = store.state == .stale || store.state == .asleep
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).font(Typo.ui(12, .semibold))
                Spacer(minLength: 6)
                Text(trailing(pct, resetsAt, hasReset))
                    .font(Typo.mono(11))
                    .foregroundStyle(.secondary)
            }
            bar(pct, color: dormant ? Tokens.calmC : AvatarInput.ramp(pct, settings.thresholds))
        }
    }

    private func trailing(_ pct: Double?, _ resetsAt: Double?, _ hasReset: Bool) -> String {
        guard let pct else { return "—" }
        // A window past its reset is empty, and this is checked before the
        // staleness branch on purpose: the zero is current even when the
        // snapshot it came from is not. Labelling it "0% · 8h ago" would read
        // as an old number when in fact it is the only reading here that is
        // definitely right.
        if hasReset {
            guard let at = resetsAt else { return Fmt.percent(0) }
            let ago = Date().timeIntervalSince1970 - at
            return "\(Fmt.percent(0)) · reset \(Fmt.age(ago)) ago"
        }
        // Stale data gets its age, never a countdown: a countdown implies the
        // number beside it is current.
        if store.state == .stale || store.state == .asleep {
            if let age = store.newestAge { return "\(Fmt.percent(pct)) · \(Fmt.age(age)) ago" }
            return Fmt.percent(pct)
        }
        if let reset = Fmt.countdown(to: resetsAt, spaced: true) {
            return "\(Fmt.percent(pct)) · resets \(reset)"
        }
        return Fmt.percent(pct)
    }

    // MARK: - Sessions

    @ViewBuilder
    private var sessionSection: some View {
        let shown = Array(store.sessions.prefix(Self.visibleSessions))
        let hidden = store.sessions.dropFirst(Self.visibleSessions)

        if store.sessions.isEmpty {
            Text("No active sessions")
                .font(Typo.ui(12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(shown, id: \.sessionId) { row($0) }
                if !hidden.isEmpty { overflow(Array(hidden)) }
            }
        }
    }

    private func row(_ s: Snapshot) -> some View {
        let pct = s.context.usedPercentage
        let live = s.age < settings.thresholds.asleepAfter
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                // Tails distinguish session names ("…site rebuild"), so they
                // truncate in the middle; model names truncate at the tail.
                Text(s.displayName)
                    .font(Typo.ui(12.5, .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(Fmt.usd(s.cost.totalCostUsd))
                    .font(Typo.mono(11))
                    .fixedSize()
            }
            bar(pct, color: sessionColor(pct))
            HStack(spacing: 6) {
                Text(s.model ?? "—")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(Fmt.tokenPair(s.context.totalInputTokens, s.context.size)) · \(Fmt.age(s.age))")
                    .fixedSize()
            }
            .font(Typo.mono(10))
            .foregroundStyle(.tertiary)
        }
        .opacity(live ? 1 : 0.55)
    }

    /// Sessions below the first threshold get a neutral grey rather than the
    /// calm token: in a list, several coloured bars compete, and only the ones
    /// worth noticing should have colour.
    private func sessionColor(_ pct: Double?) -> Color {
        guard let pct else { return Tokens.dormantC }
        if pct < settings.thresholds.focused { return Color(nsColor: NSColor(hex: 0xB8B8BD)) }
        return settings.thresholds.state(for: pct).color
    }

    private func overflow(_ rest: [Snapshot]) -> some View {
        let worst = rest.compactMap { $0.context.usedPercentage }.max()
        return HStack {
            Text("▸ \(rest.count) more session\(rest.count == 1 ? "" : "s")")
                .font(Typo.ui(12))
            Spacer()
            if let worst {
                Text("worst \(Fmt.percent(worst))")
                    .font(Typo.mono(10, .semibold))
                    .foregroundColor(sessionColor(worst))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(freshness)
                .font(Typo.ui(11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button(settings.avatarVisible ? "Hide avatar" : "Show avatar",
                   action: onToggleAvatar)
            Button("Settings…", action: onOpenSettings)
            Button("Quit", action: onQuit)
        }
        .buttonStyle(.link)
        .font(Typo.ui(11))
    }

    private var freshness: String {
        guard let age = store.newestAge else { return "No data yet" }
        if store.liveSessions.isEmpty { return "⏱ last seen \(Fmt.age(age)) ago" }
        return "Updated \(Fmt.age(age)) ago"
    }

    // MARK: - Bits

    /// A percentage bar that reads as "unknown" when the value is missing —
    /// a dashed empty track, never a 0% fill.
    @ViewBuilder
    private func bar(_ pct: Double?, color: Color) -> some View {
        if let pct {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(color)
                        .frame(width: max(2, geo.size.width * min(1, pct / 100)))
                }
            }
            .frame(height: 5)
        } else {
            Capsule()
                .strokeBorder(Tokens.dormantC, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: 5)
        }
    }
}
