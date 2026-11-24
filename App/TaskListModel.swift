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
    /// Set when a damaged list file was repaired; the original is kept as `list.damaged-*.json`.
    var showRecoveryNotice = false
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var pendingReload: DispatchWorkItem?
    @ObservationIgnored private var hasLoaded = false

    func homeTasks(at date: Date, includeCompleted: Bool, retentionDays: Int) -> [Todo] {
        let pending = tasks.filter { !$0.isDone }
        guard includeCompleted else { return pending }
        let recent = tasks.filter { $0.isDone && $0.staysOnHome(for: retentionDays, at: date) }
        return pending + recent.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    /// - Parameter syncReminders: pass `false` for file-change reloads; reminders are then
    ///   re-synced only when the list actually changed.
    func reload(refreshWidget: Bool = false, syncReminders: Bool = true) {
        do {
            let store = try TaskStore.shared()
            watchDirectory(store.directory)
            let (loaded, recovered) = try store.loadTasks()
            let next: [Todo]
            if recovered || loaded.contains(where: { $0.isDone && $0.completedAt == nil }) {
                let date = Date.now
                next = try store.update { items in
                    for index in items.indices where items[index].isDone && items[index].completedAt == nil {
                        items[index].completedAt = date
                    }
                }
                if recovered { showRecoveryNotice = true }
            } else {
                next = loaded
            }
            let changed = !hasLoaded || next != tasks
            if changed { tasks = next }
            hasLoaded = true
            loadFailed = false
            if syncReminders || changed {
                Task { await TaskReminders.shared.sync() }
            }
            if refreshWidget || recovered {
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

    struct DeletedTask: Equatable {
        let task: Todo
        let index: Int
    }

    @discardableResult
    func delete(_ id: UUID, reportError: Bool = true) -> Bool {
        deleteReturning(id, reportError: reportError) != nil
    }

    func deleteReturning(_ id: UUID, reportError: Bool = true) -> DeletedTask? {
        var removed: DeletedTask?
        let saved = change(reportError: reportError) { tasks in
            guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
            removed = DeletedTask(task: tasks.remove(at: index), index: index)
        }
        return saved ? removed : nil
    }

    @discardableResult
    func restore(_ deleted: DeletedTask, reportError: Bool = true) -> Bool {
        change(reportError: reportError) { tasks in
            guard !tasks.contains(where: { $0.id == deleted.task.id }) else { return }
            let target = min(max(0, deleted.index), tasks.count)
            tasks.insert(deleted.task, at: target)
        }
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
            self?.scheduleReloadFromDisk()
        }
        source.setCancelHandler { close(descriptor) }
        watcher = source
        source.activate()
    }

    /// Atomic writes produce several directory events in a row (temp file, rename, lock file),
    /// so coalesce them into one read.
    private func scheduleReloadFromDisk() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingReload = nil
                self?.reload(syncReminders: false)
            }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    deinit {
        watcher?.cancel()
    }
}
