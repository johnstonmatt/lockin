import SwiftUI
import Charts
import AppKit
import LockInCore

// Validated (dataviz validate_palette.js) against white and #1e1e1e card surfaces, all pairs.
extension WorkPhase {
    var color: Color {
        switch self {
        case .work: return Color(light: 0x1baf7a, dark: 0x199e70)
        case .overtime: return Color(light: 0x8b5cf6, dark: 0x9d74f7)
        case .break: return Color(light: 0x2a78d6, dark: 0x3987e5)
        case .pause: return Color(light: 0xeb6834, dark: 0xd95926)
        }
    }
    var label: String {
        switch self {
        case .work: return "Work"
        case .overtime: return "Overtime"
        case .break: return "Break"
        case .pause: return "Pause"
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
}

private let surface = Color(nsColor: .controlBackgroundColor)
private func hours(_ seconds: Double) -> String { WorkStats.format(seconds) }

struct HistoryView: View {
    @EnvironmentObject var store: Store
    @State private var period: HistoryPeriod = .week
    @State private var offset = 0
    @State private var pinnedDay: Date?

    var body: some View {
        let stats = WorkStats(sessions: store.journal.sessions, now: store.now)
        let range = stats.range(period, offset: offset)
        let totals = stats.totals(in: range)
        let buckets = stats.buckets(period, in: range)
        let day = focusDay(stats: stats, range: range, buckets: buckets)
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                Picker("Period", selection: $period) {
                    ForEach(HistoryPeriod.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Spacer()
                if offset != 0 { Button("Now") { offset = 0; pinnedDay = nil } }
                Button { offset -= 1; pinnedDay = nil } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous \(period.rawValue.lowercased())")
                Text(title(range)).font(.headline).monospacedDigit().frame(minWidth: 150)
                Button { offset += 1; pinnedDay = nil } label: { Image(systemName: "chevron.right") }
                    .disabled(offset >= 0).accessibilityLabel("Next \(period.rawValue.lowercased())")
            }
            .onChange(of: period) { _, _ in offset = 0; pinnedDay = nil }

            if store.journal.sessions.isEmpty {
                Card {
                    Text("Your working hours will appear here").font(.headline)
                    Text("Plan and start a session on the Focus page. Every minute of work, break and pause is recorded and charted here.").foregroundStyle(.secondary)
                }
            } else {
                Summary(stats: stats, period: period, offset: offset, range: range, totals: totals, nounPhrase: nounPhrase)
                Card {
                    Text(period == .year ? "Hours by month" : "Hours by day").font(.headline)
                    HoursChart(period: period, buckets: buckets) { pinnedDay = $0 }
                    HStack(spacing: 18) {
                        LegendKey(label: "Worked") { RoundedRectangle(cornerRadius: 2).fill(WorkPhase.work.color).frame(width: 9, height: 9) }
                        LegendKey(label: "Overtime") { RoundedRectangle(cornerRadius: 2).fill(WorkPhase.overtime.color).frame(width: 9, height: 9) }
                        LegendKey(label: "Planned") { Rectangle().fill(Color.primary).frame(width: 12, height: 2) }
                        Spacer()
                        if period != .year { Text("Click a day to see how it unfolded").foregroundStyle(.secondary) }
                    }.font(.caption)
                }
                if let day {
                    let dayRange = stats.day(containing: day)
                    let intervals = stats.intervals(in: dayRange)
                    Card {
                        HStack(alignment: .firstTextBaseline) {
                            Text("How \(dayName(day)) unfolded").font(.headline)
                            Spacer()
                            if pinnedDay != nil { Button("Back to today") { pinnedDay = nil }.buttonStyle(.pointer(.link)).font(.caption) }
                        }
                        DayTimeline(intervals: intervals, now: store.now)
                    }
                }
                Card {
                    Text("When you work").font(.headline)
                    RhythmChart(stats: stats, cells: stats.rhythm(in: range))
                }
                SessionList(sessions: stats.sessions(in: range).reversed(), now: store.now) { pinnedDay = $0 }
            }
        }
    }

    /// The pinned day, else today, else the last worked day in the shown period.
    private func focusDay(stats: WorkStats, range: DateInterval, buckets: [HistoryBucket]) -> Date? {
        if let pinnedDay, range.contains(pinnedDay) { return pinnedDay }
        if range.contains(store.now) { return store.now }
        return stats.intervals(in: range).last?.start
    }
    private func title(_ range: DateInterval) -> String {
        let last = range.end.addingTimeInterval(-1)
        switch period {
        case .week: return "\(range.start.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))"
        case .month: return range.start.formatted(.dateTime.month(.wide).year())
        case .year: return range.start.formatted(.dateTime.year())
        }
    }
    private var nounPhrase: String {
        let noun = period.rawValue.lowercased()
        switch offset {
        case 0: return "this \(noun)"
        case -1: return "last \(noun)"
        default: return "in this \(noun)"
        }
    }
    private func dayName(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "today" }
        if calendar.isDateInYesterday(day) { return "yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

private struct Summary: View {
    let stats: WorkStats; let period: HistoryPeriod; let offset: Int
    let range: DateInterval; let totals: PhaseTotals; let nounPhrase: String
    var body: some View {
        let worked = totals.worked
        let target = stats.target(in: range)
        let previous = stats.previousWork(period, offset: offset)
        let days = stats.daysWorked(in: range)
        Card {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Worked \(nounPhrase)").foregroundStyle(.secondary)
                    Text(hours(worked)).font(.system(size: 52, weight: .semibold, design: .rounded))
                    if target > 0 {
                        ProgressTrack(fraction: worked / target).frame(width: 260)
                        Text("\(Int((worked / target * 100).rounded()))% of \(hours(target)) planned").font(.callout).foregroundStyle(.secondary)
                    }
                    if previous > 0 || worked > 0 {
                        let delta = worked - previous
                        Label("\(delta >= 0 ? "+" : "−")\(hours(abs(delta))) vs \(offset == 0 ? "same point last" : "previous") \(period.rawValue.lowercased())",
                              systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 18) {
                    GridRow {
                        Stat(value: "\(days)", label: days == 1 ? "Day worked" : "Days worked")
                        Stat(value: days > 0 ? hours(worked / Double(days)) : "—", label: "Average per day worked")
                    }
                    GridRow {
                        Stat(value: hours(stats.longestStretch(in: range)), label: "Longest stretch")
                        Stat(value: hours(totals[.break] + totals[.pause]), label: "Breaks and pauses")
                    }
                }.padding(.top, 6)
            }
        }
    }
}

private struct Stat: View {
    let value: String; let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(minWidth: 130, alignment: .leading)
    }
}

private struct ProgressTrack: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(WorkPhase.work.color.opacity(0.18))
                Capsule().fill(WorkPhase.work.color).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }.frame(height: 8)
    }
}

