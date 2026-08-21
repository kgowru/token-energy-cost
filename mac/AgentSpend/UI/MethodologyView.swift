import SwiftUI

/// Where the numbers come from, and the one knob that matters.
///
/// This pane is not an appendix — a tool that turns unpublished data into a
/// confident-looking figure is worse than useless, so the uncertainty is part
/// of the product surface.
struct MethodologyView: View {
    @ObservedObject var engine: UsageEngine
    @AppStorage("menuBarMetric") private var metric = MenuBarMetric.cost
    @AppStorage("updateCheckEnabled") private var updateChecks = true

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
                     + " of your prompt tokens, so this one number moves your total by "
                     + "roughly 4.6× depending on where you set it. Nobody has ever "
                     + "measured the energy of a cache hit. The 10% price discount is a "
                     + "billing decision, not a measurement.")
                    .font(.caption2).foregroundStyle(.secondary)

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
                    "Reading your prompt is cheap: it all goes through the model in one "
                    + "pass. Writing the reply is expensive: the model has to run again "
                    + "for every single word it produces. Claude's own pricing treats "
                    + "output as 5× input.")
                Row("cache write", String(format: "%.2f×", defaults.cacheWriteFactor.v),
                    "A write performs a full prefill pass.")
                Row("boundary", engine.energyModel.boundary,
                    "GPU-only accounting would be ~2.4× lower.")
                Row("model coefficients", "tier proxy",
                    "Nobody publishes the size of any Claude, GPT-4o, or Gemini model, so "
                    + "each tier is based on the measured per-query figures above and "
                    + "scaled by price. Confidence: low.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text("Anchors these estimates rest on")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(["Google, median Gemini prompt: 0.24 Wh (measured, 2025-05)",
                         "Microsoft, median large-model query: 0.31 Wh (Joule, peer-reviewed)",
                         "Epoch AI, modeled GPT-4o: 0.30 Wh @ 500 output tokens"], id: \.self) {
                    Text("• " + $0).font(.caption2).foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text("Caveats").font(.caption).foregroundStyle(.secondary)
                ForEach(engine.energyModel.caveats, id: \.self) {
                    Text("• " + $0).font(.caption2).foregroundStyle(.secondary)
                }
            }

            Divider()

            Picker("Menu bar shows", selection: $metric) {
                ForEach(MenuBarMetric.allCases) { Text($0.label).tag($0) }
            }
            .font(.caption)

            // Disclosed here, in the pane that exists to say what the app does
            // and doesn't know, because it is the app's only network call and a
            // README claiming "no network calls" would otherwise be the only
            // place a user could learn that changed.
            VStack(alignment: .leading, spacing: 3) {
                Toggle(isOn: $updateChecks) {
                    Text("Check for new versions").font(.caption)
                }
                .controlSize(.small)
                Text(Self.updateCheckNote)
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Text("Coefficients generated \(engine.energyModel.generated). These figures "
                 + "go stale fast: Google reported a 33× energy reduction in 12 months.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// Built outside the view body: as one concatenated `Text` argument with an
    /// optional interpolation on the end, the type checker gave up on it.
    private static var updateCheckNote: String {
        var s = "The only network call AgentSpend makes. Once a day it asks GitHub "
              + "for the latest release number and shows a footer link if yours is "
              + "older. It sends no identifier and no usage data, and never "
              + "downloads or installs anything by itself."
        if let v = UpdateChecker.currentVersion { s += " You're on \(v)." }
        return s
    }

    @ViewBuilder
    private func Row(_ label: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(value).font(.caption).monospacedDigit()
            }
            Text(note).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
