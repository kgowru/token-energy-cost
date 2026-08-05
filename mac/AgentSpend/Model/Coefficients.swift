import Foundation

/// A coefficient with an uncertainty band. Nothing in this app is a bare
/// number — no vendor publishes per-token energy, so every figure is a modeled
/// estimate and the UI is required to render it as one.
struct Band: Decodable, Sendable {
    let v: Double
    let lo: Double
    let hi: Double
    var confidence: String?
    var note: String?

    /// Band edge selector. `lo`/`hi` are worst-case bounds, not a confidence
    /// interval — the coefficients are not independent and won't all sit at an
    /// extreme simultaneously.
    enum Edge: String, CaseIterable, Sendable { case lo, v, hi }

    func at(_ e: Edge) -> Double {
        switch e {
        case .lo: return lo
        case .v: return v
        case .hi: return hi
        }
    }
}

struct TierCoefficients: Decodable, Sendable {
    let whPer1kInput: Band
    let whPer1kOutput: Band
}

struct EnergyModel: Decodable, Sendable {
    struct Defaults: Decodable, Sendable {
        let cacheReadFactor: Band
        let cacheWriteFactor: Band
        let outputToInputRatio: Band
    }

    struct ModelEntry: Decodable, Sendable {
        let id: String
        let tier: String
        let basis: String
        let confidence: String
        var note: String?
    }

    struct Grid: Decodable, Sendable {
        let defaultCentsPerKwh: Double
        let defaultGridGramsCO2ePerKwh: Double
    }

    struct Equivalences: Decodable, Sendable {
        // Only the home anchor is consumed by the UI. The JSON keeps the other
        // sourced factors as reference; extra keys decode away harmlessly.
        let usHomeKwhPerDay: Double
    }

    let schemaVersion: Int
    let generated: String
    let boundary: String
    let defaults: Defaults
    let tiers: [String: TierCoefficients]
    let models: [ModelEntry]
    let caveats: [String]
    let equivalences: Equivalences
    let grid: Grid

    private var tierByModel: [String: String] { Dictionary(models.map { ($0.id, $0.tier) }) { a, _ in a } }

    func tier(for model: String) -> TierCoefficients? {
        guard let t = tierByModel[model] else { return nil }
        return tiers[t]
    }

    func entry(for model: String) -> ModelEntry? { models.first { $0.id == model } }
}

struct PricingModel: Decodable, Sendable {
    struct CacheMultipliers: Decodable, Sendable {
        let read: Double
        let write5m: Double
        let write1h: Double
    }

    struct Price: Decodable, Sendable {
        let id: String
        let input: Double   // USD per million tokens
        let output: Double
        let tier: String
        let confidence: String
        var why: String?
    }

    struct UnknownModels: Decodable, Sendable {
        let entries: [Price]
    }

    let schemaVersion: Int
    let cacheMultipliers: CacheMultipliers
    let models: [Price]
    let unknownModels: UnknownModels

    /// Published models plus the observed-but-uncatalogued ones, which are
    /// priced at their apparent tier and flagged rather than silently dropped.
    var allPrices: [String: Price] {
        Dictionary((models + unknownModels.entries).map { ($0.id, $0) }) { a, _ in a }
    }
}

enum Coefficients {
    static func load() throws -> (EnergyModel, PricingModel) {
        let d = JSONDecoder()
        return (try d.decode(EnergyModel.self, from: resource("energy-model")),
                try d.decode(PricingModel.self, from: resource("pricing")))
    }

    private static func resource(_ name: String) throws -> Data {
        // Packaged .app: the JSONs live directly in Contents/Resources, which
        // Bundle.main resolves reliably on every machine. Try this FIRST and,
        // when it succeeds, never touch Bundle.module — which is important
        // because Bundle.module *fatal-errors* on first access if SwiftPM's
        // resource bundle isn't exactly where it expects. On the build machine
        // it happens to resolve via a path baked into ./.build; on a fresh
        // machine that path is absent and the app crashes at launch. Guarding it
        // behind a successful Bundle.main lookup avoids ever evaluating it in the
        // shipped app.
        if let url = Bundle.main.url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        // Dev only (running straight from `swift build`, where Bundle.main is the
        // bare CLI tool and has no Resources): fall back to the SPM bundle, which
        // is present next to the build product here.
        if let url = Bundle.module.url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        throw CocoaError(.fileReadNoSuchFile, userInfo: [
            NSLocalizedDescriptionKey: "coefficient file \(name).json is missing from the app bundle"])
    }
}
