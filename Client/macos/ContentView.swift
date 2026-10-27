//
//  ContentView.swift
//  Sony Sound Connect-style SwiftUI interface.
//

import SwiftUI
import AppKit
import Combine

private enum Theme {
    static let bg = Color(red: 0.07, green: 0.07, blue: 0.086)
    static let card = Color(red: 0.13, green: 0.13, blue: 0.16)
    static let cardHi = Color(red: 0.20, green: 0.20, blue: 0.24)
    static let accent = Color(red: 0.62, green: 0.62, blue: 0.96)
    static let secondary = Color(white: 0.62)
}

@available(macOS 11.0, *)
struct ContentView: View {
    @StateObject private var model = HeadphonesModel.shared
    @State private var showAbout = false

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
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                deviceHero
                ambientCard
                if model.mode == .ambientSound {
                    ambientLevelCard
                }
                if model.multipointLoading || model.hasPairedDevices || model.hasPlaybackPinState {
                    devicesCard
                }
                if model.supportsEqualizer {
                    equalizerCard
                }
                if model.supportsDsee {
                    dseeCard
                }
                if model.hasAdaptiveVolume || model.hasSpeakToChat || model.hasAutoPowerOff || model.hasMultipointSetting {
                    settingsCard
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red.opacity(0.9))
                }
            }
            .padding(20)
        }
    }

    private var deviceHero: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Spacer()
                Button(action: { showAbout = true }) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.secondary)
                        .frame(width: 32, height: 32)
                        .background(Theme.card)
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                .popover(isPresented: $showAbout, arrowEdge: .bottom) { aboutView }
                Button(action: model.disconnect) {
                    Image(systemName: "power")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.secondary)
                        .frame(width: 32, height: 32)
                        .background(Theme.card)
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
            }

            // Product-style banner. Generic headphone graphic (device-specific Sony renders are
            // copyrighted and can't be bundled) over a soft accent halo, mirroring Sony's app layout.
            ZStack {
                // Soft accent glow behind the product for depth.
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0.0)]),
                            center: .center, startRadius: 4, endRadius: 104
                        )
                    )
                    .frame(width: 210, height: 210)

                if let image = deviceImage() {
                    // Background-removed product cutout floating on the dark UI.
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 190, height: 190)
                } else {
                    Image(systemName: "headphones")
                        .font(.system(size: 92, weight: .thin))
                        .foregroundColor(.white)
                }
            }

            Text(model.deviceName)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)

            HStack(spacing: 7) {
                if model.hasDualBattery {
                    // Earbuds report a battery each, plus the case when it's connected. An earbud that
                    // isn't reporting (docked / powered down) comes through as -1 and is left out.
                    budBattery("L", model.batteryLeft, charging: model.batteryLeftCharging)
                    budBattery("R", model.batteryRight, charging: model.batteryRightCharging)
                    if model.batteryCase >= 0 {
                        budBattery("Case", model.batteryCase, charging: model.batteryCaseCharging)
                    }
                } else if model.batteryLevel >= 0 {
                    Image(systemName: model.batteryCharging ? "bolt.fill" : batterySymbol(model.batteryLevel))
                        .font(.system(size: 13))
                        .foregroundColor(model.batteryLevel <= 20 ? .red.opacity(0.9) : Theme.accent)
                    Text("\(model.batteryLevel)%")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.secondary)
                } else {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    Text("Connected")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.secondary)
                }
                if !model.codec.isEmpty {
                    Text("·").foregroundColor(Theme.secondary)
                    Text(model.codec)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.secondary)
                }
            }
        }
        .padding(.bottom, 4)
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
        ("Treble", 0x15), ("Bass", 0x16), ("Speech", 0x17),
        ("Manual", 0xA0)
    ]
    private let eqBandLabels = ["400", "1k", "2.5k", "6.3k", "16k"]
    // WH-1000XM6: only Off and Custom have confirmed preset codes on the ten-band layout; its other preset
    // bytes (0x20, 0x30-0x33, 0xa1-0xa2) are unnamed, and the 5-band codes above don't apply to it.
    private let tenBandEqPresets: [(String, Int)] = [("Off", 0x00), ("Custom", 0xA0)]
    private let tenBandEqLabels = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    private var equalizerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Equalizer")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(model.tenBandEqualizer ? tenBandEqPresets : eqPresets, id: \.1) { preset in
                    eqChip(preset.0, preset.1)
                }
            }
            if model.eqPreset == 0xA0 {
                Divider().background(Theme.cardHi)
                let labels = model.tenBandEqualizer ? tenBandEqLabels : eqBandLabels
                ForEach(0..<min(model.eqBands.count, labels.count), id: \.self) { i in
                    eqBandRow(labels[i], value: Binding(
                        get: { Double(model.eqBands[i]) },
                        set: { model.eqBands[i] = Int($0.rounded()); model.applyCustomEq() }
                    ), display: model.eqBands[i], raw: model.tenBandEqualizer)
                }
                if !model.tenBandEqualizer {
                    eqBandRow("Bass", value: Binding(
                        get: { Double(model.clearBass) },
                        set: { model.clearBass = Int($0.rounded()); model.applyCustomEq() }
                    ), display: model.clearBass, accent: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // raw: the ten-band layout's 0...12 device steps (no dB mapping is known yet), shown unsigned.
    private func eqBandRow(_ label: String, value: Binding<Double>, display: Int, accent: Bool = false, raw: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(accent ? Theme.accent : Theme.secondary)
                .frame(width: 34, alignment: .leading)
            Slider(value: value, in: raw ? 0...12 : -10...10, step: 1).accentColor(Theme.accent)
            Text(raw ? "\(display)" : "\(display > 0 ? "+" : "")\(display)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 26, alignment: .trailing)
        }
    }

    private var dseeCard: some View {
        Toggle(isOn: Binding(get: { model.dsee }, set: { model.setDsee($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DSEE").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                Text("Upscale compressed audio").font(.system(size: 11)).foregroundColor(Theme.secondary)
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
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

    private let apoOptions = ["Off", "5 min", "30 min", "1 hour", "3 hours", "When taken off"]

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            if model.hasAdaptiveVolume {
                settingToggle("Adaptive Volume", "Auto-adjust volume by surroundings",
                              on: model.adaptiveVolume) { model.setAdaptiveVolume($0) }
            }
            if model.hasSpeakToChat {
                settingToggle("Speak-to-Chat", "Pause music when you talk",
                              on: model.speakToChat) { model.setSpeakToChat($0) }
                Toggle(isOn: $model.keepSpeakToChatOff) {
                    Text("Keep off on connect")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.secondary)
                }
                .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                .controlSize(.small)
                .padding(.leading, 12)
            }
            if model.hasMultipointSetting {
                settingToggle("Connect to 2 devices", "Stay paired to two devices at once",
                              on: model.multipointEnabled) { model.setMultipoint($0) }
            }
            if model.hasAutoPowerOff {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto Power-Off").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                        Text("Turn off when idle").font(.system(size: 11)).foregroundColor(Theme.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { model.autoPowerOff },
                        set: { model.setAutoPowerOff($0) }
                    )) {
                        ForEach(0..<apoOptions.count, id: \.self) { i in Text(apoOptions[i]).tag(i) }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 130)
                    .accentColor(Theme.accent)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func settingToggle(_ title: String, _ subtitle: String, on: Bool, action: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { action($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                Text(subtitle).font(.system(size: 11)).foregroundColor(Theme.secondary)
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
    }

    // Multipoint device list. Read-only for now: nothing here sends a command that changes the headset.
    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Devices")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                if model.multipointLoading || model.refreshingMultipoint || model.multipointBusy {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                } else {
                    Button(action: model.refreshMultipoint) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            if model.multipointLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 18, height: 18)
                    Text("Reading devices from the headset…")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
            if model.hasPlaybackPinState {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Playback device").font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                        Text(model.playbackPinned ? "Fixed" : "Switches automatically")
                            .font(.system(size: 11)).foregroundColor(Theme.secondary)
                    }
                    Spacer()
                    Button(action: { model.setPlaybackPinned(!model.playbackPinned) }) {
                        Text(model.playbackPinned ? "Unfix" : "Fix")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Theme.cardHi)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(model.multipointBusy)
                }
            }
            if model.hasPairedDevices {
                let connected = model.pairedDevices.filter { $0.connected }.sorted { $0.slot < $1.slot }
                let paired = model.pairedDevices.filter { !$0.connected }
                if !connected.isEmpty {
                    devicesSectionLabel("Connected")
                    ForEach(connected) { deviceRow($0) }
                }
                if !paired.isEmpty {
                    devicesSectionLabel("Paired")
                    ForEach(paired) { deviceRow($0) }
                }
            } else if !model.multipointLoading {
                Text("This headset didn't return a device list.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondary)
            }
            if !model.multipointLoading {
                devicesFooter
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var devicesFooter: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider().background(Theme.cardHi)
            HStack {
                Text(model.multipointBusy ? "Sending…" : "Switching and fixing are experimental")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondary.opacity(0.7))
                Spacer()
                Button(action: copyMultipointDiagnostics) {
                    Text("Copy diagnostics")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.accent)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private func devicesSectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Theme.secondary.opacity(0.8))
            .padding(.top, 2)
    }

    private func deviceRow(_ device: PairedDeviceInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: deviceSymbol(device.classOfDevice))
                .font(.system(size: 15))
                .foregroundColor(device.connected ? .white : Theme.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name.isEmpty ? device.address : device.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(device.connected ? .white : Theme.secondary)
                    .lineLimit(1)
                if device.isThisMac {
                    Text("This Mac").font(.system(size: 11)).foregroundColor(Theme.accent)
                }
            }
            Spacer()
            if device.playback {
                if model.playbackPinned {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.accent)
                }
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.accent)
            }
            if device.connected && model.hasPlaybackPinState {
                Menu {
                    Button("Switch playback device and fix") { model.switchPlayback(to: device, fix: true) }
                    if !device.playback {
                        Button("Switch playback device") { model.switchPlayback(to: device, fix: false) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(BorderlessButtonMenuStyle())
                .fixedSize()
                .disabled(model.multipointBusy)
            }
        }
    }

    // Major device class lives in bits 8-12 of the class of device (1 = computer, 2 = phone).
    private func deviceSymbol(_ classOfDevice: Int) -> String {
        guard classOfDevice >= 0, classOfDevice != 0xFFFFFF else { return "dot.radiowaves.left.and.right" }
        switch (classOfDevice >> 8) & 0x1F {
        case 1: return "laptopcomputer"
        case 2: return "iphone"
        default: return "dot.radiowaves.left.and.right"
        }
    }

    private func copyMultipointDiagnostics() {
        let header = "\(model.deviceName) · fw \(model.firmware) · \(model.protocolVersion)\n"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(header + model.multipointDiagnostics, forType: .string)
    }

    // ⋯ About / device info popover.
    private var aboutView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.deviceName)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .padding(.bottom, 10)
            aboutRow("Status", model.connected ? "Connected" : "Disconnected")
            if model.hasDualBattery {
                aboutRow("Battery L", batteryText(model.batteryLeft, model.batteryLeftCharging))
                aboutRow("Battery R", batteryText(model.batteryRight, model.batteryRightCharging))
                if model.batteryCase >= 0 {
                    aboutRow("Case", batteryText(model.batteryCase, model.batteryCaseCharging))
                }
            } else if model.batteryLevel >= 0 {
                aboutRow("Battery", "\(model.batteryLevel)%\(model.batteryCharging ? " (charging)" : "")")
            }
            if !model.codec.isEmpty { aboutRow("Codec", model.codec) }
            if !model.firmware.isEmpty { aboutRow("Firmware", model.firmware) }
            if !model.protocolVersion.isEmpty { aboutRow("Protocol", model.protocolVersion) }
            if !model.deviceMac.isEmpty { aboutRow("Bluetooth", model.deviceMac) }
            Divider().background(Theme.cardHi).padding(.vertical, 10)
            Text("SonyBridge · not affiliated with Sony")
                .font(.system(size: 10))
                .foregroundColor(Theme.secondary.opacity(0.7))
        }
        .padding(18)
        .frame(width: 260)
        .background(Theme.card)
    }

    private func batteryText(_ level: Int, _ charging: Bool) -> String {
        guard level >= 0 else { return "—" }
        return "\(level)%\(charging ? " (charging)" : "")"
    }

    private func aboutRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundColor(Theme.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium)).foregroundColor(.white)
        }
        .padding(.vertical, 3)
    }

    // Matches the connected device name to a bundled product image (e.g. "WH-CH720N" -> "wh-ch720n").
    private func deviceImage() -> NSImage? {
        let slug = model.deviceName.lowercased().replacingOccurrences(of: " ", with: "-")
        return NSImage(named: slug)
    }

    // One "L 82%" chip, with a bolt in place of the battery glyph while that unit is charging.
    // A docked/powered-down earbud reports no level; show it dimmed as "R --" rather than dropping the
    // chip, so it reads as "in the case" instead of looking like the app lost track of it.
    private func budBattery(_ label: String, _ level: Int, charging: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: level < 0 ? "battery.0" : (charging ? "bolt.fill" : batterySymbol(level)))
                .font(.system(size: 12))
                .foregroundColor(level < 0 ? Theme.secondary.opacity(0.5)
                                 : (level <= 20 && !charging ? .red.opacity(0.9) : Theme.accent))
            Text(level < 0 ? "\(label) --" : "\(label) \(level)%")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.secondary.opacity(level < 0 ? 0.5 : 1.0))
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

