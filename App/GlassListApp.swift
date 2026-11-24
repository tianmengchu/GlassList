import AppKit
import SwiftUI
import UserNotifications

@main
struct GlassListApp: App {
    fileprivate static let listWindowID = "list"

    @NSApplicationDelegateAdaptor(GlassListLifecycle.self) private var lifecycle
    @FocusedValue(\.todoComposer) private var todoComposer
    @FocusedValue(\.showListSettings) private var showListSettings
    @FocusedValue(\.showSearch) private var showSearch
    @State private var shortcutSettings = ReminderShortcutSettings()
    @State private var updates = AppUpdates()
    @State private var model = TaskListModel()
    @State private var windowDock = WindowDock()

    var body: some Scene {
        Window("一个完美的todolistG", id: Self.listWindowID) {
            TaskListView()
                .environment(model)
                .environment(windowDock)
                .environment(shortcutSettings)
                .environment(updates)
                .frame(minWidth: 660, minHeight: 480)
                .handlesExternalEvents(preferring: ["open", "new", "desktop"], allowing: ["open", "new", "desktop"])
        }
        .handlesExternalEvents(matching: ["open", "new", "desktop"])
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 820, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { showListSettings?.wrappedValue = true }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(showListSettings == nil)
            }
            CommandGroup(replacing: .newItem) {
                Button("新建待办") { todoComposer?.wrappedValue = true }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(todoComposer == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("搜索待办") { showSearch?.wrappedValue = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(showSearch == nil)
            }
        }

        MenuBarExtra {
            GlassListMenu(windowDock: windowDock)
                .environment(updates)
        } label: {
            Label("一个完美的todolistG", systemImage: updates.available == nil ? "checkmark.square" : "arrow.down.circle")
        }
    }
}

private struct GlassListMenu: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppUpdates.self) private var updates
    let windowDock: WindowDock

    var body: some View {
        Button("打开一个完美的todolistG") {
            if !windowDock.bringMainWindowForward() {
                NSApp.activate()
                openWindow(id: GlassListApp.listWindowID)
            }
        }
        Divider()
        if let update = updates.available {
            Link(update.downloadURL == nil ? "查看 \(update.version) 发布页" : "下载一个完美的todolistG \(update.version)",
                 destination: update.destination)
            Divider()
        }
        Button("退出一个完美的todolistG") {
            NSApp.terminate(nil)
        }
    }
}

private final class GlassListLifecycle: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // A task may have been completed or deleted (e.g. from the widget) after its reminder was scheduled.
        if let id = TaskReminders.taskID(fromNotification: notification.request.identifier),
           let tasks = try? TaskStore.shared().load(),
           !tasks.contains(where: { $0.id == id && !$0.isDone }) {
            return []
        }
        return [.banner, .sound]
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

extension FocusedValues {
    @Entry var todoComposer: Binding<Bool>?
    @Entry var showListSettings: Binding<Bool>?
    @Entry var showSearch: Binding<Bool>?
}
