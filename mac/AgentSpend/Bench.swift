import Foundation

/// `AgentSpend --bench`
///
/// Times the derived computations the panes trigger, over the real corpus in
/// the store, so a performance change can be seen as a number rather than a
/// feeling. Nothing here calls an LLM — every figure is local arithmetic — so
/// the cost being measured is CPU, not tokens.
@MainActor
enum Bench {
    static func run() -> Int32 {
        do {
            let engine = try UsageEngine()
            let n = engine.records.count
            guard n > 0 else { print("store empty — run the app once first"); return 1 }
            print("corpus: \(n) records\n")

            time("dailySummaries(90)")   { _ = engine.dailySummaries(days: 90) }
            time("byProject(all)")       { _ = engine.byProject(engine.records) }
            time("recentSessions(400)")  { _ = engine.recentSessions(limit: 400) }
            time("totalCost(all)")       { _ = engine.totalCost(engine.records) }
            time("counterfactuals(all)") { _ = engine.counterfactuals(engine.records) }

            let sessions = engine.recentSessions(limit: 400)
            let projects = engine.byProject(engine.records)
            time("Recommender.build") {
                _ = Recommender.build(records: engine.records, estimator: engine.estimator,
                                      sessions: sessions, projects: projects)
            }

            // What the Insights pane now actually calls. The first call computes
            // and caches (single-shot, or min-of-3 would hide it behind the memo
            // hits); every subsequent redraw on unchanged data is the memo hit.
            print("")
            once("insightsResult() — first hit (cold cache)") {
                _ = engine.insightsResult()
            }
            time("insightsResult() — memo hit (redraw, no new data)") {
                _ = engine.insightsResult()
            }
            once("cachedDailySummaries(90) — first hit") {
                _ = engine.cachedDailySummaries(days: 90)
            }
            time("cachedDailySummaries(90) — memo hit") {
                _ = engine.cachedDailySummaries(days: 90)
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("bench failed: \(error)\n".utf8))
            return 1
        }
    }

    private static func time(_ label: String, _ body: () -> Void) {
        let clock = ContinuousClock()
        // A few iterations so a sub-millisecond op still reports a stable figure.
        var best = Duration.seconds(1_000)
        for _ in 0..<3 {
            let d = clock.measure(body)
            if d < best { best = d }
        }
        report(label, best)
    }

    /// Single run — for cache-sensitive measurements where a repeat would hit
    /// the memo and report the wrong number.
    private static func once(_ label: String, _ body: () -> Void) {
        report(label, ContinuousClock().measure(body))
    }

    private static func report(_ label: String, _ d: Duration) {
        let ms = Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1e15
        print(String(format: "  %-52s %8.2f ms", (label as NSString).utf8String!, ms))
    }
}
