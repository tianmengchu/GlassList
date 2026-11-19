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

private extension WidgetFamily {
    var taskLimit: Int { self == .systemLarge ? 6 : 2 }
}

struct TaskEntry: TimelineEntry {
    var date = Date.now
    var tasks: [Todo]
    var appearance: DisplayMode = .system
    var colors = DetailColors()
    var showsCountdown = true
    var unavailable = false
    var rowLimit = 2

    static let padding: CGFloat = 10
    static let headerHeight: CGFloat = 22
    static let footerHeight: CGFloat = 14
    static let sectionSpacing: CGFloat = 5
    static let rowSpacing: CGFloat = 4

    func rowHeight(_ task: Todo, compact: Bool) -> CGFloat {
        let details: CGFloat = task.reminderAt != nil || task.note != nil ? 16 : 0
        let countdown: CGFloat = compact && showsCountdown && task.reminderAt != nil ? 12 : 0
        return 19 + details + countdown
    }

    mutating func fit(_ context: TimelineProviderContext) {
        let compact = context.family == .systemSmall
        var remaining = context.displaySize.height - Self.padding * 2 - Self.headerHeight
            - Self.footerHeight - Self.sectionSpacing * 2
        rowLimit = 0
        for task in tasks.lazy.filter({ !$0.isDone }).prefix(context.family.taskLimit) {
            let needed = rowHeight(task, compact: compact) + (rowLimit == 0 ? 0 : Self.rowSpacing)
            if rowLimit > 0 && needed > remaining { break }
            remaining -= needed
            rowLimit += 1
        }
    }
}

struct TaskProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaskEntry {
        sample(appearance: .system, context: context)
    }

    func getSnapshot(in context: Context, completion: @escaping (TaskEntry) -> Void) {
        let entry = currentEntry(in: context)
        completion(context.isPreview && !entry.unavailable && entry.tasks.isEmpty
                   ? sample(appearance: entry.appearance, context: context) : entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TaskEntry>) -> Void) {
        let entry = currentEntry(in: context)
        let policy: TimelineReloadPolicy = .after(entry.date.addingTimeInterval(entry.unavailable ? 900 : 1800))
        guard entry.showsCountdown else {
            completion(Timeline(entries: [entry], policy: policy))
            return
        }
        let dueDates = entry.tasks.lazy
            .filter { !$0.isDone }
            .prefix(entry.rowLimit)
            .compactMap(\.reminderAt)
            .filter { $0 > entry.date }
        let entries = [entry] + Set(dueDates).sorted().map { due in
            var next = entry
            next.date = due
            return next
        }
        completion(Timeline(entries: entries, policy: policy))
    }

    private func sample(appearance: DisplayMode, context: Context) -> TaskEntry {
        var entry = TaskEntry(tasks: [Todo("整理工作台"), Todo("确认本周计划"), Todo("回复邮件")], appearance: appearance)
        entry.fit(context)
        return entry
    }

    private func currentEntry(in context: Context) -> TaskEntry {
        let appearance = WidgetSize(context.family).appearance()
        do {
            let store = try TaskStore.shared()
            var entry = TaskEntry(
                tasks: try store.load(),
                appearance: appearance,
                colors: (try? store.loadDetailColors()) ?? DetailColors(),
                showsCountdown: (try? store.loadDisplaySettings().showsCountdown) ?? true
            )
            entry.fit(context)
            return entry
        } catch {
            return TaskEntry(tasks: [], appearance: appearance, unavailable: true)
        }
    }
}

