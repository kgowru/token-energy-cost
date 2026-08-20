import Foundation

/// A specific, quantified thing the user could change.
///
/// Every recommendation states the evidence it came from and, where the
/// reasoning depends on a judgement the data can't make, the caveat. Advice
/// that reads as certain when it isn't is worse than no advice — the user has
/// to be able to tell "this is arithmetic" from "this is a guess".
struct Recommendation: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case modelMix, cacheChurn, longContext, concentration, observation
    }

    let id: String
    let kind: Kind
    /// The action, phrased as something to do.
    let title: String
    /// What in the measured data supports it.
    let evidence: String
    /// Where the suggestion depends on something the data can't settle.
    let caveat: String?
    /// Dollars, when the saving is arithmetic rather than speculation.
    let savingUsd: Double?
    /// Ranking weight — dollars where known, else a nominal importance.
    let weight: Double
}

enum Recommender {
    /// Cheapest model within the same broad capability tier, used for the
    /// "same tier, lower price" suggestion where no capability trade is implied.
    private static let tierPeers: [String: String] = [
        "claude-fable-5": "claude-opus-4-8",
        "claude-mythos-5": "claude-opus-4-8",
        "claude-opus-5": "claude-opus-4-8",
    ]

    static func build(records: [UsageRecord],
                      estimator: Estimator,
                      sessions: [UsageEngine.SessionSummary],
                      projects: [(project: String, wh: Double, usd: Double)]) -> [Recommendation] {
        guard !records.isEmpty else { return [] }
        var out: [Recommendation] = []

        let totalUsd = records.reduce(0.0) { $0 + (estimator.cost($1) ?? 0) }

        // Group first with in-place appends. Pulling a struct/tuple out of the
        // dict, appending to its array, and writing it back forces a full
        // copy-on-write of the array every iteration — O(n²), and it was the
        // bulk of a multi-second Insights stall. `dict[k, default: []].append`
        // mutates the stored array in place.
        var rowsByModel: [String: [UsageRecord]] = [:]
        for r in records { rowsByModel[r.model, default: []].append(r) }

        var byModel: [String: (usd: Double, requests: Int, tokens: Int, rows: [UsageRecord])] = [:]
        for (model, rows) in rowsByModel {
            var usd = 0.0, tokens = 0
            for r in rows { usd += estimator.cost(r) ?? 0; tokens += r.totalTokens }
            byModel[model] = (usd, rows.count, tokens, rows)
        }

        // 1. Same-tier price premium. This is pure arithmetic — no capability
        //    trade is implied, only "you paid more per token for the same tier".
        for (model, e) in byModel {
            guard let peer = tierPeers[model], estimator.hasCoefficients(for: peer),
                  e.usd > 1 else { continue }
            let swapped = estimator.counterfactual(e.rows, as: peer).usd
            let saving = e.usd - swapped
            guard saving > 1 else { continue }
            out.append(Recommendation(
                id: "premium-\(model)",
                kind: .modelMix,
                title: "Move work that doesn't need \(short(model)) to \(short(peer))",
                evidence: "\(short(model)) cost you \(Format.usd(e.usd)) across "
                    + "\(e.requests) requests. The same tokens on \(short(peer)) "
                    + "would be \(Format.usd(swapped)).",
                caveat: "\(short(model)) is the more capable model, and worth it for "
                    + "hard, long-horizon work. The saving only applies to the portion "
                    + "that didn't need it, which the logs can't tell apart.",
                savingUsd: saving,
                weight: saving))
        }

        // 2. Tier downshift, sized to what's actually plausible rather than
        //    pretending every request could drop a tier.
        let frontierLarge = records.filter {
            estimator.entry(for: $0.model)?.tier == "frontier-large"
        }
        let largeUsd = frontierLarge.reduce(0.0) { $0 + (estimator.cost($1) ?? 0) }
        if largeUsd > 5, totalUsd > 0, largeUsd / totalUsd > 0.6,
           estimator.hasCoefficients(for: "claude-sonnet-5") {
            let allSonnet = estimator.counterfactual(frontierLarge, as: "claude-sonnet-5").usd
            let quarter = (largeUsd - allSonnet) * 0.25
            out.append(Recommendation(
                id: "tier-downshift",
                kind: .modelMix,
                title: "Try Sonnet 5 as the default, reserving Opus/Fable for hard work",
                evidence: String(format: "%.0f%%", 100 * largeUsd / totalUsd)
                    + " of your spend (\(Format.usd(largeUsd))) is on top-tier models. "
                    + "Sonnet 5 is roughly half the energy and a third of the price "
                    + "per token.",
                caveat: "Estimated on shifting a quarter of that work. That's a rough "
                    + "figure, not a measurement. A weaker model needing extra turns can "
                    + "erase the saving, so change the default and watch, don't switch "
                    + "blind.",
                savingUsd: quarter,
                weight: quarter))
        }

        // 3. Cache churn. Reads bill at 0.1x and skip prefill; writes re-pay full
        //    prefill at a 1.25-2x premium, so a low read share is real money.
        let churn = sessions.filter {
            $0.totals.cacheWrite > 0 && $0.usd > 1 && $0.totals.cacheEfficiency < 0.75
        }
        if let worst = churn.max(by: { $0.usd < $1.usd }) {
            let wasted = Double(worst.totals.cacheWrite) * 0.4 * 5.0 / 1_000_000
            out.append(Recommendation(
                id: "churn-\(worst.id)",
                kind: .cacheChurn,
                title: "Look at cache churn in \(worst.project)",
                evidence: "That session served only "
                    + Format.percent(worst.totals.cacheEfficiency, places: 0)
                    + " of its prompt tokens from cache "
                    + "(\(Format.tokens(worst.totals.cacheWrite)) written vs "
                    + "\(Format.tokens(worst.totals.cacheRead)) read), against "
                    + "\(churnBaseline(sessions)) typical for your sessions.",
                caveat: "Repeated cache writes usually mean something early in the "
                    + "prompt keeps changing: a timestamp, a reordered tool list, a "
                    + "varying system prompt. Worth a look, but the fix depends on the "
                    + "harness, not the model.",
                savingUsd: wasted > 0.5 ? wasted : nil,
                weight: max(wasted, 0.5)))
        }

        // 4. Long context. This is where energy actually runs away: the same
        //    output costs ~0.3 Wh at short context and ~40 Wh at 100k input.
        //    Threshold is relative to this user's own median — an absolute one
        //    fires on nearly every session for a heavy user and says nothing.
        let contexts = sessions.map(\.avgContextTokens).sorted()
        let median = contexts.isEmpty ? 0 : contexts[contexts.count / 2]
        let threshold = max(150_000, Int(Double(median) * 1.8))
        let longCtx = sessions.filter { $0.avgContextTokens > threshold && $0.usd > 1 }
            .sorted { $0.usd > $1.usd }
        if let worst = longCtx.first {
            out.append(Recommendation(
                id: "context-\(worst.id)",
                kind: .longContext,
                title: "Split long sessions in \(worst.project)",
                evidence: "Averaged \(Format.tokens(worst.avgContextTokens)) of prompt "
                    + "per request across \(worst.requests) requests "
                    + "(\(Format.usd(worst.usd))), against a "
                    + "\(Format.tokens(median)) median across your sessions. "
                    + "\(longCtx.count) session"
                    + (longCtx.count == 1 ? "" : "s") + " ran this long.",
                caveat: "Long sessions get more expensive per turn as they go, because "
                    + "every turn re-reads a bigger prompt than the last. The end of a "
                    + "long session costs far more than the start. Starting fresh when "
                    + "the task changes is usually cheaper than compacting.",
                savingUsd: nil,
                weight: worst.usd * 0.15))
        }

        // 5. Concentration. Not a problem in itself, but it tells you where any
        //    effort is worth spending.
        if let top = projects.first, totalUsd > 0, top.usd / totalUsd > 0.25 {
            out.append(Recommendation(
                id: "concentration-\(top.project)",
                kind: .concentration,
                title: "Most of your spend is one project: \(top.project)",
                evidence: "\(Format.usd(top.usd)) of \(Format.usd(totalUsd)) "
                    + "(\(Format.percent(top.usd / totalUsd, places: 0))) and "
                    + "\(Format.wh(top.wh)).",
                caveat: "Concentration isn't waste. It just means anything you change "
                    + "there matters more than the same change anywhere else.",
                savingUsd: nil,
                weight: 1.0))
        }

        return out.sorted { $0.weight > $1.weight }
    }

    private static func churnBaseline(_ sessions: [UsageEngine.SessionSummary]) -> String {
        let vals = sessions.map(\.totals.cacheEfficiency).sorted()
        guard !vals.isEmpty else { return "n/a" }
        return Format.percent(vals[vals.count / 2], places: 0)
    }

    private static func short(_ model: String) -> String {
        model.replacingOccurrences(of: "claude-", with: "")
    }
}
