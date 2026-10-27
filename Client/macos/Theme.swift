//
//  Theme.swift
//  The window's three looks: palettes, the shared card style, and the theme-specific drawings.
//

import SwiftUI
import AppKit

enum AppTheme: String, CaseIterable, Identifiable {
    case refinedDark, nativeGlass, sonySignature

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .refinedDark: return "Refined Dark"
        case .nativeGlass: return "Native Glass"
        case .sonySignature: return "Sony Signature"
        }
    }

    // Native Glass follows the system appearance; the other two are designed dark-only.
    var colorScheme: ColorScheme? { self == .nativeGlass ? nil : .dark }

    // Sony Signature changes shapes as well as colors: pill buttons, uppercase tracked labels,
    // monospaced numbers, EQ as bars and rings behind the product.
    var isSignature: Bool { self == .sonySignature }

    func palette(_ scheme: ColorScheme) -> Palette {
        switch self {
        case .refinedDark: return .refinedDark
        case .nativeGlass: return scheme == .dark ? .glassDark : .glassLight
        case .sonySignature: return .sonySignature
        }
    }
}

struct Palette {
    let background: AnyShapeStyle
    let card: AnyShapeStyle
    let cardStroke: Color
    let raised: AnyShapeStyle   // status chips and round icon buttons
    let track: Color            // recessed fill behind mode segments and idle EQ presets
    let primary: Color
    let secondary: Color
    let accent: Color
    let accentText: Color
    let onAccent: Color
    let danger: Color
    let selectedFill: Color
    let selectedText: Color
    let selectedStroke: Color
    let selectedShadow: Color
    let glow: Color             // light behind the product image
}

extension Palette {
    static let refinedDark: Palette = {
        let lavender = Color(hex: 0x8f8ff5)
        return Palette(
            background: AnyShapeStyle(Color(hex: 0x0d0d11)),
            card: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x17171d), Color(hex: 0x131318)],
                                               startPoint: .top, endPoint: .bottom)),
            cardStroke: Color(hex: 0x23232b),
            raised: AnyShapeStyle(Color(hex: 0x1b1b22)),
            track: Color.black.opacity(0.35),
            primary: Color(hex: 0xf2f2f6),
            secondary: Color(hex: 0x8d8d9a),
            accent: lavender,
            accentText: lavender,
            onAccent: .white,
            danger: Color.red.opacity(0.9),
            selectedFill: lavender,
            selectedText: .white,
            selectedStroke: .clear,
            selectedShadow: lavender.opacity(0.45),
            glow: lavender.opacity(0.32)
        )
    }()

    static let glassLight = glass(dark: false)
    static let glassDark = glass(dark: true)

    private static func glass(dark: Bool) -> Palette {
        // controlAccentColor rather than Color.accentColor, which would resolve through the
        // .accentColor(_:) the controls are given from this palette.
        let accent = Color(NSColor.controlAccentColor)
        return Palette(
            background: AnyShapeStyle(LinearGradient(
                colors: dark ? [Color(hex: 0x1a1d26), Color(hex: 0x15161b), Color(hex: 0x1c1924)]
                             : [Color(hex: 0xdfe6f3), Color(hex: 0xeef0f6), Color(hex: 0xe6e2f0)],
                startPoint: .topLeading, endPoint: .bottomTrailing)),
            // ponytail: materials, not .glassEffect(); switch to .glassEffect() behind `if #available(macOS 26, *)`
            // once the project builds with the macOS 26+ SDK in Xcode.
            card: AnyShapeStyle(.regularMaterial),
            cardStroke: Color.white.opacity(dark ? 0.1 : 0.8),
            raised: AnyShapeStyle(.thinMaterial),
            track: dark ? Color.black.opacity(0.25) : Color.gray.opacity(0.16),
            primary: .primary,
            secondary: .secondary,
            accent: accent,
            accentText: accent,
            onAccent: .white,
            danger: .red,
            selectedFill: dark ? Color.white.opacity(0.2) : .white,
            selectedText: dark ? .primary : accent,
            selectedStroke: .clear,
            selectedShadow: Color.black.opacity(dark ? 0.3 : 0.12),
            glow: Color.white.opacity(dark ? 0.12 : 0.95)
        )
    }

    static let sonySignature: Palette = {
        let amber = Color(hex: 0xffa032)
        let amberText = Color(hex: 0xffb456)
        return Palette(
            background: AnyShapeStyle(Color(hex: 0x050505)),
            card: AnyShapeStyle(Color(hex: 0x101010)),
            cardStroke: Color(hex: 0x1f1f1f),
            raised: AnyShapeStyle(Color.clear),
            track: .clear,
            primary: .white,
            secondary: Color(hex: 0x8a8a8a),
            accent: amber,
            accentText: amberText,
            onAccent: .black,
            danger: Color.red.opacity(0.9),
            selectedFill: amber.opacity(0.14),
            selectedText: amberText,
            selectedStroke: amber,
            selectedShadow: .clear,
            glow: amber.opacity(0.22)
        )
    }()
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.refinedDark
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

