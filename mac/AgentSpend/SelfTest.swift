import Foundation

/// `AgentSpend --selftest`
///
/// Covers the behaviours the `--verify` diff against `tools/prototype.py` can't
/// reach: incremental reads, file rotation, partial trailing lines, and the
/// store's upsert rules.
///
/// These are plain assertions rather than XCTest because the installed Xcode
/// predates this macOS and its XCTest can't load — and requiring an Xcode
/// reinstall to run the tests would be a poor trade. No dependencies, runs
/// anywhere the app runs.
struct SelfTest {
    private var failures: [String] = []
    private var passed = 0
    private var tmp: URL!

    static func run() -> Int32 {
        var t = SelfTest()
        return t.execute()
    }

    // MARK: - Assertions

    private mutating func ok(_ cond: Bool, _ what: String, _ line: Int = #line) {
        if cond { passed += 1 } else { failures.append("L\(line): \(what)") }
    }

    private mutating func eq<T: Equatable>(_ a: T, _ b: T, _ what: String, _ line: Int = #line) {
        if a == b { passed += 1 } else { failures.append("L\(line): \(what) — got \(a), want \(b)") }
    }

    private mutating func close(_ a: Double, _ b: Double, _ tol: Double,
                                _ what: String, _ line: Int = #line) {
        if abs(a - b) <= tol { passed += 1 }
        else { failures.append("L\(line): \(what) — got \(a), want \(b)") }
    }

    // MARK: - Fixtures

    private func row(id: String, model: String = "claude-opus-4-8", output: Int = 100,
                     input: Int = 10, cacheRead: Int = 1000, cacheWrite: Int = 50) -> String {
        """
        {"type":"assistant","timestamp":"2026-07-28T03:29:56.267Z","cwd":"/w/proj",\
        "gitBranch":"main","sessionId":"s1","isSidechain":false,"requestId":"req_\(id)",\
        "message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":\(input),\
        "output_tokens":\(output),"cache_creation_input_tokens":\(cacheWrite),\
        "cache_read_input_tokens":\(cacheRead),\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":\(cacheWrite)}}}}
        """
    }

