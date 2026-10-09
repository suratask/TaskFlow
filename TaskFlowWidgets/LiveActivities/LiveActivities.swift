import AppIntents
import ActivityKit
@preconcurrency import EventKit
import SwiftUI
import WidgetKit
import CryptoKit
import ImageIO

struct DueTodayActivityLockView: View {
    let state: TaskFlowDueTodayActivityAttributes.ContentState
    private var theme: TaskFlowSharedTheme { TaskFlowSharedSettings.theme }
    private var style: WidgetThemeStyle { WidgetThemeStyle(theme: theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TaskFlow Studio")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Today Summary")
                        .font(.title3.weight(.black))
                        .foregroundStyle(.white)
                }

                Spacer()

                VStack(spacing: 0) {
                    Text("\(state.openCount)")
                        .font(.title2.weight(.black))
                    Text("open")
                        .font(.caption2.weight(.bold))
                }
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 44)
                    .background(style.accent.opacity(0.24), in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(style.accent.opacity(0.34), lineWidth: 1)
                    }
            }

            DueTodayActivitySummaryRow(state: state, theme: theme, compact: false)
        }
        .padding(16)
    }
}

struct DueTodayActivitySummaryRow: View {
    let state: TaskFlowDueTodayActivityAttributes.ContentState
    let theme: TaskFlowSharedTheme
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            DueTodaySummaryMetric(
                title: "Open",
                value: "\(state.openCount)",
                icon: "checklist",
                color: theme.secondary,
                compact: compact
            )

            DueTodaySummaryMetric(
                title: "High",
                value: "\(state.highPriorityCount)",
                icon: "flag.fill",
                color: theme.tertiary,
                compact: compact
            )

            DueTodaySummaryMetric(
                title: "Next",
                value: state.nextDueSummary,
                icon: "clock.fill",
                color: .white.opacity(0.82),
                compact: compact
            )
        }
    }
}

struct DueTodaySummaryMetric: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 5 : 7) {
            Image(systemName: icon)
                .font((compact ? Font.caption2 : Font.caption).weight(.bold))
                .foregroundStyle(color)
                .frame(width: compact ? 14 : 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.62))
                Text(value)
                    .font((compact ? Font.caption : Font.subheadline).weight(.black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 7 : 9)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct TaskFlowEventLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskFlowEventActivityAttributes.self) { context in
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "calendar").font(.title2.weight(.semibold)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.title).font(.headline).lineLimit(1)
                    Text(context.attributes.calendarTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let location = context.attributes.location, !location.isEmpty {
                        Text(location).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    eventCountdown(context.attributes)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .widgetURL(TaskFlowDeepLink.eventURL(context.attributes.eventID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "calendar").foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startDate, style: .relative).font(.caption.weight(.semibold)).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.attributes.title).font(.headline).lineLimit(1)
                        HStack {
                            Text(context.attributes.calendarTitle).font(.caption).foregroundStyle(.secondary)
                            if let location = context.attributes.location, !location.isEmpty {
                                Text("·").foregroundStyle(.secondary)
                                Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Text("Ends \(context.attributes.endDate.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "calendar")
            } compactTrailing: {
                Text(context.attributes.startDate, style: .relative).monospacedDigit()
            } minimal: {
                Image(systemName: "calendar")
            }
            .widgetURL(TaskFlowDeepLink.eventURL(context.attributes.eventID))
        }
    }

    @ViewBuilder
    private func eventCountdown(_ attributes: TaskFlowEventActivityAttributes) -> some View {
        if Date.now < attributes.startDate {
            Text("Starts \(attributes.startDate, style: .relative)").font(.subheadline.weight(.semibold)).monospacedDigit()
        } else if Date.now < attributes.endDate {
            Text(timerInterval: attributes.startDate...attributes.endDate, countsDown: false).font(.subheadline.weight(.semibold)).monospacedDigit()
        } else {
            Text("Event ended").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}

struct TaskFlowRoutineTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskFlowRoutineTimerActivityAttributes.self) { context in
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "timer").font(.title2.weight(.semibold)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.stepTitle.isEmpty ? context.attributes.listTitle : context.attributes.stepTitle).font(.headline).lineLimit(1)
                    Text(context.attributes.listTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                routineCountdown(context.attributes, end: context.state.endDate).font(.title2.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .widgetURL(TaskFlowDeepLink.listURL(context.attributes.listID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "timer").foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    routineCountdown(context.attributes, end: context.state.endDate).font(.title3.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.attributes.stepTitle.isEmpty ? context.attributes.listTitle : context.attributes.stepTitle).font(.headline).lineLimit(1)
                        Text(context.attributes.listTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(.orange)
            } compactTrailing: {
                routineCountdown(context.attributes, end: context.state.endDate).frame(maxWidth: 56)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(.orange)
            }
            .widgetURL(TaskFlowDeepLink.listURL(context.attributes.listID))
        }
    }

    @ViewBuilder
    private func routineCountdown(_ attributes: TaskFlowRoutineTimerActivityAttributes, end: Date) -> some View {
        if Date.now < end, attributes.startDate < end {
            Text(timerInterval: attributes.startDate...end, countsDown: true).monospacedDigit().multilineTextAlignment(.trailing)
        } else {
            Text("Done").foregroundStyle(.secondary)
        }
    }
}

struct TaskFlowDueTodayLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskFlowDueTodayActivityAttributes.self) { context in
            // Uses the system Live Activity background so it adapts to light and dark Lock Screens.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Today", systemImage: "checklist")
                        .font(.headline)
                    Spacer()
                    Text("\(context.state.openCount) open")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(context.state.tasks.prefix(3)) { task in
                    DueTodayActivityTaskRow(task: task)
                }
                if context.isStale {
                    Text("Open TaskFlow to refresh")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .widgetURL(TaskFlowDeepLink.calendarURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Today", systemImage: "checklist")
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.openCount) open")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(context.state.tasks.prefix(3)) { task in
                            DueTodayActivityTaskRow(task: task)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "checklist")
                    .foregroundStyle(.tint)
            } compactTrailing: {
                Text("\(context.state.openCount)")
                    .monospacedDigit()
            } minimal: {
                Text("\(context.state.openCount)")
                    .monospacedDigit()
            }
            .widgetURL(TaskFlowDeepLink.calendarURL)
        }
    }
}

/// One task line in the Due Today Live Activity, styled like the app's task rows.
struct DueTodayActivityTaskRow: View {
    let task: TaskFlowDueTodayTaskSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.isCompleted ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary)
            Text((1...4).contains(task.priority) ? "!!! \(task.title)" : task.title)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 4)
            if task.isFlagged {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let dueDate = task.dueDate {
                Text(dueDate, style: .time)
                    .font(.caption)
                    .foregroundStyle(dueDate < Date() ? Color.red : Color.secondary)
            }
        }
    }
}
