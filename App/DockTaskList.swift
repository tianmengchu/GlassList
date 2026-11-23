import AppKit
import SwiftUI

struct DockTaskList: View {
    private enum Editor {
        case new
        case edit(Todo)

        var task: Todo? {
            if case let .edit(task) = self { return task }
            return nil
        }
    }

    let model: TaskListModel
    let settings: ReminderShortcutSettings
    let draftEditingChanged: (Bool) -> Void
    let datePickerVisibilityChanged: (Bool) -> Void
    let editorVisibilityChanged: (Bool) -> Void

    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.calendar) private var calendar
    @AppStorage("windowDisplayMode") private var displayMode: DisplayMode = .system
    @AppStorage("strikeCompletedOnHome") private var strikeCompletedOnHome = false
    @AppStorage("homeCompletedRetentionDays") private var retentionDays = 0
    @AppStorage("dockSelectedDates") private var storedDates = Data()
    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var dates = TaskDatePresentation()
    @State private var editor: Editor?
    @State private var showingDatePicker = false
    @State private var saveMessage: String?
    @FocusState private var composerFocused: Bool

    private let radius: CGFloat = 20
    private var scheme: ColorScheme { displayMode.colorScheme ?? systemScheme }
    private var palette: AppPalette { settings.theme.palette(for: scheme) }
    private var accent: Color { palette.accent.swatch }
    private var surface: Color { palette.surface.swatch.opacity(0.42) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        Group {
            if let editor {
                TaskEditor(task: editor.task, draft: draft, closeDockEditor: { self.editor = nil }) { title, reminder, day, note in
                    saveTask(id: editor.task?.id, title: title, reminder: reminder, day: day, note: note)
                }
                .environment(settings)
            } else {
                listContent
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            DockGlass(radius: radius)
                .overlay { shape.fill(palette.background.swatch.opacity(0.46)).allowsHitTesting(false) }
        }
        .overlay { shape.strokeBorder(.primary.opacity(0.12)).allowsHitTesting(false) }
        .environment(\.colorScheme, scheme)
        .environment(\.appPalette, palette)
        .foregroundStyle(palette.text.swatch)
        .tint(accent)
        .allowsWindowActivationEvents()
        .onChange(of: composerFocused && !draft.isEmpty) { _, isEditing in draftEditingChanged(isEditing) }
        .onChange(of: editor != nil) { _, isVisible in editorVisibilityChanged(isVisible) }
        .onChange(of: showingDatePicker) { _, isVisible in datePickerVisibilityChanged(isVisible) }
    }

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.everyMinute) { context in
                let tasks = model.homeTasks(at: context.date, includeCompleted: strikeCompletedOnHome,
                                           retentionDays: retentionDays)
                VStack(alignment: .leading, spacing: 10) {
                    dateHeader(now: context.date)
                    if model.loadFailed {
                        Text("清单暂不可用")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        let groups = TaskDateGroup.groups(for: tasks, now: context.date, calendar: calendar,
                                                          visibleDays: selectedDays)
                        TaskDateSections(groups: groups, now: context.date, tint: accent, dates: $dates, compact: true,
                                         removeDay: removeDate) { id, group in
                            let moved = model.moveTask(id, to: group.day, calendar: calendar)
                            saveMessage = nil
                            errorMessage = moved ? nil : "无法更改待办日期。请选择其他日期，或稍后再试。"
                            if moved { dates.reveal(group) }
                        } row: { task in
                            row(task)
                        }
                    }
                }
            }
            if let message = errorMessage ?? saveMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(errorMessage == nil ? palette.secondaryText : .red)
                    .padding(.horizontal, 4)
            }
            composer
        }
    }

    private func dateHeader(now: Date) -> some View {
        HStack {
            Text("待办清单")
                .font(.system(size: 16, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("恢复默认显示", systemImage: "arrow.counterclockwise") { resetDates(now: now) }
                .labelStyle(.iconOnly)
                .buttonStyle(ThemeButtonStyle())
                .controlSize(.small)
                .help("恢复默认显示：今天和未安排日期")
            Button("添加日期", systemImage: "calendar.badge.plus") { showingDatePicker.toggle() }
                .font(.caption.weight(.semibold))
                .buttonStyle(ThemeButtonStyle())
                .controlSize(.small)
                .popover(isPresented: $showingDatePicker) {
                    let taskDays = Set(model.tasks.compactMap(\.scheduledDate).map { calendar.startOfDay(for: $0) })
                    DockDatePicker(now: now, palette: palette, taskDays: taskDays,
                                   selectedDays: Binding(get: { selectedDays }, set: storeDates),
                                   reset: { resetDates(now: now) },
                                   finish: { showingDatePicker = false })
                }
        }
        .padding(.horizontal, 4)
    }

    private var civilCalendar: Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    private var selectedDays: Set<Date> {
        let entries = (try? JSONDecoder().decode([DateComponents].self, from: storedDates)) ?? []
        let gregorian = civilCalendar
        return Set(entries.compactMap { gregorian.date(from: $0) }.map { calendar.startOfDay(for: $0) })
    }

    private func removeDate(_ date: Date) {
        storeDates(selectedDays.subtracting([date]))
    }

    private func resetDates(now: Date) {
        storeDates([])
        dates = TaskDatePresentation()
        dates.reveal(.day(calendar.startOfDay(for: now)))
    }

    private func storeDates(_ days: Set<Date>) {
        let gregorian = civilCalendar
        let entries = days.sorted().map { gregorian.dateComponents([.year, .month, .day], from: $0) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        storedDates = data
        saveMessage = nil
        if let current = dates.jump?.group.day, !calendar.isDateInToday(current), !days.contains(current) {
            dates.clearJump()
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("添加一条待办…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($composerFocused)
                .onSubmit { openEditor(.new) }
                .onExitCommand { composerFocused = false }

            Button("添加", systemImage: "plus") { openEditor(.new) }
                .buttonStyle(ThemeButtonStyle(prominent: true))
                .controlSize(.small)
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 35)
        .dockInputSurface(tint: accent, fill: surface, focused: composerFocused)
    }

    private func openEditor(_ destination: Editor) {
        showingDatePicker = false
        saveMessage = nil
        composerFocused = false
        editor = destination
    }

    private func saveTask(id: UUID?, title: String, reminder: Date?, day: Date?, note: String) -> Bool {
        guard model.saveTask(id: id, title: title, reminder: reminder, day: day, note: note) else { return false }
        if id == nil { draft = "" }
        errorMessage = nil
        if let day = (reminder ?? day).map({ calendar.startOfDay(for: $0) }) {
            if calendar.isDateInToday(day) || selectedDays.contains(day) {
                dates.reveal(.day(day))
            } else {
                let label = day.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN")))
                saveMessage = "已保存到\(label)"
            }
        } else {
            dates.reveal(.unscheduled)
        }
        return true
    }

    private func row(_ task: Todo) -> some View {
        HStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    let saved = model.setDone(task, to: !task.isDone, reportError: false)
                    saveMessage = nil
                    errorMessage = saved ? nil : "无法保存待办，请重试。"
                } label: {
                    Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(task.isDone ? accent : palette.secondaryText)
                        .frame(width: 24, height: 25)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(task.isDone ? "恢复待办：\(task.title)" : "完成待办：\(task.title)")

                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(task.isDone ? .secondary : .primary)
                        .strikethrough(task.isDone)
                        .lineLimit(2)
                        .help(task.title)
                    if task.reminderAt != nil || task.note != nil {
                        DockDetailTags {
                            if let date = task.reminderAt {
                                DetailTag(symbol: "clock", tint: settings.colors.time.swatch, compact: true,
                                          stretchesVertically: true) {
                                    Text(date, format: .dateTime.month(.defaultDigits).day().hour().minute())
                                }
                            }
                            if let note = task.note {
                                DetailTag(symbol: "note.text", tint: settings.colors.note.swatch, compact: true,
                                          lineLimit: 2, stretchesVertically: true) {
                                    Text(note)
                                }
                                .help(note)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)

                if settings.display.showsCountdown, let date = task.reminderAt, !task.isDone {
                    TaskDueCountdown(date: date)
                        .frame(width: 79, alignment: .trailing)
                        .padding(.vertical, 3)
                }
            }

            Button {
                openEditor(.edit(task))
            } label: {
                let shape = RoundedRectangle(cornerRadius: 6)
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 27, height: 25)
                    .background(accent.opacity(0.11), in: shape)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑待办：\(task.title)")
            .help("编辑待办")
        }
        .padding(6)
        .background(surface, in: .rect(cornerRadius: 10))
        .contentShape(.rect(cornerRadius: 10))
        .contextMenu {
            Button("编辑待办…", systemImage: "pencil") { openEditor(.edit(task)) }
            Button("删除", systemImage: "trash", role: .destructive) {
                let deleted = model.delete(task.id, reportError: false)
                saveMessage = nil
                errorMessage = deleted ? nil : "无法删除待办，请重试。"
            }
        }
    }
}

private struct DockDetailTags: Layout {
    private let spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = measure(subviews, width: proposal.width)
        return CGSize(width: sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, sizes.count - 1)),
                      height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, size) in zip(subviews, measure(subviews, width: proposal.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: size.width, height: bounds.height))
            x += size.width + spacing
        }
    }

    private func measure(_ subviews: Subviews, width: CGFloat?) -> [CGSize] {
        var remaining = width
        return subviews.map { subview in
            let size = subview.sizeThatFits(ProposedViewSize(width: remaining, height: nil))
            remaining = remaining.map { max(0, $0 - size.width - spacing) }
            return size
        }
    }
}

