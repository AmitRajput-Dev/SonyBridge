//
//  HeadphonesModel.swift
//  Observable view model wrapping the Obj-C++ HeadphonesBridge for SwiftUI.
//

import Foundation
import Combine

final class HeadphonesModel: ObservableObject {
    private let bridge = HeadphonesBridge()

    @Published var connected = false
    @Published var connecting = false
    @Published var deviceName = ""
    @Published var supportsVpt = false
    @Published var maxAmbientLevel = 20

    @Published var mode: SHCAmbientMode = .off
    @Published var ambientLevel = 10
    @Published var focusOnVoice = false
    @Published var focusOnVoiceAvailable = false

    @Published var batteryLevel = -1
    @Published var batteryCharging = false
    @Published var hasDualBattery = false
    @Published var batteryLeft = -1
    @Published var batteryRight = -1
    @Published var batteryCase = -1
    @Published var eqPreset = 0
    @Published var supportsEqualizer = false
    @Published var eqBands = [0, 0, 0, 0, 0]
    @Published var clearBass = 0
    @Published var dsee = false

    @Published var hasAutoPowerOff = false
    @Published var autoPowerOff = 0
    @Published var firmware = ""
    @Published var codec = ""
    @Published var hasSpeakToChat = false
    @Published var speakToChat = false
    @Published var hasAdaptiveVolume = false
    @Published var adaptiveVolume = false
    @Published var deviceMac = ""
    @Published var protocolVersion = ""

    @Published var errorMessage: String?

    private var pollTimer: Timer?
    private var dynamicTimer: Timer?

    func connect() {
        connecting = true
        errorMessage = nil
        // Defer so SwiftUI can render the "Connecting…" state before the modal picker blocks the main thread.
        DispatchQueue.main.async {
            self.bridge.scanAndConnect { ok, error in
                self.connecting = false
                if ok {
                    self.syncFromBridge()
                    self.startWatchingConnection()
                    self.refreshStatus()
                    self.startDynamicPolling()
                } else if let error = error {
                    self.errorMessage = error
                }
            }
        }
    }

    func refreshStatus() {
        bridge.refreshStatus {
            self.batteryLevel = self.bridge.batteryLevel
            self.batteryCharging = self.bridge.batteryCharging
            self.hasDualBattery = self.bridge.hasDualBattery
            self.batteryLeft = self.bridge.batteryLeft
            self.batteryRight = self.bridge.batteryRight
            self.batteryCase = self.bridge.batteryCase
            self.eqPreset = self.bridge.eqPreset
            self.clearBass = self.bridge.clearBass
            self.dsee = self.bridge.dsee
            self.eqBands = (0..<5).map { self.bridge.equalizerBand(at: $0) }
            self.hasAutoPowerOff = self.bridge.hasAutoPowerOff
            self.autoPowerOff = self.bridge.autoPowerOff
            self.firmware = self.bridge.firmware ?? ""
            self.codec = self.bridge.codec ?? ""
            self.hasSpeakToChat = self.bridge.hasSpeakToChat
            self.speakToChat = self.bridge.speakToChat
            self.hasAdaptiveVolume = self.bridge.hasAdaptiveVolume
            self.adaptiveVolume = self.bridge.adaptiveVolume
        }
    }

    func setAutoPowerOff(_ index: Int) {
        autoPowerOff = index
        errorMessage = nil
        bridge.setAutoPowerOff(index) { ok, error in if !ok, let e = error { self.errorMessage = e } }
    }

    func setSpeakToChat(_ on: Bool) {
        speakToChat = on
        errorMessage = nil
        bridge.setSpeakToChat(on) { ok, error in if !ok, let e = error { self.errorMessage = e } }
    }

    func setAdaptiveVolume(_ on: Bool) {
        adaptiveVolume = on
        errorMessage = nil
        bridge.setAdaptiveVolume(on) { ok, error in if !ok, let e = error { self.errorMessage = e } }
    }

    // Poll the button-changeable state so the app stays in sync when you use the headphone's own controls.
    private func startDynamicPolling() {
        stopDynamicPolling()
        dynamicTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.connected else { return }
            self.bridge.refreshDynamic {
                self.mode = self.bridge.mode
                let level = self.bridge.ambientLevel
                if level > 0 { self.ambientLevel = level }
                self.eqPreset = self.bridge.eqPreset
                self.clearBass = self.bridge.clearBass
                self.dsee = self.bridge.dsee
                self.eqBands = (0..<5).map { self.bridge.equalizerBand(at: $0) }
            }
        }
    }

    private func stopDynamicPolling() {
        dynamicTimer?.invalidate()
        dynamicTimer = nil
    }

    func setEqualizer(_ preset: Int) {
        eqPreset = preset
        errorMessage = nil
        bridge.setEqualizerPreset(preset) { ok, error in
            if !ok, let error = error { self.errorMessage = error }
        }
    }

    // Manual EQ (preset byte 0xA0 = 160). Called as the user drags a band or clear-bass slider.
    func applyCustomEq() {
        eqPreset = 0xA0
        errorMessage = nil
        bridge.setCustomEqualizerBass(clearBass, bands: eqBands.map { NSNumber(value: $0) }) { ok, error in
            if !ok, let error = error { self.errorMessage = error }
        }
    }

    func setDsee(_ on: Bool) {
        dsee = on
        errorMessage = nil
        bridge.setDsee(on) { ok, error in
            if !ok, let error = error { self.errorMessage = error }
        }
    }

    func disconnect() {
        stopWatchingConnection()
        stopDynamicPolling()
        bridge.disconnect()
        connected = false
        deviceName = ""
    }

    // The headset can drop the RFCOMM link on its own (idle power-save). Poll so the UI reflects reality
    // instead of showing a stale "Connected" state.
    private func startWatchingConnection() {
        stopWatchingConnection()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.connected && !self.bridge.connected {
                self.connected = false
                self.deviceName = ""
                self.errorMessage = "Headphones disconnected."
                self.stopWatchingConnection()
                self.stopDynamicPolling()
            }
        }
    }

    private func stopWatchingConnection() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func setMode(_ newMode: SHCAmbientMode) {
        mode = newMode
        pushState()
    }

    func setLevel(_ level: Int) {
        ambientLevel = level
        if mode == .ambientSound { pushState() }
    }

    func setFocusOnVoice(_ on: Bool) {
        focusOnVoice = on
        pushState()
    }

    private func pushState() {
        errorMessage = nil
        bridge.applyMode(mode, level: ambientLevel, focusVoice: focusOnVoice) { ok, error in
            if ok {
                self.syncFromBridge()
            } else if let error = error {
                self.errorMessage = error
            }
        }
    }

    private func syncFromBridge() {
        connected = bridge.connected
        deviceName = bridge.deviceName ?? ""
        deviceMac = bridge.deviceMac ?? ""
        protocolVersion = bridge.protocolVersionString ?? ""
        supportsVpt = bridge.supportsVpt
        supportsEqualizer = bridge.supportsEqualizer
        maxAmbientLevel = bridge.maxAmbientLevel
        mode = bridge.mode
        let level = bridge.ambientLevel
        if level > 0 { ambientLevel = level }
        focusOnVoice = bridge.focusOnVoice
        focusOnVoiceAvailable = bridge.focusOnVoiceAvailable
    }
}
