import SwiftUI

enum DisplayMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case day
    case night

    var id: Self { self }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .day: "sun.max"
        case .night: "moon"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .system: "跟随系统"
        case .day: "日间"
        case .night: "夜间"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .day: .light
        case .night: .dark
        }
    }
}
