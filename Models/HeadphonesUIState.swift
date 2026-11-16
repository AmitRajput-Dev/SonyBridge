import Bridge
import Client
import Either
import Foundation

// MARK: - HeadphonesUIState

/// The domain layer's single source of truth for everything the UI renders.
///
/// Device-derived fields mirror the library's ``SonyHeadphones`` snapshots: they are
/// written only through ``init(_:)`` / ``apply(_:)`` when the client returns a new
/// snapshot, or optimistically by the reducers for the few commands the UI changes
/// before the device confirms (mode, ambient level, EQ bands, clear bass).
///
/// Transient flags (connecting, in-flight writes, last error) belong to the app and
/// are never touched by a snapshot.
public struct HeadphonesUIState: Sendable, Equatable {
    // MARK: Transient UI flags

    /// True while a connection attempt is in flight (drives the "Connecting…" UI).
    public var connecting: Bool

    /// True while a focus-on-voice change is in flight.
    ///
    /// The toggle stays disabled and keeps its previous value until the device confirms the write,
    /// so the UI never shows a value the headset hasn't acknowledged yet.
    public var focusOnVoiceLoading: Bool

    /// True while an adaptive-volume change is in flight.
    ///
    /// Like ``focusOnVoiceLoading``, the toggle stays disabled and keeps its confirmed value until
    /// the device acknowledges the write.
    public var adaptiveVolumeLoading: Bool

    /// True while an auto-power-off change is in flight.
    ///
    /// The picker stays disabled and keeps its confirmed value until the device acknowledges the
    /// write.
    public var autoPowerOffLoading: Bool

    /// True while a DSEE change is in flight.
    ///
    /// The toggle stays disabled and keeps its confirmed value until the device acknowledges the
    /// write.
    public var dseeLoading: Bool

    /// True while a speak-to-chat change is in flight.
    ///
    /// Like ``dseeLoading``, the toggle stays disabled and keeps its confirmed value until the
    /// device acknowledges the write.
    public var speakToChatLoading: Bool

    /// True while an EQ preset change is in flight.
    ///
    /// The preset chips stay disabled until the device acknowledges the write.
    public var eqPresetLoading: Bool

    /// The last user-facing error message, or nil when the most recent operation succeeded.
    public var errorMessage: String?

    // MARK: Device state mirrored from SonyHeadphones

    /// True once a connection to a headset is established.
    public var connected: Bool

    /// The connected model, resolved from the advertised Bluetooth name.
    public var deviceModel: Either<DeviceModel, String>?

    /// The maximum ambient level the slider should offer: 19 on v1, 20 on v2 devices.
    public var maxAmbientLevel: Int

    /// The current noise-control mode (off / noise cancelling / ambient sound).
    public var mode: SHCAmbientMode

    /// The ambient-sound level, 1...`maxAmbientLevel`; 0 means ambient sound is off.
    public var ambientLevel: Int

    /// Whether focus on voice (ambient sound emphasises voices) is on.
    public var focusOnVoice: Bool

    /// Whether focus on voice is offered at the current level (ambient on, level above 2).
    public var focusOnVoiceAvailable: Bool

    /// Overall battery percentage, or -1 while still unknown.
    public var batteryLevel: Int

    /// Whether the device reported itself as charging.
    public var batteryCharging: Bool

    /// True for TWS earbuds, which also report per-earbud and case levels.
    public var hasDualBattery: Bool

    /// Left earbud percentage, or -1 if not applicable/unknown.
    public var batteryLeft: Int

    /// Right earbud percentage, or -1 if not applicable/unknown.
    public var batteryRight: Int

    /// Charging-case percentage, or -1 if not applicable/unknown.
    public var batteryCase: Int

    /// The raw equalizer preset byte (`EQ_PRESET`, e.g. 0x00 Off, 0xA0 Manual).
    public var eqPreset: Int

    /// Whether the device exposes the equalizer (v2 protocol only).
    public var supportsEqualizer: Bool

    /// The 5 equalizer band gains in -10...10, ordered low to high frequency.
    public var eqBands: [Int]

    /// Clear-bass boost in -10...10.
    public var clearBass: Int

    /// Whether DSEE (audio upsampling) is enabled.
    public var dsee: Bool

    /// Whether the auto-power-off probe succeeded; if false, the setting must not be shown.
    public var hasAutoPowerOff: Bool

    /// Auto-power-off delay: 0=Off, 1=5 min, 2=30 min, 3=1 hour, 4=3 hours, 5=when taken off.
    public var autoPowerOff: Int

    /// The firmware version string, empty when unknown.
    public var firmware: String

    /// The active Bluetooth codec ("SBC", "AAC", "LDAC", "aptX", "aptX HD"), empty when unknown.
    public var codec: String

    /// Whether the speak-to-chat probe succeeded; if false, the toggle must not be shown.
    public var hasSpeakToChat: Bool

    /// Whether speak-to-chat is enabled on the device.
    public var speakToChat: Bool

    /// Whether the adaptive-volume probe succeeded; if false, the toggle must not be shown.
    public var hasAdaptiveVolume: Bool

    /// Whether adaptive volume is enabled on the device.
    public var adaptiveVolume: Bool

    /// The headset's MAC address, empty when not connected.
    public var deviceMac: String

    /// Which Sony protocol generation the headset speaks: "v1", "v2", or empty when not connected.
    public var protocolVersion: String

