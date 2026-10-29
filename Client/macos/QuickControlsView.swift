//
//  QuickControlsView.swift
//  The menu-bar panel, which is the whole app: everyday controls up top, everything else behind the
//  footer arrow.
//

import SwiftUI
import AppKit

struct QuickControlsView: View {
    let quit: () -> Void

    @ObservedObject private var model = HeadphonesModel.shared
    @AppStorage(AppTheme.storageKey) private var theme = AppTheme.refinedDark
    @AppStorage("quickControlsMoreExpanded") private var moreExpanded = false
    // The multipoint value waiting for Restart/Cancel (nil when nothing is pending).
    @State private var pendingMultipoint: Bool?
    @Environment(\.colorScheme) private var colorScheme

    private var palette: Palette { theme.palette(colorScheme) }

    private let eqBandLabels = ["400", "1k", "2.5k", "6.3k", "16k"]
    private let tenBandEqLabels = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    // At 320pt "Noise Cancelling" fits within the mode control's minimum scale. The height follows the
    // content, scrolling once it would run off the screen.
    var body: some View {
        VStack(spacing: 6) {
            CappedScrollView(maxHeight: maxContentHeight) {
                VStack(alignment: .leading, spacing: 14) {
                    if model.connected {
                        connectedContent
                    } else {
                        disconnectedContent
                    }
                    if moreExpanded {
                        moreContent
                    }
                }
                .padding([.horizontal, .top], 14)
            }
            footer
        }
        .frame(width: 320)
        .background(palette.background)
        .environment(\.appTheme, theme)
        .onChange(of: theme) { $0.applyToApp() }
    }

