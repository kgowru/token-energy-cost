import Foundation

/// Watches `~/.claude/projects` and fires when session logs change.
///
/// FSEvents rather than polling: an energy-reporting tool that spins the CPU to
/// stay current would undercut its own premise. Notifications are coalesced,
/// because an active Claude Code session appends constantly and each burst
/// should cause at most one re-ingest.
///
/// A slow timer runs alongside as a backstop — FSEvents can miss events if the
/// stream is starved or the directory is recreated, and a menu bar number that
/// silently stops updating is worse than one that updates a minute late.
/// Mutable state (`stream`, `pending`, `fallback`) is confined to `queue` after
/// construction; `start` happens-before any callback can fire, and `stop` runs
/// from `deinit`, when no other reference can still be racing it.
final class ProjectsWatcher: @unchecked Sendable {
    private let root: URL
    private let coalesce: TimeInterval
    /// Receives the `.jsonl` paths that changed, or `nil` for the periodic
    /// backstop, which asks for a full rescan.
    private let onChange: @Sendable ([URL]?) -> Void

    private let queue = DispatchQueue(label: "dev.local.agentspend.fsevents")
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var fallback: DispatchSourceTimer?
    /// Paths accumulated since the last coalesced flush.
    private var dirty: Set<String> = []

    init(root: URL,
         coalesce: TimeInterval = 2.0,
         fallbackInterval: TimeInterval = 60.0,
         onChange: @escaping @Sendable ([URL]?) -> Void) {
        self.root = root
        self.coalesce = coalesce
        self.onChange = onChange
        start(fallbackInterval: fallbackInterval)
    }

    deinit { stop() }

    private func start(fallbackInterval: TimeInterval) {
        // The FSEvents callback is a bare C function pointer and can't capture
        // context, so pass `self` through the stream's info pointer. Unretained:
        // `stop()` runs from deinit, so the stream never outlives its owner.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        // FSEvents hands back the paths that changed. Using them lets a refresh
        // touch only those files instead of re-stat'ing all ~600 session logs
        // on every burst.
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ProjectsWatcher>.fromOpaque(info).takeUnretainedValue()
            // `eventPaths` is a CFArray of CFString only because the stream is
            // created with kFSEventStreamCreateFlagUseCFTypes below. Without
            // that flag it is a C char** and this cast would read garbage.
            guard let list = unsafeBitCast(paths, to: CFArray.self) as? [String] else { return }
            let changed = list.prefix(Int(count)).filter { $0.hasSuffix(".jsonl") }
            guard !changed.isEmpty else { return }
            watcher.schedule(Array(changed))
        }

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            coalesce / 2,
            // UseCFTypes is load-bearing: it makes `eventPaths` a CFArray of
            // CFString. Remove it and the callback's cast reads a raw char**
            // as an object and segfaults.
            UInt32(kFSEventStreamCreateFlagFileEvents
                   | kFSEventStreamCreateFlagNoDefer
                   | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + fallbackInterval, repeating: fallbackInterval)
        // Capture the callback, not self — the handler is @Sendable and the
        // timer is cancelled in stop() before self goes away.
        let notify = onChange
        t.setEventHandler { notify(nil) }   // nil = full rescan backstop
        t.resume()
        fallback = t
    }

    /// Collapse a burst of writes into a single callback, accumulating the
    /// affected paths so nothing is lost while the timer is pending.
    private func schedule(_ paths: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.dirty.formUnion(paths)
            self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let batch = self.dirty
                self.dirty.removeAll()
                self.onChange(batch.map(URL.init(fileURLWithPath:)))
            }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + self.coalesce, execute: work)
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        fallback?.cancel()
        fallback = nil
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }
}
