import AppIntents
import SwiftUI
import TipKit

@main
struct TaskFlowApp: App {
    @UIApplicationDelegateAdaptor(TaskFlowAppDelegate.self) private var appDelegate
    @State private var repository: TaskRepository

    init() {
        let repository = TaskRepository()
        _repository = State(initialValue: repository)
        let notes: any TaskFlowNoteIntentHandling = RepositoryNoteIntentHandler(repository: repository)
        AppDependencyManager.shared.add(key: "TaskFlowNotes", dependency: notes)
        TaskFlowSharedNotes.save(repository.quickNotes.map(TaskFlowSharedNote.init(note:)))
        try? Tips.configure([.displayFrequency(.daily)])
    }

    var body: some Scene {
        WindowGroup {
            ContentView(repository: repository)
        }
    }
}
