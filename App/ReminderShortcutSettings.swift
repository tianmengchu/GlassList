import AppKit
import SwiftUI
import UserNotifications
import WidgetKit

private extension DetailColor {
    init?(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
    }
}

struct ReminderShortcut: Codable, Identifiable {
    enum Kind: String, Codable {
        case delay
        case nextTime
        case tomorrow
    }

    let id: Int
    var kind: Kind
    var minutes = 15
    var hour = 9
    var minute = 0

    static let defaults = [
        Self(id: 1, kind: .delay, minutes: 15),
        Self(id: 2, kind: .delay, minutes: 60),
        Self(id: 3, kind: .tomorrow)
    ]

    private var timeLabel: String { String(format: "%02d:%02d", hour, minute) }

    var title: String {
        switch kind {
        case .delay:
            return minutes.isMultiple(of: 60) ? "\(minutes / 60) 小时后" : "\(minutes) 分钟后"
        case .nextTime: return "下次 \(timeLabel)"
        case .tomorrow: return "明天 \(timeLabel)"
        }
    }

    func date(from now: Date, calendar: Calendar = .current) -> Date? {
        switch kind {
        case .delay:
            return now.addingTimeInterval(Double(minutes) * 60)
        case .nextTime:
            return calendar.nextDate(
                after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                matchingPolicy: .nextTime
            )
        case .tomorrow:
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow)
        }
    }
}

@Observable
@MainActor
final class ReminderShortcutSettings {
    private static let key = "reminderShortcutOptions"
    private static let dockColorKey = "dockTabColor"
    private static let defaultDockColor = DetailColor(red: 0.12, green: 0.38, blue: 0.34)
    static let maximum = 10
    private(set) var colors = DetailColors()
    private(set) var dockTabColor = defaultDockColor
    private(set) var colorSaveFailed = false
    private(set) var display = TaskDisplaySettings()
    private(set) var displaySaveFailed = false
    @ObservationIgnored private var widgetRefresh: Task<Void, Never>?
    var items: [ReminderShortcut] {
        didSet {
            if let data = try? JSONEncoder().encode(items) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.key)
        let decoded = stored.flatMap { try? JSONDecoder().decode([ReminderShortcut].self, from: $0) }
        items = Array((decoded ?? ReminderShortcut.defaults).prefix(Self.maximum))
        if let store = try? TaskStore.shared() {
            colors = (try? store.loadDetailColors()) ?? DetailColors()
            display = (try? store.loadDisplaySettings()) ?? TaskDisplaySettings()
        }
        if let data = UserDefaults.standard.data(forKey: Self.dockColorKey),
           let saved = try? JSONDecoder().decode(DetailColor.self, from: data) {
            dockTabColor = saved
        }
    }

    func addShortcut() {
        guard items.count < Self.maximum else { return }
        items.append(ReminderShortcut(id: (items.map(\.id).max() ?? 0) + 1, kind: .delay))
    }

    func updateColor(_ selection: Color, at keyPath: WritableKeyPath<DetailColors, DetailColor>) {
        guard let selected = DetailColor(selection) else { return }
        do {
            colors = try TaskStore.shared().updateDetailColors { $0[keyPath: keyPath] = selected }
            colorSaveFailed = false
            widgetRefresh?.cancel()
            widgetRefresh = Task {
                try? await Task.sleep(for: .milliseconds(350))
                if !Task.isCancelled {
                    WidgetCenter.shared.reloadTimelines(ofKind: GlassList.widgetKind)
                }
            }
        } catch {
            colorSaveFailed = true
        }
    }

    func updateDockColor(_ selection: Color) {
        guard let color = DetailColor(selection),
              let data = try? JSONEncoder().encode(color) else { return }
        UserDefaults.standard.set(data, forKey: Self.dockColorKey)
        dockTabColor = color
    }

    func setShowsCountdown(_ showsCountdown: Bool) {
        do {
            display = try TaskStore.shared().updateDisplaySettings { $0.showsCountdown = showsCountdown }
            displaySaveFailed = false
            WidgetCenter.shared.reloadTimelines(ofKind: GlassList.widgetKind)
        } catch {
            displaySaveFailed = true
        }
    }
}

