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
    @Published var batteryLeftCharging = false
    @Published var batteryRightCharging = false
    @Published var batteryCaseCharging = false
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
    @Published var hasSoundQualityMode = false
    @Published var prioritizeSoundQuality = true
    @Published var deviceMac = ""
    @Published var protocolVersion = ""

    @Published var errorMessage: String?

    private var pollTimer: Timer?
    private var dynamicTimer: Timer?
    // Set when we issue a write that we know makes the device drop the link on purpose.
    private var expectingLinkReset = false

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
            self.syncBatteryFromBridge()
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
            self.hasSoundQualityMode = self.bridge.hasSoundQualityMode
            self.prioritizeSoundQuality = self.bridge.prioritizeSoundQuality
        }
    }

    private func syncBatteryFromBridge() {
        batteryLevel = bridge.batteryLevel
        batteryCharging = bridge.batteryCharging
        hasDualBattery = bridge.hasDualBattery
        batteryLeft = bridge.batteryLeft
        batteryRight = bridge.batteryRight
        batteryCase = bridge.batteryCase
        batteryLeftCharging = bridge.batteryLeftCharging
        batteryRightCharging = bridge.batteryRightCharging
        batteryCaseCharging = bridge.batteryCaseCharging
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

    func setPrioritizeSoundQuality(_ on: Bool) {
        prioritizeSoundQuality = on
        errorMessage = nil
        // The headphones re-negotiate the audio link for the new priority, which drops RFCOMM with it.
        // Arm the connection watcher so that shows up as an explanation rather than as a bare failure.
        expectingLinkReset = true
        bridge.setPrioritizeSoundQuality(on) { ok, error in
            if !ok {
                self.expectingLinkReset = false
                self.prioritizeSoundQuality = self.bridge.prioritizeSoundQuality
                if let error = error { self.errorMessage = error }
            }
        }
    }

    // Poll the button-changeable state so the app stays in sync when you use the headphone's own controls.
    private func startDynamicPolling() {
        stopDynamicPolling()
        dynamicTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.connected else { return }
            self.bridge.refreshDynamic {
                // Only publish what refreshDynamic actually re-read: ambient/NC state and the battery.
                // The EQ and DSEE values used to be assigned here too, but nothing re-reads them on this
                // path - they came straight back from the C++ cache, which is only updated once a write
                // succeeds. So a write that failed had its control snap back to the old value two
                // seconds later, and dragging an EQ slider fought this timer.
                self.mode = self.bridge.mode
                let level = self.bridge.ambientLevel
                if level > 0 { self.ambientLevel = level }
                self.syncBatteryFromBridge()
            }
        }
    }

    private func stopDynamicPolling() {
        dynamicTimer?.invalidate()
        dynamicTimer = nil
    }

    // The controls below update optimistically and are corrected here if the write failed, rather than
    // being silently overwritten by the next poll tick.
    func setEqualizer(_ preset: Int) {
        eqPreset = preset
        errorMessage = nil
        bridge.setEqualizerPreset(preset) { ok, error in
            if !ok {
                self.eqPreset = self.bridge.eqPreset
                if let error = error { self.errorMessage = error }
                return
            }
            // The bridge re-reads the EQ after the write, so this picks up the band values that belong to
            // the preset just selected - in particular the custom curve the device restores for Manual,
            // which is what the sliders below the chips show.
            self.eqPreset = self.bridge.eqPreset
            self.clearBass = self.bridge.clearBass
            self.eqBands = (0..<5).map { self.bridge.equalizerBand(at: $0) }
        }
    }

    // Manual EQ (preset byte 0xA0 = 160). Called as the user drags a band or clear-bass slider.
    func applyCustomEq() {
        eqPreset = 0xA0
        errorMessage = nil
        // Deliberately no roll-back here: this fires continuously while a slider is dragged, and yanking
        // the bands back mid-drag is the exact jumpiness we're fixing. The next drag event corrects it.
        bridge.setCustomEqualizerBass(clearBass, bands: eqBands.map { NSNumber(value: $0) }) { ok, error in
            if !ok, let error = error { self.errorMessage = error }
        }
    }

    func setDsee(_ on: Bool) {
        dsee = on
        errorMessage = nil
        bridge.setDsee(on) { ok, error in
            if !ok {
                self.dsee = self.bridge.dsee
                if let error = error { self.errorMessage = error }
            }
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
                self.errorMessage = self.expectingLinkReset
                    ? "Sound quality mode changed — the headphones reconnect on their own. Connect again in a few seconds."
                    : "Headphones disconnected."
                self.expectingLinkReset = false
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
            // Sync either way: on failure the bridge has rolled the pending change back, so this shows
            // what the headphones are actually set to instead of leaving the UI lying.
            self.syncFromBridge()
            if !ok, let error = error { self.errorMessage = error }
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