    private func project(_ name: String) throws -> URL {
        let d = tmp.appending(path: name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func ingestAll(_ index: inout FileIndex) -> ([String: UsageRecord], JSONLIngestor.Stats) {
        var stats = JSONLIngestor.Stats()
        let out = JSONLIngestor.ingest(root: tmp, index: &index, stats: &stats)
        return (out, stats)
    }

    private mutating func freshTmp() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "te-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    // MARK: - Driver

    private mutating func execute() -> Int32 {
        do {
            let (energy, pricing) = try Coefficients.load()
            try modelIDs()
            try timestamps()
            try dedup()
            try recursiveWalk()
            try incremental()
            try store()
            try estimator(energy, pricing)
        } catch {
            failures.append("threw: \(error)")
        }
        if let tmp { try? FileManager.default.removeItem(at: tmp) }

        if failures.isEmpty {
            print("all \(passed) checks passed")
            return 0
        }
        print("\(passed) passed, \(failures.count) FAILED")
        for f in failures { print("  ✗ \(f)") }
        return 1
    }

    // MARK: - Cases

    private mutating func modelIDs() throws {
        eq(ModelID.normalize("claude-haiku-4-5-20251001"), "claude-haiku-4-5",
           "dated ID normalizes")
        eq(ModelID.normalize("claude-opus-4-5-20251101"), "claude-opus-4-5",
           "dated ID normalizes")
        // Aliases, and anything merely ending in digits, must be untouched.
        eq(ModelID.normalize("claude-opus-4-8"), "claude-opus-4-8", "alias untouched")
        eq(ModelID.normalize("claude-sonnet-5"), "claude-sonnet-5", "alias untouched")
        eq(ModelID.normalize("claude-fable-5"), "claude-fable-5", "alias untouched")
    }

    private mutating func timestamps() throws {
        close(JSONLIngestor.parseTimestamp("2026-07-28T03:29:56.267Z")?
            .timeIntervalSince1970 ?? -1, 1785209396.267, 0.001, "fractional seconds")
        close(JSONLIngestor.parseTimestamp("2026-07-28T03:29:56Z")?
            .timeIntervalSince1970 ?? -1, 1785209396, 0.001, "no fractional part")
        close(JSONLIngestor.parseTimestamp("1970-01-01T00:00:00Z")?
            .timeIntervalSince1970 ?? -1, 0, 0.001, "unix epoch")
        // Leap day, to exercise the civil-date algorithm.
        close(JSONLIngestor.parseTimestamp("2024-02-29T12:00:00Z")?
            .timeIntervalSince1970 ?? -1, 1709208000, 0.001, "leap day")
        ok(JSONLIngestor.parseTimestamp("not-a-date") == nil, "garbage rejected")
    }

    private mutating func dedup() throws {
        // A streaming message is logged repeatedly with a growing output count.
        // Keeping the first would undercount output — the priciest token class.
        try freshTmp()
        let f = try project("p").appending(path: "s.jsonl")
        try ([row(id: "m1", output: 3), row(id: "m1", output: 412), row(id: "m1", output: 87)]
            .joined(separator: "\n") + "\n").write(to: f, atomically: true, encoding: .utf8)

        var index = FileIndex()
        let (recs, stats) = ingestAll(&index)
        eq(recs.count, 1, "streamed repeats collapse to one record")
        eq(recs["m1"]?.output, 412, "keeps the completed message, not the first partial")
        eq(stats.duplicates, 2, "duplicate count")
        eq(stats.rawUsageRows, 3, "raw row count")

        try freshTmp()
        let g = try project("p").appending(path: "s.jsonl")
        try ([row(id: "m1"), row(id: "m2", model: "<synthetic>")].joined(separator: "\n") + "\n")
            .write(to: g, atomically: true, encoding: .utf8)
        var idx2 = FileIndex()
        let (r2, s2) = ingestAll(&idx2)
        eq(r2.count, 1, "synthetic rows excluded")
        eq(s2.synthetic, 1, "synthetic counted")
    }

    private mutating func recursiveWalk() throws {
        // Subagent logs nest two levels below session logs; a one-level glob
        // misses 77% of a real corpus.
        try freshTmp()
        let p = try project("proj")
        try (row(id: "top") + "\n").write(to: p.appending(path: "session.jsonl"),
                                          atomically: true, encoding: .utf8)
        let sub = p.appending(path: "session-id/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try (row(id: "sub") + "\n").write(to: sub.appending(path: "agent-x.jsonl"),
                                          atomically: true, encoding: .utf8)

        var index = FileIndex()
        let (recs, stats) = ingestAll(&index)
        eq(recs.count, 2, "finds both session and subagent transcripts")
        eq(stats.subagentFiles, 1, "subagent file counted")
        eq(recs["sub"]?.isSubagent, true, "subagent flagged")
        eq(recs["top"]?.isSubagent, false, "session not flagged as subagent")
    }

    private mutating func incremental() throws {
        try freshTmp()
        let f = try project("p").appending(path: "s.jsonl")
        try (row(id: "m1") + "\n").write(to: f, atomically: true, encoding: .utf8)

        var index = FileIndex()
        let (first, _) = ingestAll(&index)
        eq(first.count, 1, "initial read")

        let (second, stats2) = ingestAll(&index)
        ok(second.isEmpty, "unchanged file is not re-read")
        eq(Int(stats2.bytesRead), 0, "no bytes re-read when nothing changed")

        var h = try FileHandle(forWritingTo: f)
        try h.seekToEnd()
        try h.write(contentsOf: Data((row(id: "m2") + "\n").utf8))
        try h.close()
        let (third, _) = ingestAll(&index)
        eq(Array(third.keys), ["m2"], "only the appended record comes back")

        // Partial trailing line: files are appended to live, so a read can land
        // mid-line. The remainder must be buffered, not dropped or misparsed.
        try freshTmp()
        let g = try project("p").appending(path: "s.jsonl")
        let full = row(id: "m1") + "\n"
        let cut = full.index(full.startIndex, offsetBy: full.count / 2)
        try String(full[..<cut]).write(to: g, atomically: true, encoding: .utf8)

        var idx = FileIndex()
        let (partial, _) = ingestAll(&idx)
        ok(partial.isEmpty, "half a line does not parse")

        h = try FileHandle(forWritingTo: g)
        try h.seekToEnd()
        try h.write(contentsOf: Data(String(full[cut...]).utf8))
        try h.close()
        let (complete, cstats) = ingestAll(&idx)
        eq(complete.count, 1, "completed line appears exactly once")
        eq(complete["m1"]?.output, 100, "buffered line parses intact")
        eq(cstats.unparseable, 0, "no parse errors from the split")

        // Truncation invalidates the stored offset entirely.
        try freshTmp()
        let t = try project("p").appending(path: "s.jsonl")
        try ([row(id: "m1"), row(id: "m2")].joined(separator: "\n") + "\n")
            .write(to: t, atomically: true, encoding: .utf8)
        var idx3 = FileIndex()
        _ = ingestAll(&idx3)
        try (row(id: "m3") + "\n").write(to: t, atomically: true, encoding: .utf8)
        let (after, stats3) = ingestAll(&idx3)
        eq(stats3.rotatedFiles, 1, "truncation detected")
        eq(Array(after.keys), ["m3"], "reparsed from zero after truncation")
    }

    private mutating func store() throws {
        try freshTmp()
        let s = try UsageStore(path: tmp.appending(path: "t.sqlite"))
        let base = UsageRecord(id: "m1", timestamp: Date(timeIntervalSince1970: 1785209396),
                               model: "claude-opus-4-8", input: 10, output: 50, cacheWrite: 5,
                               cacheWrite5m: 0, cacheWrite1h: 5, cacheRead: 100, cwd: "/w/p",
                               gitBranch: "main", sessionId: "sess", isSidechain: false,
                               isSubagent: false)
        try s.upsert([base])
        try s.upsert([base])
        eq(try s.count(), 1, "re-ingest does not duplicate")
        eq(try s.count(), try s.distinctIDCount(), "request_id stays unique")

        var grown = base; grown.output = 900
        try s.upsert([grown])
        eq(try s.allRecords().first?.output, 900, "later, fuller output count wins")

        var stale = base; stale.output = 7
        try s.upsert([stale])
        eq(try s.allRecords().first?.output, 900, "a stale partial cannot clobber it")
        eq(try s.count(), 1, "still one row")

        // Full field round-trip.
        try freshTmp()
        let s2 = try UsageStore(path: tmp.appending(path: "t2.sqlite"))
        let r = UsageRecord(id: "m1", timestamp: Date(timeIntervalSince1970: 1785209396),
                            model: "claude-fable-5", input: 1, output: 2, cacheWrite: 3,
                            cacheWrite5m: 4, cacheWrite1h: 5, cacheRead: 6, cwd: "/w/proj",
                            gitBranch: "feat", sessionId: "sess", isSidechain: true,
                            isSubagent: true)
        try s2.upsert([r])
        eq(try s2.allRecords().first, r, "all fields round-trip through sqlite")

        func mk(_ id: String, _ model: String, _ out: Int) -> UsageRecord {
            UsageRecord(id: id, timestamp: Date(), model: model, input: 1, output: out,
                        cacheWrite: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 10,
                        cwd: nil, gitBranch: nil, sessionId: nil, isSidechain: false,
                        isSubagent: false)
        }
        try freshTmp()
        let s3 = try UsageStore(path: tmp.appending(path: "t3.sqlite"))
        try s3.upsert([mk("a", "claude-opus-4-8", 10), mk("b", "claude-opus-4-8", 20),
                       mk("c", "claude-sonnet-5", 5)])
        let t = try s3.totals(groupedBy: "model")
        eq(t["claude-opus-4-8"]?.output, 30, "grouped output sums")
        eq(t["claude-opus-4-8"]?.requests, 2, "grouped request counts")
        eq(t["claude-sonnet-5"]?.output, 5, "grouped by model")
    }

    private mutating func estimator(_ energy: EnergyModel, _ pricing: PricingModel) throws {
        var est = Estimator(energy: energy, pricing: pricing)

        let r = UsageRecord(id: "m", timestamp: nil, model: "claude-opus-4-8", input: 1000,
                            output: 1000, cacheWrite: 1000, cacheWrite5m: 1000, cacheWrite1h: 0,
                            cacheRead: 1000, cwd: nil, gitBranch: nil, sessionId: nil,
                            isSidechain: false, isSubagent: false)
        // frontier-large: 0.30 Wh/1k in, 1.20 Wh/1k out; read 0.10x, write 1.0x
        let wantWh = (1000 * 0.30 + 1000 * 0.30 * 1.0 + 1000 * 0.30 * 0.10 + 1000 * 1.20) / 1000.0
        close(est.wattHours(r) ?? -1, wantWh, 1e-9, "energy matches hand computation")
        // $5/MTok in, $25/MTok out; 5m write premium 1.25x, read 0.1x
        let wantUsd = (1000 * 5.0 + 1000 * 1.25 * 5.0 + 1000 * 5.0 * 0.1 + 1000 * 25.0) / 1_000_000
        close(est.cost(r) ?? -1, wantUsd, 1e-12, "cost matches hand computation")

        // The 1h cache-write premium is 2x vs the 5m 1.25x.
        func w(_ w5: Int, _ w1h: Int) -> UsageRecord {
            UsageRecord(id: "m", timestamp: nil, model: "claude-opus-4-8", input: 0, output: 0,
                        cacheWrite: w5 + w1h, cacheWrite5m: w5, cacheWrite1h: w1h, cacheRead: 0,
                        cwd: nil, gitBranch: nil, sessionId: nil, isSidechain: false,
                        isSubagent: false)
        }
        close(est.cost(w(1_000_000, 0)) ?? -1, 6.25, 1e-9, "5m cache write priced at 1.25x")
        close(est.cost(w(0, 1_000_000)) ?? -1, 10.0, 1e-9, "1h cache write priced at 2x")

        // Silently coercing an unknown model to zero is the failure mode that
        // makes a tool like this quietly wrong.
        let unknown = UsageRecord(id: "m", timestamp: nil, model: "claude-from-the-future",
                                  input: 100, output: 100, cacheWrite: 0, cacheWrite5m: 0,
                                  cacheWrite1h: 0, cacheRead: 0, cwd: nil, gitBranch: nil,
                                  sessionId: nil, isSidechain: false, isSubagent: false)
        ok(est.wattHours(unknown) == nil, "unknown model yields nil energy, not zero")
        ok(est.cost(unknown) == nil, "unknown model yields nil cost, not zero")
        ok(!est.hasCoefficients(for: unknown.model), "unknown model reported as unrecognized")

        for m in energy.models {
            ok(est.hasCoefficients(for: m.id), "cataloged model \(m.id) resolves")
        }

        let big = UsageRecord(id: "m", timestamp: nil, model: "claude-opus-4-8", input: 1000,
                              output: 1000, cacheWrite: 1000, cacheWrite5m: 0,
                              cacheWrite1h: 1000, cacheRead: 100_000, cwd: nil, gitBranch: nil,
                              sessionId: nil, isSidechain: false, isSubagent: false)
        let lo = est.wattHours(big, at: .lo) ?? 0
        let mid = est.wattHours(big, at: .v) ?? 0
        let hi = est.wattHours(big, at: .hi) ?? 0
        ok(lo < mid && mid < hi, "band is ordered lo < v < hi")

        // ~95% of real token volume is cache reads, so this one coefficient
        // moves the total more than any model-choice decision does.
        let realistic = UsageRecord(id: "m", timestamp: nil, model: "claude-opus-4-8",
                                    input: 8_000, output: 17_000, cacheWrite: 215_000,
                                    cacheWrite5m: 0, cacheWrite1h: 215_000,
                                    cacheRead: 4_250_000, cwd: nil, gitBranch: nil,
                                    sessionId: nil, isSidechain: false, isSubagent: false)
        est.cacheReadFactorOverride = 0.01
        let low = est.wattHours(realistic) ?? 0
        est.cacheReadFactorOverride = 0.30
        let high = est.wattHours(realistic) ?? 1
        ok(high / low > 4.0, "cacheReadFactor swings the total ~4.6x across its band")
        est.cacheReadFactorOverride = nil

        let rs = [UsageRecord(id: "m", timestamp: nil, model: "claude-opus-4-8", input: 1000,
                              output: 1000, cacheWrite: 0, cacheWrite5m: 0, cacheWrite1h: 0,
                              cacheRead: 10_000, cwd: nil, gitBranch: nil, sessionId: nil,
                              isSidechain: false, isSubagent: false)]
        let haiku = est.counterfactual(rs, as: "claude-haiku-4-5")
        ok(haiku.wh > 0 && haiku.wh < (est.wattHours(rs[0]) ?? 0),
           "counterfactual on a smaller model is cheaper but non-zero")

        // Cache efficiency is a prompt-side measure; output is never cacheable.
        let tt = TokenTotals(requests: 1, input: 100, cacheWrite: 100, cacheWrite5m: 0,
                             cacheWrite1h: 100, cacheRead: 800, output: 999_999)
        close(tt.cacheEfficiency, 0.8, 1e-12, "cache efficiency ignores output tokens")
    }
}
