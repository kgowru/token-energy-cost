import SwiftUI

/// Today's numbers, then the one or two things worth acting on *today*.
///
/// The full ranked analysis lives in Savings and answers "what should I change
/// about how I work". Home answers the narrower question you have while the
/// work is still running — so the strip below is scoped to today, not to the
/// whole corpus, and stays quiet when today has nothing to flag.
struct HomeView: View {
    @ObservedObject var engine: UsageEngine
    /// Set by RootView so the strip can hand off to the full pane. Defaulted so
    /// the renderer can snapshot this view standalone.
    var showSavings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TodayView(engine: engine)

            Divider()

            LiveSavings(engine: engine, showSavings: showSavings)

            // Applies to every figure above, so it belongs at the end of the
            // pane rather than in the middle of it.
            Text("Cost is exact, from published rates. Energy is a modelled estimate "
                 + "and was consumed in a datacenter, not on your Mac.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// The top couple of today's recommendations, compressed to a glance.
///
/// Deliberately not `RecommendationCard` — that one is built to be studied
/// (rank, full evidence, an expandable caveat). This one has to be readable
/// without stopping what you're doing, so it keeps the action and the number
/// and drops the rest into the Savings pane.
struct LiveSavings: View {
    @ObservedObject var engine: UsageEngine
    var showSavings: () -> Void
    /// Seeing this strip is seeing today's advice, so record its signature —
    /// that's what clears the menu bar's "!" until a genuinely new
    /// recommendation appears. Tied to the insights being on screen, not merely
    /// to the popover opening.
    @AppStorage("seenRecsSignature") private var seenRecs = ""

    var body: some View {
        let recs = Array(engine.liveRecommendations().prefix(2))

        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(recs.isEmpty ? "Today" : "Worth a look today")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("all savings ›") { showSavings() }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }

            if recs.isEmpty {
                // A quiet day is a real answer. Inventing advice from a handful
                // of requests would make the strip noise you learn to skip.
                Text("Nothing worth flagging in today's usage.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(recs) { LiveSavingsRow(rec: $0) }
            }
        }
        .onAppear { seenRecs = engine.liveRecsSignature() }
    }
}

struct LiveSavingsRow: View {
    let rec: Recommendation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(rec.title).font(.caption).fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let s = rec.savingUsd {
                    Text("~" + Format.usd(s))
                        .font(.caption).monospacedDigit().foregroundStyle(.green)
                }
            }
            Text(rec.evidence)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}
