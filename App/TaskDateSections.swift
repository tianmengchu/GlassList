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

    static func groups(for tasks: [Todo], now: Date, calendar: Calendar, additionalDay: Date? = nil,
                       visibleDays: Set<Date>? = nil) -> [Self] {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
        let byDay = Dictionary(grouping: tasks) { task in
            task.scheduledDate.map { calendar.startOfDay(for: $0) }
        }
        let orderedDays: [Date]
        if let visibleDays {
            orderedDays = [today] + visibleDays.subtracting([today]).sorted()
        } else {
            var days = Set(byDay.keys.compactMap { $0 })
            days.formUnion([today, tomorrow, additionalDay].compactMap { $0 })
            orderedDays = days.sorted()
        }
        return orderedDays.map { Self(id: .day($0), tasks: byDay[$0] ?? []) }
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
    var removeDay: ((Date) -> Void)?
    let move: (UUID, TaskDateGroup.ID) -> Void
    @ViewBuilder let row: (Todo) -> Row

    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: compact ? 8 : 14) {
                    ForEach(groups) { group in
                        TaskDateSection(group: group, title: group.title(at: now, calendar: calendar, abbreviated: false),
                                        tint: tint, compact: compact, expanded: dates.isExpanded(group.id),
                                        remove: removal(for: group)) {
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

    private func removal(for group: TaskDateGroup) -> (() -> Void)? {
        guard let day = group.id.day, let removeDay, !calendar.isDate(day, inSameDayAs: now) else { return nil }
        return { removeDay(day) }
    }
}

private struct TaskDateSection<Row: View>: View {
    @Environment(\.appPalette) private var palette
    let group: TaskDateGroup
    let title: String
    let tint: Color
    let compact: Bool
    let expanded: Bool
    let remove: (() -> Void)?
    let toggle: () -> Void
    let move: (UUID) -> Void
    @ViewBuilder let row: (Todo) -> Row

    var body: some View {
        LazyVStack(alignment: .leading, spacing: compact ? 5 : 6) {
            HStack(spacing: 0) {
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
                        Text(group.tasks.isEmpty ? (compact ? "暂无待办" : "拖到这里") : "\(group.tasks.count) 项")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, compact ? 8 : 10)
                    .frame(minHeight: compact ? 29 : 37)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue("\(expanded ? "已展开" : "已折叠")，\(group.tasks.count) 项")
                .help(group.dropHelp)

                if let remove {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 13))
                            .frame(width: 28, height: 29)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("从侧边清单移除日期")
                    .accessibilityLabel("移除 \(title)")
                }
            }
            .foregroundStyle(group.id == .unscheduled ? (palette?.secondaryText ?? .secondary) : tint)
            .background(.primary.opacity(0.035), in: .rect(cornerRadius: 8))

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
