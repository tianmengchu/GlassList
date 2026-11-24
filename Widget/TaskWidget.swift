import AppIntents
import SwiftUI
import WidgetKit

private extension DisplayMode {
    var next: DisplayMode {
        switch self {
        case .system: .day
        case .day: .night
        case .night: .system
        }
    }
}

struct TaskEntry: TimelineEntry {
    var date = Date.now
    var rows: [Todo] = []
    var pendingCount = 0
    var completedCount = 0
    var appearance: DisplayMode = .system
    var colors = DetailColors()
    var showsCountdown = true
    var unavailable = false

    var remaining: Int { pendingCount - rows.count }
}

struct TaskProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaskEntry { sample(for: context.family) }

    func getSnapshot(in context: Context, completion: @escaping (TaskEntry) -> Void) {
        completion(context.isPreview ? sample(for: context.family) : currentEntry(for: context.family))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TaskEntry>) -> Void) {
        let entry = currentEntry(for: context.family)
        let deadline = entry.date.addingTimeInterval(entry.unavailable ? 900 : 1800)
        var entries = [entry]
        if entry.showsCountdown {
            let dueDates = Set(entry.rows.compactMap(\.reminderAt))
            for due in dueDates.sorted() where due > entry.date && due < deadline {
                var next = entry
                next.date = due
                entries.append(next)
            }
        }
        completion(Timeline(entries: entries, policy: .after(deadline)))
    }

    private func sample(for family: WidgetFamily) -> TaskEntry {
        let items = [Todo("整理工作台"), Todo("确认本周计划")]
        return TaskEntry(rows: items, pendingCount: items.count, appearance: WidgetSize(family).appearance())
    }

    private func currentEntry(for family: WidgetFamily) -> TaskEntry {
        let appearance = WidgetSize(family).appearance()
        do {
            let store = try TaskStore.shared()
            let tasks = try store.load()
            // Soonest first (overdue at the top), undated tasks last; ties keep the list order.
            let pending = tasks.filter { !$0.isDone }.enumerated().sorted { lhs, rhs in
                switch (lhs.element.scheduledDate, rhs.element.scheduledDate) {
                case let (left?, right?) where left != right: left < right
                case (.some, nil): true
                case (nil, .some): false
                default: lhs.offset < rhs.offset
                }
            }.map(\.element)
            return TaskEntry(
                rows: Array(pending.prefix(family == .systemLarge ? 6 : 2)),
                pendingCount: pending.count,
                completedCount: tasks.count - pending.count,
                appearance: appearance,
                colors: (try? store.loadDetailColors()) ?? DetailColors(),
                showsCountdown: (try? store.loadDisplaySettings().showsCountdown) ?? true
            )
        } catch {
            return TaskEntry(appearance: appearance, unavailable: true)
        }
    }
}

