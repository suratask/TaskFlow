import CoreSpotlight
import Foundation
import UniformTypeIdentifiers
import AppIntents

@MainActor
enum TaskFlowSpotlightIndexer {
    private static let domain = "com.surratt.TaskFlow.reminders"
    private static let identifiersKey = "TaskFlow.spotlight.identifiers"
    private static let defaults = UserDefaults.standard

    private static var lastRequestedTasks: [TaskItem]?
    private static var lastRequestedLists: [TaskList]?
    private static var requestGeneration = 0
    private static var indexingTask: Task<Void, Never>?

    static func update(tasks: [TaskItem], lists: [TaskList]) {
        guard lastRequestedTasks != tasks || lastRequestedLists != lists else { return }
        lastRequestedTasks = tasks
        lastRequestedLists = lists
        requestGeneration += 1
        let generation = requestGeneration
        let listNames = Dictionary(lists.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var records: [(String, CSSearchableItem)] = []

        for task in tasks {
            let listName = listNames[task.listID] ?? "Reminders"
            let attributes = CSSearchableItemAttributeSet(contentType: UTType.content)
            attributes.title = task.title
            attributes.contentDescription = [listName, task.dueDate.map { $0.formatted(date: .abbreviated, time: task.hasDueTime ? .shortened : .omitted) }]
                .compactMap { $0 }.joined(separator: " · ")
            attributes.keywords = [listName] + task.tags
            attributes.kind = "Reminder"
            attributes.contentCreationDate = task.createdAt
            attributes.contentModificationDate = task.modifiedAt
            attributes.dueDate = task.dueDate

            attributes.relatedUniqueIdentifier = task.id

            let identifier = "task:\(task.id)"
            let item = CSSearchableItem(uniqueIdentifier: identifier, domainIdentifier: domain, attributeSet: attributes)
            item.expirationDate = .distantFuture
            records.append((identifier, item))
        }

        for list in lists {
            let attributes = CSSearchableItemAttributeSet(contentType: UTType.content)
            attributes.title = list.title
            attributes.contentDescription = "Reminder list"
            attributes.keywords = ["reminders", "tasks"]
            attributes.kind = "Reminder List"
            attributes.relatedUniqueIdentifier = list.id
            let identifier = "list:\(list.id)"
            let item = CSSearchableItem(uniqueIdentifier: identifier, domainIdentifier: domain, attributeSet: attributes)
            item.expirationDate = .distantFuture
            records.append((identifier, item))
        }

        let current = Set(records.map(\.0))
        let preceding = indexingTask
        indexingTask = Task { @MainActor in
            await preceding?.value
            guard generation == requestGeneration else { return }
            let previous = Set(defaults.stringArray(forKey: identifiersKey) ?? [])
            let index = CSSearchableIndex.default()
            let removed = Array(previous.subtracting(current))
            do {
                if !removed.isEmpty { try await index.deleteSearchableItems(withIdentifiers: removed) }
                try await index.indexSearchableItems(records.map(\.1))
                if generation == requestGeneration { defaults.set(Array(current), forKey: identifiersKey) }
            } catch {
                // Keep the previous identifiers so removals and indexing can both retry.
                if generation == requestGeneration {
                    lastRequestedTasks = nil
                    lastRequestedLists = nil
                }
            }
        }
    }
}
