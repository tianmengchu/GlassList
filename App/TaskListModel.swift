import Dispatch
import Foundation
import Observation
import WidgetKit

@MainActor
@Observable
final class TaskListModel {
    private(set) var tasks: [Todo] = []
    private(set) var loadFailed = false
    var showSaveError = false
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?

    func homeTasks(at date: Date, includeCompleted: Bool, retentionDays: Int) -> [Todo] {
        let pending = tasks.filter { !$0.isDone }
        guard includeCompleted else { return pending }
        let recent = tasks.filter { $0.isDone && $0.staysOnHome(for: retentionDays, at: date) }
        return pending + recent.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    func reload(refreshWidget: Bool = false) {
        do {
            let store = try TaskStore.shared()
            watchDirectory(store.directory)
            let loaded = try store.load()
            if loaded.contains(where: { $0.isDone && $0.completedAt == nil }) {
                let date = Date.now
                tasks = try store.update { items in
                    for index in items.indices where items[index].isDone && items[index].completedAt == nil {
                        items[index].completedAt = date
                    }
                }
            } else {
                tasks = loaded
            }
            loadFailed = false
            Task { await TaskReminders.shared.sync() }
            if refreshWidget {
                WidgetCenter.shared.reloadTimelines(ofKind: GlassList.widgetKind)
            }
        } catch {
            loadFailed = true
        }
    }

    func saveTask(id: UUID?, title input: String, reminder: Date?, day: Date?, note inputNote: String) -> Bool {
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        let note = inputNote.trimmingCharacters(in: .whitespacesAndNewlines)
        var found = false
        let saved = change(reportError: false) { tasks in
            let index: Int
            if let id {
                guard let existing = tasks.firstIndex(where: { $0.id == id }) else { return }
                index = existing
            } else {
                tasks.insert(Todo(title), at: 0)
                index = 0
            }
            tasks[index].title = title
            tasks[index].reminderAt = reminder
            tasks[index].scheduledDay = reminder == nil ? day : nil
            tasks[index].note = note.isEmpty ? nil : note
            found = true
        }
        return saved && found
    }

    func moveTask(_ id: UUID, to day: Date?, calendar: Calendar) -> Bool {
        var moved = false
        let saved = change(reportError: false) { tasks in
            guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
            moved = tasks[index].move(to: day, calendar: calendar)
        }
        return saved && moved
    }

    @discardableResult
    func setDone(_ task: Todo, to done: Bool, reportError: Bool = true) -> Bool {
        change(reportError: reportError) { tasks in
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index].setDone(done)
            }
        }
    }

    func delete(_ id: UUID) {
        change { $0.removeAll { $0.id == id } }
    }

    @discardableResult
    private func change(reportError: Bool = true, _ edit: (inout [Todo]) -> Void) -> Bool {
        do {
            let store = try TaskStore.shared()
            tasks = try store.update(edit)
            watchDirectory(store.directory)
            loadFailed = false
            Task { await TaskReminders.shared.sync() }
            WidgetCenter.shared.reloadTimelines(ofKind: GlassList.widgetKind)
            return true
        } catch {
            if reportError { showSaveError = true }
            return false
        }
    }

    private func watchDirectory(_ directory: URL) {
        guard watcher == nil else { return }
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.reload()
        }
        source.setCancelHandler { close(descriptor) }
        watcher = source
        source.activate()
    }

    deinit {
        watcher?.cancel()
    }
}
