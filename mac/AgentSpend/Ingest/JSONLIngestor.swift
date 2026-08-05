import Foundation

/// Incremental parser for Claude Code session logs.
///
/// Four things this has to get right, all learned the hard way in Phase 0
/// (see `tools/verify.py`, which asserts each against the real corpus):
///
///  1. **Recursive walk.** Sessions live at `<project>/<session>.jsonl`, but
///     subagent transcripts nest at `<project>/<session>/subagents/agent-*.jsonl`.
///     A one-level glob finds 143 of 623 files — 77% missing.
///  2. **Dedup on `message.id`, keeping max `output_tokens`.** ~52% of rows are
///     repeats. A streaming message is logged many times with a *partial*
///     output count; first-wins keeps the partial and undercounts total output
///     by 12.6%.
///  3. **Normalize dated model IDs**, or they match no coefficient and are
///     silently counted as zero.
///  4. **Buffer partial trailing lines.** Files are appended to live, so a read
///     can land mid-line.
struct JSONLIngestor {
    static let synthetic = "<synthetic>"

    struct Stats: Sendable {
        var filesScanned = 0
        var subagentFiles = 0
        var bytesRead: Int64 = 0
        var rawUsageRows = 0
        var duplicates = 0
        var supersededPartials = 0
        var synthetic = 0
        var unparseable = 0
        var rotatedFiles = 0
    }

    /// Only ~40% of lines carry usage. Byte-scanning for this before decoding
    /// avoids paying full JSON parse on the majority.
    private static let usageMarker = Array(#""usage":{"#.utf8)

    static func defaultRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/projects")
    }

