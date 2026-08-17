import Foundation

/// Coordinates ingest → store → estimate, and holds the state the UI renders.
@MainActor
final class UsageEngine: ObservableObject {
    @Published private(set) var records: [UsageRecord] = []
    @Published private(set) var stats = JSONLIngestor.Stats()
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    /// Models seen in the logs with no coefficient entry. Surfaced in the UI —
    /// counting them as zero would quietly understate everything.
    @Published private(set) var unrecognizedModels: Set<String> = []

    @Published var cacheReadFactor: Double {
        didSet { estimator.cacheReadFactorOverride = cacheReadFactor }
    }

    /// In-memory mirror of the store, keyed by `message.id`. Kept so a refresh
    /// can merge just the new rows instead of re-reading all ~22k records from
    /// SQLite — the watcher fires every couple of seconds during an active
    /// session, and a full reload each time is exactly the kind of waste this
    /// app exists to point at.
    private var byID: [String: UsageRecord] = [:]

    private(set) var estimator: Estimator
    private var index: FileIndex
    private let store: UsageStore
    private let root: URL
    private var watcher: ProjectsWatcher?

    // Memoization. The derived analytics are pure functions of (records,
    // cacheReadFactor). Caching them against a data-version means an open pane
    // recomputes only when the data genuinely changes — not on every incidental
    // @Published tick (the refresh spinner toggling, the "updated" timestamp),
    // and not when the watcher fires for a change that added no usage rows.
    // Deliberately NOT @Published: it's a cache, not state, and publishing it
    // would defeat the point.
    private var dataVersion = 0
    private struct DerivedCache {
        var version = -1
        var factor = Double.nan
        var insights: InsightsResult?
        var liveRecs: [Recommendation]?
        var sessions400: [SessionSummary]?
        var dailyByDays: [Int: [DaySummary]] = [:]
    }
    private var derived = DerivedCache()

    private func freshCache() -> DerivedCache {
        if derived.version == dataVersion, derived.factor == cacheReadFactor {
            return derived
        }
        derived = DerivedCache(version: dataVersion, factor: cacheReadFactor)
        return derived
    }

    init(root: URL = JSONLIngestor.defaultRoot()) throws {
        let (energy, pricing) = try Coefficients.load()
        self.root = root
        self.estimator = Estimator(energy: energy, pricing: pricing)
        self.cacheReadFactor = energy.defaults.cacheReadFactor.v
        self.index = FileIndex.load()
        self.store = try UsageStore(path: try UsageStore.defaultLocation())
        self.byID = Dictionary(((try? store.allRecords()) ?? []).map { ($0.id, $0) }) { a, _ in a }
        self.records = Array(byID.values)
        self.dataVersion = 1
        recomputeUnrecognized()
    }