private struct LegendKey<Swatch: View>: View {
    let label: String
    @ViewBuilder let swatch: Swatch
    var body: some View { HStack(spacing: 6) { swatch; Text(label) } }
}

private struct Tooltip<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 3) { content }
            .font(.caption).padding(.horizontal, 10).padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .fixedSize().allowsHitTesting(false)
    }
}

/// Pointer tracking over a chart's plot area, plus a tooltip that stays inside the chart.
private struct HoverOverlay<Tip: View>: View {
    let proxy: ChartProxy
    let onHover: (CGPoint?) -> Void
    var onTap: (() -> Void)?
    @ViewBuilder let tooltip: (CGPoint) -> Tip
    @State private var point: CGPoint?
    var body: some View {
        GeometryReader { geo in
            let plot = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let location) = phase {
                            point = location
                            onHover(CGPoint(x: location.x - plot.minX, y: location.y - plot.minY))
                        } else { point = nil; onHover(nil) }
                    }
                    .onTapGesture { onTap?() }
                if let point {
                    tooltip(point)
                        .position(x: min(max(point.x, 110), geo.size.width - 110), y: max(point.y - 44, 24))
                }
            }
        }
    }
}

private struct HoursChart: View {
    let period: HistoryPeriod
    let buckets: [HistoryBucket]
    let onSelect: (Date) -> Void
    @State private var hovered: Date?
    private var unit: Calendar.Component { period.bucket }
    private var barWidth: CGFloat { period == .month ? 12 : 24 }
    var body: some View {
        Chart {
            ForEach(buckets) { bucket in
                // Overtime stacks on top of regular work.
                ForEach([WorkPhase.work, .overtime], id: \.self) { phase in
                    let base = phase == .overtime ? bucket.totals[.work] : 0
                    if bucket.totals[phase] > 0 {
                        BarMark(x: .value("Date", bucket.start, unit: unit), yStart: .value("Hours", base / 3600),
                                yEnd: .value("Hours", (base + bucket.totals[phase]) / 3600), width: .fixed(barWidth))
                            .foregroundStyle(phase.color)
                            .cornerRadius(4)
                            .opacity(emphasis(bucket.start))
                            .accessibilityLabel(label(bucket.start) + (phase == .overtime ? ", overtime" : ""))
                            .accessibilityValue(phase == .overtime ? hours(bucket.totals[.overtime]) : workedText(bucket))
                    }
                }
                if bucket.target > 0 {
                    RectangleMark(x: .value("Date", bucket.start, unit: unit), y: .value("Planned", bucket.target / 3600),
                                  width: .fixed(barWidth + 8), height: .fixed(2))
                        .foregroundStyle(Color.primary)
                        .accessibilityHidden(true)
                }
            }
        }
        .chartXScale(domain: (buckets.first?.start ?? .now)...(buckets.last?.end ?? .now))
        .chartXAxis {
            AxisMarks(values: .stride(by: unit, count: period == .month ? 5 : 1)) { _ in
                AxisValueLabel(format: format, centered: true)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(.primary.opacity(0.08))
                AxisValueLabel { if let h = value.as(Double.self) { Text("\(h.formatted())h") } }
            }
        }
        .chartOverlay { proxy in
            HoverOverlay(proxy: proxy, onHover: { point in
                hovered = point.flatMap { proxy.value(atX: $0.x, as: Date.self) }.flatMap(bucket(at:))?.start
            }, onTap: {
                if period != .year, let hovered { onSelect(hovered) }
            }) { _ in
                if let start = hovered, let bucket = bucket(at: start) {
                    Tooltip {
                        Text(label(bucket.start)).fontWeight(.semibold)
                        Text(workedText(bucket))
                        if bucket.totals[.overtime] > 0 {
                            Text("including \(hours(bucket.totals[.overtime])) overtime").foregroundStyle(WorkPhase.overtime.color)
                        }
                        if bucket.totals[.break] + bucket.totals[.pause] > 0 {
                            Text("\(hours(bucket.totals[.break])) break · \(hours(bucket.totals[.pause])) paused").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(height: 220)
    }
    private func workedText(_ bucket: HistoryBucket) -> String {
        "\(hours(bucket.totals.worked)) worked" + (bucket.target > 0 ? " of \(hours(bucket.target)) planned" : "")
    }
    private func bucket(at date: Date) -> HistoryBucket? { buckets.first { $0.start <= date && date < $0.end } }
    private func emphasis(_ start: Date) -> Double { hovered == nil || hovered == start ? 1 : 0.45 }
    private var format: Date.FormatStyle {
        switch period {
        case .week: return .dateTime.weekday(.abbreviated)
        case .month: return .dateTime.day()
        case .year: return .dateTime.month(.abbreviated)
        }
    }
    private func label(_ date: Date) -> String {
        period == .year ? date.formatted(.dateTime.month(.wide).year()) : date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

struct DayTimeline: View {
    let intervals: [WorkInterval]
    let now: Date
    @State private var hovered: WorkInterval.ID?
    var body: some View {
        let totals = intervals.reduce(into: PhaseTotals()) { $0.seconds[$1.kind, default: 0] += $1.seconds(at: now) }
        VStack(alignment: .leading, spacing: 14) {
            if intervals.isEmpty {
                Text("No time recorded on this day.").foregroundStyle(.secondary).frame(height: 60)
            } else {
                chart
            }
            HStack(spacing: 18) {
                // Overtime is listed only on days that had some.
                ForEach(WorkPhase.allCases.filter { $0 != .overtime || totals[$0] > 0 }, id: \.self) { phase in
                    LegendKey(label: "\(phase.label) · \(hours(totals[phase]))") {
                        RoundedRectangle(cornerRadius: 2).fill(phase.color).frame(width: 9, height: 9)
                    }
                }
            }.font(.caption)
            let pauses = intervals.filter { $0.kind == .pause }
            if !pauses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pauses) { pause in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(pause.start, format: .dateTime.hour().minute()).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                            Text(hours(pause.seconds(at: now))).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                            Text(pause.reason ?? "No reason recorded")
                        }
                    }
                }.font(.caption)
            }
        }
    }
    private var domain: ClosedRange<Date> {
        let calendar = Calendar.current
        let first = intervals.map(\.start).min() ?? now, last = intervals.compactMap(\.end).max() ?? now
        let lower = calendar.dateInterval(of: .hour, for: first)?.start ?? first
        var upper = calendar.dateInterval(of: .hour, for: last.addingTimeInterval(-1))?.end ?? last
        if upper.timeIntervalSince(lower) < 3 * 3600 { upper = lower.addingTimeInterval(3 * 3600) }
        return lower...upper
    }
    private var chart: some View {
        GeometryReader { geo in
            let domain = domain
            let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
            // A 2pt surface gap between touching segments, expressed in seconds at the current width.
            let gap = span / max(Double(geo.size.width), 1) * 2
            Chart {
                ForEach(intervals) { item in
                    let end = item.end ?? now
                    let touchesNext = intervals.contains { $0.id != item.id && abs($0.start.timeIntervalSince(end)) < 1 }
                    BarMark(xStart: .value("Start", item.start),
                            xEnd: .value("End", touchesNext && end.timeIntervalSince(item.start) > gap * 2 ? end.addingTimeInterval(-gap) : end),
                            y: .value("Day", "Day"), height: .fixed(28))
                        .foregroundStyle(item.kind.color)
                        .cornerRadius(4)
                        .opacity(hovered == nil || hovered == item.id ? 1 : 0.45)
                        .accessibilityLabel(item.kind.label)
                        .accessibilityValue("\(item.start.formatted(date: .omitted, time: .shortened)) to \(end.formatted(date: .omitted, time: .shortened)), \(hours(item.seconds(at: now)))")
                }
            }
            .chartXScale(domain: domain)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: span > 10 * 3600 ? 2 : 1)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(.primary.opacity(0.08))
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartOverlay { proxy in
                HoverOverlay(proxy: proxy, onHover: { point in
                    let time = point.flatMap { proxy.value(atX: $0.x, as: Date.self) }
                    hovered = time.flatMap { t in intervals.first { $0.start <= t && t < ($0.end ?? now) } }?.id
                }) { _ in
                    if let item = intervals.first(where: { $0.id == hovered }) {
                        Tooltip {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2).fill(item.kind.color).frame(width: 9, height: 9)
                                Text("\(item.kind.label) · \(hours(item.seconds(at: now)))").fontWeight(.semibold)
                            }
                            Text("\(item.start.formatted(date: .omitted, time: .shortened)) – \((item.end ?? now).formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                            if let reason = item.reason { Text("“\(reason)”").frame(maxWidth: 260, alignment: .leading) }
                        }
                    }
                }
            }
        }.frame(height: 76)
    }
}

private struct RhythmChart: View {
    let stats: WorkStats
    let cells: [RhythmCell]
    @State private var hovered: RhythmCell.ID?
    var body: some View {
        let worked = cells.filter { $0.seconds > 0 }
        if worked.isEmpty {
            Text("No work recorded in this period.").foregroundStyle(.secondary)
        } else {
            let lowest = worked.map(\.hour).min()!, highest = worked.map(\.hour).max()!
            let first = max(0, min(lowest, highest - 7)), last = min(23, max(highest, first + 7))
            let peak = worked.map(\.seconds).max()!
            let symbols = Calendar.current.shortWeekdaySymbols
            let shown = cells.filter { (first...last).contains($0.hour) }
            VStack(alignment: .leading, spacing: 12) {
                let order = stats.orderedWeekdays
                // Numeric grid: rows are weekday positions (first weekday on top), columns are hours.
                Chart(shown) { cell in
                    let row = Double(6 - (order.firstIndex(of: cell.weekday) ?? 0))
                    RectangleMark(xStart: .value("Hour", Double(cell.hour) + 0.04), xEnd: .value("Hour", Double(cell.hour) + 0.96),
                                  yStart: .value("Day", row + 0.08), yEnd: .value("Day", row + 0.92))
                        .foregroundStyle(fill(cell.seconds, peak: peak))
                        .cornerRadius(3)
                        .opacity(hovered == nil || hovered == cell.id ? 1 : 0.6)
                        .accessibilityLabel("\(symbols[cell.weekday - 1]) \(hourLabel(cell.hour))")
                        .accessibilityValue(hours(cell.seconds))
                }
                .chartXScale(domain: Double(first)...Double(last + 1))
                .chartYScale(domain: 0.0...7.0)
                .chartXAxis {
                    AxisMarks(values: (first...last).map { Double($0) + 0.5 }) { value in
                        AxisValueLabel { if let x = value.as(Double.self) { Text(hourLabel(Int(x))) } }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: (0..<7).map { Double($0) + 0.5 }) { value in
                        AxisValueLabel { if let y = value.as(Double.self) { Text(symbols[order[6 - Int(y)] - 1]) } }
                    }
                }
                .chartOverlay { proxy in
                    HoverOverlay(proxy: proxy, onHover: { point in
                        guard let point, let x = proxy.value(atX: point.x, as: Double.self),
                              let y = proxy.value(atY: point.y, as: Double.self), (0..<7).contains(Int(y)) else { hovered = nil; return }
                        hovered = shown.first { $0.hour == Int(x) && $0.weekday == order[6 - Int(y)] }?.id
                    }) { _ in
                        if let cell = shown.first(where: { $0.id == hovered }) {
                            Tooltip {
                                Text("\(Calendar.current.weekdaySymbols[cell.weekday - 1]) · \(hourLabel(cell.hour))–\(hourLabel((cell.hour + 1) % 24))").fontWeight(.semibold)
                                Text(cell.seconds > 0 ? "\(hours(cell.seconds)) worked" : "No work").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(height: 210)
                HStack(spacing: 6) {
                    Text("Less")
                    ForEach([0.0, 0.25, 0.5, 0.75, 1], id: \.self) { step in
                        RoundedRectangle(cornerRadius: 2).fill(fill(step * peak, peak: peak)).frame(width: 12, height: 12)
                    }
                    Text("More")
                    Spacer()
                    if let top = worked.max(by: { $0.seconds < $1.seconds }) {
                        Text("Peak: \(Calendar.current.weekdaySymbols[top.weekday - 1]) around \(hourLabel(top.hour)) · \(hours(top.seconds))").foregroundStyle(.secondary)
                    }
                }.font(.caption)
            }
        }
    }
    /// One-hue sequential ramp: tinted toward the work color as minutes grow; empty hours stay a quiet track.
    private func fill(_ seconds: Double, peak: Double) -> Color {
        guard seconds > 0, peak > 0 else { return .primary.opacity(0.05) }
        return WorkPhase.work.color.opacity(0.2 + 0.8 * min(1, seconds / peak))
    }
    private func hourLabel(_ hour: Int) -> String {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!.formatted(.dateTime.hour())
    }
}

private struct SessionList: View {
    let sessions: [WorkLog]
    let now: Date
    let onSelect: (Date) -> Void
    var body: some View {
        Card {
            Text("Sessions").font(.headline)
            if sessions.isEmpty { Text("No sessions in this period.").foregroundStyle(.secondary) }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                ForEach(sessions) { session in
                    let worked = session.worked(at: now)
                    let totals = WorkPhase.allCases.reduce(into: PhaseTotals()) { $0.seconds[$1] = session.seconds($1, at: now) }
                    GridRow(alignment: .center) {
                        Image(systemName: icon(session)).foregroundStyle(.secondary).help(status(session))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.startedAt, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                            Text(timeSpan(session)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        PhaseBar(totals: totals).frame(minWidth: 180)
                        Text("\(hours(worked)) of \(hours(session.targetSeconds))").monospacedDigit().gridColumnAlignment(.trailing)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(session.startedAt) }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue("\(status(session)). \(hours(totals[.break])) break, \(hours(totals[.pause])) paused")
                }
            }
        }
    }
    private func icon(_ session: WorkLog) -> String {
        session.endedAt == nil ? "circle.dashed" : session.finishedNaturally ? "checkmark.circle" : "stop.circle"
    }
    private func status(_ session: WorkLog) -> String {
        session.endedAt == nil ? "In progress" : session.finishedNaturally ? "Target reached" : "Ended early"
    }
    private func timeSpan(_ session: WorkLog) -> String {
        let end = session.endedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "now"
        return "\(session.startedAt.formatted(date: .omitted, time: .shortened)) – \(end)"
    }
}

/// Thin segmented bar: one session split into work, break and pause, separated by 2pt surface gaps.
private struct PhaseBar: View {
    let totals: PhaseTotals
    var body: some View {
        GeometryReader { geo in
            let parts = WorkPhase.allCases.filter { totals[$0] > 0 }
            let available = geo.size.width - CGFloat(max(0, parts.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(parts, id: \.self) { phase in
                    Rectangle().fill(phase.color).frame(width: max(1, available * totals[phase] / max(totals.total, 1)))
                }
            }
        }
        .frame(height: 8)
        .background(surface)
        .clipShape(Capsule())
        .help(WorkPhase.allCases.map { "\($0.label) \(hours(totals[$0]))" }.joined(separator: " · "))
    }
}