struct TaskWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var rendering
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let entry: TaskEntry

    private var pending: [Todo] { entry.tasks.filter { !$0.isDone } }
    private var compact: Bool { family == .systemSmall }
    private var selectedScheme: ColorScheme { entry.appearance.colorScheme ?? scheme }
    private var glassTint: Color { selectedScheme == .dark ? .black : .white }
    private var accent: Color {
        guard rendering == .fullColor else { return .primary }
        return scheme == .dark ? Color(red: 0.67, green: 0.91, blue: 0.82) : Color(red: 0.14, green: 0.44, blue: 0.39)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TaskEntry.sectionSpacing) {
            header

            if entry.unavailable {
                empty(symbol: "exclamationmark.circle", text: "请打开清单重试")
            } else if pending.isEmpty {
                empty(
                    symbol: entry.tasks.isEmpty ? "plus.circle" : "checkmark.circle",
                    text: entry.tasks.isEmpty ? "点按添加待办" : "待办全部完成"
                )
            } else {
                VStack(alignment: .leading, spacing: TaskEntry.rowSpacing) {
                    ForEach(pending.prefix(entry.rowLimit)) { task in
                        row(task)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .invalidatableContent()
            }

            if !entry.unavailable {
                footer(visible: entry.rowLimit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(TaskEntry.padding)
        .containerBackground(for: .widget) {
            if rendering == .fullColor {
                ContainerRelativeShape()
                    .fill(glassTint.opacity(backgroundOpacity))
                    .overlay {
                        ContainerRelativeShape()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.65), .white.opacity(0.08)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
            } else {
                // The desktop supplies the adaptive glass surface in system-rendered styles.
                Color.clear
            }
        }
        .widgetURL(entry.tasks.isEmpty && !entry.unavailable ? GlassList.newTaskURL : GlassList.openURL)
    }

    private var backgroundOpacity: Double {
        if reduceTransparency { return 1 }
        return selectedScheme == .dark ? 0.18 : 0.08
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.square.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent)
                .widgetAccentable()
                .accessibilityHidden(true)

            Text("浮光清单")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            Button(intent: SetWidgetAppearanceIntent(size: WidgetSize(family), mode: entry.appearance.next)) {
                Image(systemName: entry.appearance.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 20, height: TaskEntry.headerHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("外观：\(entry.appearance.title)，点按切换至\(entry.appearance.next.title)"))
        }
        .frame(height: TaskEntry.headerHeight)
    }

    private func row(_ task: Todo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Button(intent: CompleteTaskIntent(taskID: task.id)) {
                    Image(systemName: "circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(accent)
                        .widgetAccentable()
                        .frame(width: 23, height: 19)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("完成待办：\(task.title)")

                Text(task.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !compact, entry.showsCountdown, let due = task.reminderAt {
                    widgetCountdown(until: due)
                        .frame(width: 70, alignment: .trailing)
                }
            }
            .frame(height: 19)

            if task.reminderAt != nil || task.note != nil {
                details(task)
                    .padding(.leading, compact ? 0 : 28)
                    .frame(height: 14)
            }
            if compact, entry.showsCountdown, let due = task.reminderAt {
                widgetCountdown(until: due)
                    .frame(height: 10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(height: entry.rowHeight(task, compact: compact), alignment: .top)
    }

    private func details(_ task: Todo) -> some View {
        HStack(spacing: 4) {
            if let time = task.reminderAt {
                DetailTag(symbol: "clock", tint: tagColor(entry.colors.time), compact: true) {
                    let terse = compact && Calendar.current.isDate(time, inSameDayAs: entry.date)
                    let clock = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
                    Text(time, format: (terse ? clock : clock.month(.defaultDigits).day(.defaultDigits))
                        .locale(Locale(identifier: "zh_CN")))
                        .minimumScaleFactor(0.85)
                }
                .layoutPriority(1)
            }
            if let note = task.note {
                DetailTag(symbol: "note.text", tint: tagColor(entry.colors.note), compact: true) {
                    Text(note.replacingOccurrences(of: "\n", with: " "))
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func tagColor(_ choice: DetailColor) -> Color {
        rendering == .fullColor ? choice.swatch : .primary
    }

    private func widgetCountdown(until due: Date) -> some View {
        Group {
            if due > entry.date {
                Text(timerInterval: entry.date...due, countsDown: true)
                    .multilineTextAlignment(.trailing)
            } else {
                Text("已到期")
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(accent)
        .minimumScaleFactor(0.75)
        .lineLimit(1)
        .accessibilityHint("距提醒时间")
    }

    private func empty(symbol: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(accent)
                .widgetAccentable()
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(visible: Int) -> some View {
        let done = entry.tasks.count - pending.count
        let remaining = pending.count - visible

        return HStack {
            Text(.currentDate, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .fixedSize()
            Spacer(minLength: 2)
            Text("\(done) / \(entry.tasks.count) 已完成")
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if remaining > 0 {
                Text("+\(remaining)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .accessibilityLabel("另有 \(remaining) 项待办")
            }
        }
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .frame(height: TaskEntry.footerHeight)
    }
}

@main
struct TaskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GlassList.widgetKind, provider: TaskProvider()) { entry in
            TaskWidgetView(entry: entry)
        }
        .configurationDisplayName("浮光清单")
        .description("在桌面查看待办的时间、备注和倒计时，也可以直接勾选完成。")
        .containerBackgroundRemovable(true)
        .contentMarginsDisabled()
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