// MARK: - Menu bar

// Status-bar item for pinning playback to this Mac without opening the window. Installed once from
// AppDelegate; reads and drives the same HeadphonesModel as the window. The icon shows the playback device
// next to the headphones (phone, computer, or its multipoint slot number), and the headphones fill in
// while playback is fixed to this Mac.
@objc final class MenuBarController: NSObject, NSMenuDelegate {
    private static var instance: MenuBarController?

    private let model = HeadphonesModel.shared
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var cancellables = Set<AnyCancellable>()

    @objc static func install() {
        guard instance == nil else { return }
        instance = MenuBarController()
    }

    private override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
        // objectWillChange fires before the new values land, so read them on the next main-loop turn.
        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } }
            .store(in: &cancellables)
    }

    private var thisMac: PairedDeviceInfo? {
        model.pairedDevices.first { $0.isThisMac && $0.connected }
    }

    private var pinnedToThisMac: Bool {
        model.playbackPinned && thisMac?.playback == true
    }

    private var playbackDevice: PairedDeviceInfo? {
        model.connected ? model.pairedDevices.first { $0.playback } : nil
    }

    // Phone if the name says so, computer for this Mac (or another Mac), otherwise the slot number.
    private func playbackSymbol(for device: PairedDeviceInfo) -> String {
        let name = device.name.lowercased()
        if name.contains("phone") { return "iphone" }
        if device.isThisMac || name.contains("mac") { return "laptopcomputer" }
        return "\(device.slot).circle"
    }

    private func updateIcon() {
        let base = pinnedToThisMac ? "headphones.circle.fill" : "headphones"
        let device = playbackDevice
        statusItem.button?.image = Self.icon(base: base, accessory: device.map(playbackSymbol(for:)))
        statusItem.button?.appearsDisabled = !model.connected
        if let device = device {
            let name = device.name.isEmpty ? device.address : device.name
            statusItem.button?.toolTip = "Playing on \(name)" + (model.playbackPinned ? " (fixed)" : "")
        } else {
            statusItem.button?.toolTip = model.connected ? model.deviceName : "SonyBridge"
        }
    }

    // Draws the headphones symbol with an optional second symbol beside it, as one template image.
    private static func icon(base: String, accessory: String?) -> NSImage? {
        let baseConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let accessoryConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        guard let baseImage = NSImage(systemSymbolName: base, accessibilityDescription: "SonyBridge")?
            .withSymbolConfiguration(baseConfig) else { return nil }
        guard let accessory = accessory,
              let accessoryImage = NSImage(systemSymbolName: accessory, accessibilityDescription: nil)?
                .withSymbolConfiguration(accessoryConfig) else {
            baseImage.isTemplate = true
            return baseImage
        }
        let spacing: CGFloat = 2
        let size = NSSize(width: baseImage.size.width + spacing + accessoryImage.size.width,
                          height: max(baseImage.size.height, accessoryImage.size.height))
        let image = NSImage(size: size, flipped: false) { _ in
            baseImage.draw(in: NSRect(x: 0, y: (size.height - baseImage.size.height) / 2,
                                      width: baseImage.size.width, height: baseImage.size.height))
            accessoryImage.draw(in: NSRect(x: baseImage.size.width + spacing, y: (size.height - accessoryImage.size.height) / 2,
                                           width: accessoryImage.size.width, height: accessoryImage.size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SonyBridge"
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if model.connected {
            menu.addItem(disabledItem(model.deviceName))
            if model.hasPlaybackPinState {
                if thisMac != nil {
                    let pin = actionItem(pinnedToThisMac ? "Playback Fixed to This Mac" : "Pin Playback to This Mac",
                                         #selector(pinToThisMac))
                    pin.state = pinnedToThisMac ? .on : .off
                    pin.isEnabled = !pinnedToThisMac && !model.multipointBusy
                    menu.addItem(pin)
                } else {
                    menu.addItem(disabledItem("This Mac isn't a connected device"))
                }
                if model.playbackPinned {
                    let unfix = actionItem("Unfix Playback", #selector(unfixPlayback))
                    unfix.isEnabled = !model.multipointBusy
                    menu.addItem(unfix)
                }
            }
            if model.multipointBusy {
                menu.addItem(disabledItem("Sending…"))
            } else if let error = model.errorMessage {
                menu.addItem(disabledItem(error))
            }
            // Re-read so the next open reflects changes made from the phone or the headset.
            if !model.multipointBusy && !model.refreshingMultipoint {
                model.refreshMultipoint()
            }
        } else {
            menu.addItem(disabledItem("No headphones connected"))
            let connect = actionItem(model.connecting ? "Connecting…" : "Connect Headphones", #selector(connectHeadphones))
            connect.isEnabled = !model.connecting
            menu.addItem(connect)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Open SonyBridge", #selector(openWindow)))
        menu.addItem(actionItem("Quit SonyBridge", #selector(quit), key: "q"))
    }

    @objc private func pinToThisMac() {
        guard let thisMac = thisMac else { return }
        model.switchPlayback(to: thisMac, fix: true)
    }

    @objc private func unfixPlayback() {
        model.setPlaybackPinned(false)
    }

    @objc private func connectHeadphones() {
        NSApp.activate(ignoringOtherApps: true)
        model.connect()
    }

    @objc private func openWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.contentViewController != nil }?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

// Factory so the Obj-C++ ViewController can instantiate the SwiftUI hierarchy.
@available(macOS 11.0, *)
@objc final class HeadphonesUIFactory: NSObject {
    @objc static func makeViewController() -> NSViewController {
        return NSHostingController(rootView: ContentView())
    }
}
