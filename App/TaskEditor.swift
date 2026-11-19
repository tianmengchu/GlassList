import AppKit
import SwiftUI

struct TaskEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ReminderShortcutSettings.self) private var shortcuts
    @FocusState private var titleFocused: Bool

    let task: Todo?
    let save: (String, Date?, String) -> Bool

    @State private var title: String
    @State private var note: String
    @State private var setsTime: Bool
    @State private var date: Date
    @State private var hour: String
    @State private var minute: String
    @State private var error: String?

    init(task: Todo? = nil, draft: String = "", save: @escaping (String, Date?, String) -> Bool) {
        self.task = task
        self.save = save
        _title = State(initialValue: task?.title ?? draft)
        _note = State(initialValue: task?.note ?? "")
        _setsTime = State(initialValue: task == nil || task?.reminderAt != nil)
        let initial = task?.reminderAt ?? .now.addingTimeInterval(3_600)
        let clock = Calendar.current.dateComponents([.hour, .minute], from: initial)
        _date = State(initialValue: initial)
        _hour = State(initialValue: Self.twoDigits(clock.hour ?? 0))
        _minute = State(initialValue: Self.twoDigits(clock.minute ?? 0))
    }

    private var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.61, green: 0.87, blue: 0.80)
            : Color(red: 0.13, green: 0.41, blue: 0.36)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(task == nil ? "新建待办" : "编辑待办")
                .font(.title2.bold())
            titleField

            datePanel

            VStack(alignment: .leading, spacing: 6) {
                Text("备注").font(.headline)
                TextEditor(text: $note)
                    .font(.body)
                    .frame(height: 62)
                    .padding(5)
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary) }
                    .accessibilityLabel("备注")
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 660)
        .onAppear { titleFocused = task == nil }
        .onChange(of: hour) { error = nil }
        .onChange(of: minute) { error = nil }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("待办标题")
                .font(.system(size: 13, weight: .semibold))
                .accessibilityHidden(true)
            TextField("写下要做的事", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .semibold))
                .padding(.horizontal, 13)
                .frame(height: 45)
                .background(.background, in: .rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(accent.opacity(titleFocused ? 0.85 : 0.33), lineWidth: titleFocused ? 1.5 : 1)
                        .allowsHitTesting(false)
                }
                .focused($titleFocused)
                .accessibilityLabel("待办标题")
        }
    }

    private var datePanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("日期与时间", systemImage: "calendar")
                    .font(.headline)
                Spacer()
                Toggle("提醒", isOn: $setsTime).toggleStyle(.switch)
            }
            HStack(alignment: .top, spacing: 14) {
                ReminderCalendar(selection: $date, accent: accent)
                    .padding(12)
                    .background(.background.opacity(0.6), in: .rect(cornerRadius: 14))
                    .frame(width: 322)
                    .disabled(!setsTime)
                    .opacity(setsTime ? 1 : 0.42)

                VStack(alignment: .leading, spacing: 12) {
                    clockPanel
                    Text("快捷时间").font(.subheadline.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                        ForEach(shortcuts.items) { shortcut in
                            Button {
                                if let chosen = shortcut.date(from: .now) {
                                    setsTime = true
                                    date = chosen
                                    let clock = calendar.dateComponents([.hour, .minute], from: chosen)
                                    hour = Self.twoDigits(clock.hour ?? 0)
                                    minute = Self.twoDigits(clock.minute ?? 0)
                                    error = nil
                                }
                            } label: {
                                Text(shortcut.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .padding(.horizontal, 6)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 26)
                                    .background(accent.opacity(0.11), in: .capsule)
                                    .contentShape(.capsule)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(accent)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(accent.opacity(0.065), in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.16)).allowsHitTesting(false) }
        .onChange(of: date) { error = nil }
        .onChange(of: setsTime) { error = nil }
    }

    private var clockPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("时间", systemImage: "clock")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 0) {
                ClockWheel(label: "小时", count: 24, value: $hour, tint: accent)
                    .frame(maxWidth: .infinity)
                Text(":")
                    .font(.system(size: 23, weight: .medium, design: .monospaced))
                    .foregroundStyle(accent)
                    .frame(width: ClockScrollMonitor.separatorWidth, height: ClockWheel.faceHeight)
                    .accessibilityHidden(true)
                ClockWheel(label: "分钟", count: 60, value: $minute, tint: accent)
                    .frame(maxWidth: .infinity)
            }
            .background(alignment: .top) {
                ClockScrollMonitor(enabled: setsTime) { column, steps in
                    switch column {
                    case .hour: hour = ClockWheel.adjusted(hour, by: steps, count: 24)
                    case .minute: minute = ClockWheel.adjusted(minute, by: steps, count: 60)
                    }
                }
                .frame(height: ClockWheel.faceHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.6), in: .rect(cornerRadius: 14))
        .disabled(!setsTime)
        .opacity(setsTime ? 1 : 0.42)
    }

    private static func twoDigits(_ value: Int) -> String { String(format: "%02d", value) }

    private func commit() {
        let reminder: Date?
        if setsTime {
            guard let hour = Int(hour), (0...23).contains(hour),
                  let minute = Int(minute), (0...59).contains(minute) else {
                error = "请输入有效的时间（00:00 至 23:59）。"
                return
            }
            let existing = task?.reminderAt
            let normalized: Date
            if let existing, calendar.isDate(existing, inSameDayAs: date),
               calendar.component(.hour, from: existing) == hour,
               calendar.component(.minute, from: existing) == minute {
                normalized = existing
            } else if let chosen = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date),
                      calendar.isDate(chosen, inSameDayAs: date),
                      calendar.component(.hour, from: chosen) == hour,
                      calendar.component(.minute, from: chosen) == minute {
                normalized = chosen
            } else {
                error = "该日期没有这个时刻，请选择其他时间。"
                return
            }
            guard normalized == task?.reminderAt || normalized > .now else {
                error = "请选择将来的提醒时间，或关闭提醒。"
                return
            }
            reminder = normalized
        } else {
            reminder = nil
        }

        if save(title, reminder, note) {
            dismiss()
        } else {
            error = "暂时无法保存待办，请重试。"
        }
    }
}

