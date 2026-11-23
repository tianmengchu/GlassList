import SwiftUI

struct DetailColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    var swatch: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

struct DetailColors: Codable, Equatable, Sendable {
    var time = DetailColor(red: 0.12, green: 0.51, blue: 0.80)
    var note = DetailColor(red: 0.59, green: 0.33, blue: 0.76)
}

struct DetailTag<Content: View>: View {
    let symbol: String
    let tint: Color
    var compact = false
    var lineLimit = 1
    var stretchesVertically = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: compact ? 3 : 5) {
            Image(systemName: symbol)
                .fontWeight(.semibold)
                .accessibilityHidden(true)
            content()
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: compact ? 9 : 11))
        .foregroundStyle(.primary)
        .padding(.horizontal, compact ? 4 : 7)
        .padding(.vertical, compact ? 2 : 4)
        .frame(maxHeight: stretchesVertically ? .infinity : nil)
        .background(tint.opacity(compact ? 0.17 : 0.16), in: .rect(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5).strokeBorder(tint.opacity(0.42), lineWidth: 0.7)
        }
        .accessibilityElement(children: .combine)
    }
}
