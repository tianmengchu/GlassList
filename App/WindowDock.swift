import AppKit
import Observation
import SwiftUI

enum DockEdge: String, CaseIterable, Identifiable {
    case left
    case right

    var id: Self { self }
    var title: String { self == .left ? "贴合左侧" : "贴合右侧" }
    var symbol: String { self == .left ? "sidebar.left" : "sidebar.right" }
    var arrow: String { self == .left ? "chevron.right" : "chevron.left" }
}

@Observable
@MainActor
final class WindowDock: NSObject {
    static let autoDockAtLaunchKey = "autoDockAtLaunch"
    private static let lastDockEdgeKey = "lastDockEdge"
    private static let listSize = NSSize(width: 350, height: 600)

    private(set) var edge: DockEdge?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var mainWindowClosed = false
    @ObservationIgnored private var startupDockPending = UserDefaults.standard.bool(forKey: WindowDock.autoDockAtLaunchKey)
    @ObservationIgnored private weak var model: TaskListModel?
    @ObservationIgnored private weak var settings: ReminderShortcutSettings?
    @ObservationIgnored private var tab: NSPanel?
    @ObservationIgnored private var list: DockListPanel?
    @ObservationIgnored private var pointerTimer: Timer?
    @ObservationIgnored private var motionTimer: Timer?
    @ObservationIgnored private var expanded = false
    @ObservationIgnored private var revealFraction: CGFloat = 0
    @ObservationIgnored private var cursorLeftAt: TimeInterval?
    @ObservationIgnored private var keepVisibleUntil: TimeInterval = 0
    @ObservationIgnored private var openMenus = 0
    @ObservationIgnored private var screen: NSScreen?
    @ObservationIgnored private var originalCenterY: CGFloat?
    @ObservationIgnored private var expandedFrame: NSRect = .zero

