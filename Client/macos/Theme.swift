//
//  Theme.swift
//  The app's three looks: palettes, the shared card and control styles, and the theme-specific drawings.
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

    static let storageKey = "appTheme"

    static var stored: AppTheme {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AppTheme.init(rawValue:)) ?? .refinedDark
    }

    // Applied app-wide so the window, its popovers and the menu-bar panel all follow the theme. Not
    // .preferredColorScheme: on macOS, once it has forced a window dark, setting it back to nil doesn't
    // return the window to the system appearance, so Native Glass would stay dark until relaunch.
    func applyToApp() {
        NSApp.appearance = colorScheme == .dark ? NSAppearance(named: .darkAqua) : nil
    }

    // The concrete appearance for views that don't inherit the app's (the menu-bar panel): dark for the
    // dark-only themes, the system's current light/dark for Native Glass.
    var resolvedAppearance: NSAppearance? {
        if colorScheme == .dark { return NSAppearance(named: .darkAqua) }
        let systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSAppearance(named: systemIsDark ? .darkAqua : .aqua)
    }

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
    let compact: Bool

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let palette = theme.palette(colorScheme)
        let shape = RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous)
        return content
            .padding(compact ? 12 : 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.card, in: shape)
            .overlay(shape.strokeBorder(palette.cardStroke, lineWidth: 1))
    }
}

// Selected/idle look shared by the mode control and the EQ presets: pills in Sony Signature, rounded
// segments otherwise. Pills must be a real Capsule: a continuous RoundedRectangle with a radius near half
// the height has no room for its corner curves and renders flat-sided ends.
private struct Selectable: ViewModifier {
    let selected: Bool
    let filledWhenIdle: Bool

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme.isSignature {
            chrome(content, in: Capsule())
        } else {
            chrome(content, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // The content shape keeps clear (idle) segments clickable.
    private func chrome<S: InsettableShape>(_ content: Content, in shape: S) -> some View {
        let palette = theme.palette(colorScheme)
        return content
            .foregroundColor(selected ? palette.selectedText : palette.secondary)
            .background(selected ? palette.selectedFill : (filledWhenIdle ? palette.track : .clear), in: shape)
            .overlay(shape.strokeBorder(selected ? palette.selectedStroke
                                        : (theme.isSignature ? palette.cardStroke : .clear), lineWidth: 1))
            .contentShape(shape)
    }
}

extension View {
    // compact: the menu-bar panel's tighter card.
    func themedCard(compact: Bool = false) -> some View { modifier(ThemedCard(compact: compact)) }

    func selectable(_ selected: Bool, filledWhenIdle: Bool = false) -> some View {
        modifier(Selectable(selected: selected, filledWhenIdle: filledWhenIdle))
    }
}

// Label on the left, switch on the trailing edge, so every switch lines up.
// The title stays on the hidden Toggle label for VoiceOver.
struct SwitchRow<Label: View>: View {
    private let title: String
    private let isOn: Binding<Bool>
    private let label: Label

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String, isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self.title = title
        self.isOn = isOn
        self.label = label()
    }

    var body: some View {
        HStack {
            label
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: theme.palette(colorScheme).accent))
        }
    }
}