private struct ThemedCard: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let palette = theme.palette(colorScheme)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.card, in: shape)
            .overlay(shape.strokeBorder(palette.cardStroke, lineWidth: 1))
    }
}

extension View {
    func themedCard() -> some View { modifier(ThemedCard()) }
}

// Light behind the product image: a soft glow, or Sony Signature's warm rim and rings.
struct HeroBackdrop: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = theme.palette(colorScheme)
        ZStack {
            if theme.isSignature {
                Circle()
                    .fill(RadialGradient(colors: [palette.glow.opacity(0), palette.glow],
                                         center: .center, startRadius: 40, endRadius: 105))
                ForEach(0..<3) { ring in
                    Circle()
                        .strokeBorder(palette.accent.opacity(0.3 - Double(ring) * 0.1), lineWidth: 1)
                        .frame(width: 222 + CGFloat(ring) * 36, height: 222 + CGFloat(ring) * 36)
                }
            } else {
                Circle()
                    .fill(RadialGradient(colors: [palette.glow, palette.glow.opacity(0)],
                                         center: .center, startRadius: 4, endRadius: 104))
            }
        }
        .frame(width: 210, height: 210)
    }
}

// Small picture of the EQ: a filled curve, or bars in Sony Signature. `range` is the band value range.
struct EQPreview: View {
    let bands: [Int]
    let range: ClosedRange<Double>

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let accent = theme.palette(colorScheme).accent
        let span = range.upperBound - range.lowerBound
        let levels = bands.map { min(max((Double($0) - range.lowerBound) / span, 0), 1) }
        Group {
            if theme.isSignature {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(levels.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(accent.opacity(0.5 + 0.4 * levels[i]))
                            .frame(maxWidth: 34)
                            .frame(height: 6 + 48 * levels[i])
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                ZStack {
                    EQCurve(levels: levels, closed: true).fill(accent.opacity(0.15))
                    EQCurve(levels: levels, closed: false)
                        .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(height: 54, alignment: .bottom)
    }
}

// Levels are 0...1, spread evenly left to right. Horizontal tangents at each band keep the curve
// from overshooting between them.
private struct EQCurve: Shape {
    let levels: [Double]
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let levels = self.levels.count == 1 ? self.levels + self.levels : self.levels
        guard levels.count > 1 else { return path }
        let inset: CGFloat = 3
        let step = rect.width / CGFloat(levels.count - 1)
        let points = levels.enumerated().map { i, level in
            CGPoint(x: rect.minX + CGFloat(i) * step,
                    y: rect.maxY - inset - CGFloat(level) * (rect.height - 2 * inset))
        }
        path.move(to: points[0])
        for (from, to) in zip(points, points.dropFirst()) {
            let midX = (from.x + to.x) / 2
            path.addCurve(to: to, control1: CGPoint(x: midX, y: from.y), control2: CGPoint(x: midX, y: to.y))
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

// Mini preview for the theme picker. Native Glass is shown in its light look.
struct ThemeSwatch: View {
    let theme: AppTheme

    var body: some View {
        let palette = theme.palette(.light)
        let bar = RoundedRectangle(cornerRadius: 3, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            bar.fill(palette.cardStroke).frame(height: 8)
            bar.fill(palette.accent).frame(width: 24, height: 8)
            bar.fill(palette.cardStroke).frame(height: 8)
        }
        .padding(8)
        .frame(height: 56)
        .background(palette.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
