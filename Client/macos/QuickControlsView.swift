//
//  QuickControlsView.swift
//  The menu-bar panel: the everyday controls without opening the window.
//

import SwiftUI

struct QuickControlsView: View {
    let openWindow: () -> Void
    let quit: () -> Void

    @ObservedObject private var model = HeadphonesModel.shared
    @AppStorage(AppTheme.storageKey) private var theme = AppTheme.refinedDark
    @Environment(\.colorScheme) private var colorScheme

    private var palette: Palette { theme.palette(colorScheme) }

    // 320pt gives each mode segment a little more room than the window's at its 360pt minimum, so
    // "Noise Canceling" fits within the mode control's minimum scale. The height follows the content.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.connected {
                connectedContent
            } else {
                disconnectedContent
            }
            Divider().background(palette.cardStroke)
            footer
        }
        .padding(14)
        .frame(width: 320)
        .background(palette.background)
        .environment(\.appTheme, theme)
    }

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

        if model.supportsEqualizer || model.hasPlaybackPinState {
            VStack(alignment: .leading, spacing: 12) {
                if model.supportsEqualizer {
                    equalizerRow
                }
                if model.supportsEqualizer && model.hasPlaybackPinState {
                    Divider().background(palette.cardStroke)
                }
                if model.hasPlaybackPinState {
                    playbackRow
                }
            }
            .themedCard(compact: true)
        }

        errorText
    }

    private var equalizerRow: some View {
        HStack {
            Text("Equalizer")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(palette.primary)
            Spacer()
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
            .frame(width: 120)
            .accentColor(palette.accent)
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

    private var footer: some View {
        HStack {
            Button(action: openWindow) {
                Text("Open SonyBridge")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(palette.accentText)
            }
            Spacer()
            Button(action: quit) {
                Text("Quit")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(palette.secondary)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}
