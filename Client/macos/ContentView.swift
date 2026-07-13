//
//  ContentView.swift
//  Sony Sound Connect-style SwiftUI interface.
//

import SwiftUI
import AppKit

private enum Theme {
    static let bg = Color(red: 0.07, green: 0.07, blue: 0.086)
    static let card = Color(red: 0.13, green: 0.13, blue: 0.16)
    static let cardHi = Color(red: 0.20, green: 0.20, blue: 0.24)
    static let accent = Color(red: 0.62, green: 0.62, blue: 0.96)
    static let secondary = Color(white: 0.62)
}

@available(macOS 11.0, *)
struct ContentView: View {
    @StateObject private var model = HeadphonesModel()

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if model.connected {
                connectedView
            } else {
                disconnectedView
            }
        }
        .frame(minWidth: 360, minHeight: 500)
    }

    // MARK: - Disconnected

    private var disconnectedView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "headphones")
                .font(.system(size: 64, weight: .thin))
                .foregroundColor(Theme.secondary)
            Text("No headphones connected")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.secondary)
            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button(action: model.connect) {
                Text(model.connecting ? "Connecting…" : "Connect headphones")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(model.connecting)
            .padding(.horizontal, 40)
            Spacer()
        }
    }

    // MARK: - Connected

    private var connectedView: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ambientCard
            if model.mode == .ambientSound {
                ambientLevelCard
            }
            equalizerCard
            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.9))
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.deviceName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                HStack(spacing: 6) {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    Text("Connected")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.secondary)
                    if model.batteryLevel >= 0 {
                        Text("·").foregroundColor(Theme.secondary)
                        Image(systemName: model.batteryCharging ? "bolt.fill" : batterySymbol(model.batteryLevel))
                            .font(.system(size: 12))
                            .foregroundColor(model.batteryLevel <= 20 ? .red.opacity(0.9) : Theme.accent)
                        Text("\(model.batteryLevel)%")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.secondary)
                    }
                }
            }
            Spacer()
            Button(action: model.disconnect) {
                Image(systemName: "power")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.secondary)
                    .frame(width: 34, height: 34)
                    .background(Theme.card)
                    .clipShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var ambientCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ambient Sound Control")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            HStack(spacing: 0) {
                modeButton(.noiseCanceling, "speaker.slash.fill", "Noise\nCanceling")
                modeButton(.ambientSound, "wind", "Ambient\nSound")
                modeButton(.off, "circle", "Off")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func modeButton(_ mode: SHCAmbientMode, _ symbol: String, _ label: String) -> some View {
        let selected = model.mode == mode
        return Button(action: { model.setMode(mode) }) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(selected ? Theme.accent : Theme.cardHi)
                        .frame(width: 58, height: 58)
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(selected ? .white : Theme.secondary)
                }
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundColor(selected ? .white : Theme.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var ambientLevelCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Ambient Sound Level")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.secondary)
                Spacer()
                Text("\(model.ambientLevel)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.accent)
            }
            Slider(
                value: Binding(
                    get: { Double(model.ambientLevel) },
                    set: { model.setLevel(Int($0.rounded())) }
                ),
                in: 1...Double(model.maxAmbientLevel),
                step: 1
            )
            .accentColor(Theme.accent)

            if model.focusOnVoiceAvailable {
                Toggle(isOn: Binding(
                    get: { model.focusOnVoice },
                    set: { model.setFocusOnVoice($0) }
                )) {
                    Text("Focus on Voice")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
                .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private let eqPresets: [(String, Int)] = [
        ("Off", 0x00), ("Bright", 0x10), ("Excited", 0x11),
        ("Mellow", 0x12), ("Relaxed", 0x13), ("Vocal", 0x14),
        ("Treble", 0x15), ("Bass", 0x16), ("Speech", 0x17)
    ]

    private var equalizerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Equalizer")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(eqPresets, id: \.1) { preset in
                    eqChip(preset.0, preset.1)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func eqChip(_ name: String, _ code: Int) -> some View {
        let selected = model.eqPreset == code
        return Button(action: { model.setEqualizer(code) }) {
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(selected ? .white : Theme.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? Theme.accent : Theme.cardHi)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case ...15: return "battery.0"
        case ...50: return "battery.25"
        default: return "battery.100"
        }
    }
}

// Factory so the Obj-C++ ViewController can instantiate the SwiftUI hierarchy.
@available(macOS 11.0, *)
@objc final class HeadphonesUIFactory: NSObject {
    @objc static func makeViewController() -> NSViewController {
        return NSHostingController(rootView: ContentView())
    }
}
