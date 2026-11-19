import AppKit
import Sparkle
import SwiftUI
import UserNotifications

@main
struct GlassListApp: App {
    @NSApplicationDelegateAdaptor(GlassListLifecycle.self) private var lifecycle
    @FocusedValue(\.todoComposer) private var todoComposer
    @FocusedValue(\.showListSettings) private var showListSettings
    @State private var shortcutSettings = ReminderShortcutSettings()
    @State private var updates = AppUpdates()

    var body: some Scene {
        Window("浮光清单", id: "list") {
            TaskListView()
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
        }
    }
}

@MainActor
@Observable
final class AppUpdates {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    static let releasePage = URL(string: "https://github.com/tianmengchu/GlassList/releases")!

    private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    private(set) var canCheck = false
    private(set) var automaticallyChecks = false
    var isConfigured: Bool { controller != nil }

    init() {
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard let publicKey, Data(base64Encoded: publicKey)?.count == 32 else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let available = change.newValue ?? false
            Task { @MainActor [weak self] in self?.canCheck = available }
        }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard let controller else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecks = enabled
    }

    func check() {
        controller?.checkForUpdates(nil)
    }
}

private final class GlassListLifecycle: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !WindowDock.hasVisibleTab(in: sender)
    }
}

extension FocusedValues {
    @Entry var todoComposer: Binding<Bool>?
    @Entry var showListSettings: Binding<Bool>?
}
