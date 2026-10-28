//
//  ContentView.swift
//  Sony Sound Connect-style SwiftUI interface.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var model = HeadphonesModel.shared
    @State private var showAbout = false
    @AppStorage(AppTheme.storageKey) private var theme = AppTheme.refinedDark
    @Environment(\.colorScheme) private var colorScheme

    private var palette: Palette { theme.palette(colorScheme) }

    var body: some View {
        ZStack {
            if model.connected {
                connectedView
            } else {
                disconnectedView
            }
        }
        .frame(minWidth: 360, minHeight: 500)
        .background(palette.background)
        .environment(\.appTheme, theme)
        .onAppear { theme.applyToApp() }
        .onChange(of: theme) { $0.applyToApp() }
    }

    // MARK: - Disconnected

    private var disconnectedView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "headphones")
                .font(.system(size: 64, weight: .thin))
                .foregroundColor(palette.secondary)
            Text("No headphones connected")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(palette.secondary)
            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(palette.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            ConnectButton(model: model)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    // MARK: - Connected

    // Two independently scrolling columns once the window is wide enough, otherwise one. The pair is capped
    // and centered so cards don't stretch on a very wide window.
    private var connectedView: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 720 {
                HStack(alignment: .top, spacing: 0) {
                    column { primaryCards }
                        .frame(width: 380)
                    column(padding: [.vertical, .trailing]) { secondaryCards }
                        .frame(maxWidth: 580)
                }
                .frame(maxWidth: .infinity)
            } else {
                column {
                    primaryCards
                    secondaryCards
                }
            }
        }
    }

    private func column<Content: View>(padding edges: Edge.Set = .all,
                                       @ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16, content: content)
                .padding(edges, 20)
        }
    }

    @ViewBuilder
    private var primaryCards: some View {
        deviceHero
        ambientCard
        if model.mode == .ambientSound {
            ambientLevelCard
        }
    }

    @ViewBuilder
    private var secondaryCards: some View {
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
                .foregroundColor(palette.danger)
        }
    }

    private var deviceHero: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Spacer()
                Button(action: { showAbout = true }) {
                    roundIcon("ellipsis", size: 15)
                }
                .buttonStyle(PlainButtonStyle())
                .popover(isPresented: $showAbout, arrowEdge: .bottom) { aboutView }
                Button(action: model.disconnect) {
                    roundIcon("power", size: 14)
                }
                .buttonStyle(PlainButtonStyle())
            }

            // Product-style banner. Generic headphone graphic (device-specific Sony renders are
            // copyrighted and can't be bundled) over the theme's backdrop, mirroring Sony's app layout.
            ZStack {
                HeroBackdrop()
                ProductImage(deviceName: model.deviceName, size: 190)
            }

            Text(model.deviceName)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(palette.primary)

            StatusChips(model: model)
        }
        .padding(.bottom, 4)
    }

    private func roundIcon(_ symbol: String, size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(palette.secondary)
            .frame(width: 32, height: 32)
            .background(palette.raised, in: Circle())
            .overlay(Circle().strokeBorder(palette.cardStroke, lineWidth: 1))
    }

    private func cardTitle(_ title: String) -> some View {
        Text(theme.isSignature ? title.uppercased() : title)
            .font(.system(size: theme.isSignature ? 11 : 15, weight: .semibold))
            .tracking(theme.isSignature ? 1.2 : 0)
            .foregroundColor(theme.isSignature ? palette.secondary : palette.primary)
    }

    private var ambientCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardTitle("Ambient Sound Control")
            AmbientModeControl(model: model)
        }
        .themedCard()
    }

    private var ambientLevelCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Ambient Sound Level")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(palette.secondary)
                Spacer()
                Text("\(model.ambientLevel)")
                    .font(.system(size: 20, weight: .bold, design: theme.isSignature ? .monospaced : .rounded))
                    .foregroundColor(palette.accentText)
            }
            AmbientLevelSlider(model: model)

            if model.focusOnVoiceAvailable {
                FocusOnVoiceSwitch(model: model)
            }
        }
        .themedCard()
    }

    private let eqBandLabels = ["400", "1k", "2.5k", "6.3k", "16k"]
    private let tenBandEqLabels = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    private var equalizerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardTitle("Equalizer")
            EQPreview(bands: model.eqBands, range: model.tenBandEqualizer ? 0...12 : -10...10)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(EQPresets.list(tenBand: model.tenBandEqualizer), id: \.1) { preset in
                    eqChip(preset.0, preset.1)
                }
            }
            if model.eqPreset == 0xA0 {
                Divider().background(palette.cardStroke)
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
        .themedCard()
    }

    // raw: the ten-band layout's 0...12 device steps (no dB mapping is known yet), shown unsigned.
    private func eqBandRow(_ label: String, value: Binding<Double>, display: Int, accent: Bool = false, raw: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(accent ? palette.accentText : palette.secondary)
                .frame(width: 34, alignment: .leading)
            Slider(value: value, in: raw ? 0...12 : -10...10, step: 1).accentColor(palette.accent)
            Text(raw ? "\(display)" : "\(display > 0 ? "+" : "")\(display)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(palette.primary)
                .frame(width: 26, alignment: .trailing)
        }
    }

    private var dseeCard: some View {
        SwitchRow("DSEE", isOn: Binding(get: { model.dsee }, set: { model.setDsee($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DSEE").font(.system(size: 14, weight: .semibold)).foregroundColor(palette.primary)
                Text("Upscale compressed audio").font(.system(size: 11)).foregroundColor(palette.secondary)
            }
        }
        .themedCard()
    }

    private func eqChip(_ name: String, _ code: Int) -> some View {
        let selected = model.eqPreset == code
        return Button(action: { model.setEqualizer(code) }) {
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .selectable(selected, filledWhenIdle: true)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private let apoOptions = ["Off", "5 min", "30 min", "1 hour", "3 hours", "When taken off"]

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardTitle("Settings")
            if model.hasAdaptiveVolume {
                settingToggle("Adaptive Volume", "Auto-adjust volume by surroundings",
                              on: model.adaptiveVolume) { model.setAdaptiveVolume($0) }
            }
            if model.hasSpeakToChat {
                settingToggle("Speak-to-Chat", "Pause music when you talk",
                              on: model.speakToChat) { model.setSpeakToChat($0) }
                SwitchRow("Keep off on connect", isOn: $model.keepSpeakToChatOff) {
                    Text("Keep off on connect")
                        .font(.system(size: 11))
                        .foregroundColor(palette.secondary)
                }
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
                        Text("Auto Power-Off").font(.system(size: 14, weight: .semibold)).foregroundColor(palette.primary)
                        Text("Turn off when idle").font(.system(size: 11)).foregroundColor(palette.secondary)
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
                    .accentColor(palette.accent)
                }
            }
        }
        .themedCard()
    }

    private func settingToggle(_ title: String, _ subtitle: String, on: Bool, action: @escaping (Bool) -> Void) -> some View {
        SwitchRow(title, isOn: Binding(get: { on }, set: { action($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(palette.primary)
                Text(subtitle).font(.system(size: 11)).foregroundColor(palette.secondary)
            }
        }
    }

    // Multipoint device list. Read-only for now: nothing here sends a command that changes the headset.
    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                cardTitle("Devices")
                Spacer()
                if model.multipointLoading || model.refreshingMultipoint || model.multipointBusy {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                } else {
                    Button(action: model.refreshMultipoint) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(palette.secondary)
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
                        .foregroundColor(palette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
            if model.hasPlaybackPinState {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Playback device").font(.system(size: 13, weight: .medium)).foregroundColor(palette.primary)
                        Text(model.playbackPinned ? "Fixed" : "Switches automatically")
                            .font(.system(size: 11)).foregroundColor(palette.secondary)
                    }
                    Spacer()
                    CapsuleButton(model.playbackPinned ? "Unfix" : "Fix") {
                        model.setPlaybackPinned(!model.playbackPinned)
                    }
                    .disabled(model.multipointBusy)
                }
            }
            if model.hasPairedDevices {
                let connected = model.pairedDevices.filter { $0.connected }.sorted { $0.slot < $1.slot }
                let paired = model.pairedDevices.filter { !$0.connected }
                if !connected.isEmpty {
                    sectionLabel("Connected")
                    ForEach(connected) { deviceRow($0) }
                }
                if !paired.isEmpty {
                    sectionLabel("Paired")
                    ForEach(paired) { deviceRow($0) }
                }
            } else if !model.multipointLoading {
                Text("This headset didn't return a device list.")
                    .font(.system(size: 12))
                    .foregroundColor(palette.secondary)
            }
            if !model.multipointLoading {
                devicesFooter
            }
        }
        .themedCard()
    }

    private var devicesFooter: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider().background(palette.cardStroke)
            HStack {
                Text(model.multipointBusy ? "Sending…" : "Switching and fixing are experimental")
                    .font(.system(size: 11))
                    .foregroundColor(palette.secondary.opacity(0.7))
                Spacer()
                Button(action: copyMultipointDiagnostics) {
                    Text("Copy diagnostics")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(palette.accentText)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundColor(palette.secondary.opacity(0.8))
            .padding(.top, 2)
    }

    private func deviceRow(_ device: PairedDeviceInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: deviceSymbol(device.classOfDevice))
                .font(.system(size: 15))
                .foregroundColor(device.connected ? palette.primary : palette.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name.isEmpty ? device.address : device.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(device.connected ? palette.primary : palette.secondary)
                    .lineLimit(1)
                if device.isThisMac {
                    Text("This Mac").font(.system(size: 11)).foregroundColor(palette.accentText)
                }
            }
            Spacer()
            if device.playback {
                if model.playbackPinned {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundColor(palette.accent)
                }
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundColor(palette.accent)
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
                .foregroundColor(palette.primary)
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
            sectionLabel("Appearance")
                .padding(.top, 12)
                .padding(.bottom, 8)
            HStack(spacing: 6) {
                ForEach(AppTheme.allCases) { option in
                    themeOption(option)
                }
            }
            Divider().background(palette.cardStroke).padding(.vertical, 10)
            Text("SonyBridge · not affiliated with Sony")
                .font(.system(size: 10))
                .foregroundColor(palette.secondary.opacity(0.7))
        }
        .padding(18)
        .frame(width: 290)
        .background(palette.card)
    }

    private func themeOption(_ option: AppTheme) -> some View {
        let selected = option == theme
        return Button(action: { theme = option }) {
            VStack(spacing: 5) {
                ThemeSwatch(theme: option)
                Text(option.displayName)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(selected ? palette.primary : palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(5)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? palette.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func batteryText(_ level: Int, _ charging: Bool) -> String {
        guard level >= 0 else { return "—" }
        return "\(level)%\(charging ? " (charging)" : "")"
    }

    private func aboutRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundColor(palette.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium)).foregroundColor(palette.primary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Shared with the menu-bar panel

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

extension SHCAmbientMode {
    var displayName: String {
        switch self {
        case .noiseCanceling: return "Noise Canceling"
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
            if !model.codec.isEmpty {
                chip { chipText(model.codec) }
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

// Noise Canceling / Ambient / Off: segments in a recessed track, or separate pills in Sony Signature.
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

// Factory so the Obj-C++ ViewController can instantiate the SwiftUI hierarchy.
@objc final class HeadphonesUIFactory: NSObject {
    @objc static func makeViewController() -> NSViewController {
        return NSHostingController(rootView: ContentView())
    }
}
