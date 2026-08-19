import SwiftUI

/// Where the numbers come from, and the one knob that matters.
///
/// This pane is not an appendix — a tool that turns unpublished data into a
/// confident-looking figure is worse than useless, so the uncertainty is part
/// of the product surface.
struct MethodologyView: View {
    @ObservedObject var engine: UsageEngine
    @AppStorage("menuBarMetric") private var metric = MenuBarMetric.cost

    var body: some View {
        let all = engine.records
        let defaults = engine.energyModel.defaults

        VStack(alignment: .leading, spacing: 14) {
            // The per-model baseline lives here rather than in its own tab: it's
            // reference data, and it reads better next to the caveats that say
            // how much to trust it.
            ModelsView(engine: engine)

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("Cache-read energy factor").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Slider(value: $engine.cacheReadFactor,
                           in: defaults.cacheReadFactor.lo...defaults.cacheReadFactor.hi)
                    Text(String(format: "%.2f", engine.cacheReadFactor))
                        .font(.caption).monospacedDigit().frame(width: 34)
                }
                // Cache reads are ~95% of local token volume, so this single
                // coefficient moves the total more than any model choice.
                Text("Drag it. Cache reads are "
                     + Format.percent(engine.tokenTotals(all).cacheEfficiency, places: 0)
                     + " of your prompt tokens, so this one number swings your total "
                     + "roughly 4.6× across its plausible range. There is no published "
                     + "energy measurement of a prompt-cache hit; the 10% price discount "
                     + "is a billing decision, not a measured energy ratio.")
                    .font(.caption2).foregroundStyle(.tertiary)

                HStack {
                    Text("all time:").font(.caption2).foregroundStyle(.secondary)
                    Text(Format.wh(engine.totalWattHours(all)))
                        .font(.caption).monospacedDigit()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Coefficients").font(.caption).foregroundStyle(.secondary)
                Row("output : input energy", String(format: "%.0f×", defaults.outputToInputRatio.v),
                    "Prefill is one parallel GEMM (compute-bound); decode streams every "
                    + "weight from HBM per token (bandwidth-bound). Claude's pricing uses 5×.")
                Row("cache write", String(format: "%.2f×", defaults.cacheWriteFactor.v),
                    "A write performs a full prefill pass.")
                Row("boundary", engine.energyModel.boundary,
                    "GPU-only accounting would be ~2.4× lower.")
                Row("model coefficients", "tier proxy",
                    "No credible active-parameter figures are published for any Claude, "
                    + "GPT-4o, or Gemini model, so tiers are anchored to measured "
                    + "per-query figures and scaled by price. Confidence: low.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text("Anchors these estimates rest on")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(["Google, median Gemini prompt — 0.24 Wh (measured, 2025-05)",
                         "Microsoft, median large-model query — 0.31 Wh (Joule, peer-reviewed)",
                         "Epoch AI, modeled GPT-4o — 0.30 Wh @ 500 output tokens"], id: \.self) {
                    Text("• " + $0).font(.caption2).foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text("Caveats").font(.caption).foregroundStyle(.secondary)
                ForEach(engine.energyModel.caveats, id: \.self) {
                    Text("• " + $0).font(.caption2).foregroundStyle(.tertiary)
                }
            }

            Divider()

            Picker("Menu bar shows", selection: $metric) {
                ForEach(MenuBarMetric.allCases) { Text($0.label).tag($0) }
            }
            .font(.caption)

            Text("Coefficients generated \(engine.energyModel.generated). These figures "
                 + "decay fast — Google reported a 33× energy reduction in 12 months.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func Row(_ label: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(value).font(.caption).monospacedDigit()
            }
            Text(note).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