    private var maxContentHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 80
    }

    // MARK: - Main controls

    private var disconnectedContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "headphones")
                .font(.system(size: 34, weight: .thin))
                .foregroundColor(palette.secondary)
            Text("No headphones connected")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(palette.secondary)
            errorText
            ConnectButton(model: model)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var connectedContent: some View {
        HStack(spacing: 12) {
            ProductImage(deviceName: model.deviceName, size: 56)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.deviceName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(palette.primary)
                    .lineLimit(1)
                StatusChips(model: model, showsMode: false)
            }
            Spacer(minLength: 0)
            Button(action: model.disconnect) {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(palette.secondary)
                    .frame(width: 26, height: 26)
                    .background(palette.raised, in: Circle())
                    .overlay(Circle().strokeBorder(palette.cardStroke, lineWidth: 1))
            }
            .buttonStyle(PlainButtonStyle())
            .help("Disconnect")
        }

        AmbientModeControl(model: model)

        if model.mode == .ambientSound {
            HStack(spacing: 10) {
                Text("Level")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(palette.secondary)
                AmbientLevelSlider(model: model)
                Text("\(model.ambientLevel)")
                    .font(.system(size: 12, weight: .semibold, design: theme.isSignature ? .monospaced : .rounded))
                    .foregroundColor(palette.accentText)
                    .frame(width: 22, alignment: .trailing)
            }
            if model.focusOnVoiceAvailable {
                FocusOnVoiceSwitch(model: model)
            }
        }

        if model.supportsEqualizer {
            equalizerCard
        }

        if model.hasPlaybackPinState {
            playbackRow
                .themedCard(compact: true)
        }

        errorText
    }

    // The graph shows the active preset's curve. Editing it (or Clear Bass) switches to Manual, starting
    // from that curve, the way Sony's app does.
    private var equalizerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Equalizer")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(palette.primary)
                Spacer()
                if model.eqPreset == 0xA0 && !model.tenBandEqualizer {
                    CapsuleButton("Flat") {
                        model.eqBands = model.eqBands.map { _ in 0 }
                        model.clearBass = 0
                        model.applyCustomEq()
                    }
                }
                Picker("Equalizer", selection: Binding(
                    get: { model.eqPreset },
                    set: { model.setEqualizer($0) }
                )) {
                    ForEach(EQPresets.list(tenBand: model.tenBandEqualizer), id: \.1) { preset in
                        Text(preset.0).tag(preset.1)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .labelsHidden()
                .fixedSize()
                .accentColor(palette.accent)
            }
            // The ten-band layout's 0...12 device steps have no known dB mapping yet, so they're shown raw.
            EQEditor(bands: model.eqBands,
                     labels: model.tenBandEqualizer ? tenBandEqLabels : eqBandLabels,
                     range: model.tenBandEqualizer ? 0...12 : -10...10,
                     signed: !model.tenBandEqualizer,
                     plotHeight: 110) { band, value in
                model.eqBands[band] = value
                model.applyCustomEq()
            }
            if !model.tenBandEqualizer {
                clearBassRow
            }
        }
        .themedCard(compact: true)
    }

    private var clearBassRow: some View {
        HStack(spacing: 10) {
            Text("Clear Bass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(palette.accentText)
                .fixedSize()
            Slider(value: Binding(
                get: { Double(model.clearBass) },
                set: {
                    let value = Int($0.rounded())
                    guard value != model.clearBass else { return }
                    model.clearBass = value
                    model.applyCustomEq()
                }
            ), in: -10...10, step: 1)
            .accentColor(palette.accent)
            Text(model.clearBass > 0 ? "+\(model.clearBass)" : "\(model.clearBass)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(palette.primary)
                .frame(width: 26, alignment: .trailing)
        }
    }

    private var playbackRow: some View {
        let canPin = model.thisMac != nil && !model.playbackPinnedToThisMac
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundColor(palette.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.playbackPinned ? "Playback fixed to" : "Playing on")
                        .font(.system(size: 11))
                        .foregroundColor(palette.secondary)
                    Text(model.playbackDevice.map { $0.name.isEmpty ? $0.address : $0.name } ?? "No playback device")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(palette.primary)
                        .lineLimit(1)
                }
            }
            if canPin || model.playbackPinned {
                HStack(spacing: 8) {
                    if canPin {
                        CapsuleButton("Pin to this Mac", action: model.pinPlaybackToThisMac)
                    }
                    if model.playbackPinned {
                        CapsuleButton("Unfix") { model.setPlaybackPinned(false) }
                    }
                }
                .disabled(model.multipointBusy)
            }
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let error = model.errorMessage {
            Text(error)
                .font(.system(size: 11))
                .foregroundColor(palette.danger)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Behind the footer arrow

    @ViewBuilder
    private var moreContent: some View {
        if model.connected {
            if model.supportsDsee || model.hasAdaptiveVolume || model.hasSpeakToChat
                || model.hasMultipointSetting || model.hasTouchPanelSetting || model.hasAutoPowerOff {
                settingsCard
            }
            if model.multipointLoading || model.hasPairedDevices {
                devicesCard
            }
        }
        appearanceCard
        if model.connected {
            deviceInfo
        }
        Button(action: quit) {
            Text("Quit SonyBridge")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(palette.secondary)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.supportsDsee {
                settingToggle("DSEE", "Upscale compressed audio", on: model.dsee) { model.setDsee($0) }
            }
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
                // Applying it restarts the headset, so flipping the switch only asks; Restart sends it.
                settingToggle("Connect to 2 devices", "Restarts the headphones to apply",
                              on: pendingMultipoint ?? model.multipointEnabled) {
                    pendingMultipoint = $0 == model.multipointEnabled ? nil : $0
                }
                if let target = pendingMultipoint {
                    multipointConfirmation(target)
                }
            }
            if model.hasTouchPanelSetting {
                settingToggle("Touch Controls", "Swipe and tap on the earcup",
                              on: model.touchPanelEnabled) { model.setTouchPanel($0) }
            }
            if model.hasAutoPowerOff {
                HStack {
                    Text("Auto Power-Off")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(palette.primary)
                    Spacer()
                    Picker("Auto Power-Off", selection: Binding(
                        get: { model.autoPowerOff },
                        set: { model.setAutoPowerOff($0) }
                    )) {
                        ForEach(0..<AutoPowerOff.options.count, id: \.self) { i in
                            Text(AutoPowerOff.options[i]).tag(i)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .labelsHidden()
                    .fixedSize()
                    .accentColor(palette.accent)
                }
            }
        }
        .themedCard(compact: true)
    }

    private func multipointConfirmation(_ target: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(model.deviceName) will restart\(target ? "" : " and disconnect your other device").")
                .font(.system(size: 11))
                .foregroundColor(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                CapsuleButton("Cancel") { pendingMultipoint = nil }
                CapsuleButton("Restart") {
                    pendingMultipoint = nil
                    model.setMultipoint(target)
                }
            }
        }
        .padding(10)
        .background(palette.track, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func settingToggle(_ title: String, _ subtitle: String, on: Bool, action: @escaping (Bool) -> Void) -> some View {
        SwitchRow(title, isOn: Binding(get: { on }, set: { action($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(palette.primary)
                Text(subtitle).font(.system(size: 11)).foregroundColor(palette.secondary)
            }
        }
    }

    // Multipoint device list. Switching playback is experimental, hence the diagnostics link.
    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Devices")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(palette.primary)
                Spacer()
                if model.multipointLoading || model.refreshingMultipoint || model.multipointBusy {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                } else {
                    Button(action: model.refreshMultipoint) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(palette.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Refresh")
                }
            }
            if model.multipointLoading {
                Text("Reading devices from the headset…")
                    .font(.system(size: 11))
                    .foregroundColor(palette.secondary)
            } else {
                let connected = model.pairedDevices.filter { $0.connected }.sorted { $0.slot < $1.slot }
                let paired = model.pairedDevices.filter { !$0.connected }
                ForEach(connected) { deviceRow($0) }
                ForEach(paired) { deviceRow($0) }
                HStack {
                    Text(model.multipointBusy ? "Sending…" : "Switching is experimental")
                        .font(.system(size: 10))
                        .foregroundColor(palette.secondary.opacity(0.7))
                    Spacer()
                    Button(action: copyMultipointDiagnostics) {
                        Text("Copy diagnostics")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(palette.accentText)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .themedCard(compact: true)
    }

    private func deviceRow(_ device: PairedDeviceInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: deviceSymbol(device.classOfDevice))
                .font(.system(size: 13))
                .foregroundColor(device.connected ? palette.primary : palette.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name.isEmpty ? device.address : device.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(device.connected ? palette.primary : palette.secondary)
                    .lineLimit(1)
                if device.isThisMac {
                    Text("This Mac").font(.system(size: 10)).foregroundColor(palette.accentText)
                }
            }
            Spacer()
            if device.playback {
                if model.playbackPinned {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundColor(palette.accent)
                }
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))
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

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Appearance")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(palette.primary)
            HStack(spacing: 6) {
                ForEach(AppTheme.allCases) { option in
                    themeOption(option)
                }
            }
        }
        .themedCard(compact: true)
    }

    private func themeOption(_ option: AppTheme) -> some View {
        let selected = option == theme
        return Button(action: { theme = option }) {
            VStack(spacing: 4) {
                ThemeSwatch(theme: option)
                Text(option.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(selected ? palette.primary : palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? palette.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var deviceInfo: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.hasDualBattery {
                infoRow("Battery L", batteryText(model.batteryLeft, model.batteryLeftCharging))
                infoRow("Battery R", batteryText(model.batteryRight, model.batteryRightCharging))
                if model.batteryCase >= 0 {
                    infoRow("Case", batteryText(model.batteryCase, model.batteryCaseCharging))
                }
            }
            if !model.firmware.isEmpty { infoRow("Firmware", model.firmware) }
            if !model.protocolVersion.isEmpty { infoRow("Protocol", model.protocolVersion) }
            if !model.deviceMac.isEmpty { infoRow("Bluetooth", model.deviceMac) }
            Text("SonyBridge · not affiliated with Sony")
                .font(.system(size: 10))
                .foregroundColor(palette.secondary.opacity(0.7))
                .padding(.top, 6)
        }
        .padding(.horizontal, 4)
    }

    private func batteryText(_ level: Int, _ charging: Bool) -> String {
        guard level >= 0 else { return "—" }
        return "\(level)%\(charging ? " (charging)" : "")"
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(palette.secondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium)).foregroundColor(palette.primary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Footer

    // Just the arrow that shows or hides everything above it; open/closed is remembered.
    private var footer: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { moreExpanded.toggle() } }) {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(palette.secondary)
                .rotationEffect(.degrees(moreExpanded ? 180 : 0))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .help(moreExpanded ? "Fewer settings" : "More settings")
        .accessibilityLabel(moreExpanded ? "Fewer settings" : "More settings")
        .padding(.bottom, 4)
    }
}

// Exactly as tall as its content until that passes maxHeight, then scrolls, so the popover still sizes
// to fit. (A bare ScrollView would take all the height it's offered.)
private struct CappedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(showsIndicators: false) {
            content.background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            })
        }
        .frame(height: min(contentHeight, maxHeight))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