struct TaskWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var rendering
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let entry: TaskEntry

    private var compact: Bool { family == .systemSmall }
    private var isDark: Bool { (entry.appearance.colorScheme ?? scheme) == .dark }
    private var ink: Color {
        guard rendering == .fullColor else { return .primary }
        return isDark ? Color(red: 0.94, green: 0.98, blue: 0.96) : Color(red: 0.08, green: 0.18, blue: 0.16)
    }
    private var accent: Color {
        guard rendering == .fullColor else { return .primary }
        return isDark ? Color(red: 0.56, green: 0.88, blue: 0.78) : Color(red: 0.09, green: 0.36, blue: 0.30)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if entry.unavailable {
                empty("清单暂不可用", symbol: "exclamationmark.circle")
            } else if entry.rows.isEmpty {
                let allDone = entry.completedCount > 0
                empty(allDone ? "待办全部完成" : "点按添加待办",
                      symbol: allDone ? "checkmark.circle" : "plus.circle")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.rows) { task in row(task) }
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }

            footer
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .containerBackground(for: .widget) {
            let colors = isDark
                ? [Color(red: 0.12, green: 0.25, blue: 0.23), Color(red: 0.07, green: 0.15, blue: 0.15)]
                : [Color(red: 0.86, green: 0.96, blue: 0.91), Color(red: 0.72, green: 0.88, blue: 0.82)]
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(reduceTransparency ? 1 : 0.82)
        }
        .widgetURL(entry.pendingCount == 0 && entry.completedCount == 0 && !entry.unavailable
                   ? GlassList.newTaskURL : GlassList.openURL)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.square.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent)
                .widgetAccentable()
                .accessibilityHidden(true)

            Text("一个完美的todolist")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            Button(intent: SetWidgetAppearanceIntent(size: WidgetSize(family), mode: entry.appearance.next)) {
                Image(systemName: entry.appearance.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 26, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("外观：\(entry.appearance.title)，点按切换至\(entry.appearance.next.title)"))
        }
        .frame(height: 22)
    }

    private func row(_ task: Todo) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Button(intent: CompleteTaskIntent(taskID: task.id)) {
                Image(systemName: "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("完成待办：\(task.title)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(task.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !compact, entry.showsCountdown, let due = task.reminderAt {
                        countdown(due).frame(width: 66, alignment: .trailing)
                    }
                }
                .frame(height: 16)

                if task.scheduledDate != nil || task.note != nil {
                    HStack(spacing: 5) {
                        if let due = task.reminderAt {
                            let clock = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
                            let short = compact && Calendar.current.isDate(due, inSameDayAs: entry.date)
                            Label {
                                Text(due, format: (short ? clock : clock.month(.defaultDigits).day(.defaultDigits))
                                    .locale(Locale(identifier: "zh_CN")))
                            } icon: {
                                Image(systemName: "clock")
                            }
                            .foregroundStyle(detailInk(entry.colors.time))
                            .lineLimit(1)
                            .layoutPriority(1)
                        } else if let day = task.scheduledDay {
                            Label {
                                Text(day, format: .dateTime.month(.defaultDigits).day(.defaultDigits)
                                    .locale(Locale(identifier: "zh_CN")))
                            } icon: {
                                Image(systemName: "calendar")
                            }
                            .foregroundStyle(detailInk(entry.colors.time))
                            .lineLimit(1)
                            .layoutPriority(1)
                        }
                        if let note = task.note {
                            Text(note.replacingOccurrences(of: "\n", with: " "))
                                .foregroundStyle(detailInk(entry.colors.note))
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 9, weight: .medium))
                    .frame(height: 12)
                }
                if compact, entry.showsCountdown, let due = task.reminderAt {
                    countdown(due).frame(height: 11)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailInk(_ choice: DetailColor) -> Color {
        guard rendering == .fullColor else { return .primary.opacity(0.78) }
        let mix = isDark ? 0.55 : 0.36
        let base = isDark ? 0.96 : 0.10
        return Color(red: base + (choice.red - base) * mix,
                     green: base + (choice.green - base) * mix,
                     blue: base + (choice.blue - base) * mix)
    }

    private func countdown(_ due: Date) -> some View {
        Group {
            if due > entry.date {
                Text(timerInterval: entry.date...due, countsDown: true)
            } else {
                Text("已到期")
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(accent)
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .accessibilityHint("距提醒时间")
    }

    private func empty(_ message: String, symbol: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 11, weight: .medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(.currentDate, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .fixedSize()
            Spacer(minLength: 0)
            if !entry.unavailable {
                Text("\(entry.pendingCount) 项待办")
                    .lineLimit(1)
                if entry.remaining > 0 && !compact {
                    Text("另有 \(entry.remaining) 项")
                        .lineLimit(1)
                }
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(ink.opacity(0.72))
        .frame(height: 13)
    }
}

@main
struct TaskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GlassList.widgetKind, provider: TaskProvider()) { entry in
            TaskWidgetView(entry: entry)
        }
        .configurationDisplayName("一个完美的todolist")
        .description("在桌面查看待办、时间和备注，并直接勾选完成。")
        .containerBackgroundRemovable(true)
        .contentMarginsDisabled()
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
