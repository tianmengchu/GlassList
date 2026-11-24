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

private struct HeaderActionChrome: ViewModifier {
    let palette: AppPalette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        content
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(palette.surface.swatch, in: shape)
            .overlay { shape.strokeBorder(palette.text.swatch.opacity(0.13)).allowsHitTesting(false) }
            .contentShape(shape)
    }
}

struct TaskListView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.calendar) private var calendar
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ReminderShortcutSettings.self) private var detailSettings
    @Environment(TaskListModel.self) private var model
    @Environment(WindowDock.self) private var windowDock
    @Environment(AppUpdates.self) private var updates
    @AppStorage("windowDisplayMode") private var displayMode: DisplayMode = .system
    @AppStorage("strikeCompletedOnHome") private var strikeCompletedOnHome = false
    @AppStorage("homeCompletedRetentionDays") private var retentionDays = 0
    @State private var filter: ListFilter = .pending
    @State private var draft = ""
    @State private var searchQuery = ""
    @State private var showingSearch = false
    @State private var editTask: Todo?
    @State private var showNewTask = false
    @State private var showingSettings = false
    @State private var showMoveError = false
    @State private var dates = TaskDatePresentation()
    @State private var lookingAtDate = Date.now
    @State private var showingDatePicker = false
    @State private var dismissedUpdateVersion: String?
    @State private var recentlyDeleted: TaskListModel.DeletedTask?
    @State private var undoHideTask: Task<Void, Never>?
    @FocusState private var composerFocused: Bool
    @FocusState private var searchFocused: Bool

    private var palette: AppPalette { detailSettings.theme.palette(for: displayMode.colorScheme ?? scheme) }
    private var accent: Color { palette.accent.swatch }
    private var controlFill: Color { palette.surface.swatch }
    private var trimmedSearch: String { searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func visibleTasks(at date: Date) -> [Todo] {
        let base: [Todo] = if filter == .pending {
            model.homeTasks(at: date, includeCompleted: strikeCompletedOnHome, retentionDays: retentionDays)
        } else {
            model.tasks.filter(filter.contains)
        }
        guard !trimmedSearch.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedSearch)
                || ($0.note?.localizedCaseInsensitiveContains(trimmedSearch) ?? false)
        }
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
        TimelineView(.everyMinute) { context in
            let now = context.date
            let visible = visibleTasks(at: now)
            let groups = TaskDateGroup.groups(for: visible, now: now, calendar: calendar, additionalDay: dates.additionalDay)
            HStack(spacing: 0) {
                sidebar(groups: groups, now: now)
                    .frame(width: 210)
                Rectangle()
                    .fill(.primary.opacity(0.08))
                    .frame(width: 1)
                    .accessibilityHidden(true)
                Group {
                    if showingSettings {
                        settingsPanel
                    } else {
                        mainPanel(tasks: visible, groups: groups, now: now)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            DockWindowAccess(controller: windowDock, model: model, settings: detailSettings)
                .allowsHitTesting(false)
        }
        .containerBackground(palette.background.swatch, for: .window)
        .preferredColorScheme(displayMode.colorScheme)
        .environment(\.appPalette, palette)
        .foregroundStyle(palette.text.swatch)
        .tint(accent)
        .focusedSceneValue(\.todoComposer, $showNewTask)
        .focusedSceneValue(\.showListSettings, $showingSettings)
        .focusedSceneValue(\.showSearch, $showingSearch)
        .onChange(of: showNewTask) { _, isPresented in
            if isPresented { showingSettings = false }
        }
        .onChange(of: showingSearch) { _, isPresented in
            if isPresented {
                showingSettings = false
                searchFocused = true
            }
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
            TaskEditor(task: task) { title, reminder, day, note in
                model.saveTask(id: task.id, title: title, reminder: reminder, day: day, note: note)
            }
        }
        .sheet(isPresented: $showNewTask) {
            TaskEditor(draft: draft) { title, reminder, day, note in
                guard model.saveTask(id: nil, title: title, reminder: reminder, day: day, note: note) else { return false }
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
        .alert("已修复待办清单", isPresented: $model.showRecoveryNotice) {
            Button("好", role: .cancel) {}
        } message: {
            Text("本地清单文件已损坏，已恢复所有可读取的待办。原文件已备份为 list.damaged-日期.json，与清单保存在同一文件夹。")
        }
        .alert("无法更改待办日期", isPresented: $showMoveError) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请选择其他日期，或稍后再试。")
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: filter)
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: model.tasks)
    }

    private func sidebar(groups: [TaskDateGroup], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 34, height: 34)
                    .background(accent.opacity(0.13), in: .rect(cornerRadius: 11))
                    .accessibilityHidden(true)
                Text("一个完美的todolist")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.bottom, 23)

            VStack(spacing: 4) {
                ForEach(ListFilter.allCases) { item in
                    filterButton(item)
                }
            }

            dateSidebar(groups: groups, now: now)
                .padding(.top, 12)
                .padding(.bottom, 10)
            progressCard
            appearancePicker
                .padding(.top, 13)
        }
        .padding(.horizontal, 20)
        .padding(.top, 48)
        .padding(.bottom, 18)
        .background(palette.sidebar.swatch)
    }

    private func dateSidebar(groups: [TaskDateGroup], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Rectangle().fill(palette.text.swatch.opacity(0.08)).frame(height: 1)
                .accessibilityHidden(true)
            HStack {
                Text("日期")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("今天") {
                    showingSettings = false
                    dates.reveal(.day(calendar.startOfDay(for: now)))
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .help("跳转到今天")
            }
            .padding(.horizontal, 8)
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(groups) { group in
                            dateSidebarRow(group, now: now)
                                .id(group.id)
                        }
                    }
                    .padding(1)
                }
                .scrollIndicators(.hidden)
                .onChange(of: dates.jump) { _, jump in
                    if let jump { scroll.scrollTo(jump.group) }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func dateSidebarRow(_ group: TaskDateGroup, now: Date) -> some View {
        let selected = dates.jump?.group == group.id && !showingSettings
        return Button {
            showingSettings = false
            dates.reveal(group.id)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: group.id == .unscheduled ? "tray" : "calendar")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? accent : palette.secondaryText)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(group.title(at: now, calendar: calendar, abbreviated: true))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                Text(group.tasks.count, format: .number)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(accent.opacity(selected ? 0.14 : 0), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue("\(group.tasks.count) 项")
        .help(group.dropHelp)
        .taskDateDropTarget(tint: accent) { id in moveTask(id, to: group.id) }
    }

    private func moveTask(_ id: UUID, to group: TaskDateGroup.ID) {
        let moved = model.moveTask(id, to: group.day, calendar: calendar)
        showMoveError = !moved
        if moved {
            showingSettings = false
            dates.reveal(group)
        }
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
            dates.clearJump()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .foregroundStyle(selected ? accent : palette.secondaryText)
                    .frame(width: 18)
                Text(item.rawValue)
                Spacer(minLength: 4)
                Text(model.tasks.count(where: item.contains), format: .number)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: selected ? .semibold : .medium))
            .padding(.horizontal, 13)
            .frame(height: 34)
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

    private func mainPanel(tasks: [Todo], groups: [TaskDateGroup], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(now: now)
            if let update = updates.available, dismissedUpdateVersion != update.version {
                updateBanner(update)
            }
            if showingSearch {
                searchBar
            }
            listContent(tasks, groups: groups, now: now)
                .frame(maxHeight: .infinity)
            if let deleted = recentlyDeleted {
                undoBar(deleted)
            }
            Rectangle()
                .fill(palette.text.swatch.opacity(0.07))
                .frame(height: 1)
                .accessibilityHidden(true)
            composer(now: now)
        }
        .padding(.horizontal, 32)
        .padding(.top, 50)
        .padding(.bottom, 24)
    }

    private func updateBanner(_ update: AppUpdates.Update) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text("发现新版本 \(update.version)")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 8)
            Link(update.downloadURL == nil ? "查看发布页" : "下载更新", destination: update.destination)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
            Button {
                dismissedUpdateVersion = update.version
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("暂时忽略更新提示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(accent.opacity(0.10), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accent.opacity(0.24))
                .allowsHitTesting(false)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .accessibilityHidden(true)
            TextField("搜索待办标题或备注…", text: $searchQuery)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { closeSearch() }
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
            Button("取消") { closeSearch() }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(controlFill, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(searchFocused ? accent.opacity(0.65) : palette.text.swatch.opacity(0.11))
                .allowsHitTesting(false)
        }
    }

    private func closeSearch() {
        searchQuery = ""
        showingSearch = false
        searchFocused = false
    }

    private func undoBar(_ deleted: TaskListModel.DeletedTask) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 12))
                .foregroundStyle(palette.secondaryText)
                .accessibilityHidden(true)
            Text("已删除「\(deleted.task.title)」")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("撤销") {
                undoHideTask?.cancel()
                undoHideTask = nil
                model.restore(deleted)
                recentlyDeleted = nil
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(controlFill, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(palette.text.swatch.opacity(0.12))
                .allowsHitTesting(false)
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("设置")
                    .font(.system(size: 32, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("返回清单", systemImage: "chevron.backward") { showingSettings = false }
                    .buttonStyle(ThemeButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.top, 50)
            ReminderSettingsView()
        }
    }

    @ViewBuilder
    private func listContent(_ visibleTasks: [Todo], groups: [TaskDateGroup], now: Date) -> some View {
        if model.loadFailed {
            emptyState(symbol: "exclamationmark", title: "清单暂不可用", detail: "请返回应用后再试一次。")
        } else if !trimmedSearch.isEmpty && visibleTasks.isEmpty {
            emptyState(symbol: "magnifyingglass", title: "没有找到匹配的待办", detail: "换个关键词试试，或按 Esc 清除搜索。")
        } else if visibleTasks.isEmpty && dates.jump == nil {
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
            TaskDateSections(groups: groups, now: now, tint: accent, dates: $dates) { id, group in
                moveTask(id, to: group)
            } row: { task in
                taskRow(task)
            }
        }
    }

    private func header(now: Date) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 12) {
                headerTitle(now: now)
                    .fixedSize()
                Spacer(minLength: 0)
                headerActions(now: now)
                    .padding(.bottom, 3)
            }
            VStack(alignment: .leading, spacing: 12) {
                headerTitle(now: now)
                headerActions(now: now)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func headerTitle(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(now, format: dateFormat)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accent)
            Text(filter.rawValue)
                .font(.system(size: 36, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func headerActions(now: Date) -> some View {
        HStack(spacing: 8) {
            Button {
                if showingSearch {
                    closeSearch()
                } else {
                    showingSearch = true
                    searchFocused = true
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(showingSearch ? accent : palette.text.swatch)
                    .modifier(HeaderActionChrome(palette: palette))
            }
            .buttonStyle(.plain)
            .help("搜索待办 (⌘F)")
            .accessibilityLabel("搜索待办")

            datePickerButton(now: now)

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
                headerActionContent("侧边贴合", symbol: windowDock.edge?.symbol ?? "dock.rectangle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .modifier(HeaderActionChrome(palette: palette))

            Button {
                showingSettings = true
            } label: {
                headerActionContent("设置", symbol: "gearshape")
                    .modifier(HeaderActionChrome(palette: palette))
                    .overlay(alignment: .topTrailing) {
                        if updates.available != nil {
                            Circle()
                                .fill(.red)
                                .frame(width: 7, height: 7)
                                .offset(x: 2, y: -2)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(updates.available == nil ? "设置" : "设置（有可用更新）")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func headerActionContent(_ title: String, symbol: String, showsChevron: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(accent)
                .frame(width: 15)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(palette.text.swatch)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 12, weight: .medium))
    }

    private func datePickerButton(now: Date) -> some View {
        Button {
            lookingAtDate = dates.additionalDay ?? dates.jump?.group.day ?? now
            showingDatePicker = true
        } label: {
            headerActionContent("选择日期", symbol: "calendar", showsChevron: true)
                .modifier(HeaderActionChrome(palette: palette))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingDatePicker) {
            let taskDays = Set(model.tasks.lazy.filter { !$0.isDone }.compactMap(\.scheduledDate)
                .map { calendar.startOfDay(for: $0) })
            MainDatePicker(
                now: now,
                palette: palette,
                taskDays: taskDays,
                selectedDay: $lookingAtDate,
                select: { day in
                    lookingAtDate = day
                    dates.showDay(day)
                },
                finish: { showingDatePicker = false }
            )
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
        TaskRowCard(
            task: task,
            palette: palette,
            detailColors: detailSettings.colors,
            showsCountdown: detailSettings.display.showsCountdown,
            toggleDone: { model.setDone(task, to: !task.isDone) },
            edit: { editTask = task },
            delete: { deleteTask(task) }
        )
    }

    private func deleteTask(_ task: Todo) {
        guard let deleted = model.deleteReturning(task.id) else { return }
        undoHideTask?.cancel()
        recentlyDeleted = deleted
        undoHideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            recentlyDeleted = nil
        }
    }

    private func quickAddTask(now: Date) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showNewTask = true
            return
        }
        let today = calendar.startOfDay(for: now)
        guard model.saveTask(id: nil, title: trimmed, reminder: nil, day: today, note: "") else { return }
        draft = ""
        if filter == .completed { filter = .pending }
        dates.reveal(.day(today))
    }

    private func composer(now: Date) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent)
                .accessibilityHidden(true)

            TextField("添加一条待办，回车快速记到今天…", text: $draft)
                .font(.system(size: 14))
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .onSubmit { quickAddTask(now: now) }

            Button("详细") { showNewTask = true }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(ThemeButtonStyle(prominent: true))
                .help("打开完整编辑窗口，设置提醒时间和备注 (⌘N)")
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

private struct TaskRowCard: View {
    let task: Todo
    let palette: AppPalette
    let detailColors: DetailColors
    let showsCountdown: Bool
    let toggleDone: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    @State private var isHovered = false

    private var accent: Color { palette.accent.swatch }
    private var hasDetails: Bool { task.scheduledDate != nil || task.note != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button(action: toggleDone) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(task.isDone ? accent : palette.secondaryText)
                    .frame(width: 30, height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "恢复待办：\(task.title)" : "完成待办：\(task.title)")

            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(.system(size: 15, weight: .semibold))
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, hasDetails ? 2 : 6)
                    .onTapGesture(count: 2, perform: edit)
                if hasDetails {
                    HStack(alignment: .top, spacing: 7) {
                        if let time = task.reminderAt {
                            DetailTag(symbol: "clock", tint: detailColors.time.swatch) {
                                Text(time, format: .dateTime.year().month(.defaultDigits).day().hour().minute())
                            }
                            .layoutPriority(1)
                        } else if let day = task.scheduledDay {
                            DetailTag(symbol: "calendar", tint: detailColors.time.swatch) {
                                Text(day, format: .dateTime.year().month(.defaultDigits).day())
                            }
                            .layoutPriority(1)
                        }
                        if let note = task.note {
                            DetailTag(symbol: "note.text", tint: detailColors.note.swatch, lineLimit: 2) {
                                Text(note)
                            }
                            .help(note)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 4) {
                    if isHovered {
                        Button(action: edit) {
                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(accent)
                                .frame(width: 24, height: 23)
                                .background(accent.opacity(0.11), in: .rect(cornerRadius: 6))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help("编辑待办")
                        .accessibilityLabel("编辑待办：\(task.title)")
                    }
                    Menu {
                        actions
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 24, height: 23)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("待办操作")
                }
                if showsCountdown, let time = task.reminderAt, !task.isDone {
                    TaskDueCountdown(date: time)
                        .frame(width: 108, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(palette.surface.swatch, in: .rect(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(isHovered ? accent.opacity(0.32) : palette.text.swatch.opacity(0.05))
                .allowsHitTesting(false)
        }
        .onHover { isHovered = $0 }
        .contextMenu { actions }
    }

    @ViewBuilder
    private var actions: some View {
        Button("编辑待办…", systemImage: "pencil", action: edit)
        Button("删除", systemImage: "trash", role: .destructive, action: delete)
    }
}

private struct MainDatePicker: View {
    let now: Date
    let palette: AppPalette
    let taskDays: Set<Date>
    @Binding var selectedDay: Date
    let select: (Date) -> Void
    let finish: () -> Void

    @Environment(\.calendar) private var calendar
    @State private var displayedMonth: Date?

    private var today: Date { calendar.startOfDay(for: now) }
    private var activeDay: Date { calendar.startOfDay(for: selectedDay) }
    private var tint: Color { palette.accent.swatch }
    private var monthStart: Date { calendar.dateInterval(of: .month, for: displayedMonth ?? activeDay)?.start ?? today }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(monthStart, format: .dateTime.year().month(.wide).locale(Locale(identifier: "zh_CN")))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                monthButton(-1, label: "上个月", symbol: "chevron.left")
                monthButton(1, label: "下个月", symbol: "chevron.right")
            }

            HStack(spacing: 6) {
                shortcut("今天", systemImage: "sun.max") {
                    choose(today)
                }
                shortcut("明天", systemImage: "sunrise") {
                    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) {
                        choose(tomorrow)
                    }
                }
                shortcut("下周", systemImage: "calendar") {
                    if let nextWeek = calendar.date(byAdding: .day, value: 7, to: today) {
                        choose(nextWeek)
                    }
                }
            }

            monthGrid

            Label {
                Text("已有待办")
                    .foregroundStyle(.secondary)
            } icon: {
                Circle().fill(.red).frame(width: 5, height: 5)
            }
            .font(.caption2)

            Rectangle().fill(palette.text.swatch.opacity(0.1)).frame(height: 1)
                .accessibilityHidden(true)
            HStack(spacing: 10) {
                Text(activeDay, format: .dateTime.year().month().day().locale(Locale(identifier: "zh_CN")))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成", action: finish)
                    .buttonStyle(ThemeButtonStyle(prominent: true))
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 310)
        .background(palette.background.swatch)
        .foregroundStyle(palette.text.swatch)
        .tint(tint)
    }

    private func choose(_ day: Date) {
        let normalized = calendar.startOfDay(for: day)
        displayedMonth = normalized
        select(normalized)
    }

    private var monthGrid: some View {
        var chineseCalendar = calendar
        chineseCalendar.locale = Locale(identifier: "zh_CN")
        let firstWeekday = calendar.firstWeekday
        let weekdayNames = chineseCalendar.veryShortStandaloneWeekdaySymbols
        let leading = (calendar.component(.weekday, from: monthStart) - firstWeekday + 7) % 7
        let days = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 0
        let cellCount = ((leading + days + 6) / 7) * 7
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 4) {
            ForEach(0..<7, id: \.self) { offset in
                Text(weekdayNames[(firstWeekday - 1 + offset) % 7])
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 17)
                    .accessibilityHidden(true)
            }
            ForEach(0..<cellCount, id: \.self) { cell in
                let offset = cell - leading
                if (0..<days).contains(offset), let day = calendar.date(byAdding: .day, value: offset, to: monthStart) {
                    dayButton(calendar.startOfDay(for: day))
                } else {
                    Color.clear.frame(height: 31).accessibilityHidden(true)
                }
            }
        }
    }

    private func dayButton(_ day: Date) -> some View {
        let isToday = day == today
        let selected = day == activeDay
        let hasTasks = taskDays.contains(day)
        return Button {
            choose(day)
        } label: {
            Text(calendar.component(.day, from: day), format: .number)
                .font(.system(size: 12, weight: selected || isToday ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(selected ? tint : palette.text.swatch)
                .frame(maxWidth: .infinity)
                .frame(height: 31)
                .background(selected ? tint.opacity(0.15) : Color.primary.opacity(0.035), in: .rect(cornerRadius: 7))
                .overlay {
                    if isToday && !selected {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(tint.opacity(0.5))
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(tint)
                            .padding(3)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottom) {
                    if hasTasks {
                        Circle().fill(.red)
                            .frame(width: 5, height: 5)
                            .padding(.bottom, 3)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(day, format: .dateTime.year().month().day().weekday()))
        .accessibilityValue(hasTasks ? "已有待办" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func monthButton(_ offset: Int, label: String, symbol: String) -> some View {
        Button {
            displayedMonth = calendar.date(byAdding: .month, value: offset, to: monthStart)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 25, height: 25)
                .background(.primary.opacity(0.055), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func shortcut(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .frame(height: 27)
                .background(tint.opacity(0.1), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}
