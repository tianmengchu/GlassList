import SwiftUI

private enum ListFilter: String, CaseIterable, Identifiable {
    case pending = "待办"
    case completed = "已完成"
    case all = "全部"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .pending: "circle.dashed"
        case .completed: "checkmark.circle"
        case .all: "list.bullet"
        }
    }

    func contains(_ task: Todo) -> Bool {
        switch self {
        case .pending: !task.isDone
        case .completed: task.isDone
        case .all: true
        }
    }
}

struct TaskListView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ReminderShortcutSettings.self) private var detailSettings
    @Environment(TaskListModel.self) private var model
    @Environment(WindowDock.self) private var windowDock
    @AppStorage("windowDisplayMode") private var displayMode: DisplayMode = .system
    @AppStorage("strikeCompletedOnHome") private var strikeCompletedOnHome = false
    @AppStorage("homeCompletedRetentionDays") private var retentionDays = 0
    @State private var filter: ListFilter = .pending
    @State private var draft = ""
    @State private var editTask: Todo?
    @State private var showNewTask = false
    @State private var showingSettings = false
    @FocusState private var composerFocused: Bool

    private var isDark: Bool { scheme == .dark }
    private var accent: Color { isDark ? Color(red: 0.65, green: 0.88, blue: 0.80) : Color(red: 0.13, green: 0.41, blue: 0.36) }
    private var windowFill: Color { isDark ? Color(red: 0.08, green: 0.10, blue: 0.12) : Color(red: 0.97, green: 0.98, blue: 0.98) }
    private var sidebarFill: Color { isDark ? Color(red: 0.11, green: 0.13, blue: 0.16) : Color(red: 0.92, green: 0.94, blue: 0.94) }
    private var controlFill: Color { isDark ? Color(red: 0.13, green: 0.16, blue: 0.19) : .white }
    private func visibleTasks(at date: Date) -> [Todo] {
        if filter == .pending {
            return model.homeTasks(at: date, includeCompleted: strikeCompletedOnHome, retentionDays: retentionDays)
        }
        return model.tasks.filter(filter.contains)
    }
    private var doneCount: Int { model.tasks.count(where: \.isDone) }
    private let dateFormat = Date.VerbatimFormatStyle(
        format: "\(month: .defaultDigits)月\(day: .defaultDigits)日 \(weekday: .wide)",
        locale: Locale(identifier: "zh_CN"),
        timeZone: .autoupdatingCurrent,
        calendar: Calendar(identifier: .gregorian)
    )

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
            Rectangle()
                .fill(.primary.opacity(0.08))
                .frame(width: 1)
                .accessibilityHidden(true)
            Group {
                if showingSettings {
                    settingsPanel
                } else {
                    mainPanel
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            DockWindowAccess(controller: windowDock, model: model, settings: detailSettings)
                .allowsHitTesting(false)
        }
        .containerBackground(windowFill, for: .window)
        .preferredColorScheme(displayMode.colorScheme)
        .tint(accent)
        .focusedSceneValue(\.todoComposer, $showNewTask)
        .focusedSceneValue(\.showListSettings, $showingSettings)
        .onChange(of: showNewTask) { _, isPresented in
            if isPresented { showingSettings = false }
        }
        .task { model.reload(refreshWidget: true) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.reload() }
        }
        .onOpenURL { url in
            guard url.scheme == GlassList.openURL.scheme else { return }
            model.reload()
            windowDock.bringMainWindowForward()
            if url.host == GlassList.newTaskURL.host { showNewTask = true }
        }
        .sheet(item: $editTask) { task in
            TaskEditor(task: task) { title, date, note in
                model.saveTask(id: task.id, title: title, reminder: date, note: note)
            }
        }
        .sheet(isPresented: $showNewTask) {
            TaskEditor(draft: draft) { title, date, note in
                guard model.saveTask(id: nil, title: title, reminder: date, note: note) else { return false }
                draft = ""
                if filter == .completed { filter = .pending }
                return true
            }
        }
        .alert("无法保存待办", isPresented: $model.showSaveError) {
            Button("好", role: .cancel) {}
        } message: {
            Text("暂时无法写入本地清单。请稍后重试。")
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: filter)
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: model.tasks)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 34, height: 34)
                    .background(accent.opacity(0.13), in: .rect(cornerRadius: 11))
                    .accessibilityHidden(true)
                Text("浮光清单")
                    .font(.system(size: 16, weight: .semibold))
            }
            .padding(.bottom, 32)

            VStack(spacing: 4) {
                ForEach(ListFilter.allCases) { item in
                    filterButton(item)
                }
            }

            Spacer(minLength: 20)
            progressCard
            appearancePicker
                .padding(.top, 20)
        }
        .padding(.horizontal, 20)
        .padding(.top, 52)
        .padding(.bottom, 24)
        .background(sidebarFill)
    }

    private var appearancePicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("外观")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            HStack(spacing: 2) {
                ForEach(DisplayMode.allCases) { mode in
                    let selected = displayMode == mode
                    Button {
                        displayMode = mode
                    } label: {
                        Text(mode == .system ? "系统" : mode.title)
                            .font(.system(size: 11, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background(selected ? controlFill : .clear, in: .rect(cornerRadius: 6))
                            .contentShape(.rect(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(mode.title))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(3)
            .background(.primary.opacity(0.07), in: .rect(cornerRadius: 9))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("主窗口外观")
        }
    }

    private func filterButton(_ item: ListFilter) -> some View {
        let selected = filter == item && !showingSettings
        return Button {
            filter = item
            showingSettings = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .foregroundStyle(selected ? accent : .secondary)
                    .frame(width: 18)
                Text(item.rawValue)
                Spacer(minLength: 4)
                Text(model.tasks.count(where: item.contains), format: .number)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: selected ? .semibold : .medium))
            .padding(.horizontal, 13)
            .frame(height: 38)
            .contentShape(.rect(cornerRadius: 13))
            .background(accent.opacity(selected ? 0.13 : 0), in: .rect(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var progressCard: some View {
        let total = model.tasks.count
        let fraction = total == 0 ? 0 : Double(doneCount) / Double(total)

        return HStack(spacing: 10) {
            ZStack {
                Circle().strokeBorder(accent.opacity(0.22), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .padding(1.25)
                    .rotationEffect(.degrees(-90))
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("完成进度")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(doneCount) / \(total) 项")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: .rect(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.075)) }
        .accessibilityElement(children: .combine)
    }

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            TimelineView(.everyMinute) { context in
                listContent(visibleTasks(at: context.date))
            }
            .frame(maxHeight: .infinity)
            composer
        }
        .padding(.horizontal, 32)
        .padding(.top, 50)
        .padding(.bottom, 24)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("设置")
                    .font(.system(size: 32, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("返回清单", systemImage: "chevron.backward") { showingSettings = false }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.top, 50)
            ReminderSettingsView()
        }
    }

    @ViewBuilder
    private func listContent(_ visibleTasks: [Todo]) -> some View {
        if model.loadFailed {
            emptyState(symbol: "exclamationmark", title: "清单暂不可用", detail: "请返回应用后再试一次。")
        } else if visibleTasks.isEmpty {
            switch filter {
            case .pending:
                if model.tasks.isEmpty {
                    emptyState(symbol: "checkmark", title: "清单还是空的", detail: "在下方输入，记下第一件要做的事。")
                } else {
                    emptyState(symbol: "checkmark", title: "待办已清空", detail: "所有待办都完成了。")
                }
            case .completed:
                emptyState(symbol: "checkmark", title: "还没有完成的待办", detail: "勾选后的待办会出现在这里。")
            case .all:
                emptyState(symbol: "checkmark", title: "清单还是空的", detail: "在下方添加你的第一条待办。")
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(visibleTasks) { task in
                        taskRow(task)
                    }
                }
                .padding(.vertical, 1)
            }
            .defaultScrollAnchor(.top)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.everyMinute) { context in
                    Text(context.date, format: dateFormat)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(accent)
                }
                Text(filter.rawValue)
                    .font(.system(size: 36, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()

            Button {
                showingSettings = true
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.bottom, 4)

            Menu {
                ForEach(DockEdge.allCases) { edge in
                    Button {
                        windowDock.dock(to: edge)
                    } label: {
                        Label(edge.title, systemImage: windowDock.edge == edge ? "checkmark" : edge.symbol)
                    }
                }
                if windowDock.edge != nil {
                    Divider()
                    Button("取消贴合") { windowDock.undock() }
                }
            } label: {
                Label("侧边贴合", systemImage: windowDock.edge?.symbol ?? "dock.rectangle")
            }
            .controlSize(.large)
            .padding(.bottom, 4)
        }
    }

    private func emptyState(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 64, height: 64)
                .background(accent.opacity(0.10), in: .rect(cornerRadius: 20))
                .padding(.bottom, 8)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 18, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func taskRow(_ task: Todo) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Button {
                model.setDone(task, to: !task.isDone)
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(task.isDone ? accent : .secondary)
                    .frame(width: 30, height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "恢复待办：\(task.title)" : "完成待办：\(task.title)")

            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(.system(size: 17, weight: .semibold))
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture(count: 2) { editTask = task }
                HStack(spacing: 7) {
                    DetailTag(symbol: "clock", tint: detailSettings.colors.time.swatch) {
                        if let time = task.reminderAt {
                            Text(time, format: .dateTime.year().month(.defaultDigits).day().hour().minute())
                        } else {
                            Text("未设置时间")
                        }
                    }
                    .layoutPriority(1)
                    DetailTag(symbol: "note.text", tint: detailSettings.colors.note.swatch) {
                        Text(task.note?.replacingOccurrences(of: "\n", with: " ") ?? "无备注")
                    }
                    .help(task.note ?? "无备注")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 7) {
                Menu {
                    taskActions(task)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 24, height: 23)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("待办操作")
                if detailSettings.display.showsCountdown, let time = task.reminderAt, !task.isDone {
                    TaskDueCountdown(date: time)
                        .frame(width: 108, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(.primary.opacity(0.045), in: .rect(cornerRadius: 13))
        .contextMenu { taskActions(task) }
    }

    @ViewBuilder
    private func taskActions(_ task: Todo) -> some View {
        Button("编辑待办…", systemImage: "pencil") { editTask = task }
        Button("删除", systemImage: "trash", role: .destructive) { model.delete(task.id) }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent)
                .accessibilityHidden(true)

            TextField("添加一条待办…", text: $draft)
                .font(.system(size: 14))
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .onSubmit { showNewTask = true }

            Button("添加") { showNewTask = true }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(accent)
                .foregroundStyle(isDark ? Color.black.opacity(0.82) : .primary)
        }
        .padding(.leading, 17)
        .padding(.trailing, 8)
        .frame(height: 48)
        .background(controlFill, in: .rect(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(composerFocused ? accent.opacity(0.7) : .primary.opacity(0.10))
                .allowsHitTesting(false)
        }
    }

}
