import SwiftUI

/// Day-by-day spend. Today's number on its own has no meaning — the useful
/// question is whether today is normal, so the history is the primary view and
/// today is just the top row.
struct TodayView: View {
    @ObservedObject var engine: UsageEngine
    @AppStorage("historyDays") private var days = 14
    @State private var projectsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !engine.unrecognizedModels.isEmpty {
                Banner(text: "No price or energy figures yet for "
                       + engine.unrecognizedModels.sorted().joined(separator: ", ")
                       + ", so those requests count as zero.")
            }

            // Selector first: the headline below is the total for whichever
            // window is chosen, so the control has to read as its input. "1d"
            // makes the headline today's spend rather than a period total.
            Picker("", selection: $days) {
                Text("1d").tag(1)
                Text("14d").tag(14); Text("30d").tag(30); Text("90d").tag(90)
            }
            .pickerStyle(.segmented).labelsHidden()

            if days == 1 { todaySection } else { periodSection }
        }
    }

    // MARK: - Today (1d)

    @ViewBuilder
    private var todaySection: some View {
        let start = Calendar.current.startOfDay(for: Date())
        let today = engine.cachedDailySummaries(days: 1).last
        // "Typical" baseline from the trailing 30 days (a 1-day window has no
        // meaningful internal average to compare against). Memoized.
        let baseline = engine.cachedDailySummaries(days: 30).filter { $0.requests > 0 }
        let typical = baseline.isEmpty ? 0
            : baseline.reduce(0) { $0 + $1.usd } / Double(baseline.count)
        let projects = engine.byProject(engine.records(since: start))

        // Traffic-light color for today's spend relative to the 30d average:
        // green while under, yellow as it runs over, red once well past.
        // Uncolored (primary) until there's both a baseline and activity today.
        let overageColor: AnyShapeStyle = {
            guard typical > 0, let t = today, t.requests > 0 else {
                return AnyShapeStyle(.primary)
            }
            let ratio = t.usd / typical
            if ratio < 1.0 { return AnyShapeStyle(.green) }
            if ratio < 1.5 { return AnyShapeStyle(.yellow) }
            return AnyShapeStyle(.red)
        }()

        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Today").font(.caption).foregroundStyle(.secondary)
                Text(Format.usd(today?.usd ?? 0))
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(overageColor)
                Text("\(Format.wh(today?.wh ?? 0)) · \(today?.requests ?? 0) requests")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(Format.homeEnergy(today?.wh ?? 0, engine.energyModel.equivalences))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if typical > 0, let t = today, t.requests > 0 {
                let ratio = t.usd / typical
                // Plain-language comparison instead of a bare "0.2×" multiplier,
                // which readers have to mentally convert. Within ±10% reads as
                // "about normal"; otherwise it's a percentage above/below.
                let pct = Int((abs(ratio - 1) * 100).rounded())
                let phrase = abs(ratio - 1) < 0.1 ? "About normal"
                    : ratio < 1 ? "\(pct)% below normal"
                                : "\(pct)% above normal"
                // Mirror the "Today" column on the left: label, big number,
                // then a smaller detail line underneath.
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Average").font(.caption).foregroundStyle(.secondary)
                    Text(Format.usd(typical))
                        .font(.system(size: 28, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text(phrase)
                        .font(.caption2)
                        .foregroundStyle(ratio > 1.5 ? AnyShapeStyle(.orange)
                                                     : AnyShapeStyle(.secondary))
                }
            }
        }

        if today?.requests ?? 0 == 0 {
            Text("No activity yet today.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 20)
        } else {
            HourlyBars(hours: engine.hourlyActivity(since: start))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("project today").frame(maxWidth: .infinity, alignment: .leading)
                    Text("cost").frame(width: 58, alignment: .trailing)
                    Text("energy").frame(width: 64, alignment: .trailing)
                }
                .font(.caption2).foregroundStyle(.secondary)
                Divider()
                let shown = projectsExpanded ? projects : Array(projects.prefix(3))
                ForEach(shown, id: \.project) { p in
                    HStack {
                        Text(p.project).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Format.usd(p.usd)).frame(width: 58, alignment: .trailing)
                        Text(Format.wh(p.wh)).frame(width: 64, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption).monospacedDigit()
                }
                if projects.count > 3 {
                    Button(projectsExpanded
                           ? "Show less"
                           : "Show \(projects.count - 3) more") {
                        projectsExpanded.toggle()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Period (14d / 30d / 90d)

    @ViewBuilder
    private var periodSection: some View {
        let summaries = engine.cachedDailySummaries(days: days)
        let today = summaries.last
        let active = summaries.filter { $0.requests > 0 }
        let avg = active.isEmpty ? 0 : active.reduce(0) { $0 + $1.usd } / Double(active.count)
        let periodUsd = summaries.reduce(0) { $0 + $1.usd }
        let periodWh = summaries.reduce(0) { $0 + $1.wh }

        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Last \(days) days").font(.caption).foregroundStyle(.secondary)
                Text(Format.usd(periodUsd))
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Text("\(Format.wh(periodWh)) · "
                     + "\(Format.count(summaries.reduce(0) { $0 + $1.requests })) requests")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(Format.homeEnergy(periodWh, engine.energyModel.equivalences))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("Today").font(.caption).foregroundStyle(.secondary)
                Text(Format.usd(today?.usd ?? 0))
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .monospacedDigit()
                if avg > 0, let t = today {
                    let ratio = t.usd / avg
                    Text(String(format: "%.1f× the %@ avg", ratio, "\(days)d"))
                        .font(.caption2)
                        .foregroundStyle(ratio > 1.5 ? AnyShapeStyle(.orange)
                                                     : AnyShapeStyle(.tertiary))
                }
            }
        }

        DailyBars(summaries: summaries)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("day").frame(maxWidth: .infinity, alignment: .leading)
                Text("cost").frame(width: 58, alignment: .trailing)
                Text("energy").frame(width: 64, alignment: .trailing)
                Text("reqs").frame(width: 40, alignment: .trailing)
            }
            .font(.caption2).foregroundStyle(.secondary)
            Divider()

            // Newest first — the recent days are the ones you act on.
            ForEach(summaries.reversed().filter { $0.requests > 0 }) { d in
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(dayLabel(d.day))
                        if let p = d.topProject {
                            Text(p).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Format.usd(d.usd)).frame(width: 58, alignment: .trailing)
                    Text(Format.wh(d.wh)).frame(width: 64, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Text("\(d.requests)").frame(width: 40, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                .font(.caption).monospacedDigit()
            }
        }

        Divider()

        HStack {
            Text("\(active.count) active day\(active.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(Format.usd(avg)) · \(Format.wh(periodWh / Double(max(active.count, 1)))) per active day")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// Daily cost bars. Today is tinted so it reads against the rest at a glance.
/// Hovering a bar reads out that day's spend; the rest dim so the focus is clear.
struct DailyBars: View {
    let summaries: [UsageEngine.DaySummary]
    @State private var hovered: UsageEngine.DaySummary.ID?

    var body: some View {
        let maxV = summaries.map(\.usd).max() ?? 0
        let focus = summaries.first { $0.id == hovered }

        VStack(alignment: .leading, spacing: 3) {
            // Readout line — reserves its own height so the layout doesn't jump
            // as the hover moves on and off the chart.
            Group {
                if let d = focus {
                    Text(label(d.day)).foregroundStyle(.primary)
                    + Text("  \(Format.usd(d.usd)) · \(Format.wh(d.wh)) · "
                           + "\(Format.count(d.requests)) req").foregroundStyle(.secondary)
                } else {
                    Text("Hover a bar for that day").foregroundStyle(.tertiary)
                }
            }
            .font(.caption2).monospacedDigit().lineLimit(1)

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(summaries) { d in
                    // Full-height, full-slot hover target so the thin bars and
                    // the gaps between them are all easy to land on.
                    ZStack(alignment: .bottom) {
                        Color.clear
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Calendar.current.isDateInToday(d.day) ? Color.orange : Color.accentColor)
                            .opacity(opacity(for: d))
                            .frame(height: maxV == 0 ? 2 : max(2, 54 * d.usd / maxV))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        // On exit, only clear if this bar was the focused one —
                        // otherwise moving between adjacent bars would flicker.
                        if inside { hovered = d.id }
                        else if hovered == d.id { hovered = nil }
                    }
                    .help("\(label(d.day)): \(Format.usd(d.usd)) · \(Format.wh(d.wh))")
                }
            }
            .frame(height: 54)

            HStack {
                Text(summaries.first.map { $0.day.formatted(.dateTime.month(.abbreviated).day()) } ?? "")
                Spacer()
                if maxV > 0 { Text("peak \(Format.usd(maxV))") }
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func opacity(for d: UsageEngine.DaySummary) -> Double {
        if d.usd == 0 { return 0.12 }
        return hovered == nil || hovered == d.id ? 0.85 : 0.35
    }

    private func label(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
