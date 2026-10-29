//
//  SharedViews.swift
//  Building blocks used by the menu-bar panel (QuickControlsView).
//

import SwiftUI
import AppKit

enum EQPresets {
    static let fiveBand: [(String, Int)] = [
        ("Off", 0x00), ("Bright", 0x10), ("Excited", 0x11),
        ("Mellow", 0x12), ("Relaxed", 0x13), ("Vocal", 0x14),
        ("Treble", 0x15), ("Bass", 0x16), ("Speech", 0x17),
        ("Manual", 0xA0)
    ]
    // WH-1000XM6: only Off and Custom have confirmed preset codes on the ten-band layout; its other preset
    // bytes (0x20, 0x30-0x33, 0xa1-0xa2) are unnamed, and the 5-band codes above don't apply to it.
    static let tenBand: [(String, Int)] = [("Off", 0x00), ("Custom", 0xA0)]

    static func list(tenBand: Bool) -> [(String, Int)] { tenBand ? Self.tenBand : fiveBand }
}

// Indexed like Headphones::setAutoPowerOff (0=Off ... 5=when taken off).
enum AutoPowerOff {
    static let options = ["Off", "5 min", "30 min", "1 hour", "3 hours", "When taken off"]
}

extension SHCAmbientMode {
    var displayName: String {
        switch self {
        case .noiseCanceling: return "Noise Cancelling"
        case .ambientSound: return "Ambient"
        default: return "Off"
        }
    }
}

// The bundled product cutout matching the device name (e.g. "WH-CH720N" -> "wh-ch720n"), or a generic
// headphones glyph for models without one.
struct ProductImage: View {
    let deviceName: String
    let size: CGFloat

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = NSImage(named: deviceName.lowercased().replacingOccurrences(of: " ", with: "-")) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "headphones")
                .font(.system(size: size * 0.48, weight: .thin))
                .foregroundColor(theme.palette(colorScheme).primary)
                .frame(width: size, height: size)
        }
    }
}

// Battery, codec and (optionally) the current mode as capsule chips.
struct StatusChips: View {
    @ObservedObject var model: HeadphonesModel
    var showsMode = true

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var palette: Palette { theme.palette(colorScheme) }

    var body: some View {
        HStack(spacing: 6) {
            chip {
                if model.hasDualBattery {
                    // Earbuds report a battery each, plus the case when it's connected. An earbud that
                    // isn't reporting (docked / powered down) comes through as -1 and is left out.
                    budBattery("L", model.batteryLeft, charging: model.batteryLeftCharging)
                    Text("·")
                    budBattery("R", model.batteryRight, charging: model.batteryRightCharging)
                    if model.batteryCase >= 0 {
                        Text("·")
                        budBattery("Case", model.batteryCase, charging: model.batteryCaseCharging)
                    }
                } else if model.batteryLevel >= 0 {
                    Image(systemName: model.batteryCharging ? "bolt.fill" : batterySymbol(model.batteryLevel))
                        .foregroundColor(model.batteryLevel <= 20 ? palette.danger : palette.accent)
                    chipText("\(model.batteryLevel)%")
                } else {
                    Circle().fill(palette.accent).frame(width: 6, height: 6)
                    chipText("Connected")
                }
            }
            if showsMode {
                chip { chipText(model.mode.displayName) }
            }
        }
    }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4, content: content)
            .font(.system(size: theme.isSignature ? 10 : 11, weight: .semibold))
            .foregroundColor(palette.secondary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(palette.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(palette.cardStroke, lineWidth: 1))
    }

    private func chipText(_ text: String) -> Text {
        Text(theme.isSignature ? text.uppercased() : text).tracking(theme.isSignature ? 0.8 : 0)
    }

    // One "L 82%" reading in the battery chip, with a bolt in place of the battery glyph while that unit
    // is charging. A docked/powered-down earbud reports no level; show it dimmed as "R --" rather than
    // dropping it, so it reads as "in the case" instead of looking like the app lost track of it.
    private func budBattery(_ label: String, _ level: Int, charging: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: level < 0 ? "battery.0" : (charging ? "bolt.fill" : batterySymbol(level)))
                .foregroundColor(level < 0 ? palette.secondary.opacity(0.5)
                                 : (level <= 20 && !charging ? palette.danger : palette.accent))
            chipText(level < 0 ? "\(label) --" : "\(label) \(level)%")
                .foregroundColor(palette.secondary.opacity(level < 0 ? 0.5 : 1.0))
        }
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case ...15: return "battery.0"
        case ...50: return "battery.25"
        default: return "battery.100"
        }
    }
}

// Noise Cancelling / Ambient / Off: segments in a recessed track, or separate pills in Sony Signature.
struct AmbientModeControl: View {
    @ObservedObject var model: HeadphonesModel

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var palette: Palette { theme.palette(colorScheme) }

    var body: some View {
        let track = RoundedRectangle(cornerRadius: 11, style: .continuous)
        HStack(spacing: theme.isSignature ? 6 : 0) {
            modeButton(.noiseCanceling)
            modeButton(.ambientSound)
            modeButton(.off)
        }
        .padding(theme.isSignature ? 0 : 3)
        .background(palette.track, in: track)
        .overlay(track.strokeBorder(theme.isSignature ? .clear : palette.cardStroke, lineWidth: 1))
    }

    private func modeButton(_ mode: SHCAmbientMode) -> some View {
        let selected = model.mode == mode
        return Button(action: { model.setMode(mode) }) {
            Text(mode.displayName)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .selectable(selected)
                .shadow(color: selected ? palette.selectedShadow : .clear, radius: 8)
        }
        .buttonStyle(.plain)
    }
}

struct AmbientLevelSlider: View {
    @ObservedObject var model: HeadphonesModel

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Slider(
            value: Binding(
                get: { Double(model.ambientLevel) },
                set: { model.setLevel(Int($0.rounded())) }
            ),
            in: 1...Double(model.maxAmbientLevel),
            step: 1
        )
        .accentColor(theme.palette(colorScheme).accent)
    }
}

struct FocusOnVoiceSwitch: View {
    @ObservedObject var model: HeadphonesModel

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SwitchRow("Focus on Voice", isOn: Binding(
            get: { model.focusOnVoice },
            set: { model.setFocusOnVoice($0) }
        )) {
            Text("Focus on Voice")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.palette(colorScheme).primary)
        }
    }
}

struct ConnectButton: View {
    @ObservedObject var model: HeadphonesModel

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = theme.palette(colorScheme)
        // Activate first: from the menu-bar panel the app isn't frontmost, and the device picker the
        // connect shows would open behind other apps.
        Button(action: { NSApp.activate(ignoringOtherApps: true); model.connect() }) {
            Text(model.connecting ? "Connecting…" : "Connect headphones")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(palette.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(palette.accent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(model.connecting)
    }
}
