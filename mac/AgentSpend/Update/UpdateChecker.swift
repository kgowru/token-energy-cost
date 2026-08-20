import Foundation

/// Asks GitHub whether a newer release exists, at most once a day.
///
/// This is the app's only network call, and it is deliberately the smallest one
/// that answers the question: an unauthenticated GET for a version string. It
/// sends no identifier, no usage data, and no query parameters — nothing about
/// you goes out, which is why the "nothing leaves your Mac" promise survives it
/// intact. It can be switched off in the Method pane.
///
/// It also never downloads or installs anything. Clicking the footer badge opens
/// the release page in a browser and the upgrade stays a deliberate, visible act
/// (drag to Applications). That choice is what keeps this ~100 lines with no
/// dependency, instead of Sparkle's framework, appcast, and second signing key —
/// which would roughly triple a 1 MB download to automate a drag done twice a
/// year, in an app whose pitch is that it has no dependencies.
@MainActor
final class UpdateChecker: ObservableObject {
    /// A singleton because the footer is rebuilt every time the popover opens and
    /// the result should outlive it — and because `RootView` is constructed from
    /// three places (the menu bar app, `--window`, and the `--render` snapshotter)
    /// that shouldn't each have to thread one through.
    static let shared = UpdateChecker()

    struct Available: Equatable {
        let version: String
        let url: URL
    }

    @Published private(set) var available: Available?

    /// `releases/latest` rather than `releases`: it already excludes drafts and
    /// prereleases, so a tagged beta can't page users who wanted stable.
    ///
    /// The slug is `agent-spend`, the repo's current name. The old
    /// `token-energy-cost` still resolves, but only through GitHub's rename
    /// redirect — which stops working the moment anyone else claims that name,
    /// and would then silently disable update checks for every shipped copy.
    private static let endpoint = URL(
        string: "https://api.github.com/repos/kgowru/agent-spend/releases/latest")!

    /// Once a day. GitHub allows 60 unauthenticated requests an hour per IP, so
    /// even a shared office address would need a thousand-odd users before the
    /// limit came into view.
    private static let interval: TimeInterval = 24 * 60 * 60

    private static let enabledKey = "updateCheckEnabled"
    private static let lastCheckKey = "lastUpdateCheck"

    private let defaults: UserDefaults
    private let session: URLSession
    private var inFlight = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Ephemeral: no cache, no cookies, no credential storage touching disk.
        // A version check has nothing worth persisting, and this way it leaves no
        // trace on the filesystem either.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// Defaults to on for a fresh install; `object(forKey:)` distinguishes "never
    /// set" from an explicit `false`, which `bool(forKey:)` alone cannot.
    var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// The running app's marketing version, e.g. `"0.1.1"`.
    ///
    /// `nil` when there's no Info.plist to read — `swift run`, the test harness.
    /// The checker stays silent in that case rather than comparing a tag against
    /// a guess and badging every development build.
    /// `nonisolated` here and on the comparison helpers below: they're pure
    /// functions of their inputs, and `--selftest` exercises them from outside
    /// the main actor.
    nonisolated static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Checks if a day has passed since the last successful attempt.
    ///
    /// Silent on every failure — offline, rate-limited, GitHub down, tag renamed.
    /// A menu bar app that reports its own inability to reach the internet is
    /// noise about something the user can't act on, and the cost of missing a
    /// check is that the badge appears a day later than it might have.
    func checkIfDue() async {
        guard isEnabled, !inFlight, let current = Self.currentVersion else { return }
        let last = defaults.double(forKey: Self.lastCheckKey)
        let now = Date().timeIntervalSince1970
        // `now < last` guards a backwards clock change, which would otherwise
        // park the next check up to a day in the future.
        guard last == 0 || now - last >= Self.interval || now < last else { return }

        inFlight = true
        defer { inFlight = false }

        guard let release = try? await fetch() else { return }
        // Stamped only on success, so a spell offline retries at the next
        // opportunity instead of counting as a check that happened.
        defaults.set(now, forKey: Self.lastCheckKey)

        let latest = Self.normalize(release.tagName)
        available = Self.isNewer(latest, than: current)
            ? Available(version: latest, url: release.htmlURL)
            : nil
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private func fetch() async throws -> Release {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Load-bearing: the GitHub API rejects requests with no User-Agent
        // outright (403), so omitting this fails every time, everywhere.
        request.setValue("AgentSpend/\(Self.currentVersion ?? "dev")",
                         forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Strips the `v` the tags carry (`v0.1.1` → `0.1.1`) so the comparison sees
    /// the same shape as the Info.plist value.
    nonisolated static func normalize(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        return s
    }

    /// Compares dotted numeric versions component-wise.
    ///
    /// Not a string compare: that ranks `"0.1.10"` below `"0.1.9"` and would
    /// strand everyone on the tenth patch release of a line.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// `"0.2.0-beta.1"` → `[0, 2, 0]`. Trailing prerelease text is dropped rather
    /// than ordered: `releases/latest` doesn't serve prereleases anyway, so the
    /// only job here is to not crash on one.
    nonisolated private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }
}
