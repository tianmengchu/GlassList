import SwiftUI

struct AppPalette: Codable, Equatable, Sendable {
    var background: DetailColor
    var sidebar: DetailColor
    var surface: DetailColor
    var text: DetailColor
    var accent: DetailColor

    var secondaryText: Color { text.swatch.opacity(0.72) }

    var accentText: Color {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(accent.red) + 0.7152 * linear(accent.green) + 0.0722 * linear(accent.blue)
        return luminance > 0.179 ? .black : .white
    }

    fileprivate init(background: UInt32, sidebar: UInt32, surface: UInt32, text: UInt32, accent: UInt32) {
        self.background = DetailColor(hex: background)
        self.sidebar = DetailColor(hex: sidebar)
        self.surface = DetailColor(hex: surface)
        self.text = DetailColor(hex: text)
        self.accent = DetailColor(hex: accent)
    }
}

private extension DetailColor {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

enum ThemePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard, ocean, lilac, sand, rose, graphite

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: "默认青绿"
        case .ocean: "晴海"
        case .lilac: "紫雾"
        case .sand: "暖沙"
        case .rose: "落日玫瑰"
        case .graphite: "石墨"
        }
    }

    func palette(for scheme: ColorScheme) -> AppPalette {
        switch (self, scheme == .dark) {
        case (.standard, false): AppPalette(background: 0xF7FAFA, sidebar: 0xEBF0F0, surface: 0xFFFFFF, text: 0x1C2728, accent: 0x21695C)
        case (.standard, true): AppPalette(background: 0x141A1F, sidebar: 0x1C2129, surface: 0x242C34, text: 0xE8EFEE, accent: 0xA6E0CC)
        case (.ocean, false): AppPalette(background: 0xF0F7FF, sidebar: 0xDCEBFC, surface: 0xFAFDFF, text: 0x19364D, accent: 0x125DA1)
        case (.ocean, true): AppPalette(background: 0x101E2E, sidebar: 0x17283E, surface: 0x1E344E, text: 0xDCEEFF, accent: 0x91CBFF)
        case (.lilac, false): AppPalette(background: 0xF6F1FC, sidebar: 0xEBE0F7, surface: 0xFDF9FF, text: 0x39254F, accent: 0x70449B)
        case (.lilac, true): AppPalette(background: 0x21182F, sidebar: 0x2D203E, surface: 0x36274A, text: 0xF2E6FF, accent: 0xD8B4FF)
        case (.sand, false): AppPalette(background: 0xFCF5E8, sidebar: 0xF1E4CE, surface: 0xFFFAF0, text: 0x43351F, accent: 0x81561F)
        case (.sand, true): AppPalette(background: 0x251D15, sidebar: 0x31261B, surface: 0x3B2F22, text: 0xFAECD8, accent: 0xF1C07E)
        case (.rose, false): AppPalette(background: 0xFFF2EF, sidebar: 0xF8DFD9, surface: 0xFFF9F7, text: 0x512F35, accent: 0xA83754)
        case (.rose, true): AppPalette(background: 0x291920, sidebar: 0x39232E, surface: 0x452B38, text: 0xFFE6EC, accent: 0xFFA7B9)
        case (.graphite, false): AppPalette(background: 0xF1F2F4, sidebar: 0xE0E3E8, surface: 0xFAFBFC, text: 0x242933, accent: 0x4D5A6B)
        case (.graphite, true): AppPalette(background: 0x17191D, sidebar: 0x21242A, surface: 0x2B2F36, text: 0xF0F2F4, accent: 0xBFCFE4)
        }
    }
}

struct AppTheme: Codable, Equatable, Sendable {
    var preset: ThemePreset = .standard
    private(set) var day: AppPalette?
    private(set) var night: AppPalette?

    var hasCustomColors: Bool { day != nil || night != nil }

    func palette(for scheme: ColorScheme) -> AppPalette {
        (scheme == .dark ? night : day) ?? preset.palette(for: scheme)
    }

    mutating func setColor(_ color: DetailColor, at keyPath: WritableKeyPath<AppPalette, DetailColor>, for scheme: ColorScheme) {
        var palette = palette(for: scheme)
        palette[keyPath: keyPath] = color
        let custom = palette == preset.palette(for: scheme) ? nil : palette
        if scheme == .dark { night = custom } else { day = custom }
    }
}

extension EnvironmentValues {
    @Entry var appPalette: AppPalette? = nil
}

struct ThemeButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.appPalette) private var appPalette
    @Environment(\.colorScheme) private var scheme
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let palette = appPalette ?? ThemePreset.standard.palette(for: scheme)
        let compact = controlSize == .small || controlSize == .mini
        let border = palette.text.swatch.opacity(prominent ? 0 : 0.11)
        let shape = RoundedRectangle(cornerRadius: compact ? 7 : 9)
        return configuration.label
            .foregroundStyle(prominent ? palette.accentText : palette.text.swatch)
            .padding(.horizontal, compact ? 8 : 11)
            .padding(.vertical, compact ? 4 : 6)
            .background(prominent ? palette.accent.swatch : palette.surface.swatch, in: shape)
            .overlay { shape.strokeBorder(border).allowsHitTesting(false) }
            .contentShape(shape)
            .opacity(!isEnabled ? 0.46 : configuration.isPressed ? 0.78 : 1)
    }
}

struct ThemeGallery: View {
    let theme: AppTheme
    let scheme: ColorScheme
    let select: (ThemePreset) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3), spacing: 10) {
            ForEach(ThemePreset.allCases) { preset in
                let selected = preset == theme.preset
                let preview = selected ? theme.palette(for: scheme) : preset.palette(for: scheme)
                Button { select(preset) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        themePreview(preview)
                        HStack(spacing: 4) {
                            Text(preset.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if selected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                                    .font(.caption)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .padding(6)
                    .background(.primary.opacity(selected ? 0.08 : 0.035), in: .rect(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.tint.opacity(selected ? 0.7 : 0.14))
                            .allowsHitTesting(false)
                    }
                    .contentShape(.rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    private func themePreview(_ palette: AppPalette) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Circle().fill(palette.accent.swatch).frame(width: 7, height: 7)
                Capsule().fill(palette.text.swatch.opacity(0.55)).frame(width: 12, height: 2)
                Capsule().fill(palette.text.swatch.opacity(0.3)).frame(width: 8, height: 2)
                Spacer(minLength: 0)
            }
            .frame(width: 25)
            .padding(.top, 7)
            .frame(maxHeight: .infinity)
            .background(palette.sidebar.swatch)

            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(palette.text.swatch).frame(width: 25, height: 3)
                HStack(spacing: 4) {
                    Circle().strokeBorder(palette.accent.swatch, lineWidth: 1).frame(width: 6, height: 6)
                    Capsule().fill(palette.text.swatch.opacity(0.55)).frame(width: 16, height: 2)
                    Spacer(minLength: 0)
                }
                .padding(5)
                .background(palette.surface.swatch, in: .rect(cornerRadius: 4))
                Spacer(minLength: 0)
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(palette.background.swatch)
        }
        .frame(height: 40)
        .clipShape(.rect(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}
