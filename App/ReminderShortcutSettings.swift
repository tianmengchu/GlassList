import AppKit
import ServiceManagement
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
    private static let themeKey = "appTheme"
    private static let defaultDockColor = DetailColor(red: 0.12, green: 0.38, blue: 0.34)
    static let maximum = 10
    private(set) var colors = DetailColors()
    private(set) var customDockTabColor: DetailColor?
    var dockTabColor: DetailColor {
        if let customDockTabColor { return customDockTabColor }
        if theme.preset == .standard && theme.day == nil { return Self.defaultDockColor }
        return theme.palette(for: .light).accent
    }
    private(set) var colorSaveFailed = false
    private(set) var display = TaskDisplaySettings()
    private(set) var displaySaveFailed = false
    private(set) var theme = AppTheme() {
        didSet {
            if let data = try? JSONEncoder().encode(theme) {
                UserDefaults.standard.set(data, forKey: Self.themeKey)
            }
        }
    }
    @ObservationIgnored private var colorSave: Task<Void, Never>?
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
        if let data = UserDefaults.standard.data(forKey: Self.themeKey),
           let saved = try? JSONDecoder().decode(AppTheme.self, from: data) {
            theme = saved
        }
        if let store = try? TaskStore.shared() {
            colors = (try? store.loadDetailColors()) ?? DetailColors()
            display = (try? store.loadDisplaySettings()) ?? TaskDisplaySettings()
        }
        if let data = UserDefaults.standard.data(forKey: Self.dockColorKey),
           let saved = try? JSONDecoder().decode(DetailColor.self, from: data) {
            customDockTabColor = saved
        }
    }

    func addShortcut() {
        guard items.count < Self.maximum else { return }
        items.append(ReminderShortcut(id: (items.map(\.id).max() ?? 0) + 1, kind: .delay))
    }

    func updateColor(_ selection: Color, at keyPath: WritableKeyPath<DetailColors, DetailColor>) {
        guard let selected = DetailColor(selection), colors[keyPath: keyPath] != selected else { return }
        colors[keyPath: keyPath] = selected
        // The color picker reports every drag step; write the file and refresh widgets once it settles.
        colorSave?.cancel()
        colorSave = Task { [colors] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                try TaskStore.shared().updateDetailColors { $0 = colors }
                colorSaveFailed = false
                WidgetCenter.shared.reloadTimelines(ofKind: GlassList.widgetKind)
            } catch {
                colorSaveFailed = true
            }
        }
    }

    func updateDockColor(_ selection: Color) {
        guard let color = DetailColor(selection),
              let data = try? JSONEncoder().encode(color) else { return }
        UserDefaults.standard.set(data, forKey: Self.dockColorKey)
        customDockTabColor = color
    }

    func useThemeDockColor() {
        UserDefaults.standard.removeObject(forKey: Self.dockColorKey)
        customDockTabColor = nil
    }

    func applyTheme(_ preset: ThemePreset) {
        theme = AppTheme(preset: preset)
    }

    func updateThemeColor(_ selection: Color, at keyPath: WritableKeyPath<AppPalette, DetailColor>, for scheme: ColorScheme) {
        guard let color = DetailColor(selection) else { return }
        theme.setColor(color, at: keyPath, for: scheme)
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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.appPalette) private var appPalette
    @AppStorage(WindowDock.autoDockAtLaunchKey) private var autoDockAtLaunch = false
    @AppStorage("strikeCompletedOnHome") private var strikeCompletedOnHome = false
    @AppStorage("homeCompletedRetentionDays") private var retentionDays = 0
    @State private var authorization: UNAuthorizationStatus?
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemError: String?
    @State private var editingThemeScheme: ColorScheme?

    private var themeScheme: ColorScheme { editingThemeScheme ?? scheme }

    private var loginItemRegistered: Bool {
        loginItemStatus == .enabled || loginItemStatus == .requiresApproval
    }

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsGroup("启动") {
                    settingsToggle("登录时启动", isOn: Binding(
                        get: { loginItemRegistered },
                        set: { setLoginItem(enabled: $0) }
                    ))
                    if loginItemStatus == .requiresApproval {
                        LabeledContent("登录项", value: "等待 macOS 批准")
                        Button("打开系统登录项设置…") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                    if let loginItemError {
                        Text(loginItemError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    settingsToggle("启动时自动贴边", isOn: $autoDockAtLaunch)
                        .help("沿用上次选择的贴边方向，首次默认贴合右侧。")
                }

                settingsGroup("版本与更新") {
                    LabeledContent("当前版本", value: "\(AppUpdates.version)（\(AppUpdates.build)）")
                    settingsToggle("自动检查更新", isOn: Binding(
                        get: { updates.automaticallyChecks },
                        set: { updates.setAutomaticChecks($0) }
                    ))
                    HStack {
                        Button(updates.isChecking ? "正在检查…" : "检查更新…") {
                            Task { await updates.check() }
                        }
                        .disabled(updates.isChecking)
                        Spacer()
                        Link("GitHub 发布页", destination: AppUpdates.releasePage)
                    }
                    if let update = updates.available {
                        LabeledContent("可用更新", value: update.version)
                        if let notes = update.notes {
                            Text(notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(.primary.opacity(0.04), in: .rect(cornerRadius: 8))
                        }
                        HStack(spacing: 12) {
                            Link(update.downloadURL == nil ? "查看 \(update.version) 发布页" : "下载 \(update.version) 安装包",
                                 destination: update.destination)
                            if update.downloadURL != nil {
                                Link("查看发布说明", destination: update.releaseURL)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let statusMessage = updates.statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                settingsGroup("显示") {
                    settingsToggle("显示倒计时", isOn: Binding(
                        get: { settings.display.showsCountdown },
                        set: { settings.setShowsCountdown($0) }
                    ))
                    .help("同时控制主窗口、侧边清单和桌面小组件的倒计时")
                    if settings.displaySaveFailed {
                        Text("暂时无法保存显示设置，请重试。")
                            .foregroundStyle(.red)
                    }
                }
                settingsGroup("配色") {
                    ThemeGallery(theme: settings.theme, scheme: themeScheme, select: settings.applyTheme)
                    LabeledContent("调整模式") {
                        Picker("调整模式", selection: Binding(get: { themeScheme }, set: { editingThemeScheme = $0 })) {
                            Text("日间").tag(ColorScheme.light)
                            Text("夜间").tag(ColorScheme.dark)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 132)
                    }
                    themeColorPicker("主窗口背景", keyPath: \.background)
                    themeColorPicker("导航栏背景", keyPath: \.sidebar)
                    themeColorPicker("卡片和输入框", keyPath: \.surface)
                    themeColorPicker("文字", keyPath: \.text)
                    themeColorPicker("强调色", keyPath: \.accent)
                    Button("恢复默认主题") { settings.applyTheme(.standard) }
                        .disabled(settings.theme.preset == .standard && !settings.theme.hasCustomColors)
                }
                settingsGroup("标签与侧边条") {
                    colorPicker("时间标签", keyPath: \.time)
                    colorPicker("备注标签", keyPath: \.note)
                    settingsColorPicker("侧边条", selection: Binding(
                        get: { settings.dockTabColor.swatch },
                        set: { settings.updateDockColor($0) }
                    ))
                    if settings.customDockTabColor != nil {
                        Button("侧边条跟随主题") { settings.useThemeDockColor() }
                    }
                    if settings.colorSaveFailed {
                        Text("暂时无法保存颜色，请重试。")
                            .foregroundStyle(.red)
                    }
                }

                settingsGroup("完成项") {
                    LabeledContent("完成后") {
                        Picker("完成后", selection: $strikeCompletedOnHome) {
                            Text("移到已完成").tag(false)
                            Text("在首页划线保留").tag(true)
                        }
                        .labelsHidden()
                    }
                    LabeledContent("首页完成项保留") {
                        Picker("首页完成项保留", selection: $retentionDays) {
                            Text("永远保留").tag(0)
                            Text("完成后 1 天").tag(1)
                            Text("完成后 7 天").tag(7)
                            Text("完成后 30 天").tag(30)
                        }
                        .labelsHidden()
                        .disabled(!strikeCompletedOnHome)
                    }
                }

                settingsGroup("快捷时间") {
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
                }

                if let authorization {
                    settingsGroup("到期通知") {
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
            .frame(maxWidth: 700)
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .labeledContentStyle(SettingsRowStyle())
        .background(appPalette?.background.swatch ?? Color.clear)
        .task(id: scenePhase) {
            loginItemStatus = SMAppService.mainApp.status
            authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            await TaskReminders.shared.sync()
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 3)
            VStack(alignment: .leading, spacing: 11, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(appPalette?.surface.swatch ?? Color(nsColor: .controlBackgroundColor),
                            in: .rect(cornerRadius: 12))
                .buttonStyle(ThemeButtonStyle())
        }
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        LabeledContent(title) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func settingsColorPicker(_ title: String, selection: Binding<Color>) -> some View {
        LabeledContent(title) {
            ColorPicker(title, selection: selection, supportsOpacity: false).labelsHidden()
        }
    }

    private func setLoginItem(enabled: Bool) {
        let service = SMAppService.mainApp
        loginItemStatus = service.status
        loginItemError = nil
        guard enabled != loginItemRegistered else { return }
        defer { loginItemStatus = service.status }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            if !enabled || service.status != .requiresApproval {
                loginItemError = enabled ? "暂时无法启用登录时启动，请重试。" : "暂时无法关闭登录时启动，请重试。"
            }
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
        return settingsColorPicker(title, selection: selection)
    }

    private func themeColorPicker(_ title: String, keyPath: WritableKeyPath<AppPalette, DetailColor>) -> some View {
        settingsColorPicker(title, selection: Binding(
            get: { settings.theme.palette(for: themeScheme)[keyPath: keyPath].swatch },
            set: { settings.updateThemeColor($0, at: keyPath, for: themeScheme) }
        ))
    }
}

private struct SettingsRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
            Spacer(minLength: 6)
            configuration.content
        }
    }
}
