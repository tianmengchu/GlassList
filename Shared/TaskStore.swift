import Darwin
import Foundation

struct Todo: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var isDone: Bool
    var completedAt: Date?
    var reminderAt: Date?
    var note: String?

    init(_ title: String, id: UUID = UUID(), isDone: Bool = false) {
        self.id = id
        self.title = title
        self.isDone = isDone
    }

    mutating func setDone(_ done: Bool, at date: Date = .now) {
        guard isDone != done else { return }
        isDone = done
        completedAt = done ? date : nil
    }

    func staysOnHome(for days: Int, at date: Date) -> Bool {
        guard isDone, days > 0, let completedAt else { return true }
        return date.timeIntervalSince(completedAt) < Double(days) * 86_400
    }
}

enum GlassList {
    static let group = Bundle.main.object(forInfoDictionaryKey: "GlassListAppGroup") as? String ?? "group.com.tian.glasslist"
    static let bundleID = "com.tian.glasslist"
    static let widgetKind = "com.tian.glasslist.widget.tasks"
    static let openURL = URL(string: "glasslist://open")!
    static let newTaskURL = URL(string: "glasslist://new")!
}

struct TaskDisplaySettings: Codable, Equatable, Sendable {
    var showsCountdown = true
}

struct TaskStore: Sendable {
    let directory: URL

    static func shared() throws -> TaskStore {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: GlassList.group
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let directory = container.appending(path: "Tasks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return TaskStore(directory: directory)
    }

    private var file: URL {
        directory.appending(path: "list.json")
    }

    private var colorsFile: URL {
        directory.appending(path: "detail-colors.json")
    }

    private var displaySettingsFile: URL {
        directory.appending(path: "display-settings.json")
    }

    func load() throws -> [Todo] {
        try read(file, default: [])
    }

    func loadDetailColors() throws -> DetailColors {
        try read(colorsFile, default: DetailColors())
    }

    func loadDisplaySettings() throws -> TaskDisplaySettings {
        try read(displaySettingsFile, default: TaskDisplaySettings())
    }

    private func read<Value: Decodable>(_ file: URL, default defaultValue: Value) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return defaultValue
        }
    }

    @discardableResult
    func update(_ edit: (inout [Todo]) -> Void) throws -> [Todo] {
        try update(file, lock: "list.lock", default: [], edit)
    }

    @discardableResult
    func updateDetailColors(_ edit: (inout DetailColors) -> Void) throws -> DetailColors {
        try update(colorsFile, lock: "detail-colors.lock", default: DetailColors(), edit)
    }

    func updateDisplaySettings(_ edit: (inout TaskDisplaySettings) -> Void) throws -> TaskDisplaySettings {
        try update(displaySettingsFile, lock: "display-settings.lock", default: TaskDisplaySettings(), edit)
    }

    // Lock a separate file so atomic replacements never replace the lock itself.
    private func update<Value: Codable & Equatable>(
        _ file: URL,
        lock lockName: String,
        default defaultValue: Value,
        _ edit: (inout Value) -> Void
    ) throws -> Value {
        let lock = directory.appending(path: lockName)
        let fd = try checkedPOSIX { Darwin.open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600) }
        defer { close(fd) }
        _ = try checkedPOSIX { flock(fd, LOCK_EX) }

        var value = try read(file, default: defaultValue)
        let previous = value
        edit(&value)
        if value != previous {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(value).write(to: file, options: .atomic)
        }
        return value
    }

    private func checkedPOSIX(_ call: () -> Int32) throws -> Int32 {
        while true {
            let result = call()
            if result >= 0 { return result }
            let error = errno
            if error != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
        }
    }
}
