import SwiftUI
import AppKit

/// The menubar popover: account-wide rate limits on top, then one row per
/// session. Rate limits are shared across every session; context is not, which
/// is the whole reason the sessions are listed separately.
struct SessionListView: View {
    @ObservedObject var store: SnapshotStore
    var avatarVisible: Bool
    var onToggleAvatar: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 10)
            limitsSection
            Divider().padding(.vertical, 10)
            sessionsSection
            Divider().padding(.vertical, 10)
            footer
        }
        .padding(14)
        .frame(width: 330)
        .id(store.tick.timeIntervalSince1970.rounded())
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(store.mood.face)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(store.mood.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.mood.label)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var subtitle: String {
        let live = store.liveSessions.count
        guard live > 0 else { return "nothing running" }
        return live == 1 ? "1 live session" : "\(live) live sessions"
    }

    // MARK: - Rate limits

    @ViewBuilder
    private var limitsSection: some View {
        if let (limits, asOf) = store.accountLimits {
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("ACCOUNT LIMITS")
                window("5-hour", limits.fiveHour)
                window("7-day", limits.sevenDay)
                let age = Date().timeIntervalSince1970 - asOf
                if age >= Snapshot.Liveness.live {
                    Text("as of \(Fmt.age(age)) ago")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("ACCOUNT LIMITS")
                // Claude Code only sends rate_limits to Claude.ai subscribers,
                // and only once a session has had an API response come back.
                Text("No limit data yet — send a message in a session.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func window(_ title: String, _ w: Snapshot.RateLimits.Window?) -> some View {
        let pct = w?.usedPercentage
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                if let reset = Fmt.countdown(to: w?.resetsAt) {
                    Text("resets \(reset)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                Text(Fmt.percent(pct))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.tint(for: pct))
            }
            bar(pct)
        }
    }

    // MARK: - Sessions

    @ViewBuilder
    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("SESSIONS")
            if store.sessions.isEmpty {
                Text("No sessions publishing. Start Claude Code.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.sessions, id: \.sessionId) { s in
                    sessionRow(s)
                }
            }
        }
    }

    private func sessionRow(_ s: Snapshot) -> some View {
        let pct = s.context.usedPercentage
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(s.isLive ? Palette.green : Palette.dim)
                    .frame(width: 5, height: 5)
                Text(s.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(Fmt.percent(pct))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.tint(for: pct))
            }
            bar(pct)
            HStack(spacing: 6) {
                Text("\(Fmt.tokens(s.context.totalInputTokens))/\(Fmt.tokens(s.context.size))")
                if let model = s.model { Text("·"); Text(model).lineLimit(1) }
                Spacer(minLength: 4)
                Text(Fmt.usd(s.cost.totalCostUsd))
                if !s.isLive { Text("· \(Fmt.age(s.age))") }
            }
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        .opacity(s.isLive ? 1 : 0.55)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button(avatarVisible ? "Hide avatar" : "Show avatar", action: onToggleAvatar)
            Spacer()
            Button("Quit", action: onQuit)
        }
        .buttonStyle(.link)
        .font(.system(size: 11))
    }

    // MARK: - Bits

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
    }

    /// A percentage bar that stays visible at 0% and reads as "unknown" when
    /// the value is missing, rather than silently rendering as empty.
    private func bar(_ pct: Double?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                if let pct {
                    Capsule()
                        .fill(Palette.tint(for: pct))
                        .frame(width: max(2, geo.size.width * min(1, pct / 100)))
                }
            }
        }
        .frame(height: 4)
    }
}