    private var availableMainWindow: NSWindow? { mainWindowClosed ? nil : window }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuOpened), name: NSMenu.didBeginTrackingNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuClosed), name: NSMenu.didEndTrackingNotification, object: nil
        )
    }

    func attach(to window: NSWindow, model: TaskListModel, settings: ReminderShortcutSettings) {
        self.model = model
        self.settings = settings
        guard self.window !== window else { return }
        let center = NotificationCenter.default
        if let previous = self.window {
            center.removeObserver(self, name: NSWindow.willCloseNotification, object: previous)
            center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: previous)
            center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: previous)
        }
        self.window = window
        mainWindowClosed = false
        center.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: window)
        center.addObserver(self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: window)
        if startupDockPending {
            center.addObserver(
                self, selector: #selector(scheduleStartupDock), name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
            scheduleStartupDock()
        }
    }

    @objc private func scheduleStartupDock() {
        guard startupDockPending else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.startupDockPending, self.availableMainWindow?.isVisible == true else { return }
            let savedEdge = UserDefaults.standard.string(forKey: Self.lastDockEdgeKey).flatMap { DockEdge(rawValue: $0) }
            self.dock(to: savedEdge ?? .right)
        }
    }

    func dock(to edge: DockEdge) {
        let mainWindow = availableMainWindow
        guard let model, let settings,
              let currentScreen = screen ?? mainWindow?.screen ?? NSScreen.main else { return }
        startupDockPending = false
        UserDefaults.standard.set(edge.rawValue, forKey: Self.lastDockEdgeKey)
        if self.edge == nil {
            originalCenterY = mainWindow?.frame.midY
            screen = currentScreen
        }

        hideList()
        self.edge = edge
        tab?.orderOut(nil)
        tab = makeTab(edge, settings: settings)
        list = makeList(model: model, settings: settings)
        reposition()
        tab?.orderFrontRegardless()
        mainWindow?.orderOut(nil)
    }

    private func reveal(grace: TimeInterval = 0) {
        guard let list else { return }
        keepVisibleUntil = max(keepVisibleUntil, ProcessInfo.processInfo.systemUptime + grace)
        cursorLeftAt = nil
        if !expanded {
            expanded = true
            if !list.isVisible {
                applyRevealFraction()
                list.orderFrontRegardless()
                tab?.orderFrontRegardless()
            }
            animateList(to: 1)
        }
        startPointerTracking()
    }

    private func startPointerTracking() {
        guard pointerTimer == nil else { return }
        let poll = Timer(timeInterval: 0.06, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.trackPointer() }
        }
        pointerTimer = poll
        RunLoop.main.add(poll, forMode: .common)
    }

    @objc private func menuOpened() { openMenus += 1 }
    @objc private func menuClosed() { openMenus = max(0, openMenus - 1) }

    @objc func undock() {
        guard edge != nil else { return }
        clearDock()
        showMainWindow()
    }

    @discardableResult
    func bringMainWindowForward() -> Bool {
        startupDockPending = false
        hideList()
        guard let window = availableMainWindow else { return false }
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    @objc private func showMainWindow() {
        if !bringMainWindowForward() {
            NSWorkspace.shared.open(
                [GlassList.openURL], withApplicationAt: Bundle.main.bundleURL,
                configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil
            )
        }
    }

    private var positionKey: String? {
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return "dockTabPosition.\(number.uint32Value)"
    }

    private func moveTab(to y: CGFloat) {
        guard let area = screen?.visibleFrame, let positionKey, area.height > 0 else { return }
        let ratio = min(1, max(0, (y - area.minY) / area.height))
        UserDefaults.standard.set(Double(ratio), forKey: positionKey)
        reposition()
    }

    @objc private func resetTabPosition() {
        guard let area = screen?.visibleFrame else { return }
        moveTab(to: area.midY)
    }

    @objc private func dockLeft() { dock(to: .left) }
    @objc private func dockRight() { dock(to: .right) }

    private func makeTab(_ edge: DockEdge, settings: ReminderShortcutSettings) -> NSPanel {
        let panel = DockTabPanel(
            contentRect: NSRect(x: 0, y: 0, width: 20, height: 88),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "一个完美的todolist侧边标签"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        let tabView = DockTabView(
            edge: edge,
            settings: settings,
            reveal: { [weak self] in self?.reveal() },
            activate: { [weak self] in self?.reveal(grace: 0.9) },
            onDrag: { [weak self] y in self?.moveTab(to: y) }
        )
        let menu = NSMenu()
        for (title, action) in [
            ("贴合左侧", #selector(dockLeft)),
            ("贴合右侧", #selector(dockRight)),
            ("位置复位", #selector(resetTabPosition))
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        menu.addItem(.separator())
        let show = menu.addItem(withTitle: "打开主窗口", action: #selector(showMainWindow), keyEquivalent: "")
        show.target = self
        let undock = menu.addItem(withTitle: "取消贴合", action: #selector(undock), keyEquivalent: "")
        undock.target = self
        tabView.menu = menu
        panel.contentView = tabView
        return panel
    }

    private func makeList(model: TaskListModel, settings: ReminderShortcutSettings) -> DockListPanel {
        let panel = DockListPanel(
            contentRect: NSRect(origin: .zero, size: Self.listSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "侧边待办清单"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let hosting = NSHostingView(rootView: DockTaskList(
            model: model, settings: settings,
            draftEditingChanged: { [weak panel] in panel?.hasFocusedDraft = $0 },
            datePickerVisibilityChanged: { [weak panel] in panel?.isChoosingDate = $0 },
            editorVisibilityChanged: { [weak panel] isVisible in
                guard let panel else { return }
                panel.isEditingTask = isVisible
                if isVisible, panel.isVisible, !panel.isKeyWindow { panel.makeKey() }
            }
        ))
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }

    private func reposition() {
        guard let edge, let tab, let screen = screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let tabSize = tab.frame.size
        let savedRatio = positionKey.flatMap { UserDefaults.standard.object(forKey: $0) as? Double }
        let preferredY = savedRatio.map { area.minY + area.height * $0 } ?? originalCenterY ?? area.midY
        let centerY = min(area.maxY - tabSize.height / 2, max(area.minY + tabSize.height / 2, preferredY))
        let tabX = edge == .left ? area.minX : area.maxX - tabSize.width
        tab.setFrameOrigin(NSPoint(x: tabX, y: centerY - tabSize.height / 2))

        let gap: CGFloat = 5
        let width = min(Self.listSize.width, area.width - tabSize.width - gap)
        let height = min(Self.listSize.height, area.height)
        let x = edge == .left ? tab.frame.maxX + gap : tab.frame.minX - width - gap
        let y = min(area.maxY - height, max(area.minY, centerY - height / 2))
        expandedFrame = NSRect(x: x, y: y, width: width, height: height)
        applyRevealFraction()
    }

    private func trackPointer() {
        guard let list, let tab else { return }
        let cursor = NSEvent.mouseLocation
        let overList = list.frame.insetBy(dx: -6, dy: -3).contains(cursor)
        let overTab = tab.frame.contains(cursor)
        let now = ProcessInfo.processInfo.systemUptime
        if overList || overTab {
            keepVisibleUntil = 0
            cursorLeftAt = nil
            if !expanded { reveal() }
        } else if now < keepVisibleUntil || openMenus > 0 || NSEvent.pressedMouseButtons != 0
                    || (list.isKeyWindow && (list.hasFocusedDraft || list.isEditingTask)) || list.isChoosingDate {
            cursorLeftAt = nil
        } else if let cursorLeftAt {
            if expanded && now - cursorLeftAt >= 0.15 {
                expanded = false
                animateList(to: 0)
            }
        } else {
            cursorLeftAt = now
        }
    }

    private func animateList(to target: CGFloat) {
        motionTimer?.invalidate()
        motionTimer = nil
        let start = revealFraction
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || start == target {
            revealFraction = target
            applyRevealFraction()
            if target == 0 { hideList() }
            return
        }

        let startTime = ProcessInfo.processInfo.systemUptime
        let duration = (target == 1 ? 0.28 : 0.13) * max(0.35, abs(target - start))
        let motion = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                let t = min(1, (ProcessInfo.processInfo.systemUptime - startTime) / duration)
                let eased = target == 1 ? 1 - pow(1 - t, 3) : t * t * (3 - 2 * t)
                self.revealFraction = start + (target - start) * eased
                self.applyRevealFraction()
                if t == 1 {
                    self.motionTimer?.invalidate()
                    self.motionTimer = nil
                    if target == 0 { self.hideList() }
                }
            }
        }
        motionTimer = motion
        RunLoop.main.add(motion, forMode: .common)
    }

    private func applyRevealFraction() {
        guard let edge, let list else { return }
        let shift = (edge == .left ? -20.0 : 20.0) * (1 - revealFraction)
        let frame = expandedFrame.offsetBy(dx: shift, dy: 0)
        if list.frame.size != frame.size {
            list.setFrame(frame, display: list.isVisible)
        } else if list.frame.origin != frame.origin {
            list.setFrameOrigin(frame.origin)
        }
        list.alphaValue = revealFraction
    }

    private func hideList() {
        motionTimer?.invalidate()
        motionTimer = nil
        pointerTimer?.invalidate()
        pointerTimer = nil
        expanded = false
        revealFraction = 0
        cursorLeftAt = nil
        keepVisibleUntil = 0
        list?.isChoosingDate = false
        list?.orderOut(nil)
    }

    private func clearDock() {
        hideList()
        list = nil
        tab?.orderOut(nil)
        tab = nil
        edge = nil
        screen = nil
        originalCenterY = nil
        openMenus = 0
    }

    @objc private func windowClosed() {
        mainWindowClosed = true
        startupDockPending = false
    }

    @objc private func windowBecameKey() {
        mainWindowClosed = false
        hideList()
        scheduleStartupDock()
    }

    @objc private func screenChanged() {
        guard edge != nil else { return }
        screen = NSScreen.screens.first(where: { $0 == screen })
            ?? availableMainWindow?.screen ?? NSScreen.main
        reposition()
    }
}

private final class DockTabPanel: NSPanel {}

private final class DockListPanel: NSPanel {
    var hasFocusedDraft = false
    var isChoosingDate = false
    var isEditingTask = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct DockWindowAccess: NSViewRepresentable {
    let controller: WindowDock
    let model: TaskListModel
    let settings: ReminderShortcutSettings

    func makeNSView(context: Context) -> NSView {
        AccessView(controller: controller, model: model, settings: settings)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AccessView: NSView {
        private weak var controller: WindowDock?
        private let model: TaskListModel
        private let settings: ReminderShortcutSettings

        init(controller: WindowDock, model: TaskListModel, settings: ReminderShortcutSettings) {
            self.controller = controller
            self.model = model
            self.settings = settings
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { controller?.attach(to: window, model: model, settings: settings) }
        }
    }
}

private final class DockTabView: NSView {
    private let edge: DockEdge
    private let reveal: () -> Void
    private let activate: () -> Void
    private let onDrag: (CGFloat) -> Void
    private var color: DetailColor
    private weak var settings: ReminderShortcutSettings?
    private var tracker: NSTrackingArea?
    private var dragStart: CGFloat?
    private var dragOffset: CGFloat = 0
    private var didDrag = false

    init(
        edge: DockEdge, settings: ReminderShortcutSettings,
        reveal: @escaping () -> Void, activate: @escaping () -> Void, onDrag: @escaping (CGFloat) -> Void
    ) {
        self.edge = edge
        self.settings = settings
        color = settings.dockTabColor
        self.reveal = reveal
        self.activate = activate
        self.onDrag = onDrag
        super.init(frame: .zero)
        toolTip = "移入展开 · 上下拖动"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("展开一个完美的todolist")
        observeColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func observeColor() {
        guard let settings else { return }
        color = withObservationTracking {
            settings.dockTabColor
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeColor() }
        }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        if let tracker { removeTrackingArea(tracker) }
        let area = NSTrackingArea(
            rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited], owner: self, userInfo: nil
        )
        addTrackingArea(area)
        tracker = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { reveal() }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let y = window.convertPoint(toScreen: event.locationInWindow).y
        dragStart = y
        dragOffset = y - window.frame.midY
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStart else { return }
        let y = window.convertPoint(toScreen: event.locationInWindow).y
        guard didDrag || abs(y - dragStart) >= 4 else { return }
        didDrag = true
        onDrag(y - dragOffset)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { activate() }
        dragStart = nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        activate()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let opacity = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1.0 : 0.63
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: opacity).setFill()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1), xRadius: 8, yRadius: 8)
        shape.fill()
        NSColor.white.withAlphaComponent(0.38).setStroke()
        shape.lineWidth = 0.75
        shape.stroke()
        let brightness = color.red * 0.2126 + color.green * 0.7152 + color.blue * 0.0722
        let arrowColor: NSColor = brightness > 0.61 ? .black : .white
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(.init(paletteColors: [arrowColor]))
        if let image = NSImage(systemSymbolName: edge.arrow, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            image.draw(at: NSPoint(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2),
                       from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
}
