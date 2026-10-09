import AppIntents
import ActivityKit
@preconcurrency import EventKit
import SwiftUI
import WidgetKit
import CryptoKit
import ImageIO

struct TaskFlowQuickCaptureWidgetEntry: TimelineEntry { let date: Date }

struct TaskFlowQuickCaptureTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaskFlowQuickCaptureWidgetEntry { .init(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (TaskFlowQuickCaptureWidgetEntry) -> Void) { completion(.init(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TaskFlowQuickCaptureWidgetEntry>) -> Void) {
        completion(Timeline(entries: [.init(date: Date())], policy: .never))
    }
}

struct TaskFlowQuickCaptureWidget: Widget {
    let kind = "TaskFlowQuickCaptureWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TaskFlowQuickCaptureTimelineProvider()) { _ in
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "square.and.pencil").font(.title.weight(.medium)).foregroundStyle(WidgetThemeStyle(theme: TaskFlowSharedSettings.theme).accent)
                Text("Quick Capture").font(.headline.weight(.semibold)).foregroundStyle(.primary)
                Text("Task or event").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(TaskFlowDeepLink.captureURL)
            .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Quick Capture")
        .description("Open TaskFlow’s natural-language capture.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// Control Center, Lock Screen, and Action button control that opens Quick Capture.
@available(iOS 18.0, *)
struct QuickCaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.surratt.TaskFlow.quickCaptureControl") {
            ControlWidgetButton(action: OpenQuickCaptureControlIntent()) {
                Label("Quick Capture", systemImage: "plus.circle")
            }
        }
        .displayName("Quick Capture")
        .description("Add a task in TaskFlow Studio.")
    }
}

@available(iOS 18.0, *)
struct NewNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.surratt.TaskFlow.newNoteControl") {
            ControlWidgetButton(action: NewNoteControlIntent()) {
                Label("New Note", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Note")
        .description("Write a new note in TaskFlow Studio.")
    }
}

@available(iOS 18.0, *)
struct DictateNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.surratt.TaskFlow.dictateNoteControl") {
            ControlWidgetButton(action: DictateNoteControlIntent()) {
                Label("Dictate Note", systemImage: "mic.fill")
            }
        }
        .displayName("Dictate Note")
        .description("Speak a new note and review its transcription.")
    }
}
