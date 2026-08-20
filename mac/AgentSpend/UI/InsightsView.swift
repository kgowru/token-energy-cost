import SwiftUI

/// What to change, ranked by what it's worth. The Savings pane.
///
/// Ranked over the whole corpus, so this is about habits — the counterpart to
/// Home's strip, which asks the same recommender about today alone.
///
/// Each item leads with an action, then the measured evidence, then the caveat.
/// The caveat isn't fine print — several of these depend on a judgement the logs
/// can't make, and the user needs to see which ones.
struct InsightsView: View {
    @ObservedObject var engine: UsageEngine
    /// Viewing the full insights pane also counts as seeing today's advice, so
    /// it clears the menu bar's "!" — same signature the Home strip records.
    @AppStorage("seenRecsSignature") private var seenRecs = ""

    var body: some View {
        // One memoized bundle instead of recomputing the whole analysis on
        // every redraw. On an unchanged corpus this returns instantly.
        let result = engine.insightsResult()
        let recs = result.recommendations
        let totalUsd = result.totalUsd
        let headline = result.headlineSavings

        VStack(alignment: .leading, spacing: 14) {
            if recs.isEmpty {
                Text("Nothing worth changing yet. Not enough history.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Possible savings").font(.caption).foregroundStyle(.secondary)
                    Text("up to \(Format.usd(headline))")
                        .font(.system(size: 26, weight: .medium, design: .rounded))
                        .monospacedDigit().foregroundStyle(.green)
                    Text("against \(Format.usd(totalUsd)) spent to date")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                // Anchor the abstract kWh to something physical.
                VStack(alignment: .leading, spacing: 1) {
                    Text("Energy to date").font(.caption).foregroundStyle(.secondary)
                    Text(Format.wh(result.totalWh))
                        .font(.system(.title3, design: .rounded)).monospacedDigit()
                    Text(Format.homeEnergy(result.totalWh, engine.energyModel.equivalences))
                        .font(.caption2).foregroundStyle(.secondary)
                }

                // Says out loud what separates this from Home's strip, so two
                // panes ranking the same recommender don't read as a bug.
                Text("Ranked across your whole history: the patterns, not today.")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(Array(recs.enumerated()), id: \.element.id) { i, r in
                    RecommendationCard(rank: i + 1, rec: r)
                }
            }

            Divider()

            // Kept from the old view: the raw swap comparison, which is the
            // cleanest way to see the shape of the model-price curve. Comes from
            // the same memoized bundle — no second full pass.
            let cfs = result.counterfactuals
            VStack(alignment: .leading, spacing: 5) {
                Text("Whole history replayed on one model")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(cfs, id: \.model) { cf in
                    HStack {
                        Text(cf.model.replacingOccurrences(of: "claude-", with: ""))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(format: "%.2f× energy", cf.whRatio))
                            .frame(width: 88, alignment: .trailing)
                            .foregroundStyle(cf.whRatio < 1 ? .green : .secondary)
                        Text(cf.usdSaved > 0 ? "−" + Format.usd(cf.usdSaved)
                                             : "+" + Format.usd(-cf.usdSaved))
                            .frame(width: 68, alignment: .trailing)
                            .foregroundStyle(cf.usdSaved > 0 ? .green : .secondary)
                    }
                    .font(.caption).monospacedDigit()
                }
                Text("A ceiling, not a plan. Nobody should run everything on one "
                     + "model. It holds turn count fixed, and a weaker model that "
                     + "needs more turns gives the saving back.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear { seenRecs = engine.liveRecsSignature() }
    }
}

struct RecommendationCard: View {
    let rank: Int
    let rec: Recommendation
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(rank)")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 12, alignment: .trailing)
                Text(rec.title).font(.callout).fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let s = rec.savingUsd {
                    Text("~" + Format.usd(s))
                        .font(.caption).monospacedDigit().foregroundStyle(.green)
                }
            }

            Text(rec.evidence)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 18)

            if let caveat = rec.caveat {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8))
                        Text(expanded ? "caveat" : "caveat")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 18)

                if expanded {
                    Text(caveat)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 18)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}
