//
//  HeadphonesModel.swift
//  Observable view model wrapping the Obj-C++ HeadphonesBridge for SwiftUI.
//

import Foundation
import Combine

private let keepSpeakToChatOffKey = "KeepSpeakToChatOffOnConnect"

struct PairedDeviceInfo: Identifiable, Equatable {
    let name: String
    let address: String
    let slot: Int              // 0 = paired only, 1/2 = connected
    let classOfDevice: Int     // -1 if not reported
    let playback: Bool
    let isThisMac: Bool

    var id: String { address }
    var connected: Bool { slot != 0 }
}

final class HeadphonesModel: ObservableObject {
    // One connection per app: the window and the menu-bar item drive the same model.
    static let shared = HeadphonesModel()

    private let bridge = HeadphonesBridge()

    @Published var connected = false
    @Published var connecting = false
    // A paired Sony headset is connected to the Mac (audio), whether or not this app's control link is up.
    @Published var headsetConnectedToMac = false
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
    @Published var tenBandEqualizer = false
    @Published var clearBass = 0
    @Published var supportsDsee = false
    @Published var dsee = false

    @Published var hasAutoPowerOff = false
    @Published var autoPowerOff = 0
    @Published var firmware = ""
    @Published var codec = ""
    @Published var hasSpeakToChat = false
    @Published var speakToChat = false
    // Force Speak-to-Chat off each time we connect (it pauses audio whenever it hears
    // speech, which is hostile to dictation). Flipping this takes effect next connect.
    @Published var keepSpeakToChatOff = UserDefaults.standard.object(forKey: keepSpeakToChatOffKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepSpeakToChatOff, forKey: keepSpeakToChatOffKey) }
    }
    @Published var hasAdaptiveVolume = false
    @Published var adaptiveVolume = false
    @Published var deviceMac = ""
    @Published var protocolVersion = ""

    @Published var hasPairedDevices = false
    @Published var pairedDevices: [PairedDeviceInfo] = []
    @Published var hasPlaybackPinState = false
    @Published var playbackPinned = false
    // Multipoint ("Connect to 2 devices"). Device-persistent - no app-enforced default; the
    // toggle just mirrors the on-device state.
    @Published var hasMultipointSetting = false
    @Published var multipointEnabled = false
    @Published var hasTouchPanelSetting = false
    @Published var touchPanelEnabled = false
    @Published var multipointDiagnostics = ""
    @Published var refreshingMultipoint = false
    @Published var multipointBusy = false

    // True from connect until the first multipoint read has finished. Those reads run after the
    // capability probes, so on a v2 headset this can take several seconds.
    var multipointLoading: Bool {
        connected && protocolVersion == "v2" && multipointDiagnostics.isEmpty
    }

    @Published var errorMessage: String?

    private var pollTimer: Timer?
    private var dynamicTimer: Timer?

    // Slider-drag coalescing (mirrors the ImGui in-flight gate in CrossPlatformGUI).
    // While an exchange is in flight, only the latest value is remembered; when the
    // exchange completes, at most one more send fires with that latest value. All
    // state is main-thread-confined (bridge completions arrive on the main queue).
    private var pushInFlight = false
    private var pendingPush: (mode: SHCAmbientMode, level: Int, focusVoice: Bool)?
    private var eqInFlight = false
    private var pendingEq: (bass: Int, bands: [Int])?

    // Armed on each successful connect; consumed once Speak-to-Chat capability is
    // confirmed, so the off-on-connect enforcement fires at most once per connection.
    private var s2cAutoDisablePending = false

    // Set while a multipoint change may restart the headset: a link drop before it then reconnects.
    private var restartReconnectDeadline: Date?

    // Set by a manual disconnect so auto-connect leaves the headset alone until it next connects to the Mac.
    private var autoConnectSuppressed = false
    private var headsetTimer: Timer?

    // Connects on launch and whenever a Sony headset connects to the Mac, never through the device picker.
    // An idle link drop (headset still connected to the Mac) isn't retried: nothing new connected.
    func startAutoConnect() {
        headsetConnectedToMac = bridge.hasConnectedSonyHeadset
        // macOS notifies connects but not disconnects, so poll for the Mac-level connection (cheap: paired
        // devices plus cached SDP records). The menu-bar icon hides on it.
        headsetTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.assignIfChanged(\.headsetConnectedToMac, self.bridge.hasConnectedSonyHeadset)
        }
        bridge.watchForHeadsetConnections { [weak self] in
            guard let self = self else { return }
            self.headsetConnectedToMac = true
            self.autoConnectSuppressed = false
            // The headset's control service isn't ready the moment the Mac sees it connect.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.autoConnectIfIdle() }
        }
        autoConnectIfIdle()
    }

    private func autoConnectIfIdle() {
        guard !connected, !connecting, !autoConnectSuppressed, bridge.hasConnectedSonyHeadset else { return }
        connect()
    }

    func connect() {
        connecting = true
        errorMessage = nil
        // Defer so SwiftUI can render the "Connecting…" state before the modal picker blocks the main thread.
        DispatchQueue.main.async {
            self.bridge.scanAndConnect { ok, error in
                self.connecting = false
                if ok {
                    self.restartReconnectDeadline = nil
                    self.s2cAutoDisablePending = true
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
            self.supportsEqualizer = self.bridge.supportsEqualizer
            self.clearBass = self.bridge.clearBass
            self.supportsDsee = self.bridge.supportsDsee
            self.dsee = self.bridge.dsee
            self.tenBandEqualizer = self.bridge.tenBandEqualizer
            self.eqBands = self.readEqBands()
            self.hasAutoPowerOff = self.bridge.hasAutoPowerOff
            self.autoPowerOff = self.bridge.autoPowerOff
            self.firmware = self.bridge.firmware ?? ""
            self.codec = self.bridge.codec ?? ""
            self.hasSpeakToChat = self.bridge.hasSpeakToChat
            self.speakToChat = self.bridge.speakToChat
            self.hasAdaptiveVolume = self.bridge.hasAdaptiveVolume
            self.adaptiveVolume = self.bridge.adaptiveVolume
            self.syncMultipointFromBridge()
            // Speak-to-Chat capability is only confirmed by the probeCapabilities pass
            // (the second completion), so this stays armed until then and fires at most
            // once per connect. The device stays untouched unless it reports S2C on.
            if self.s2cAutoDisablePending && self.hasSpeakToChat {
                self.s2cAutoDisablePending = false
                if self.keepSpeakToChatOff && self.speakToChat {
                    self.setSpeakToChat(false)
                }
            }
        }
    }

    func refreshMultipoint() {
        refreshingMultipoint = true
        bridge.refreshMultipoint {
            self.refreshingMultipoint = false
            self.syncMultipointFromBridge()
        }
    }

    func switchPlayback(to device: PairedDeviceInfo, fix: Bool) {
        multipointBusy = true
        errorMessage = nil
        bridge.switchPlayback(toAddress: device.address, fix: fix) { ok, error in
            self.multipointBusy = false
            if !ok, let error = error { self.errorMessage = error }
            self.syncMultipointFromBridge()
        }
    }

    func setPlaybackPinned(_ pinned: Bool) {
        multipointBusy = true
        errorMessage = nil
        bridge.setPlaybackPinned(pinned) { ok, error in
            self.multipointBusy = false
            if !ok, let error = error { self.errorMessage = error }
            self.syncMultipointFromBridge()
        }
    }

    private func syncMultipointFromBridge() {
        hasPairedDevices = bridge.hasPairedDevices
        pairedDevices = bridge.pairedDevices.map {
            PairedDeviceInfo(name: $0.name, address: $0.address, slot: $0.slot,
                             classOfDevice: $0.classOfDevice, playback: $0.playback, isThisMac: $0.isThisMac)
        }
        hasPlaybackPinState = bridge.hasPlaybackPinState
        playbackPinned = bridge.playbackPinned
        hasMultipointSetting = bridge.hasMultipointSetting
        multipointEnabled = bridge.multipointEnabled
        hasTouchPanelSetting = bridge.hasTouchPanelSetting
        touchPanelEnabled = bridge.touchPanelEnabled
        multipointDiagnostics = bridge.multipointDiagnostics
    }

    private func readEqBands() -> [Int] {
        (0..<bridge.equalizerBandCount).map { bridge.equalizerBand(at: $0) }
    }

    private func syncBatteryFromBridge() {
        assignIfChanged(\.batteryLevel, bridge.batteryLevel)
        assignIfChanged(\.batteryCharging, bridge.batteryCharging)
        assignIfChanged(\.hasDualBattery, bridge.hasDualBattery)
        assignIfChanged(\.batteryLeft, bridge.batteryLeft)
        assignIfChanged(\.batteryRight, bridge.batteryRight)
        assignIfChanged(\.batteryCase, bridge.batteryCase)
        assignIfChanged(\.batteryLeftCharging, bridge.batteryLeftCharging)
        assignIfChanged(\.batteryRightCharging, bridge.batteryRightCharging)
        assignIfChanged(\.batteryCaseCharging, bridge.batteryCaseCharging)
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

    func setMultipoint(_ on: Bool) {
        multipointEnabled = on
        errorMessage = nil
        // Applying it restarts the headset (XM4 at least), which drops this link; reconnect once it's back.
        restartReconnectDeadline = Date().addingTimeInterval(90)
        bridge.setMultipoint(on) { ok, error in
            if !ok {
                self.restartReconnectDeadline = nil
                // Show what the headset actually kept rather than the value just requested.
                self.multipointEnabled = self.bridge.multipointEnabled
                if let e = error { self.errorMessage = e }
            }
        }
    }

    func setTouchPanel(_ on: Bool) {
        touchPanelEnabled = on
        errorMessage = nil
        bridge.setTouchPanel(on) { ok, error in if !ok, let e = error { self.errorMessage = e } }
    }

    // Retries connect() every few seconds while a headset restart (after a multipoint change) is expected.
    private func reconnectAfterRestart() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self = self, !self.connected, let deadline = self.restartReconnectDeadline else { return }
            guard Date() < deadline else {
                self.restartReconnectDeadline = nil
                self.errorMessage = "Headphones didn't come back after restarting. Connect them again."
                return
            }
            if !self.connecting { self.connect() }
            self.reconnectAfterRestart()
        }
    }

    // Every @Published setter fires objectWillChange — and a full ContentView body
    // re-evaluation — even when the value is unchanged. The 2s poll mostly re-reads
    // cached bridge values, so gate writes to real changes.
    private func assignIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<HeadphonesModel, T>, _ newValue: T) {
        if self[keyPath: keyPath] != newValue {
            self[keyPath: keyPath] = newValue
        }
    }

    // Poll the button-changeable state so the app stays in sync when you use the headphone's own controls.
    private func startDynamicPolling() {
        stopDynamicPolling()
        var tick = 0
        dynamicTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.connected else { return }
            // Every 5th tick (10 s), also re-read which device has playback, so the menu-bar icon follows
            // changes made from the phone. Skipped while a multipoint write or refresh is in flight.
            tick += 1
            if tick % 5 == 0 && self.hasPairedDevices && !self.multipointBusy && !self.refreshingMultipoint {
                self.bridge.refreshMultipoint { self.syncMultipointFromBridge() }
            }
            self.bridge.refreshDynamic {
                // Only publish what refreshDynamic actually re-read: ambient/NC state and the battery.
                // EQ and DSEE aren't re-read on this path - they'd come straight back from the C++ cache,
                // so a failed write would snap back two seconds later and an EQ drag would fight the timer.
                self.assignIfChanged(\.mode, self.bridge.mode)
                let level = self.bridge.ambientLevel
                if level > 0 { self.assignIfChanged(\.ambientLevel, level) }
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
        if preset == 0xA0 {
            applyCustomEq()
            return
        }
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
            self.eqBands = self.readEqBands()
        }
    }

    // Manual EQ (preset byte 0xA0 = 160). Called as the user drags a band or clear-bass slider.
    func applyCustomEq() {
        eqPreset = 0xA0
        errorMessage = nil
        if eqInFlight {
            pendingEq = (clearBass, eqBands)
            return
        }
        sendCustomEq((clearBass, eqBands))
    }

    private func sendCustomEq(_ sent: (bass: Int, bands: [Int])) {
        eqInFlight = true
        bridge.setCustomEqualizerBass(sent.bass, bands: sent.bands.map { NSNumber(value: $0) }) { ok, error in
            self.eqInFlight = false
            if let pending = self.pendingEq {
                self.pendingEq = nil
                if pending != sent {
                    self.sendCustomEq(pending)
                    return
                }
            }
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
        pendingPush = nil
        pendingEq = nil
        s2cAutoDisablePending = false
        restartReconnectDeadline = nil
        autoConnectSuppressed = true
        bridge.disconnect()
        connected = false
        deviceName = ""
        syncMultipointFromBridge()
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
                // Release the dead session too, so a reconnect starts clean and the device list doesn't
                // linger with Fix/Switch enabled.
                self.bridge.disconnect()
                self.syncMultipointFromBridge()
                if let deadline = self.restartReconnectDeadline, Date() < deadline {
                    self.errorMessage = "Headphones restarting…"
                    self.reconnectAfterRestart()
                }
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
        if pushInFlight {
            pendingPush = (mode, ambientLevel, focusOnVoice)
            return
        }
        sendPush((mode, ambientLevel, focusOnVoice))
    }

    private func sendPush(_ sent: (mode: SHCAmbientMode, level: Int, focusVoice: Bool)) {
        pushInFlight = true
        bridge.applyMode(sent.mode, level: sent.level, focusVoice: sent.focusVoice) { ok, error in
            self.pushInFlight = false
            if let pending = self.pendingPush {
                self.pendingPush = nil
                if pending != sent {
                    self.sendPush(pending)
                    return
                }
            }
            // Sync either way: on failure the bridge has rolled the pending change back, so this shows
            // what the headphones are actually set to instead of leaving the UI lying.
            self.syncFromBridge()
            if !ok, let error = error { self.errorMessage = error }
        }
    }

    private func syncFromBridge() {
        assignIfChanged(\.connected, bridge.connected)
        assignIfChanged(\.deviceName, bridge.deviceName ?? "")
        assignIfChanged(\.deviceMac, bridge.deviceMac ?? "")
        assignIfChanged(\.protocolVersion, bridge.protocolVersionString ?? "")
        assignIfChanged(\.supportsVpt, bridge.supportsVpt)
        assignIfChanged(\.supportsEqualizer, bridge.supportsEqualizer)
        assignIfChanged(\.supportsDsee, bridge.supportsDsee)
        assignIfChanged(\.maxAmbientLevel, bridge.maxAmbientLevel)
        assignIfChanged(\.mode, bridge.mode)
        let level = bridge.ambientLevel
        if level > 0 { assignIfChanged(\.ambientLevel, level) }
        assignIfChanged(\.focusOnVoice, bridge.focusOnVoice)
        assignIfChanged(\.focusOnVoiceAvailable, bridge.focusOnVoiceAvailable)
    }
}

// Playback-pin shortcuts shared by the menu-bar menu and the quick-controls panel.
extension HeadphonesModel {
    var thisMac: PairedDeviceInfo? {
        pairedDevices.first { $0.isThisMac && $0.connected }
    }

    var playbackPinnedToThisMac: Bool {
        playbackPinned && thisMac?.playback == true
    }

    var playbackDevice: PairedDeviceInfo? {
        connected ? pairedDevices.first { $0.playback } : nil
    }

    func pinPlaybackToThisMac() {
        if let thisMac = thisMac { switchPlayback(to: thisMac, fix: true) }
    }
}