    public init(
        connecting: Bool = false,
        focusOnVoiceLoading: Bool = false,
        adaptiveVolumeLoading: Bool = false,
        autoPowerOffLoading: Bool = false,
        dseeLoading: Bool = false,
        speakToChatLoading: Bool = false,
        eqPresetLoading: Bool = false,
        errorMessage: String? = nil,
        connected: Bool = false,
        deviceModel: Either<DeviceModel, String>? = nil,
        maxAmbientLevel: Int = 20,
        mode: SHCAmbientMode = .off,
        ambientLevel: Int = 10,
        focusOnVoice: Bool = false,
        focusOnVoiceAvailable: Bool = false,
        batteryLevel: Int = -1,
        batteryCharging: Bool = false,
        hasDualBattery: Bool = false,
        batteryLeft: Int = -1,
        batteryRight: Int = -1,
        batteryCase: Int = -1,
        eqPreset: Int = 0,
        supportsEqualizer: Bool = false,
        eqBands: [Int] = [0, 0, 0, 0, 0],
        clearBass: Int = 0,
        dsee: Bool = false,
        hasAutoPowerOff: Bool = false,
        autoPowerOff: Int = 0,
        firmware: String = "",
        codec: String = "",
        hasSpeakToChat: Bool = false,
        speakToChat: Bool = false,
        hasAdaptiveVolume: Bool = false,
        adaptiveVolume: Bool = false,
        deviceMac: String = "",
        protocolVersion: String = ""
    ) {
        self.connecting = connecting
        self.focusOnVoiceLoading = focusOnVoiceLoading
        self.adaptiveVolumeLoading = adaptiveVolumeLoading
        self.autoPowerOffLoading = autoPowerOffLoading
        self.dseeLoading = dseeLoading
        self.speakToChatLoading = speakToChatLoading
        self.eqPresetLoading = eqPresetLoading
        self.errorMessage = errorMessage
        self.connected = connected
        self.deviceModel = deviceModel
        self.maxAmbientLevel = maxAmbientLevel
        self.mode = mode
        self.ambientLevel = ambientLevel
        self.focusOnVoice = focusOnVoice
        self.focusOnVoiceAvailable = focusOnVoiceAvailable
        self.batteryLevel = batteryLevel
        self.batteryCharging = batteryCharging
        self.hasDualBattery = hasDualBattery
        self.batteryLeft = batteryLeft
        self.batteryRight = batteryRight
        self.batteryCase = batteryCase
        self.eqPreset = eqPreset
        self.supportsEqualizer = supportsEqualizer
        self.eqBands = eqBands
        self.clearBass = clearBass
        self.dsee = dsee
        self.hasAutoPowerOff = hasAutoPowerOff
        self.autoPowerOff = autoPowerOff
        self.firmware = firmware
        self.codec = codec
        self.hasSpeakToChat = hasSpeakToChat
        self.speakToChat = speakToChat
        self.hasAdaptiveVolume = hasAdaptiveVolume
        self.adaptiveVolume = adaptiveVolume
        self.deviceMac = deviceMac
        self.protocolVersion = protocolVersion
    }
}

// MARK: - Mapping from the library snapshot

extension HeadphonesUIState {
    /// Builds the domain state from a library snapshot; transient flags start at their defaults.
    ///
    /// - Parameter headphones: The snapshot the client returned.
    public init(_ headphones: SonyHeadphones) {
        self.init(
            connected: headphones.connected,
            deviceModel: headphones.deviceModel,
            maxAmbientLevel: headphones.maxAmbientLevel,
            mode: headphones.mode,
            ambientLevel: headphones.ambientLevel,
            focusOnVoice: headphones.focusOnVoice,
            focusOnVoiceAvailable: headphones.focusOnVoiceAvailable,
            batteryLevel: headphones.batteryLevel,
            batteryCharging: headphones.batteryCharging,
            hasDualBattery: headphones.hasDualBattery,
            batteryLeft: headphones.batteryLeft,
            batteryRight: headphones.batteryRight,
            batteryCase: headphones.batteryCase,
            eqPreset: headphones.eqPreset,
            supportsEqualizer: headphones.supportsEqualizer,
            eqBands: headphones.eqBands,
            clearBass: headphones.clearBass,
            dsee: headphones.dsee,
            hasAutoPowerOff: headphones.hasAutoPowerOff,
            autoPowerOff: headphones.autoPowerOff,
            firmware: headphones.firmware,
            codec: headphones.codec,
            hasSpeakToChat: headphones.hasSpeakToChat,
            speakToChat: headphones.speakToChat,
            hasAdaptiveVolume: headphones.hasAdaptiveVolume,
            adaptiveVolume: headphones.adaptiveVolume,
            deviceMac: headphones.deviceMac,
            protocolVersion: headphones.protocolVersion
        )
    }

    /// Returns the domain state that results from folding a library snapshot into this one.
    ///
    /// Every device-derived field comes from the snapshot, while the transient flags (`connecting`,
    /// the `*Loading` in-flight markers and `errorMessage`) are carried over: they describe the
    /// app's own progress, not the headset, and a snapshot carries no information about them.
    ///
    /// The receiver is left untouched.
    ///
    /// - Parameter headphones: The snapshot the client returned.
    /// - Returns: A new domain state holding the snapshot's device state.
    public func applying(_ headphones: SonyHeadphones) -> HeadphonesUIState {
        var updated = HeadphonesUIState(headphones)
        updated.connecting = connecting
        updated.focusOnVoiceLoading = focusOnVoiceLoading
        updated.adaptiveVolumeLoading = adaptiveVolumeLoading
        updated.autoPowerOffLoading = autoPowerOffLoading
        updated.dseeLoading = dseeLoading
        updated.speakToChatLoading = speakToChatLoading
        updated.eqPresetLoading = eqPresetLoading
        updated.errorMessage = errorMessage
        return updated
    }

    /// The battery level/charging combination reduced to the icon the UI shows.
    public var batteryState: BatteryState {
        .init(rawValue: batteryLevel, isCharging: batteryCharging)
    }
}
