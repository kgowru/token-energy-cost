import Foundation

/// Per-file read offsets, so steady-state ingestion touches only new bytes.
///
/// A full cold index of the corpus happens once; after that each pass reads
/// only what was appended. Identity is `(inode, size)`: if the inode changes
/// the file was replaced, and if size shrank below our offset it was truncated
/// — either way, reparse from zero.
struct FileIndex: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var inode: UInt64
        var size: UInt64
        var offset: UInt64
        var mtime: Double
        /// Bytes after the last newline in the previous read — a file being
        /// appended to can be read mid-line.
        var tail: Data
    }

    private(set) var entries: [String: Entry] = [:]

    struct Prepared {
        var offset: UInt64
        var size: UInt64
        var inode: UInt64
        var rotated: Bool
    }

    /// Decide where to start reading this file. Returns nil when there is
    /// nothing new to read.
    mutating func prepare(for url: URL) -> Prepared? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value
        else { return nil }
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        guard let prior = entries[url.path] else {
            return Prepared(offset: 0, size: size, inode: inode, rotated: false)
        }
        // Replaced or truncated — the offset no longer means anything.
        if prior.inode != inode || size < prior.offset {
            entries[url.path] = nil
            return Prepared(offset: 0, size: size, inode: inode, rotated: true)
        }
        if size == prior.offset, mtime == prior.mtime { return nil }
        return Prepared(offset: prior.offset, size: size, inode: inode, rotated: false)
    }

    func pendingTail(for url: URL) -> Data { entries[url.path]?.tail ?? Data() }

    mutating func record(url: URL, offset: UInt64, size: UInt64, inode: UInt64, tail: Data) {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { ($0[.modificationDate] as? Date)?.timeIntervalSince1970 } ?? 0
        entries[url.path] = Entry(inode: inode, size: size, offset: offset,
                                  mtime: mtime, tail: tail)
    }

    // MARK: - Persistence

    static func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appending(path: "AgentSpend")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load() -> FileIndex {
        guard let dir = try? supportDirectory(),
              let data = try? Data(contentsOf: dir.appending(path: "file-index.json")),
              let idx = try? JSONDecoder().decode(FileIndex.self, from: data)
        else { return FileIndex() }
        return idx
    }

    func save() throws {
        let dir = try Self.supportDirectory()
        try JSONEncoder().encode(self).write(to: dir.appending(path: "file-index.json"),
                                             options: .atomic)
    }

    mutating func reset() { entries.removeAll() }
}