    /// Begin watching for new session activity. Separate from `init` so the
    /// headless `--verify` / `--render` / `--selftest` paths don't start one.
    func startWatching() {
        guard watcher == nil else { return }
        watcher = ProjectsWatcher(root: root) { [weak self] changed in
            Task { @MainActor in await self?.refresh(files: changed) }
        }
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    var energyModel: EnergyModel { estimator.energy }

    /// Re-ingest. `files == nil` walks the whole tree (launch, manual refresh,
    /// periodic backstop); otherwise only the paths the watcher flagged.
    func refresh(files: [URL]? = nil) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Parsing runs off the main actor; everything it touches is a value
        // type, so the result crosses back cleanly.
        let result = await Self.parseOffMain(root: root, files: files, index: index)

        do {
            try store.upsert(result.records.values)
            try result.index.save()
            index = result.index

            // Merge with the same max-output rule the store uses: a streamed
            // message can arrive first as a partial and later as complete, and
            // a stale partial must never clobber the finished count.
            var changed = false
            for (id, r) in result.records {
                if let prior = byID[id], r.output <= prior.output { continue }
                byID[id] = r
                changed = true
            }
            if changed {
                records = Array(byID.values)
                dataVersion += 1   // invalidates the memoized analytics
            }
            stats = result.stats
            lastRefresh = Date()
            errorMessage = nil
            recomputeUnrecognized()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private struct ParseResult: Sendable {
        var records: [String: UsageRecord]
        var index: FileIndex
        var stats: JSONLIngestor.Stats
    }

    private nonisolated static func parseOffMain(root: URL, files: [URL]?,
                                                 index: FileIndex) async -> ParseResult {
        await Task.detached(priority: .utility) {
            var idx = index
            var stats = JSONLIngestor.Stats()
            let out = files.map { JSONLIngestor.ingest(files: $0, index: &idx, stats: &stats) }
                ?? JSONLIngestor.ingest(root: root, index: &idx, stats: &stats)
            return ParseResult(records: out, index: idx, stats: stats)
        }.value
    }

    private func recomputeUnrecognized() {
        unrecognizedModels = Set(records.map(\.model).filter { !estimator.hasCoefficients(for: $0) })
    }

    // MARK: - Derived views

    func records(since: Date) -> [UsageRecord] {
        records.filter { ($0.timestamp ?? .distantPast) >= since }
    }

    func totalWattHours(_ rs: [UsageRecord], at edge: Band.Edge = .v) -> Double {
        rs.reduce(0) { $0 + (estimator.wattHours($1, at: edge) ?? 0) }
    }

    func totalCost(_ rs: [UsageRecord]) -> Double {
        rs.reduce(0) { $0 + (estimator.cost($1) ?? 0) }
    }

    func tokenTotals(_ rs: [UsageRecord]) -> TokenTotals {
        rs.reduce(into: TokenTotals()) { acc, r in
            acc.requests += 1
            acc.input += r.input
            acc.cacheWrite += r.cacheWrite
            acc.cacheWrite5m += r.cacheWrite5m
            acc.cacheWrite1h += r.cacheWrite1h
            acc.cacheRead += r.cacheRead
            acc.output += r.output
        }
    }

    struct ModelRow: Identifiable, Sendable {
        var id: String { model }
        let model: String
        let totals: TokenTotals
        let wh: Double
        let usd: Double
        let confidence: String
    }

    func byModel(_ rs: [UsageRecord]) -> [ModelRow] {
        var grouped: [String: [UsageRecord]] = [:]
        for r in rs { grouped[r.model, default: []].append(r) }
        return grouped.map { model, rows in
            ModelRow(model: model,
                     totals: tokenTotals(rows),
                     wh: totalWattHours(rows),
                     usd: totalCost(rows),
                     confidence: estimator.entry(for: model)?.confidence ?? "none")
        }
        .sorted { $0.wh > $1.wh }
    }

    func byProject(_ rs: [UsageRecord]) -> [(project: String, wh: Double, usd: Double)] {
        var grouped: [String: [UsageRecord]] = [:]
        for r in rs { grouped[r.project, default: []].append(r) }
        return grouped.map { (project: $0.key,
                              wh: totalWattHours($0.value),
                              usd: totalCost($0.value)) }
            .sorted { $0.wh > $1.wh }
    }

    /// Daily energy for the trailing `days`, oldest first — the sparkline.
    func dailyWattHours(days: Int = 14) -> [(day: Date, wh: Double)] {
        dailySummaries(days: days).map { (day: $0.day, wh: $0.wh) }
    }

    struct DaySummary: Identifiable, Sendable {
        var id: Date { day }
        let day: Date
        let wh: Double
        let usd: Double
        let requests: Int
        let totals: TokenTotals
        /// Model that accounted for the most spend that day.
        let topModel: String?
        let topProject: String?
    }

    /// Day-by-day spend, oldest first. Days with no activity are included as
    /// zeroes so gaps in the history are visible rather than silently skipped.
    func dailySummaries(days: Int = 14) -> [DaySummary] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date()).addingTimeInterval(-Double(days - 1) * 86_400)

        var byDay: [Date: [UsageRecord]] = [:]
        for r in records {
            guard let ts = r.timestamp, ts >= start else { continue }
            byDay[cal.startOfDay(for: ts), default: []].append(r)
        }

        return (0..<days).map { i in
            let day = cal.startOfDay(for: start.addingTimeInterval(Double(i) * 86_400))
            let rows = byDay[day] ?? []
            return DaySummary(
                day: day,
                wh: totalWattHours(rows),
                usd: totalCost(rows),
                requests: rows.count,
                totals: tokenTotals(rows),
                topModel: byModel(rows).first?.model,
                topProject: byProject(rows).first?.project
            )
        }
    }