private struct ClockWheel: View {
    static let faceHeight: CGFloat = 72
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let label: String
    let count: Int
    @Binding var value: String
    let tint: Color
    @GestureState private var dragging = false
    @State private var dragBase: Int?
    @State private var hovered = false

    private var current: Int { min(count - 1, Int(value) ?? 0) }

    var body: some View {
        VStack(spacing: 4) {
            VStack(spacing: 0) {
                neighbor(-1)
                TextField("00", text: $value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 23, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(height: 34)
                    .foregroundStyle(tint)
                    .background(tint.opacity(0.13), in: .rect(cornerRadius: 7))
                    .accessibilityLabel(label)
                    .onChange(of: value) { _, input in
                        let digits = input.compactMap(\.wholeNumberValue)
                            .filter { (0...9).contains($0) }
                        let normalized = digits.prefix(2).map(String.init).joined()
                        if normalized != input { value = normalized }
                    }
                neighbor(1)
            }
            .frame(height: Self.faceHeight)
            .background(tint.opacity(hovered && enabled ? 0.12 : 0.055), in: .rect(cornerRadius: 8))
            .overlay {
                if hovered && enabled {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(tint.opacity(0.45))
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovered = $0 }
            .contentShape(.rect)
            .simultaneousGesture(
                DragGesture(minimumDistance: 5)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { gesture in
                        guard enabled, abs(gesture.translation.height) > abs(gesture.translation.width) else { return }
                        let start = dragBase ?? current
                        dragBase = start
                        let steps = Int(-gesture.translation.height / 19)
                        if steps != 0 || current != start { adjust(from: start, by: steps) }
                    }
            )
            .onChange(of: dragging) { _, active in
                if !active { dragBase = nil }
            }
            .help("上下滚动或拖动可调整\(label)，也可以直接输入")
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private func neighbor(_ step: Int) -> some View {
        Button {
            adjust(from: current, by: step)
        } label: {
            Text(wrapped(current + step), format: .number.precision(.integerLength(2)))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 19)
                .contentShape(.rect)
                .contentTransition(.numericText())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(step < 0 ? "减少一\(label)" : "增加一\(label)")
    }

    private func adjust(from base: Int, by step: Int) {
        let next = Self.adjusted(String(base), by: step, count: count)
        guard next != value else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.13)) { value = next }
    }

    private func wrapped(_ number: Int) -> Int { (number % count + count) % count }

    static func adjusted(_ value: String, by step: Int, count: Int) -> String {
        let current = max(0, min(count - 1, Int(value) ?? 0))
        return String(format: "%02d", ((current + step) % count + count) % count)
    }
}

private struct ClockScrollMonitor: NSViewRepresentable {
    enum Column { case hour, minute }
    static let separatorWidth: CGFloat = 26

    let enabled: Bool
    let adjust: (Column, Int) -> Void

    func makeNSView(context: Context) -> Region { Region() }

    func updateNSView(_ view: Region, context: Context) {
        view.adjust = enabled ? adjust : nil
    }

    static func dismantleNSView(_ view: Region, coordinator: ()) {
        view.stopMonitoring()
    }

    final class Region: NSView {
        var adjust: ((Column, Int) -> Void)?
        private var activeColumn: Column?
        private var monitor: Any?
        private var pending: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.consume(event) == true ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            pending = 0
            activeColumn = nil
        }

        private func consume(_ event: NSEvent) -> Bool {
            guard let adjust, let window, window.isVisible, !isHiddenOrHasHiddenAncestor,
                  event.window == nil || event.window === window || event.window === window.sheetParent else { return false }
            let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let distance = pointer.x - bounds.midX
            guard visibleRect.contains(pointer), abs(distance) >= ClockScrollMonitor.separatorWidth / 2 else {
                pending = 0
                activeColumn = nil
                return false
            }
            let column: Column = distance < 0 ? .hour : .minute
            if activeColumn != column || event.phase.contains(.began) { pending = 0 }
            activeColumn = column
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                pending = 0
                return true
            }
            let vertical = event.scrollingDeltaY
            guard abs(vertical) > abs(event.scrollingDeltaX) else { return false }
            // Ignore momentum so a flick doesn't spin past the selected time.
            guard event.momentumPhase.isEmpty else { return true }
            if event.hasPreciseScrollingDeltas {
                pending -= vertical
                let steps = Int(pending / 16)
                pending -= CGFloat(steps) * 16
                if steps != 0 { adjust(column, steps) }
            } else {
                adjust(column, vertical < 0 ? 1 : -1)
            }
            return true
        }
    }
}

