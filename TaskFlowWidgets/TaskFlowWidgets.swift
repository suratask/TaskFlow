import AppIntents
import ActivityKit
@preconcurrency import EventKit
import SwiftUI
import WidgetKit
import CryptoKit
import ImageIO

/// Whether widgets include calendar events: Calendars are on in TaskFlow and access was granted.
var widgetShowsCalendarEvents: Bool {
    TaskFlowSharedSettings.usesCalendars && hasEventKitAccess(EKEventStore.authorizationStatus(for: .event))
}

func hasEventKitAccess(_ status: EKAuthorizationStatus) -> Bool {
    if #available(iOS 17.0, *) {
        return status == .fullAccess
    }
    // Before iOS 17, the authorized status has the same raw value as fullAccess.
    return status.rawValue == 3
}

@main
struct TaskFlowWidgetBundle: WidgetBundle {
    var body: some Widget {
        TaskFlowTodayWidget()
        TaskFlowNextUpWidget()
        TaskFlowQuickCaptureWidget()
        TaskFlowSmartListWidget()
        TaskFlowShoppingListWidget()
        TaskFlowReadLaterWidget()
        TaskFlowWatchLaterWidget()
        TaskFlowContinueWatchingWidget()
        TaskFlowNewEpisodesWidget()
        TaskFlowComingSoonWidget()
        TaskFlowPinnedNoteWidget()
        TaskFlowDueTodayLiveActivity()
        TaskFlowEventLiveActivity()
        TaskFlowRoutineTimerLiveActivity()
        if #available(iOS 18.0, *) {
            QuickCaptureControl()
            NewNoteControl()
            DictateNoteControl()
        }
    }
}
