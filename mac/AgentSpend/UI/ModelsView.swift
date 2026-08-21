import SwiftUI

/// The baseline table: model → energy per 1k tokens, price, your volume, and
/// your share. Confidence is shown per row, because it varies and the
/// difference matters.
struct ModelsView: View {
    @ObservedObject var engine: UsageEngine

    var body: some View {
        let rows = engine.byModel(engine.records)
        let totalWh = rows.reduce(0) { $0 + $1.wh }
        let prices = engine.estimator.pricing.allPrices

        VStack(alignment: .leading, spacing: 12) {
            Text("Per-model baseline")
                .font(.caption).foregroundStyle(.secondary)

            VStack(spacing: 6) {
                HStack {
                    Text("model").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Wh/1k in").frame(width: 58, alignment: .trailing)
                    Text("Wh/1k out").frame(width: 62, alignment: .trailing)
                    Text("share").frame(width: 44, alignment: .trailing)
                }
                .font(.caption2).foregroundStyle(.secondary)

                Divider()

                ForEach(rows) { row in
                    let tier = engine.energyModel.tier(for: row.model)
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.model).lineLimit(1)
                            HStack(spacing: 4) {
                                Text(Format.tokens(row.totals.total) + " tokens")
                                Text("·")
                                Text(Format.usd(row.usd))
                                if let p = prices[row.model], p.confidence == "unknown" {
                                    Text("· price assumed").foregroundStyle(.orange)
                                }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(tier.map { fmt($0.whPer1kInput.v) } ?? "—")
                            .frame(width: 58, alignment: .trailing)
                        Text(tier.map { fmt($0.whPer1kOutput.v) } ?? "—")
                            .frame(width: 62, alignment: .trailing)
                        Text(totalWh == 0 ? "—" : Format.percent(row.wh / totalWh, places: 0))
                            .frame(width: 44, alignment: .trailing)
                    }
                    .font(.caption)
                    .monospacedDigit()
                }
            }

            Text("These are estimates, based on published per-query measurements and "
                 + "scaled by price as a rough stand-in for model size. No vendor "
                 + "publishes per-token energy, so read the columns above as an "
                 + "ordering, not as absolute truth.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func fmt(_ d: Double) -> String {
        String(format: d < 0.1 ? "%.3f" : "%.2f", d)
    }
}
