import Charts
import SwiftUI

struct MenuPopoverView: View {
    @ObservedObject var model: AppModel
    @State private var attentionFrames: [String: CGRect] = [:]
    @State private var attentionVisibilityTask: Task<Void, Never>?

    private static let attentionViewportID = "attention-viewport"

    var body: some View {
        Group {
            switch model.connectionState {
            case .disconnected, .authorizing:
                OnboardingView(model: model)
            case .connected:
                dashboard
            }
        }
        .frame(width: 390)
        .task { await model.start() }
    }

    private var dashboard: some View {
        let asOf = Date()
        let metrics = model.snapshot?.metrics(range: model.selectedRange, asOf: asOf) ?? .empty
        let activity = model.snapshot?.activity(range: model.selectedRange, asOf: asOf) ?? .empty
        return VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { viewport in
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(spacing: 10) {
                        Color.clear
                            .frame(height: 0)
                            .id(Self.attentionViewportID)

                        Picker("Window", selection: $model.selectedRange) {
                        ForEach(CohortRange.allCases) { range in Text(range.rawValue).tag(range) }
                    }
                    .pickerStyle(.segmented)
                    .help("Choose the rolling window used for activity and opening-cohort membership.")

                    ActivityCard(
                        title: "Activity",
                        tint: .blue,
                        summary: nil,
                        values: [
                            MetricValue(label: "Opened", value: activity.opened, help: "PRs that first became ready for review during the selected window."),
                            MetricValue(label: "Handoffs", value: activity.handoffs, help: "Qualifying handoff cycles initiated during the selected window. Repeated cycles count separately; withdrawn cycles do not count."),
                            MetricValue(label: "Merged", value: activity.merged, help: "PRs merged during the selected window, regardless of when they were opened.")
                        ],
                        help: "Independent events during the selected window. The counts can refer to different PRs and are not stages that must reconcile."
                    )
                    ActivityCard(
                        title: "Review activity",
                        tint: .orange,
                        summary: "\(activity.decisions) decision\(activity.decisions == 1 ? "" : "s")",
                        values: [
                            MetricValue(label: "Approved", value: activity.approved, help: "Approval review events submitted during the selected window."),
                            MetricValue(label: "Changes", accessibilityLabel: "Changes requested", value: activity.changesRequested, help: "Changes-requested review events submitted during the selected window."),
                            MetricValue(label: "Awaiting", value: activity.awaiting, help: "Non-withdrawn handoffs initiated during the selected window that still have no review decision.")
                        ],
                        help: "Review events during the selected window. Awaiting handoffs are not included in the decision count."
                    )

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Opening cohort")
                            .font(.headline)
                            .help("Performance of PRs that first became ready for review during the selected window. Their outcomes continue to update after the window ends.")
                        HStack(spacing: 10) {
                            MetricTile(title: "Merged", value: percent(metrics.mergeCompletionRate), tint: .blue)
                                .help("Percentage of PRs opened in this cohort that have merged")
                            MetricTile(title: "Median age", value: openAgeText(metrics), tint: .orange)
                                .help("Median age of PRs in this cohort that are still open")
                                .accessibilityLabel("Median age of open pull requests")
                                .accessibilityValue(openAgeText(metrics))
                            MetricTile(title: "Acceptance", value: percent(metrics.acceptanceRate), tint: .green)
                                .help("Approved reviews as a percentage of completed reviews")
                        }
                    }

                    HStack {
                        Label(maturityText(metrics), systemImage: "hourglass")
                            .help("Cohort PRs that have merged or closed without merging.")
                        Spacer()
                        if let seconds = metrics.medianTimeToMerge {
                            Text("Median merge: \(duration(seconds))")
                                .help("Median time from first becoming ready for review to merge for merged PRs in this opening cohort.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                    ActivityChart(snapshot: model.snapshot, range: model.selectedRange, asOf: asOf)

                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !model.unacknowledgedItems.isEmpty {
                        attentionSection
                    }
                        }
                        .padding(12)
                    }
                    .background {
                        Color.clear.preference(
                            key: AttentionFramePreferenceKey.self,
                            value: [Self.attentionViewportID: viewport.frame(in: .global)]
                        )
                    }
                    .onAppear {
                        // The dashboard can replace a short loading view. Pin its
                        // first settled viewport to the metrics instead of letting
                        // SwiftUI preserve the former view's bottom edge.
                        DispatchQueue.main.async {
                            scrollProxy.scrollTo(Self.attentionViewportID, anchor: .top)
                        }
                    }
                    .onPreferenceChange(AttentionFramePreferenceKey.self) { frames in
                        attentionFrames = frames
                        scheduleAttentionVisibilityCheck(frames)
                    }
                    .onChange(of: model.isPopoverPresented) { _, _ in
                        scheduleAttentionVisibilityCheck(attentionFrames)
                    }
                    .onDisappear { attentionVisibilityTask?.cancel() }
                }
            }
            Divider()
            footer
        }
        .frame(height: 580)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.assignedCount)").font(.system(size: 28, weight: .regular, design: .rounded))
                Text("open PRs assigned to you")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.isSyncing { ProgressView().controlSize(.small) }
            VStack(alignment: .trailing, spacing: 2) {
                Text("@\(model.snapshot?.viewer.login ?? "")").font(.caption).fontWeight(.medium)
                if let date = model.snapshot?.metadata.lastSuccessfulSync {
                    Text(fullSyncText(date)).font(.caption2).foregroundStyle(model.isStale ? .orange : .secondary)
                }
                if model.isDataVerified {
                    Label("Reconciled", systemImage: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .help("Source facts and all displayed metric equations passed reconciliation checks.")
                }
            }
        }
        .padding(12)
    }

    private var attentionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Needs attention").font(.headline)
                Spacer()
                Button("Mark all seen") { model.acknowledgeAll() }.buttonStyle(.plain).font(.caption)
            }
            LazyVStack(spacing: 8) {
                ForEach(model.unacknowledgedItems) { item in
                Button { model.acknowledge(item) } label: {
                    HStack(spacing: 9) {
                        Circle()
                            .fill(actionColor(item.highestPriorityActiveApplication?.colorHex))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).lineLimit(1).foregroundStyle(.primary)
                            HStack(spacing: 5) {
                                Text(item.repository)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                ForEach(item.applications.sorted { $0.ruleID.priority < $1.ruleID.priority }) { application in
                                    Text(application.labelName)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(actionColor(application.colorHex), in: Capsule())
                                        .foregroundStyle(actionTextColor(application.colorHex))
                                        .help(application.labelName)
                                }
                            }
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.repository), pull request \(item.pullRequestNumber ?? 0), \(item.title)")
                .accessibilityValue(item.applications.sorted { $0.ruleID.priority < $1.ruleID.priority }
                    .map(\.labelName).joined(separator: ", "))
                .accessibilityHint("Opens the pull request and dismisses its current action labels")
                .background {
                    GeometryReader { row in
                        Color.clear.preference(
                            key: AttentionFramePreferenceKey.self,
                            value: [item.id: row.frame(in: .global)]
                        )
                    }
                }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private func actionColor(_ hex: String?) -> Color {
        guard let hex, hex.count == 6, let value = Int(hex, radix: 16) else { return .secondary }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    private func actionTextColor(_ hex: String) -> Color {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return .primary }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        return (0.299 * red + 0.587 * green + 0.114 * blue) > 0.58 ? .black : .white
    }

    private func scheduleAttentionVisibilityCheck(_ frames: [String: CGRect]) {
        attentionVisibilityTask?.cancel()
        attentionVisibilityTask = Task { @MainActor in
            // SwiftUI briefly places lazy rows at the same provisional origin.
            // Debounce until the preference map reflects the settled layout.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled,
                  model.isPopoverPresented,
                  let viewport = frames[Self.attentionViewportID],
                  viewport.width > 0,
                  viewport.height > 0 else { return }

            let candidates = model.unseenItems.compactMap { item -> (AttentionItem, CGRect)? in
                guard let frame = frames[item.id], frame.width > 0, frame.height > 0 else { return nil }
                let intersection = frame.intersection(viewport)
                guard !intersection.isNull,
                      intersection.width >= frame.width * 0.5,
                      intersection.height >= frame.height * 0.5 else { return nil }
                return (item, frame)
            }
            .sorted { $0.1.minY < $1.1.minY }

            // If the lazy stack ever reports duplicate provisional frames, err
            // toward retaining the dot instead of falsely marking hidden tags seen.
            var acceptedFrames: [CGRect] = []
            for (item, frame) in candidates {
                let duplicatesExisting = acceptedFrames.contains { existing in
                    let overlap = frame.intersection(existing)
                    return !overlap.isNull && overlap.height >= min(frame.height, existing.height) * 0.8
                }
                guard !duplicatesExisting else { continue }
                acceptedFrames.append(frame)
                model.markSeen(item)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(model.isSyncing)
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.plain)
                .help("Quit PR Throughput")
                .accessibilityLabel("Quit PR Throughput")
        }
        .padding(12)
    }

    private func maturityText(_ metrics: CohortMetrics) -> String {
        let terminal = metrics.merged + metrics.closedUnmerged
        return "\(terminal) of \(metrics.opened) PRs merged or closed"
    }

    private func fullSyncText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Full sync \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func openAgeText(_ metrics: CohortMetrics) -> String {
        if metrics.open == 0 { return "0m" }
        return metrics.medianOpenAge.map(duration) ?? "—"
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "—"
    }

    private func percent(_ value: Double?) -> String {
        value?.formatted(.percent.precision(.fractionLength(0))) ?? "—"
    }
}

private struct AttentionFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct MetricValue {
    let label: String
    var accessibilityLabel: String? = nil
    let value: Int
    let help: String
}

private struct ActivityCard: View {
    let title: String
    let tint: Color
    let summary: String?
    let values: [MetricValue]
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .help(help)
                Spacer()
                if let summary {
                    Text(summary)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            HStack(spacing: 0) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 3) {
                        Text("\(item.value)")
                            .font(.title3)
                            .monospacedDigit()
                        Text(item.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .allowsTightening(true)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .help(item.help)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.accessibilityLabel ?? item.label)
                    .accessibilityValue("\(item.value)")
                    .accessibilityHint(item.help)
                }
            }
        }
        .padding(11)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3).monospacedDigit().foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