// Small secondary action, e.g. Fix / Unfix playback.
struct CapsuleButton: View {
    private let title: String
    private let action: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        let palette = theme.palette(colorScheme)
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(palette.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(palette.raised, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.cardStroke, lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
    }
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
                // Outermost ring is the frame itself, so none reach the button row or the device name.
                ForEach(0..<3) { ring in
                    Circle()
                        .strokeBorder(palette.accent.opacity(0.3 - Double(ring) * 0.08), lineWidth: 1)
                        .frame(width: 210 - CGFloat(ring) * 24, height: 210 - CGFloat(ring) * 24)
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

// Interactive EQ graph. The bands are evenly spaced on a log-frequency axis (400 Hz-16 kHz in 2.5x steps,
// or octaves on the ten-band layout), so even spacing is their true position. One EQGeometry maps
// band/value to a point and back, and the curve, nodes, labels and drag all go through it, so they line
// up exactly. Click or drag anywhere in a band's column to set it; values snap to whole device steps.
// Drawn as a curve, or as bars in Sony Signature.
struct EQEditor: View {
    let bands: [Int]
    let labels: [String]
    let range: ClosedRange<Int>
    let signed: Bool                    // dB values (-10...10); the ten-band layout's raw 0...12 steps are unsigned
    let set: (_ band: Int, _ value: Int) -> Void

    @State private var dragging: Int?

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private let plotHeight: CGFloat = 150
    private let axisWidth: CGFloat = 26
    private let labelsHeight: CGFloat = 34

    var body: some View {
        let palette = theme.palette(colorScheme)
        GeometryReader { proxy in
            let geo = EQGeometry(plot: CGRect(x: axisWidth, y: 0, width: proxy.size.width - axisWidth, height: plotHeight),
                                 count: bands.count, range: range)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.track)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.cardStroke, lineWidth: 1))
                    .frame(width: geo.plot.width, height: geo.plot.height)
                    .offset(x: geo.plot.minX)

                grid(geo, palette)
                trace(geo, palette)

                ForEach(bands.indices, id: \.self) { i in
                    node(i, geo, palette)
                }

                // Frequency under each node, its value under that.
                ForEach(bands.indices, id: \.self) { i in
                    VStack(spacing: 2) {
                        Text(i < labels.count ? labels[i] : "")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(palette.secondary)
                        Text(valueText(bands[i]))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(dragging == i ? palette.accentText : palette.primary)
                    }
                    .fixedSize()
                    .position(x: geo.x(i), y: plotHeight + labelsHeight / 2 + 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let band = dragging ?? geo.band(atX: drag.startLocation.x)
                    dragging = band
                    let value = geo.value(atY: drag.location.y)
                    if band < bands.count && value != bands[band] { set(band, value) }
                }
                .onEnded { _ in dragging = nil })
        }
        .frame(height: plotHeight + labelsHeight)
    }

    private var gridValues: [Int] {
        let quarter = (range.upperBound - range.lowerBound) / 4
        return (0...4).map { range.lowerBound + $0 * quarter }
    }

    private func valueText(_ value: Int) -> String {
        signed && value > 0 ? "+\(value)" : "\(value)"
    }