    struct SessionSummary: Identifiable, Sendable {
        let id: String
        let project: String
        let branch: String?
        let started: Date
        let lastActivity: Date
        let models: [String]
        let requests: Int
        let wh: Double
        let usd: Double
        let totals: TokenTotals
        let subagentRequests: Int

        /// Average prompt size per request. A high value means long context,
        /// which is where energy and cost actually run away — prefill attention
        /// is O(n^2) and each decode step re-reads a growing KV cache.
        var avgContextTokens: Int {
            requests == 0 ? 0 : (totals.cacheRead + totals.cacheWrite + totals.input) / requests
        }
    }

    /// Sessions ordered by most recent activity.
    func recentSessions(limit: Int = 12, since: Date? = nil) -> [SessionSummary] {
        var grouped: [String: [UsageRecord]] = [:]
        for r in records {
            guard let sid = r.sessionId else { continue }
            if let since, (r.timestamp ?? .distantPast) < since { continue }
            grouped[sid, default: []].append(r)
        }

        return grouped.compactMap { sid, rows -> SessionSummary? in
            let stamps = rows.compactMap(\.timestamp)
            guard let last = stamps.max(), let first = stamps.min() else { return nil }
            var models: [String: Double] = [:]
            for r in rows { models[r.model, default: 0] += estimator.cost(r) ?? 0 }
            return SessionSummary(
                id: sid,
                project: rows.first?.project ?? "unknown",
                branch: rows.first(where: { $0.gitBranch != nil })?.gitBranch,
                started: first,
                lastActivity: last,
                models: models.sorted { $0.value > $1.value }.map(\.key),
                requests: rows.count,
                wh: totalWattHours(rows),
                usd: totalCost(rows),
                totals: tokenTotals(rows),
                subagentRequests: rows.filter(\.isSubagent).count
            )
        }
        .sorted { $0.lastActivity > $1.lastActivity }
        .prefix(limit)
        .map { $0 }
    }

    /// Requests bucketed by hour of the day, for the activity histogram.
    func hourlyActivity(since: Date) -> [(hour: Int, requests: Int, usd: Double)] {
        let cal = Calendar.current
        var buckets: [Int: (Int, Double)] = [:]
        for r in records {
            guard let ts = r.timestamp, ts >= since else { continue }
            let h = cal.component(.hour, from: ts)
            var e = buckets[h] ?? (0, 0)
            e.0 += 1
            e.1 += estimator.cost(r) ?? 0
            buckets[h] = e
        }
        return (0..<24).map { (hour: $0, requests: buckets[$0]?.0 ?? 0, usd: buckets[$0]?.1 ?? 0) }
    }

    /// Savings if the same tokens had run on `model`. Upper bound — holds turn
    /// count fixed, and a cheaper model may need more turns.
    func counterfactuals(_ rs: [UsageRecord],
                         candidates: [String] = ["claude-opus-4-8", "claude-sonnet-5",
                                                 "claude-haiku-4-5"])
        -> [(model: String, wh: Double, usd: Double, whRatio: Double, usdSaved: Double)] {
        let baseWh = totalWattHours(rs)
        let baseUsd = totalCost(rs)
        return candidates.compactMap { m in
            guard estimator.hasCoefficients(for: m) else { return nil }
            let (wh, usd) = estimator.counterfactual(rs, as: m)
            return (model: m, wh: wh, usd: usd,
                    whRatio: baseWh == 0 ? 0 : wh / baseWh,
                    usdSaved: baseUsd - usd)
        }
    }