struct ActivityPoint: Identifiable, Equatable {
    let date: Date
    let count: Int
    let series: String
    var id: String { "\(series):\(date.timeIntervalSinceReferenceDate)" }
}

private struct ActivityChart: View {
    let snapshot: AppSnapshot?
    let range: CohortRange
    let asOf: Date

    var body: some View {
        let chartPoints = points
        VStack(alignment: .leading, spacing: 6) {
            Text("Opened and merged")
                .font(.headline)
                .lineLimit(1)
                .help("Event activity during the selected window. The 48-hour view uses hourly buckets; longer views use daily buckets.")
            Chart(chartPoints) { point in
                LineMark(x: .value("Date", point.date), y: .value("Count", point.count), series: .value("Series", point.series))
                    .foregroundStyle(by: .value("Series", point.series))
                    .interpolationMethod(.linear)
                if point.count > 0 {
                    PointMark(x: .value("Date", point.date), y: .value("Count", point.count))
                        .foregroundStyle(by: .value("Series", point.series))
                }
            }
            .chartForegroundStyleScale(["Opened": Color.blue, "Merged": Color.purple])
            .chartYAxis(.hidden)
            .chartLegend(position: .bottom, spacing: 10)
            .frame(height: 90)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pull requests opened and merged during the selected window")
            .accessibilityValue(chartSummary(chartPoints))
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var points: [ActivityPoint] {
        ActivitySeriesBuilder.points(snapshot: snapshot, range: range, asOf: asOf)
    }

    private func chartSummary(_ points: [ActivityPoint]) -> String {
        let opened = points.filter { $0.series == "Opened" }.reduce(0) { $0 + $1.count }
        let merged = points.filter { $0.series == "Merged" }.reduce(0) { $0 + $1.count }
        return "\(opened) opened and \(merged) merged in the \(range.rawValue) window."
    }
}

enum ActivitySeriesBuilder {
    static func points(
        snapshot: AppSnapshot?,
        range: CohortRange,
        asOf: Date,
        calendar: Calendar = .current
    ) -> [ActivityPoint] {
        guard let snapshot else { return [] }
        let start = asOf.addingTimeInterval(-range.duration)
        let component: Calendar.Component = range == .hours48 ? .hour : .day
        guard let startBucket = calendar.dateInterval(of: component, for: start)?.start,
              let endBucket = calendar.dateInterval(of: component, for: asOf)?.start else { return [] }
        var opened: [Date: Int] = [:]
        var merged: [Date: Int] = [:]
        let authored = snapshot.pullRequests.filter { $0.authorID == snapshot.viewer.id && $0.eligibleAt != nil }
        for pull in authored {
            if let eligible = pull.eligibleAt, eligible >= start, eligible <= asOf,
               let bucket = calendar.dateInterval(of: component, for: eligible)?.start {
                opened[bucket, default: 0] += 1
            }
            if let eligibleAt = pull.eligibleAt, let mergedAt = pull.mergedAt,
               mergedAt >= eligibleAt, mergedAt >= start, mergedAt <= asOf,
               let bucket = calendar.dateInterval(of: component, for: mergedAt)?.start {
                merged[bucket, default: 0] += 1
            }
        }
        var buckets: [Date] = []
        var bucket = startBucket
        while bucket <= endBucket {
            buckets.append(bucket)
            guard let next = calendar.date(byAdding: component, value: 1, to: bucket), next > bucket else { break }
            bucket = next
        }
        let openedPoints = buckets.map { ActivityPoint(date: $0, count: opened[$0, default: 0], series: "Opened") }
        let mergedPoints = buckets.map { ActivityPoint(date: $0, count: merged[$0, default: 0], series: "Merged") }
        return openedPoints + mergedPoints
    }
}