    /// Enumerate every `.jsonl` beneath `root`, at any depth.
    static func sessionFiles(under root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.path < $1.path }
    }

    /// Parse everything past each file's recorded offset.
    ///
    /// Returns records keyed by `message.id`. The caller merges them into the
    /// store with the same max-output rule, so a streamed message split across
    /// two incremental passes still resolves correctly.
    static func ingest(
        root: URL,
        index: inout FileIndex,
        stats: inout Stats
    ) -> [String: UsageRecord] {
        ingest(files: sessionFiles(under: root), index: &index, stats: &stats)
    }

    /// Ingest a specific set of files.
    ///
    /// The watcher knows exactly which logs changed, so a live refresh passes
    /// just those rather than re-stat'ing the whole tree — with ~600 session
    /// files and a burst every couple of seconds, the difference is the whole
    /// cost of staying current.
    static func ingest(
        files: [URL],
        index: inout FileIndex,
        stats: inout Stats
    ) -> [String: UsageRecord] {
        var best: [String: UsageRecord] = [:]

        for url in files {
            let isSubagent = url.path.contains("/subagents/")
            stats.filesScanned += 1
            if isSubagent { stats.subagentFiles += 1 }

            guard let entry = index.prepare(for: url) else { continue }
            if entry.rotated { stats.rotatedFiles += 1 }

            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }

            do { try handle.seek(toOffset: entry.offset) } catch { continue }
            guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { continue }
            stats.bytesRead += Int64(chunk.count)

            // A file being appended to can end mid-line. Keep the remainder and
            // prepend it on the next pass rather than dropping or misparsing it.
            var data = index.pendingTail(for: url)
            data.append(chunk)

            var consumed = 0
            var lineStart = data.startIndex
            while let nl = data[lineStart...].firstIndex(of: 0x0A) {
                let line = data[lineStart..<nl]
                consumed = nl + 1 - data.startIndex
                lineStart = nl + 1
                ingest(line: line, isSubagent: isSubagent, into: &best, stats: &stats)
            }

            let tail = data[lineStart...]
            index.record(url: url,
                         offset: entry.offset + UInt64(chunk.count),
                         size: entry.size,
                         inode: entry.inode,
                         tail: tail.isEmpty ? Data() : Data(tail))
            _ = consumed
        }
        return best
    }

    private static func ingest(
        line: Data.SubSequence,
        isSubagent: Bool,
        into best: inout [String: UsageRecord],
        stats: inout Stats
    ) {
        guard line.count > usageMarker.count, contains(line, usageMarker) else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any]
        else {
            stats.unparseable += 1
            return
        }

        stats.rawUsageRows += 1

        guard let key = (msg["id"] as? String) ?? (obj["requestId"] as? String) else { return }
        let output = usage["output_tokens"] as? Int ?? 0

        if let prior = best[key] {
            stats.duplicates += 1
            // Keep the completed message, not the first partial one.
            guard output > prior.output else { return }
            stats.supersededPartials += 1
        }

        guard let rawModel = msg["model"] as? String else { return }
        if rawModel == synthetic {
            stats.synthetic += 1
            return
        }

        let cc = usage["cache_creation"] as? [String: Any] ?? [:]
        best[key] = UsageRecord(
            id: key,
            timestamp: (obj["timestamp"] as? String).flatMap(parseTimestamp),
            model: ModelID.normalize(rawModel),
            input: usage["input_tokens"] as? Int ?? 0,
            output: output,
            cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
            cacheWrite5m: cc["ephemeral_5m_input_tokens"] as? Int ?? 0,
            cacheWrite1h: cc["ephemeral_1h_input_tokens"] as? Int ?? 0,
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
            cwd: obj["cwd"] as? String,
            gitBranch: obj["gitBranch"] as? String,
            sessionId: obj["sessionId"] as? String,
            isSidechain: obj["isSidechain"] as? Bool ?? false,
            isSubagent: isSubagent
        )
    }

    /// Parse `2026-07-28T03:29:56.267Z` by hand.
    ///
    /// `ISO8601DateFormatter` isn't `Sendable`, so a shared instance can't be a
    /// static let under strict concurrency, and allocating one per row across
    /// ~46k rows is wasteful. The format here is fixed and UTC, so a direct
    /// parse is both simpler and considerably faster.
    static func parseTimestamp(_ s: String) -> Date? {
        let u = Array(s.utf8)
        guard u.count >= 19, u[4] == 0x2D, u[7] == 0x2D, u[10] == 0x54,
              u[13] == 0x3A, u[16] == 0x3A else { return nil }

        func num(_ lo: Int, _ hi: Int) -> Int? {
            var v = 0
            for i in lo..<hi {
                let d = Int(u[i]) - 48
                guard (0...9).contains(d) else { return nil }
                v = v * 10 + d
            }
            return v
        }
        guard let year = num(0, 4), let month = num(5, 7), let day = num(8, 10),
              let hour = num(11, 13), let minute = num(14, 16), let second = num(17, 19)
        else { return nil }

        // Days since the Unix epoch — civil-date algorithm (Howard Hinnant),
        // valid for the whole proleptic Gregorian range.
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468

        var t = Double(days * 86_400 + hour * 3600 + minute * 60 + second)

        // Optional fractional seconds.
        if u.count > 20, u[19] == 0x2E {
            var i = 20, scale = 0.1
            while i < u.count, (48...57).contains(u[i]) {
                t += Double(Int(u[i]) - 48) * scale
                scale /= 10
                i += 1
            }
        }
        return Date(timeIntervalSince1970: t)
    }

    /// Substring search over raw bytes — cheaper than decoding to String.
    private static func contains(_ haystack: Data.SubSequence, _ needle: [UInt8]) -> Bool {
        guard let first = needle.first else { return true }
        var i = haystack.startIndex
        let limit = haystack.index(haystack.endIndex, offsetBy: -needle.count)
        while i <= limit {
            guard let hit = haystack[i...].firstIndex(of: first), hit <= limit else { return false }
            var match = true
            for (k, b) in needle.enumerated() where haystack[hit + k] != b {
                match = false
                break
            }
            if match { return true }
            i = hit + 1
        }
        return false
    }
}