    // MARK: - Memoized products for the panes

    typealias Counterfactual = (model: String, wh: Double, usd: Double,
                                whRatio: Double, usdSaved: Double)

    struct InsightsResult: Sendable {
        let recommendations: [Recommendation]
        let counterfactuals: [Counterfactual]
        let totalUsd: Double
        let totalWh: Double
        let headlineSavings: Double
    }

    /// Everything the Insights pane needs, computed once per data change. This
    /// is the expensive one (grouping, per-session summaries, ranked
    /// recommendations); memoizing it is what makes the tab open instantly on an
    /// unchanged corpus instead of recomputing every time the view redraws.
    func insightsResult() -> InsightsResult {
        var cache = freshCache()
        if let cached = cache.insights { return cached }

        let sessions = cachedSessions400()
        let projects = byProject(records)
        let recs = Recommender.build(records: records, estimator: estimator,
                                     sessions: sessions, projects: projects)
        let result = InsightsResult(
            recommendations: recs,
            counterfactuals: counterfactuals(records),
            totalUsd: totalCost(records),
            totalWh: totalWattHours(records),
            headlineSavings: recs.compactMap(\.savingUsd).reduce(0, +))

        cache.insights = result
        derived = cache
        return result
    }

    /// The same analysis run over today alone.
    ///
    /// The Savings pane answers "what should I change about how I work", from
    /// the whole corpus. This answers a different question — "is what I'm doing
    /// right now costing me" — and the whole-corpus recommendations can't: a
    /// habit you fixed last week still dominates a 90-day ranking, and the
    /// session burning money this afternoon is a rounding error against it.
    ///
    /// Thresholds inside the recommender are absolute dollars, so on a quiet
    /// day this correctly returns nothing rather than manufacturing advice.
    func liveRecommendations() -> [Recommendation] {
        var cache = freshCache()
        if let r = cache.liveRecs { return r }

        let start = Calendar.current.startOfDay(for: Date())
        let today = records(since: start)
        let recs = today.isEmpty ? [] : Recommender.build(
            records: today,
            estimator: estimator,
            sessions: recentSessions(limit: 100, since: start),
            projects: byProject(today))
            // Concentration and bare observations are orientation, not actions
            // — "most of your spend is one project" is worth knowing once, not
            // worth a slot in a two-item strip you glance at mid-task. The
            // Savings pane still ranks them.
            .filter { $0.kind != .concentration && $0.kind != .observation }

        cache.liveRecs = recs
        derived = cache
        return recs
    }

    /// A stable fingerprint of today's actionable recommendations. Built from
    /// their ids — which are identity-based (model / session / project), not the
    /// dollar figures that drift through the day — so it only changes when a
    /// genuinely different suggestion appears. The menu bar uses it to tell
    /// advice the user hasn't opened the popover to see yet ("!") from advice
    /// they already have.
    func liveRecsSignature() -> String {
        liveRecommendations().map(\.id).sorted().joined(separator: ",")
    }

    /// The full session list (used by Insights and, filtered, by Activity),
    /// memoized so both panes share one grouping pass.
    func cachedSessions400() -> [SessionSummary] {
        var cache = freshCache()
        if let s = cache.sessions400 { return s }
        let s = recentSessions(limit: 400)
        cache.sessions400 = s
        derived = cache
        return s
    }

    /// Memoized day-by-day history. History is the default pane, so this runs on
    /// every launch; caching it keeps window switches and incidental redraws off
    /// the hot path.
    func cachedDailySummaries(days: Int) -> [DaySummary] {
        var cache = freshCache()
        if let d = cache.dailyByDays[days] { return d }
        let d = dailySummaries(days: days)
        cache.dailyByDays[days] = d
        derived = cache
        return d
    }
}
