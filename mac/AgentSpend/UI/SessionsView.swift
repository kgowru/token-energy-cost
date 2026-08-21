import SwiftUI

/// What's actually running: recent sessions, what they cost, and when the day's
/// work happened. This is the "where did that number come from" view.
struct SessionsView: View {
    @ObservedObject var engine: UsageEngine
    // Key kept as-is through the rename — changing it would silently reset the
    // scope on every install that had already chosen one.
    @AppStorage("activityScope") private var scopeDays = 1

    var body: some View {
        let since = Calendar.current.startOfDay(for: Date())
            .addingTimeInterval(-Double(scopeDays - 1) * 86_400)
        let sessions = engine.recentSessions(limit: 15, since: since)
        let hours = engine.hourlyActivity(since: since)

        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $scopeDays) {
                Text("Today").tag(1); Text("3 days").tag(3); Text("7 days").tag(7)
            }
            .pickerStyle(.segmented).labelsHidden()

            if sessions.isEmpty {
                Text("No activity in this window.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                if scopeDays == 1 { HourlyBars(hours: hours) }

                // Flag long context relative to this user's own baseline. An
                // absolute threshold fired on nearly every row here, which makes
                // it decoration rather than a signal.
                let contexts = sessions.map(\.avgContextTokens).sorted()
                let median = contexts[contexts.count / 2]
                let longThreshold = max(150_000, Int(Double(median) * 1.8))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Sessions, most recent first")
                        Spacer()
                        Text("median context \(Format.tokens(median))")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption).foregroundStyle(.secondary)

                    ForEach(sessions) { s in
                        SessionRow(session: s, longThreshold: longThreshold)
                        if s.id != sessions.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

struct SessionRow: View {
    let session: UsageEngine.SessionSummary
    /// Relative to the user's own median, so the flag marks outliers rather
    /// than firing on every row.
    let longThreshold: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.project).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Format.usd(session.usd)).monospacedDigit()
                Text(Format.wh(session.wh)).foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)
            }
            .font(.caption)

            HStack(spacing: 5) {
                Text(session.lastActivity.formatted(date: .omitted, time: .shortened))
                if let b = session.branch {
                    Text("·"); Text(b).lineLimit(1)
                }
                Text("·"); Text(session.models.first.map(short) ?? "—")
                if session.models.count > 1 { Text("+\(session.models.count - 1)") }
                Text("·"); Text("\(session.requests) req")
                if session.subagentRequests > 0 {
                    Text("· \(session.subagentRequests) subagent")
                }
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)

            // Long context is where cost runs away superlinearly, so outliers
            // are worth calling out on the row rather than leaving to inference.
            if session.avgContextTokens > longThreshold {
                Text("avg context \(Format.tokens(session.avgContextTokens)), "
                     + "well above your median")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private func short(_ m: String) -> String {
        m.replacingOccurrences(of: "claude-", with: "")
    }
}

/// When today's work happened. Hovering an hour reads out that hour's spend.
struct HourlyBars: View {
    let hours: [(hour: Int, requests: Int, usd: Double)]
    @State private var hovered: Int?

    var body: some View {
        let maxV = hours.map(\.usd).max() ?? 0
        let focus = hours.first { $0.hour == hovered }

        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("By hour").foregroundStyle(.secondary)
                Spacer()
                if let h = focus, h.requests > 0 {
                    Text(String(format: "%02d:00", h.hour)).foregroundStyle(.primary)
                    + Text("  \(Format.usd(h.usd)) · \(Format.count(h.requests)) req")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2).monospacedDigit().lineLimit(1)

            HStack(alignment: .bottom, spacing: 1) {
                ForEach(hours, id: \.hour) { h in
                    ZStack(alignment: .bottom) {
                        Color.clear
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.tint)
                            .opacity(h.usd == 0 ? 0.12 : (hovered == nil || hovered == h.hour ? 0.85 : 0.35))
                            .frame(height: maxV == 0 ? 2 : max(2, 34 * h.usd / maxV))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hovered = h.hour }
                        else if hovered == h.hour { hovered = nil }
                    }
                    .help(String(format: "%02d:00 · %@ · %d req", h.hour,
                                 Format.usd(h.usd), h.requests))
                }
            }
            .frame(height: 34)
            HStack {
                Text("00"); Spacer(); Text("12"); Spacer(); Text("23")
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
