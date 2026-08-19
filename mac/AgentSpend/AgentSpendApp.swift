import SwiftUI

@main
enum Main {
    static func main() {
        // Headless verification path, so the ingestor can be diffed against
        // tools/prototype.py without launching a UI.
        let args = CommandLine.arguments
        if args.contains("--selftest") { exit(SelfTest.run()) }
        if args.contains("--bench") { exit(MainActor.assumeIsolated { Bench.run() }) }
        if let i = args.firstIndex(of: "--verify") {
            let root = args.count > i + 1
                ? URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
                : JSONLIngestor.defaultRoot()
            exit(CLI.runVerify(root: root))
        }
        // Renders the same view hierarchy in an ordinary window. A menu bar
        // popover can't be opened programmatically without accessibility
        // permission, which makes this the practical way to eyeball the UI.
        if let i = args.firstIndex(of: "--render") {
            let dir = args.count > i + 1 ? args[i + 1] : "/tmp/te-render"
            exit(MainActor.assumeIsolated { Render.run(to: dir) })
        }
        if args.contains("--window") {
            PreviewApp.main()
            return
        }
        AgentSpendApp.main()
    }
}

struct AgentSpendApp: App {
    @StateObject private var engine: EngineBox = EngineBox()

    var body: some Scene {
        MenuBarExtra {
            Group {
                if let engine = engine.value {
                    RootView(engine: engine)
                } else {
                    VStack(spacing: 8) {
                        Text("Couldn't start").font(.headline)
                        Text(engine.failure ?? "unknown error")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(width: 320)
                }
            }
        } label: {
            if let engine = engine.value {
                MenuBarLabel(engine: engine)
            } else {
                Image(systemName: "bolt.slash")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// `UsageEngine.init` can throw (bad resources, unwritable support dir), which
/// `@StateObject` can't express directly.
@MainActor
final class EngineBox: ObservableObject {
    @Published var value: UsageEngine?
    @Published var failure: String?

    init() {
        do {
            let e = try UsageEngine()
            value = e
            Task {
                await e.refresh()
                e.startWatching()
            }
        } catch {
            failure = String(describing: error)
        }
    }
}

/// The always-visible bit. Deliberately terse — a menu bar item earns its space
/// by being glanceable.
struct MenuBarLabel: View {
    @ObservedObject var engine: UsageEngine
    @AppStorage("menuBarMetric") private var metric = MenuBarMetric.cost
    /// The recommendation set the user last saw by opening the popover. The "!"
    /// shows only while today's advice differs from it, so glancing at the menu
    /// clears the flag until something genuinely new turns up.
    @AppStorage("seenRecsSignature") private var seenRecs = ""

    var body: some View {
        let today = engine.records(since: Calendar.current.startOfDay(for: Date()))
        // A warning "!" when there's actionable advice for today the user hasn't
        // opened the popover to see yet — the same recommendations the Home and
        // Savings strips surface. Cleared once seen (see RootView.onAppear).
        let sig = engine.liveRecsSignature()
        let hasRecs = !sig.isEmpty && sig != seenRecs
        HStack(spacing: 3) {
            // `.small` brings the bolt to ~18px against the text's 16px so it
            // doesn't overshoot the digits. The alignment guide below is what
            // actually centers the two: digits have no descenders, so their ink
            // sits high in the line box and frame-centering leaves the bolt
            // reading low. Pinning the bolt's center to the text's *cap* center
            // (baseline − capHeight/2) lines their optical middles up.
            Image(systemName: "bolt.fill").imageScale(.small)
                .alignmentGuide(VerticalAlignment.center) { d in d[VerticalAlignment.center] }
            // The recommendations indicator is a "!" baked into the number's own
            // glyph run, not a second view: MenuBarExtra renders its label as a
            // single monochrome template image where only the first Image
            // survives, so a separate/colored badge would vanish or drop the bolt.
            Text((metric == .energy
                  ? Format.wh(engine.totalWattHours(today))
                  : Format.usd(engine.totalCost(today)))
                 + (hasRecs ? " !" : ""))
                .alignmentGuide(VerticalAlignment.center) { d in
                    // Optical center of the digits: half the cap height above
                    // the baseline, rather than the full line box's middle.
                    d[.firstTextBaseline] - NSFont.menuBarFont(ofSize: 11).capHeight / 2
                }
        }
        // The menu bar font, at the size AppKit renders the battery percentage
        // at — the default (13pt) is a quarter taller than everything beside it.
        .font(Font(NSFont.menuBarFont(ofSize: 11)))
    }
}

enum MenuBarMetric: String, CaseIterable, Identifiable {
    case energy, cost
    var id: String { rawValue }
    var label: String { self == .energy ? "Energy (Wh)" : "Cost ($)" }
}

/// Debug harness for `--window`. Same views, ordinary window.
struct PreviewApp: App {
    @StateObject private var engine = EngineBox()

    var body: some Scene {
        WindowGroup("AgentSpend (debug)") {
            Group {
                if let engine = engine.value {
                    RootView(engine: engine)
                } else {
                    Text(engine.failure ?? "starting…").padding()
                }
            }
            .frame(width: 420)
            .onAppear {
                // LSUIElement keeps the real app out of the Dock, which also
                // stops this debug window from being focusable. Opt back in.
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                // Pin to a known spot on the main screen so a verification
                // screenshot can target it precisely.
                // The window may not exist yet on first onAppear; re-apply
                // shortly after so placement is deterministic.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { place() }
                place()
            }
        }
        .windowResizability(.contentSize)
    }

    private func place() {
        guard let screen = NSScreen.screens.first else { return }
        for w in NSApp.windows {
            w.level = .floating
            w.setFrame(NSRect(x: screen.frame.minX + 40,
                              y: screen.frame.maxY - 780,
                              width: 420, height: 720), display: true)
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
