import Foundation
import UserNotifications
import CloudKit
import EventKit
import Observation
import SwiftUI
import WidgetKit
import LinkPresentation
import UIKit

/// Turns system errors into short, specific messages that say what to do next.
/// TaskFlow's own errors (domains starting "TaskFlow") are already written for people and pass through.
enum FriendlyError {
    static func message(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain.hasPrefix("TaskFlow") { return nsError.localizedDescription }
        if nsError.domain == EKErrorDomain, let code = EKError.Code(rawValue: nsError.code) {
            switch code {
            case .calendarReadOnly, .calendarIsImmutable, .sourceDoesNotAllowCalendarAddDelete, .calendarDoesNotAllowReminders, .calendarDoesNotAllowEvents:
                return "Couldn’t save — that list or calendar is read-only. Choose another one."
            case .eventStoreNotAuthorized:
                return "TaskFlow doesn’t have access to Reminders or Calendar. You can turn it on in Settings."
            case .noCalendar, .calendarHasNoSource, .objectBelongsToDifferentStore:
                return "That list or calendar is no longer available. Choose another one."
            case .datesInverted, .durationGreaterThanRecurrence:
                return "The end time needs to be after the start time."
            case .noStartDate, .noEndDate:
                return "Add a start and end time, then try again."
            case .recurringReminderRequiresDueDate:
                return "Repeating reminders need a due date."
            default:
                break
            }
        }
        if nsError.domain == CKErrorDomain, let code = CKError.Code(rawValue: nsError.code) {
            switch code {
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                return "iCloud isn’t reachable right now. Your changes are saved and will sync when it’s back."
            case .notAuthenticated:
                return "Sign in to iCloud in Settings to sync TaskFlow between your devices."
            case .quotaExceeded:
                return "Your iCloud storage is full, so TaskFlow can’t sync. Free up space in Settings → iCloud."
            default:
                break
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "You’re offline. Try again when you’re connected."
            case .timedOut:
                return "That took too long to respond. Try again."
            default:
                break
            }
        }
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileWriteOutOfSpace:
                return "Your device is out of storage. Free up space and try again."
            case .fileReadNoSuchFile, .fileNoSuchFile:
                return "That file is no longer available."
            case .fileReadNoPermission, .fileWriteNoPermission:
                return "TaskFlow doesn’t have permission to use that file."
            default:
                break
            }
        }
        return nsError.localizedDescription
    }
}