    private func grid(_ geo: EQGeometry, _ palette: Palette) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(gridValues, id: \.self) { value in
                let zero = signed && value == 0
                Path { p in
                    p.move(to: CGPoint(x: geo.plot.minX, y: geo.y(value)))
                    p.addLine(to: CGPoint(x: geo.plot.maxX, y: geo.y(value)))
                }
                .stroke(palette.secondary.opacity(zero ? 0.45 : 0.18),
                        style: StrokeStyle(lineWidth: 1, dash: zero ? [] : [3, 3]))
                Text(valueText(value))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(palette.secondary)
                    .fixedSize()
                    .position(x: axisWidth / 2 - 2, y: geo.y(value))
            }
            ForEach(bands.indices, id: \.self) { i in
                Path { p in
                    p.move(to: CGPoint(x: geo.x(i), y: geo.plot.minY + 6))
                    p.addLine(to: CGPoint(x: geo.x(i), y: geo.plot.maxY - 6))
                }
                .stroke(palette.secondary.opacity(dragging == i ? 0.35 : 0.1), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func trace(_ geo: EQGeometry, _ palette: Palette) -> some View {
        // Fill toward 0 dB, or the bottom for the unsigned raw steps.
        let base = signed ? 0 : range.lowerBound
        if theme.isSignature {
            ForEach(bands.indices, id: \.self) { i in
                let top = min(geo.y(bands[i]), geo.y(base))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(palette.accent.opacity(dragging == i ? 0.6 : 0.35))
                    .frame(width: 10, height: max(abs(geo.y(bands[i]) - geo.y(base)), 2))
                    .position(x: geo.x(i), y: top + max(abs(geo.y(bands[i]) - geo.y(base)), 2) / 2)
            }
        } else {
            geo.curve(bands, fillTo: base).fill(palette.accent.opacity(0.15))
            geo.curve(bands, fillTo: nil)
                .stroke(palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
    }

    private func node(_ i: Int, _ geo: EQGeometry, _ palette: Palette) -> some View {
        let active = dragging == i
        let size: CGFloat = active ? 16 : 12
        return ZStack {
            Circle()
                .fill(palette.accent)
                .overlay(Circle().strokeBorder(palette.onAccent, lineWidth: 2))
                .frame(width: size, height: size)
                .shadow(color: palette.accent.opacity(active ? 0.5 : 0), radius: 6)
            if active {
                Text(valueText(bands[i]))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.onAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(palette.accent, in: Capsule())
                    .fixedSize()
                    .offset(y: geo.y(bands[i]) - geo.plot.minY < 34 ? 22 : -22)
            }
        }
        .position(x: geo.x(i), y: geo.y(bands[i]))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(i < labels.count ? "\(labels[i]) Hz" : "Band \(i + 1)")
        .accessibilityValue(signed ? "\(valueText(bands[i])) dB" : valueText(bands[i]))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1 : -1
            let value = min(max(bands[i] + step, range.lowerBound), range.upperBound)
            if value != bands[i] { set(i, value) }
        }
    }
}

// Band index/value <-> point in the plot. Nodes are inset so ones at the ends or the limits aren't clipped.
private struct EQGeometry {
    let plot: CGRect
    let count: Int
    let range: ClosedRange<Int>

    private let sideInset: CGFloat = 16
    private let topBottomInset: CGFloat = 12

    private var span: Double { Double(range.upperBound - range.lowerBound) }
    private var usableHeight: CGFloat { plot.height - 2 * topBottomInset }

    func x(_ band: Int) -> CGFloat {
        guard count > 1 else { return plot.midX }
        return plot.minX + sideInset + CGFloat(band) * (plot.width - 2 * sideInset) / CGFloat(count - 1)
    }

    func y(_ value: Int) -> CGFloat {
        let t = (Double(value) - Double(range.lowerBound)) / span
        return plot.maxY - topBottomInset - CGFloat(t) * usableHeight
    }

    func value(atY y: CGFloat) -> Int {
        let t = Double((plot.maxY - topBottomInset - y) / usableHeight)
        let value = Int((Double(range.lowerBound) + t * span).rounded())
        return min(max(value, range.lowerBound), range.upperBound)
    }

    func band(atX x: CGFloat) -> Int {
        guard count > 1 else { return 0 }
        let step = (plot.width - 2 * sideInset) / CGFloat(count - 1)
        return min(max(Int(((x - plot.minX - sideInset) / step).rounded()), 0), count - 1)
    }

    // Through every node, flat out to the plot's edges. Horizontal tangents at each node keep the curve
    // from overshooting between bands, so it never shows a level no band is set to.
    func curve(_ bands: [Int], fillTo base: Int?) -> Path {
        var path = Path()
        guard !bands.isEmpty else { return path }
        let points = bands.indices.map { CGPoint(x: x($0), y: y(bands[$0])) }
        path.move(to: CGPoint(x: plot.minX + 1, y: points[0].y))
        path.addLine(to: points[0])
        for (from, to) in zip(points, points.dropFirst()) {
            let midX = (from.x + to.x) / 2
            path.addCurve(to: to, control1: CGPoint(x: midX, y: from.y), control2: CGPoint(x: midX, y: to.y))
        }
        path.addLine(to: CGPoint(x: plot.maxX - 1, y: points[points.count - 1].y))
        if let base = base {
            path.addLine(to: CGPoint(x: plot.maxX - 1, y: y(base)))
            path.addLine(to: CGPoint(x: plot.minX + 1, y: y(base)))
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
