import AppKit
import SwiftUI

/// `AgentSpend --render <dir>`
///
/// Renders each pane offscreen to a PNG. Verifying the UI by screenshotting the
/// live menu bar needs accessibility permission and captures whatever else is
/// on screen; this renders only our own view tree, deterministically, into a
/// file. Reads from the store populated by a prior run, so it needs no ingest.
@MainActor
enum Render {
    static func run(to dir: String) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        do {
            let out = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let engine = try UsageEngine()

            if engine.records.isEmpty {
                print("store is empty — run the app once so it can ingest, then retry")
                return 1
            }

            // The History headline is the total for the selected window, so
            // the windows must actually produce different totals — otherwise
            // the selector looks live but the number never moves.
            var lastUsd = -1.0
            for window in [1, 14, 30, 90] {
                let s = engine.dailySummaries(days: window)
                let usd = s.reduce(0) { $0 + $1.usd }
                let wh = s.reduce(0) { $0 + $1.wh }
                let reqs = s.reduce(0) { $0 + $1.requests }
                print(String(format: "  %2dd  $%-9.0f %7.1f kWh  %6d reqs", window, usd,
                             wh / 1000, reqs))
                guard usd > lastUsd else {
                    print("  FAIL: \(window)d total did not exceed the shorter window")
                    return 1
                }
                lastUsd = usd
                // Snapshot each window so the headline can be eyeballed too.
                UserDefaults.standard.set(window, forKey: "historyDays")
                try snap(TodayView(engine: engine), "content-history-\(window)d", out)
            }
            UserDefaults.standard.set(14, forKey: "historyDays")

            // Panes on their own: verifies the CONTENT is right. ImageRenderer
            // cannot rasterize a ScrollView's children, so this has to bypass
            // RootView's scroll container to show anything at all.
            try snap(TodayView(engine: engine), "content-history", out)
            try snap(ActivityView(engine: engine), "content-activity", out)
            try snap(InsightsView(engine: engine), "content-insights", out)
            try snap(MethodologyView(engine: engine), "content-method", out)

            // Render the WHOLE RootView at its natural size, with no frame
            // imposed — this is what MenuBarExtra does, and rendering only the
            // inner panes is exactly how an empty popover shipped once already.
            for tab in RootView.Tab.allCases {
                let size = try snap(RootView(engine: engine, initialTab: tab),
                                    "pane-\(tab.rawValue.lowercased())", out, width: nil)
                let ok = size.height > 300
                print(String(format: "  %-10s %.0fx%.0f  %@", (tab.rawValue as NSString).utf8String!,
                             size.width, size.height,
                             ok ? "ok" : "COLLAPSED — popover would render empty"))
                if !ok { return 1 }
            }

            print("rendered \(RootView.Tab.allCases.count) panes from "
                  + "\(engine.records.count) records to \(out.path)")

            // The check that actually matters. MenuBarExtra hosts its popover
            // through AppKit, so NSHostingController.fittingSize is the size the
            // real popover gets — ImageRenderer proposes a concrete size and
            // reports a healthy 535 even for a layout that collapses in the
            // popover, which is exactly how an empty menu bar shipped once.
            for tab in RootView.Tab.allCases {
                let host = NSHostingController(rootView: RootView(engine: engine,
                                                                  initialTab: tab))
                let fitting = host.view.fittingSize
                let ok = fitting.height > 300
                print(String(format: "  hosted %-9s %.0fx%.0f  %@",
                             (tab.rawValue as NSString).utf8String!,
                             fitting.width, fitting.height,
                             ok ? "ok" : "COLLAPSED — popover renders empty"))
                if !ok { return 1 }
            }

            // ImageRenderer can't rasterize interactive controls, so the Slider
            // shows as a placeholder above. Its appearance is stock SwiftUI; the
            // part that could genuinely be wrong is the binding, so exercise
            // that directly rather than trusting a screenshot.
            let before = engine.totalWattHours(engine.records)
            engine.cacheReadFactor = 0.01
            let low = engine.totalWattHours(engine.records)
            engine.cacheReadFactor = 0.30
            let high = engine.totalWattHours(engine.records)
            engine.cacheReadFactor = 0.10
            let restored = engine.totalWattHours(engine.records)

            guard low < before, high > before, high / low > 4.0,
                  abs(restored - before) < 1e-6 else {
                print("FAIL: cacheReadFactor binding did not drive recomputation "
                      + "(before \(before), low \(low), high \(high), restored \(restored))")
                return 1
            }
            print(String(format: "cacheReadFactor binding OK: %.1f kWh at 0.01 → "
                                 + "%.1f kWh at 0.30 (%.1fx), restores to %.1f kWh",
                         low / 1000, high / 1000, high / low, restored / 1000))
            return 0
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            return 1
        }
    }

    @discardableResult
    private static func snap(_ view: some View, _ name: String, _ dir: URL,
                             width: CGFloat? = 396) throws -> CGSize {
        let base = width.map { view.frame(width: $0, alignment: .topLeading).padding(12)
            .background(Color(nsColor: .windowBackgroundColor)).eraseToAny() }
            ?? view.background(Color(nsColor: .windowBackgroundColor)).eraseToAny()
        let renderer = ImageRenderer(content: base)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: dir.appending(path: "\(name).png"))
        return image.size
    }
}


private extension View {
    func eraseToAny() -> AnyView { AnyView(self) }
}
