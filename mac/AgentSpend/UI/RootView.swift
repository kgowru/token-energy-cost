import SwiftUI

struct RootView: View {
    @ObservedObject var engine: UsageEngine
    @State private var tab: Tab

    /// `initialTab` lets the renderer snapshot each pane. Otherwise `--tab X`
    /// opens straight to one, which a screenshot can reach without needing
    /// accessibility permission to click.
    init(engine: UsageEngine, initialTab: Tab? = nil) {
        self.engine = engine
        let args = CommandLine.arguments
        let fromArgs = args.firstIndex(of: "--tab").flatMap { i -> Tab? in
            guard args.count > i + 1 else { return nil }
            return Tab(rawValue: args[i + 1].capitalized)
        }
        _tab = State(initialValue: initialTab ?? fromArgs ?? .today)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case today = "History", activity = "Activity", insights = "Insights", method = "Method"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            ScrollView {
                Group {
                    switch tab {
                    case .today:    TodayView(engine: engine)
                    case .activity: ActivityView(engine: engine)
                    case .insights: InsightsView(engine: engine)
                    case .method:   MethodologyView(engine: engine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            // Fills whatever the definite outer frame leaves over. Safe only
            // because that outer frame is concrete — see below.
            .frame(maxHeight: .infinity)

            Divider()
            FooterView(engine: engine)
        }
        // A fully definite size, both axes. MenuBarExtra's popover proposes its
        // own height during layout, and anything flexible here (a ScrollView
        // under `maxHeight`, say) can resolve that proposal to zero and render
        // an empty popover — which shipped once. A concrete frame can't.
        .frame(width: 420, height: 540)
        .background(
            // Records what the popover was actually laid out at, so the real
            // thing can be checked without needing to screenshot it. Neither
            // ImageRenderer nor NSHostingController.fittingSize reproduced the
            // collapse; only the live popover does.
            GeometryReader { geo in
                Color.clear.onAppear { LayoutProbe.record(geo.size) }
            }
        )
    }
}

/// Writes the popover's real laid-out size to the support directory on first
/// appearance. Exists because the collapse that shipped was invisible to every
/// offscreen check — the only faithful measurement is the live popover.
enum LayoutProbe {
    static func record(_ size: CGSize) {
        guard let dir = try? FileIndex.supportDirectory() else { return }
        let line = "popover laid out at \(Int(size.width))x\(Int(size.height))"
            + (size.height < 300 ? "  COLLAPSED" : "  ok") + "\n"
        try? line.write(to: dir.appending(path: "layout-probe.txt"),
                        atomically: true, encoding: .utf8)
    }
}

struct FooterView: View {
    @ObservedObject var engine: UsageEngine

    var body: some View {
        HStack(spacing: 8) {
            if engine.isRefreshing {
                ProgressView().controlSize(.small)
            } else if let t = engine.lastRefresh {
                Text("updated \(t.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") { Task { await engine.refresh() } }
                .disabled(engine.isRefreshing)
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct Stat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .rounded)).monospacedDigit()
        }
    }
}

struct Banner: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}
