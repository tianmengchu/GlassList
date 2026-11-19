import SwiftUI
import UniformTypeIdentifiers

struct TaskDateGroup: Identifiable {
    enum ID: Hashable {
        case day(Date)
        case unscheduled

        var day: Date? {
            if case let .day(date) = self { date } else { nil }
        }
    }

    let id: ID
    let tasks: [Todo]

    static func groups(for tasks: [Todo], now: Date, calendar: Calendar, additionalDay: Date?) -> [Self] {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
        let byDay = Dictionary(grouping: tasks) { task in
            task.scheduledDate.map { calendar.startOfDay(for: $0) }
        }
        var days = Set(byDay.keys.compactMap { $0 })
        days.formUnion([today, tomorrow, additionalDay].compactMap { $0 })
        return days.sorted().map { Self(id: .day($0), tasks: byDay[$0] ?? []) }
            + [Self(id: .unscheduled, tasks: byDay[nil] ?? [])]
    }

    func title(at now: Date, calendar: Calendar, abbreviated: Bool) -> String {
        guard let day = id.day else { return "未安排日期" }
        var format = Date.FormatStyle.dateTime.month().day().locale(Locale(identifier: "zh_CN"))
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        if !calendar.isDate(day, equalTo: now, toGranularity: .year) { format = format.year() }
        if !abbreviated { format = format.weekday(.abbreviated) }
        let label = day.formatted(format)
        if calendar.isDate(day, inSameDayAs: now) { return "今天 · \(label)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(day, inSameDayAs: tomorrow) { return "明天 · \(label)" }
        return label
    }

    var dropHelp: String {
        id == .unscheduled ? "拖到此处会移除日期和提醒" : "将待办拖到这里更改日期"
    }
}

struct TaskDatePresentation {
    struct Jump: Equatable {
        let group: TaskDateGroup.ID
        private let request = UUID()

        init(group: TaskDateGroup.ID) { self.group = group }
    }

    private(set) var additionalDay: Date?
    private(set) var jump: Jump?
    private var collapsed: Set<TaskDateGroup.ID> = []

    func isExpanded(_ group: TaskDateGroup.ID) -> Bool { !collapsed.contains(group) }

    mutating func toggle(_ group: TaskDateGroup.ID) {
        if collapsed.remove(group) == nil { collapsed.insert(group) }
    }

    mutating func reveal(_ group: TaskDateGroup.ID) {
        collapsed.remove(group)
        jump = Jump(group: group)
    }

    mutating func showDay(_ day: Date) {
        additionalDay = day
        reveal(.day(day))
    }

    mutating func clearJump() { jump = nil }
}

struct TaskDateSections<Row: View>: View {
    let groups: [TaskDateGroup]
    let now: Date
    let tint: Color
    @Binding var dates: TaskDatePresentation
    var compact = false
    var datePickerVisibilityChanged: (Bool) -> Void = { _ in }
    let move: (UUID, TaskDateGroup.ID) -> Void
    @ViewBuilder let row: (Todo) -> Row

    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lookingAtDate = Date.now
    @State private var showingDatePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack {
                Spacer()
                datePickerButton
            }
            .padding(.trailing, 4)

            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: compact ? 8 : 14) {
                        ForEach(groups) { group in
                            TaskDateSection(group: group, title: group.title(at: now, calendar: calendar, abbreviated: false),
                                            tint: tint, compact: compact, expanded: dates.isExpanded(group.id)) {
                                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { dates.toggle(group.id) }
                            } move: { id in
                                move(id, group.id)
                            } row: { task in
                                row(task)
                            }
                            .id(group.id)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .defaultScrollAnchor(.top)
                .onChange(of: dates.jump, initial: true) { _, jump in
                    if let jump { scroll.scrollTo(jump.group, anchor: .top) }
                }
            }
        }
        .onChange(of: showingDatePicker) { _, isVisible in datePickerVisibilityChanged(isVisible) }
        .onDisappear { datePickerVisibilityChanged(false) }
    }

    private var datePickerButton: some View {
        Button("选择日期…", systemImage: "calendar") {
            lookingAtDate = dates.additionalDay ?? now
            showingDatePicker = true
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .popover(isPresented: $showingDatePicker) {
            VStack(spacing: 12) {
                DatePicker("选择日期", selection: $lookingAtDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                Button("显示这一天") {
                    dates.showDay(calendar.startOfDay(for: lookingAtDate))
                    showingDatePicker = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .frame(width: 280)
        }
    }
}

private struct TaskDateSection<Row: View>: View {
    let group: TaskDateGroup
    let title: String
    let tint: Color
    let compact: Bool
    let expanded: Bool
    let toggle: () -> Void
    let move: (UUID) -> Void
    @ViewBuilder let row: (Todo) -> Row

    var body: some View {
        LazyVStack(alignment: .leading, spacing: compact ? 5 : 6) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: compact ? 10 : 11, weight: .semibold))
                        .frame(width: 13)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.system(size: compact ? 15 : 18, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(group.tasks.isEmpty ? "拖到这里" : "\(group.tasks.count) 项")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(group.id == .unscheduled ? .secondary : tint)
                .padding(.horizontal, compact ? 8 : 10)
                .frame(minHeight: compact ? 29 : 37)
                .background(.primary.opacity(0.035), in: .rect(cornerRadius: 8))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue("\(expanded ? "已展开" : "已折叠")，\(group.tasks.count) 项")
            .help(group.dropHelp)

            if expanded {
                ForEach(group.tasks) { task in
                    row(task)
                        .contentShape(.rect)
                        .draggable(TaskDragItem(id: task.id))
                }
            }
        }
        .taskDateDropTarget(tint: tint, move: move)
    }
}

extension View {
    func taskDateDropTarget(tint: Color, move: @escaping (UUID) -> Void) -> some View {
        modifier(TaskDateDropTarget(tint: tint, move: move))
    }
}

private struct TaskDateDropTarget: ViewModifier {
    let tint: Color
    let move: (UUID) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        content
            .background(tint.opacity(targeted ? 0.13 : 0), in: shape)
            .overlay { shape.strokeBorder(tint.opacity(targeted ? 0.72 : 0)).allowsHitTesting(false) }
            .contentShape(.rect)
            .dropDestination(for: TaskDragItem.self, isEnabled: true) { items, _ in
                if let item = items.first { move(item.id) }
            }
            .onDropSessionUpdated { session in
                targeted = session.phase == .entering || session.phase == .active
            }
    }
}

private struct TaskDragItem: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "com.tian.glasslist.task-drag"))
            .visibility(.ownProcess)
    }
}