struct ReminderSettingsView: View {
    @Environment(ReminderShortcutSettings.self) private var settings
    @Environment(AppUpdates.self) private var updates
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("strikeCompletedOnHome") private var strikeCompletedOnHome = false
    @AppStorage("homeCompletedRetentionDays") private var retentionDays = 0
    @State private var authorization: UNAuthorizationStatus?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("版本与更新") {
                LabeledContent("当前版本", value: "\(AppUpdates.version)（\(AppUpdates.build)）")
                Toggle("自动检查更新", isOn: Binding(
                    get: { updates.automaticallyChecks },
                    set: { updates.setAutomaticChecks($0) }
                ))
                .disabled(!updates.isConfigured)
                HStack {
                    Button("检查更新…") { updates.check() }
                        .disabled(!updates.canCheck)
                    Spacer()
                    Link("GitHub 发布页", destination: AppUpdates.releasePage)
                }
                if !updates.isConfigured {
                    Text("当前构建尚未配置已签名的更新源。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("显示") {
                Toggle("显示倒计时", isOn: Binding(
                    get: { settings.display.showsCountdown },
                    set: { settings.setShowsCountdown($0) }
                ))
                .help("同时控制主窗口、侧边清单和桌面小组件的倒计时")
                if settings.displaySaveFailed {
                    Text("暂时无法保存显示设置，请重试。")
                        .foregroundStyle(.red)
                }
            }
            Section("配色") {
                colorPicker("时间标签", keyPath: \.time)
                colorPicker("备注标签", keyPath: \.note)
                ColorPicker("侧边条", selection: Binding(
                    get: { settings.dockTabColor.swatch },
                    set: { settings.updateDockColor($0) }
                ), supportsOpacity: false)
                if settings.colorSaveFailed {
                    Text("暂时无法保存颜色，请重试。")
                        .foregroundStyle(.red)
                }
            }

            Section("完成项") {
                Picker("完成后", selection: $strikeCompletedOnHome) {
                    Text("移到已完成").tag(false)
                    Text("在首页划线保留").tag(true)
                }
                Picker("首页完成项保留", selection: $retentionDays) {
                    Text("永远保留").tag(0)
                    Text("完成后 1 天").tag(1)
                    Text("完成后 7 天").tag(7)
                    Text("完成后 30 天").tag(30)
                }
                .disabled(!strikeCompletedOnHome)
            }

            Section {
                ForEach($settings.items) { $item in
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .frame(minWidth: 75, maxWidth: .infinity, alignment: .leading)

                        Picker("类型", selection: $item.kind) {
                            Text("多久后").tag(ReminderShortcut.Kind.delay)
                            Text("下次指定时刻").tag(ReminderShortcut.Kind.nextTime)
                            Text("明天指定时刻").tag(ReminderShortcut.Kind.tomorrow)
                        }
                        .labelsHidden()
                        .frame(width: 118)

                        Group {
                            if item.kind == .delay {
                                HStack(spacing: 7) {
                                    TextField("", value: Binding(
                                        get: { item.minutes },
                                        set: { item.minutes = max(1, min(10_080, $0)) }
                                    ), format: .number.grouping(.never))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 53)
                                    .accessibilityLabel("间隔分钟数")
                                    Text("分钟")
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                            } else {
                                DatePicker("时刻", selection: Binding(
                                    get: {
                                        Calendar.current.date(bySettingHour: item.hour, minute: item.minute, second: 0,
                                                              of: Date(timeIntervalSinceReferenceDate: 0)) ?? .now
                                    },
                                    set: {
                                        let components = Calendar.current.dateComponents([.hour, .minute], from: $0)
                                        var updated = item
                                        updated.hour = components.hour ?? 9
                                        updated.minute = components.minute ?? 0
                                        item = updated
                                    }
                                ), displayedComponents: [.hourAndMinute])
                                .datePickerStyle(.stepperField)
                                .labelsHidden()
                            }
                        }
                        .frame(width: 105, alignment: .leading)
                        Button {
                            let id = item.id
                            settings.items.removeAll { $0.id == id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .frame(width: 22)
                        .accessibilityLabel("移除\(item.title)")
                    }
                }
                HStack {
                    Button("添加快捷时间", systemImage: "plus") { settings.addShortcut() }
                        .disabled(settings.items.count >= ReminderShortcutSettings.maximum)
                    Spacer()
                    Button("恢复默认") { settings.items = ReminderShortcut.defaults }
                    Spacer()
                    Text("\(settings.items.count) / \(ReminderShortcutSettings.maximum)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("快捷时间")
            }

            if let authorization {
                Section("到期通知") {
                    switch authorization {
                    case .notDetermined:
                        Button("允许到期通知…") {
                            Task { await enableNotifications() }
                        }
                    case .denied:
                        LabeledContent("通知权限", value: "请在 macOS 系统设置的「通知」中开启")
                    default:
                        LabeledContent("通知权限", value: "已允许")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: scenePhase) {
            authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            await TaskReminders.shared.sync()
        }
    }

    private func enableNotifications() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        authorization = await center.notificationSettings().authorizationStatus
        await TaskReminders.shared.sync()
    }

    private func colorPicker(
        _ title: String, keyPath: WritableKeyPath<DetailColors, DetailColor>
    ) -> some View {
        let selection = Binding(
            get: { settings.colors[keyPath: keyPath].swatch },
            set: { settings.updateColor($0, at: keyPath) }
        )
        return ColorPicker(title, selection: selection, supportsOpacity: false)
    }
}
