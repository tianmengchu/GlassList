import AppIntents
import Foundation
import OSLog
import UserNotifications
import WidgetKit

private let widgetLog = Logger(subsystem: GlassList.widgetKind, category: "Interaction")

struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "完成待办"
    static let description = IntentDescription("在一个完美的todolistG中勾选一条待办。")
    static let isDiscoverable = false
    static var supportedModes: IntentModes { .background }
    @available(macOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }

    @Parameter(title: "待办编号")
    var taskID: String

    init() {}

    init(taskID: UUID) {
        self.taskID = taskID.uuidString
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: taskID) else { return .result() }
        let tasks = try TaskStore.shared().update { tasks in
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index].setDone(true)
            }
        }
        if tasks.contains(where: { $0.id == id && $0.isDone }) {
            widgetLog.info("Widget task completed")
        }
        await TaskReminders.shared.sync()
        WidgetCenter.shared.reloadTimelines(ofKind: GlassList.widgetKind)
        return .result()
    }
}

actor TaskReminders {
    static let shared = TaskReminders()
    static let identifierPrefix = "todo-reminder-"
    private let prefix = TaskReminders.identifierPrefix
    private var needsSync = false
    private var syncing = false

    static func taskID(fromNotification identifier: String) -> UUID? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(identifierPrefix.count)))
    }

    func sync() async {
        guard Bundle.main.bundleIdentifier == GlassList.bundleID else { return }
        needsSync = true
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        while needsSync {
            needsSync = false
            await reconcile()
        }
    }

    private func reconcile() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
              let tasks = try? TaskStore.shared().load() else { return }
        let pending = await center.pendingNotificationRequests()
        let scheduled = Dictionary(uniqueKeysWithValues: pending.filter { $0.identifier.hasPrefix(prefix) }.map { ($0.identifier, $0) })
        let now = Date.now
        let expected = tasks.filter { !$0.isDone && ($0.reminderAt ?? .distantPast) > now }
        let ids = Set(expected.map { prefix + $0.id.uuidString })
        center.removePendingNotificationRequests(withIdentifiers: scheduled.keys.filter { !ids.contains($0) })

        for task in expected {
            guard let date = task.reminderAt, date > .now else { continue }
            let id = prefix + task.id.uuidString
            if let request = scheduled[id],
               request.content.userInfo["date"] as? Double == date.timeIntervalSince1970,
               request.content.body == task.title {
                continue
            }
            let content = UNMutableNotificationContent()
            content.title = "待办提醒"
            content.body = task.title
            content.sound = .default
            content.userInfo = ["date": date.timeIntervalSince1970]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }
}

enum WidgetSize: String, Sendable {
    case small
    case medium
    case large

    init(_ family: WidgetFamily) {
        switch family {
        case .systemMedium: self = .medium
        case .systemLarge: self = .large
        default: self = .small
        }
    }

    func appearance() -> DisplayMode {
        guard let file = try? appearanceFile(),
              let value = try? String(contentsOf: file, encoding: .utf8) else {
            return .system
        }
        return DisplayMode(rawValue: value) ?? .system
    }

    func setAppearance(_ appearance: DisplayMode) throws {
        try Data(appearance.rawValue.utf8).write(to: appearanceFile(), options: .atomic)
    }

    private func appearanceFile() throws -> URL {
        try TaskStore.shared().directory.appending(path: "widget-appearance-\(rawValue)")
    }
}

struct SetWidgetAppearanceIntent: AppIntent {
    static let title: LocalizedStringResource = "切换小组件外观"
    static let description = IntentDescription("更改这个尺寸的一个完美的todolistG小组件的显示模式。")
    static let isDiscoverable = false
    static var supportedModes: IntentModes { .background }
    @available(macOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }

    @Parameter(title: "尺寸")
    var sizeID: String

    @Parameter(title: "外观")
    var modeID: String

    init() {}

    init(size: WidgetSize, mode: DisplayMode) {
        sizeID = size.rawValue
        modeID = mode.rawValue
    }

    func perform() async throws -> some IntentResult {
        guard let size = WidgetSize(rawValue: sizeID),
              let mode = DisplayMode(rawValue: modeID) else {
            return .result()
        }
        try size.setAppearance(mode)
        widgetLog.info("Widget appearance changed")
        WidgetCenter.shared.reloadTimelines(ofKind: GlassList.widgetKind)
        return .result()
    }
}
