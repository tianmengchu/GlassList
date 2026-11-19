import AppKit
import SwiftUI

struct DockTaskList: View {
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
    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var dates = TaskDatePresentation()
    @State private var showingEditor = false
    @FocusState private var composerFocused: Bool

    private let radius: CGFloat = 20
    private var scheme: ColorScheme { displayMode.colorScheme ?? systemScheme }
    private var accent: Color {
        scheme == .dark
            ? Color(red: 0.65, green: 0.88, blue: 0.80)
            : Color(red: 0.13, green: 0.41, blue: 0.36)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        Group {
            if showingEditor {
                TaskEditor(draft: draft, closeDockEditor: { showingEditor = false }, save: saveTask)
                    .environment(settings)
            } else {
                listContent
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { DockGlass(radius: radius) }
        .overlay { shape.strokeBorder(.primary.opacity(0.12)).allowsHitTesting(false) }
        .environment(\.colorScheme, scheme)
        .tint(accent)
        .allowsWindowActivationEvents()
        .onChange(of: composerFocused && !draft.isEmpty) { _, isEditing in draftEditingChanged(isEditing) }
        .onChange(of: showingEditor) { _, isVisible in editorVisibilityChanged(isVisible) }
    }

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("待办清单")
                .font(.system(size: 16, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 4)
            TimelineView(.everyMinute) { context in
                let tasks = model.homeTasks(at: context.date, includeCompleted: strikeCompletedOnHome, retentionDays: retentionDays)
                if model.loadFailed || tasks.isEmpty {
                    Text(model.loadFailed ? "清单暂不可用" : "暂无待办")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let groups = TaskDateGroup.groups(for: tasks, now: context.date, calendar: calendar,
                                                      additionalDay: dates.additionalDay)
                    TaskDateSections(groups: groups, now: context.date, tint: accent, dates: $dates, compact: true,
                                     datePickerVisibilityChanged: datePickerVisibilityChanged) { id, group in
                        let moved = model.moveTask(id, to: group.day, calendar: calendar)
                        errorMessage = moved ? nil : "无法更改待办日期。请选择其他日期，或稍后再试。"
                        if moved { dates.reveal(group) }
                    } row: { task in
                        row(task)
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }
            composer
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("添加一条待办…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($composerFocused)
                .onSubmit(openEditor)
                .onExitCommand { composerFocused = false }

            Button("添加", systemImage: "plus", action: openEditor)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 35)
        .dockInputSurface(tint: accent, focused: composerFocused)
    }

    private func openEditor() {
        composerFocused = false
        showingEditor = true
    }

    private func saveTask(title: String, reminder: Date?, day: Date?, note: String) -> Bool {
        guard model.saveTask(id: nil, title: title, reminder: reminder, day: day, note: note) else { return false }
        draft = ""
        errorMessage = nil
        let group = (reminder ?? day).map { TaskDateGroup.ID.day(calendar.startOfDay(for: $0)) } ?? .unscheduled
        dates.reveal(group)
        return true
    }

    private func row(_ task: Todo) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                let saved = model.setDone(task, to: !task.isDone, reportError: false)
                errorMessage = saved ? nil : "无法保存待办，请重试。"
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(task.isDone ? accent : .secondary)
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
                    HStack(spacing: 4) {
                        if let date = task.reminderAt {
                            DetailTag(symbol: "clock", tint: settings.colors.time.swatch, compact: true) {
                                Text(date, format: .dateTime.month(.defaultDigits).day().hour().minute())
                            }
                            .layoutPriority(1)
                        }
                        if let note = task.note {
                            DetailTag(symbol: "note.text", tint: settings.colors.note.swatch, compact: true) {
                                Text(note.replacingOccurrences(of: "\n", with: " "))
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
        .padding(6)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 10))
    }
}

extension View {
    func dockInputSurface(tint: Color, focused: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        return background(.primary.opacity(0.06), in: shape)
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
