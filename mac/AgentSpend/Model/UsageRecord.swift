import Foundation

/// One deduplicated API request, as recovered from a Claude Code session log.
struct UsageRecord: Sendable, Equatable {
    var id: String            // message.id — the dedup key
    var timestamp: Date?
    var model: String         // date-suffix normalized
    var input: Int
    var output: Int
    var cacheWrite: Int
    var cacheWrite5m: Int
    var cacheWrite1h: Int
    var cacheRead: Int
    var cwd: String?
    var gitBranch: String?
    var sessionId: String?
    var isSidechain: Bool
    var isSubagent: Bool

    var project: String { (cwd as NSString?)?.lastPathComponent ?? "unknown" }
    var totalTokens: Int { input + output + cacheWrite + cacheRead }
}

/// Model IDs appear in both alias (`claude-haiku-4-5`) and dated
/// (`claude-haiku-4-5-20251001`) form. Unnormalized, dated rows match no
/// coefficient and are silently counted as zero — which is exactly how a tool
/// like this ends up quietly wrong.
enum ModelID {
    static func normalize(_ raw: String) -> String {
        guard raw.count > 9 else { return raw }
        let suffix = raw.suffix(9)
        guard suffix.first == "-", suffix.dropFirst().allSatisfy(\.isNumber) else { return raw }
        return String(raw.dropLast(9))
    }
}

/// Energy and cost for a set of records.
///
/// Energy is a modeled estimate with a wide band; cost is exact arithmetic on
/// published rates. The UI leads with cost and relative comparisons for that
/// reason.
struct Estimator: Sendable {
    let energy: EnergyModel
    let pricing: PricingModel
    private let prices: [String: PricingModel.Price]
    // O(1) lookups, built once. The equivalents on EnergyModel rebuild a
    // dictionary or linear-scan on every call, and these run once per record in
    // every aggregation pass — with ~23k records and several passes per Insights
    // render, that was ~100k dictionary rebuilds and the bulk of a multi-second
    // stall. Behaviour is identical; only the cost changed.
    private let tierByModel: [String: TierCoefficients]
    private let entryByModel: [String: EnergyModel.ModelEntry]

    /// User-overridable. Cache reads are ~95% of local token volume, so this
    /// single coefficient swings the total by ~4.6x across its plausible range
    /// — the dominant uncertainty in the whole model, and the reason it is a
    /// slider rather than a buried constant.
    var cacheReadFactorOverride: Double?

    init(energy: EnergyModel, pricing: PricingModel) {
        self.energy = energy
        self.pricing = pricing
        self.prices = pricing.allPrices
        var tiers: [String: TierCoefficients] = [:]
        var entries: [String: EnergyModel.ModelEntry] = [:]
        for m in energy.models {
            entries[m.id] = m
            if let t = energy.tiers[m.tier] { tiers[m.id] = t }
        }
        self.tierByModel = tiers
        self.entryByModel = entries
    }

    func hasCoefficients(for model: String) -> Bool {
        tierByModel[model] != nil && prices[model] != nil
    }

    /// Model metadata (tier, confidence) — O(1), cached.
    func entry(for model: String) -> EnergyModel.ModelEntry? { entryByModel[model] }

    /// Watt-hours at the given band edge. `nil` when the model is unrecognized
    /// — callers must surface that rather than coercing it to zero.
    func wattHours(_ r: UsageRecord, at edge: Band.Edge = .v) -> Double? {
        guard let t = tierByModel[r.model] else { return nil }
        let eIn = t.whPer1kInput.at(edge)
        let eOut = t.whPer1kOutput.at(edge)
        let readFactor = cacheReadFactorOverride ?? energy.defaults.cacheReadFactor.at(edge)
        let writeFactor = energy.defaults.cacheWriteFactor.at(edge)

        return (Double(r.input) * eIn
                + Double(r.cacheWrite) * eIn * writeFactor
                + Double(r.cacheRead) * eIn * readFactor
                + Double(r.output) * eOut) / 1000.0
    }

    /// USD from published per-MTok rates.
    func cost(_ r: UsageRecord) -> Double? {
        guard let p = prices[r.model] else { return nil }
        let m = pricing.cacheMultipliers
        // Split the write by TTL when the breakdown is present: the 1h premium
        // is 2x vs the 5m 1.25x, and Claude Code leans on 1h caching.
        let write: Double
        if r.cacheWrite5m + r.cacheWrite1h == 0 {
            write = Double(r.cacheWrite) * m.write5m
        } else {
            write = Double(r.cacheWrite5m) * m.write5m + Double(r.cacheWrite1h) * m.write1h
        }
        return (Double(r.input) * p.input
                + write * p.input
                + Double(r.cacheRead) * p.input * m.read
                + Double(r.output) * p.output) / 1_000_000.0
    }

    /// Replay the same token counts under a different model.
    ///
    /// An **upper bound** on savings: it holds turn count fixed, and a smaller
    /// model may need more turns to reach the same result. Never present the
    /// result as free.
    func counterfactual(_ records: [UsageRecord], as model: String) -> (wh: Double, usd: Double) {
        var wh = 0.0, usd = 0.0
        for r in records {
            var alt = r
            alt.model = model
            wh += wattHours(alt) ?? 0
            usd += cost(alt) ?? 0
        }
        return (wh, usd)
    }
}
