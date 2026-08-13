import Charts
import SwiftUI

enum MenuPresentationState: Equatable {
    case onboarding
    case initialSync
    case dashboard

    static func resolve(connectionState: AppModel.ConnectionState, hasSnapshot: Bool) -> Self {
        switch connectionState {
        case .disconnected, .authorizing: .onboarding
        case .connected: hasSnapshot ? .dashboard : .initialSync
        }
    }
}

struct MenuPopoverView: View {
    @ObservedObject var model: AppModel
    @State private var attentionFrames: [String: CGRect] = [:]
    @State private var attentionVisibilityTask: Task<Void, Never>?

    private static let attentionViewportID = "attention-viewport"

    var body: some View {
        Group {
            switch MenuPresentationState.resolve(
                connectionState: model.connectionState,
                hasSnapshot: model.snapshot != nil
            ) {
            case .onboarding:
                OnboardingView(model: model)
            case .initialSync:
                initialSync
            case .dashboard:
                dashboard
            }
        }
        .frame(width: 390)
        .task { await model.start() }
    }

    private var initialSync: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                if model.isSyncing {
                    ProgressView()
                        .controlSize(.regular)
                } else if model.errorMessage != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(initialSyncTitle)
                    .font(.headline)
                Text("Verified totals will appear after reconciliation completes. The first sync can take a few minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: 330, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
            Divider()
            footer
        }
        .frame(height: 300)
    }

    private var initialSyncTitle: String {
        if model.isSyncing { return "Syncing GitHub history…" }
        if model.errorMessage != nil { return "Unable to verify totals" }
        return "Preparing first sync…"
    }

    private var dashboard: some View {
        // Keep every card on the same verified source boundary. The 15-second
        // assigned/action lanes must not silently move a five-minute metric window.
        let asOf = model.snapshot?.metadata.lastSuccessfulSync ?? Date()
        let metrics = model.snapshot?.windowMetrics(range: model.selectedRange, asOf: asOf)
            ?? .empty(range: model.selectedRange, asOf: asOf)
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
                        ForEach(WindowRange.allCases) { range in Text(range.rawValue).tag(range) }
                    }
                    .pickerStyle(.segmented)
                    .help("Choose the rolling window used by every event count and opening balance.")

                    BacklogFlowCard(
                        metrics: metrics,
                        range: model.selectedRange
                    )
                    ActivityCard(
                        title: "Review events",
                        tint: .orange,
                        summary: acceptanceSummary(metrics),
                        values: [
                            MetricValue(label: "Handoffs", value: metrics.handoffs, help: "Non-withdrawn named-person handoff cycles initiated during the selected window."),
                            MetricValue(label: "Approved", value: metrics.approved, help: "Qualifying approval review events submitted during the selected window."),
                            MetricValue(label: "Changes", accessibilityLabel: "Changes requested", value: metrics.changesRequested, help: "Qualifying changes-requested review events submitted during the selected window."),
                            MetricValue(label: "Awaiting now", value: metrics.awaitingNow, help: "All unresolved, non-withdrawn handoffs at the verified closing boundary, regardless of when they began.")
                        ],
                        help: "Review decisions and handoffs during the selected window. Awaiting now is current closing-boundary state and is excluded from acceptance."
                    )

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Window KPIs")
                            .font(.headline)
                            .help("Throughput and review efficiency measured only against the selected rolling window.")
                        HStack(spacing: 10) {
                            MetricTile(title: "Merged", value: "\(metrics.merged)", tint: .blue)
                                .help("PRs merged during the selected window")
                            MetricTile(title: "Acceptance", value: percent(metrics.acceptanceRate), tint: .green)
                                .help("Approval review events divided by all qualifying review decisions in the selected window")
                            MetricTile(title: "Median merge", value: metrics.medianTimeToMerge.map(duration) ?? "—", tint: .purple)
                                .help("Median time from first becoming ready to merge for PRs merged during the selected window")
                        }
                    }

                    HStack {
                        Label("\(metrics.openNow) authored open", systemImage: "hourglass")
                            .help("Authored, ready, non-draft PRs open at the verified closing boundary.")
                        Spacer()
                        Text("Median age now: \(metrics.medianOpenAge.map(duration) ?? "—")")
                            .help("Median time since first becoming ready among authored PRs open at the verified closing boundary.")
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
                .accessibilityHint("Opens the pull request and marks its notification seen")
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

    private func fullSyncText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Full sync \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func acceptanceSummary(_ metrics: WindowMetrics) -> String {
        guard let rate = metrics.acceptanceRate else { return "No decisions" }
        return "\(metrics.approved)/\(metrics.decisions) · \(percent(rate))"
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

private struct BacklogFlowCard: View {
    let metrics: WindowMetrics
    let range: WindowRange

    private var values: [MetricValue] {
        [
            MetricValue(label: "Open at start", value: metrics.openAtStart, help: "Authored, ready, non-draft PRs open immediately before the rolling window."),
            MetricValue(label: "New", value: metrics.new, help: "PRs entering ready, open work for the first time during the window."),
            MetricValue(label: "Re-entered", value: metrics.reentered, help: "Existing PRs returning through reopen or draft-to-ready during the window."),
            MetricValue(label: "Merged", value: metrics.merged, help: "Active authored PRs merged during the window."),
            MetricValue(label: "Closed", value: metrics.closed, help: "Active authored PRs closed without merging during the window."),
            MetricValue(label: "Drafted", value: metrics.drafted, help: "Active authored PRs converted back to draft during the window."),
            MetricValue(label: "Authored open", value: metrics.openNow, help: "Authored, ready, non-draft PRs open at the verified closing boundary."),
            MetricValue(label: "Net", value: metrics.netChange, help: "Authored open minus open at start.")
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Authored PR flow")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Label("Balances", systemImage: "equal.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .help("Opening balance plus entries minus exits equals authored open.")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 4), spacing: 8) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 2) {
                        Text("\(item.value)").font(.title3).monospacedDigit()
                        Text(item.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .frame(maxWidth: .infinity)
                    .help(item.help)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.label)
                    .accessibilityValue("\(item.value)")
                    .accessibilityHint(item.help)
                }
            }
        }
        .padding(11)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .help("Backlog transitions in the rolling \(range.rawValue) window.")
    }
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
    let range: WindowRange
    let asOf: Date

    var body: some View {
        let chartPoints = points
        VStack(alignment: .leading, spacing: 6) {
            Text("New, handoffs, and merged")
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
            .chartForegroundStyleScale(["New": Color.blue, "Handoffs": Color.orange, "Merged": Color.purple])
            .chartYAxis(.hidden)
            .chartLegend(position: .bottom, spacing: 10)
            .frame(height: 90)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pull requests first entering ready work, handed off, and merged during the selected window")
            .accessibilityValue(chartSummary(chartPoints))
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var points: [ActivityPoint] {
        ActivitySeriesBuilder.points(snapshot: snapshot, range: range, asOf: asOf)
    }

    private func chartSummary(_ points: [ActivityPoint]) -> String {
        let opened = points.filter { $0.series == "New" }.reduce(0) { $0 + $1.count }
        let handoffs = points.filter { $0.series == "Handoffs" }.reduce(0) { $0 + $1.count }
        let merged = points.filter { $0.series == "Merged" }.reduce(0) { $0 + $1.count }
        return "\(opened) new, \(handoffs) handoffs, and \(merged) merged in the \(range.rawValue) window."
    }
}

enum ActivitySeriesBuilder {
    static func points(
        snapshot: AppSnapshot?,
        range: WindowRange,
        asOf: Date,
        calendar: Calendar = .current
    ) -> [ActivityPoint] {
        guard let snapshot else { return [] }
        let start = asOf.addingTimeInterval(-range.duration)
        let component: Calendar.Component = range == .hours48 ? .hour : .day
        guard let startBucket = calendar.dateInterval(of: component, for: start)?.start,
              let endBucket = calendar.dateInterval(of: component, for: asOf)?.start else { return [] }
        var opened: [Date: Int] = [:]
        var handoffs: [Date: Int] = [:]
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
        let includedHandoffIDs = Set(snapshot.windowMetrics(range: range, asOf: asOf).handoffIDs)
        for handoff in snapshot.handoffs where includedHandoffIDs.contains(handoff.id) {
            if let bucket = calendar.dateInterval(of: component, for: handoff.at)?.start {
                handoffs[bucket, default: 0] += 1
            }
        }
        var buckets: [Date] = []
        var bucket = startBucket
        while bucket <= endBucket {
            buckets.append(bucket)
            guard let next = calendar.date(byAdding: component, value: 1, to: bucket), next > bucket else { break }
            bucket = next
        }
        let openedPoints = buckets.map { ActivityPoint(date: $0, count: opened[$0, default: 0], series: "New") }
        let handoffPoints = buckets.map { ActivityPoint(date: $0, count: handoffs[$0, default: 0], series: "Handoffs") }
        let mergedPoints = buckets.map { ActivityPoint(date: $0, count: merged[$0, default: 0], series: "Merged") }
        return openedPoints + handoffPoints + mergedPoints
    }
}