private struct DockDatePicker: View {
    let now: Date
    let palette: AppPalette
    let taskDays: Set<Date>
    @Binding var selectedDays: Set<Date>
    let reset: () -> Void
    let finish: () -> Void

    @Environment(\.calendar) private var calendar
    @State private var displayedMonth: Date?

    private var today: Date { calendar.startOfDay(for: now) }
    private var tint: Color { palette.accent.swatch }
    private var monthStart: Date { calendar.dateInterval(of: .month, for: displayedMonth ?? now)?.start ?? today }

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
                shortcut("明天", systemImage: "sunrise") {
                    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) {
                        selectedDays.insert(tomorrow)
                        displayedMonth = tomorrow
                    }
                }
                shortcut("本周", systemImage: "calendar") { addPeriod(.weekOfYear) }
                shortcut("本月", systemImage: "calendar.circle") { addPeriod(.month) }
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
                Text("已添加 \(selectedDays.subtracting([today]).count) 天")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认", action: reset)
                    .buttonStyle(ThemeButtonStyle())
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
        let checked = isToday || selectedDays.contains(day)
        let hasTasks = taskDays.contains(day)
        let selection = isToday ? "始终显示" : checked ? "已勾选" : "未勾选"
        return Button {
            if checked { selectedDays.remove(day) } else { selectedDays.insert(day) }
        } label: {
            Text(calendar.component(.day, from: day), format: .number)
                .font(.system(size: 12, weight: checked ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(checked ? tint : palette.text.swatch)
                .frame(maxWidth: .infinity)
                .frame(height: 31)
                .background(checked ? tint.opacity(0.15) : Color.primary.opacity(0.035), in: .rect(cornerRadius: 7))
                .overlay(alignment: .topTrailing) {
                    if checked {
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
        .disabled(isToday)
        .accessibilityLabel(Text(day, format: .dateTime.year().month().day().weekday()))
        .accessibilityValue(hasTasks ? "\(selection)，已有待办" : selection)
        .accessibilityAddTraits(checked ? .isSelected : [])
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

    private func addPeriod(_ component: Calendar.Component) {
        guard let period = calendar.dateInterval(of: component, for: now) else { return }
        var days = selectedDays
        var day = calendar.startOfDay(for: period.start)
        while day < period.end {
            if day != today { days.insert(day) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let nextDay = calendar.startOfDay(for: next)
            guard nextDay > day else { break }
            day = nextDay
        }
        selectedDays = days
        displayedMonth = now
    }
}

extension View {
    func dockInputSurface(tint: Color, fill: Color, focused: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        return background(fill, in: shape)
            .overlay {
                shape.strokeBorder(focused ? tint.opacity(0.75) : .primary.opacity(0.13))
                    .allowsHitTesting(false)
            }
    }
}

private struct DockGlass: NSViewRepresentable {
    @Environment(\.colorScheme) private var scheme
    let radius: CGFloat

    func makeNSView(context: Context) -> GlassView {
        let view = GlassView(radius: radius)
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: GlassView, context: Context) {
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    }

    final class GlassView: NSVisualEffectView {
        init(radius: CGFloat) {
            super.init(frame: .zero)
            let side = radius * 2 + 1
            let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                NSColor.white.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                return true
            }
            mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
            mask.resizingMode = .stretch
            maskImage = mask
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
    }
}