private struct ReminderCalendar: View {
    @Environment(\.calendar) private var userCalendar
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: Date
    let accent: Color
    @State private var displayedMonth: Date?

    private var calendar: Calendar {
        var calendar = userCalendar
        let firstWeekday = calendar.firstWeekday
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    var body: some View {
        let month = displayedMonth ?? selection
        let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)
        let weekdays = calendar.veryShortStandaloneWeekdaySymbols
        let firstWeekday = calendar.firstWeekday - 1
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(month, format: .dateTime.year().month(.wide).locale(Locale(identifier: "zh_CN")))
                    .font(.system(size: 16, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("今天") {
                    let today = Date.now
                    selection = today
                    displayedMonth = today
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                monthArrow("上个月", symbol: "chevron.left", amount: -1, month: month)
                monthArrow("下个月", symbol: "chevron.right", amount: 1, month: month)
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(0..<7, id: \.self) { offset in
                    Text(weekdays[(firstWeekday + offset) % 7])
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(height: 16)
                        .accessibilityHidden(true)
                }
                if let start = calendar.dateInterval(of: .month, for: month)?.start {
                    let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
                    ForEach(0..<42, id: \.self) { slot in
                        if let day = calendar.date(byAdding: .day, value: slot - leading, to: start) {
                            dayButton(day, in: start)
                        } else {
                            Color.clear.frame(height: 27)
                        }
                    }
                }
            }
        }
        .onChange(of: selection) { _, date in displayedMonth = date }
    }

    private func monthArrow(_ label: String, symbol: String, amount: Int, month: Date) -> some View {
        Button {
            let start = calendar.dateInterval(of: .month, for: month)?.start ?? month
            displayedMonth = calendar.date(byAdding: .month, value: amount, to: start)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 6))
                .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func dayButton(_ day: Date, in month: Date) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: selection)
        let today = calendar.isDateInToday(day)
        let currentMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let selectionInk: Color = colorScheme == .dark ? Color(red: 0.09, green: 0.17, blue: 0.15) : .white
        return Button {
            selection = day
            displayedMonth = day
        } label: {
            Text(calendar.component(.day, from: day), format: .number)
                .font(.system(size: 12, weight: selected || today ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(selected ? selectionInk : currentMonth ? Color.primary : Color.secondary.opacity(0.6))
                .frame(maxWidth: .infinity)
                .frame(height: 27)
                .background(selected ? accent : .clear, in: .rect(cornerRadius: 7))
                .overlay {
                    if today && !selected {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(accent.opacity(0.55))
                    }
                }
                .contentShape(.rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(day, format: .dateTime.year().month().day().weekday()))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct TaskDueCountdown: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = Int(max(0, ceil(date.timeIntervalSince(context.date))))
            VStack(alignment: .trailing, spacing: 3) {
                Text("倒计时").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Text(label(seconds))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(seconds == 0 ? Color.red : Color.accentColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .contentTransition(.identity)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func label(_ seconds: Int) -> String {
        guard seconds > 0 else { return "已到期" }
        if seconds >= 86_400 {
            return String(format: "%d天 %02d:%02d:%02d",
                          seconds / 86_400, seconds / 3_600 % 24, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
    }
}
