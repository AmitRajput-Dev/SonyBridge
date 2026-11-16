import AppKit
import Bridge
import Client
import Clocks
import ComposableArchitecture
@testable import SonyHeadphonesClient
import SwiftUI

// MARK: - FixedScaleWindow

/// A window that always reports a 2x backing scale so snapshots are recorded and
/// compared at the same pixel size on Retina Macs and headless CI runners.
@MainActor private final class FixedScaleWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 2 }
}

// MARK: - SnapshotFixtures

/// Deterministic `HeadphonesState` values shared by the snapshot tests.
@MainActor enum SnapshotFixtures {
    /// Wraps a SwiftUI view for image snapshotting on macOS.
    ///
    /// swift-snapshot-testing only ships `NSView`/`NSViewController` image
    /// strategies on macOS, so views go through an `NSHostingController`
    /// upcast to `NSViewController`. The color scheme is pinned to Dark so
    /// references stay deterministic regardless of the host Mac's setting.
    private static var snapshotWindows: [NSWindow] = []

    static func hostingController(_ view: some View) -> NSViewController {
        let controller = NSHostingController(
            rootView: AnyView(
                view
                    .preferredColorScheme(.dark)
                    .environment(\.colorScheme, .dark)
            )
        )
        let window = FixedScaleWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 1000),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))

        // `preferredColorScheme` alone is not enough on every macOS version:
        // some runners resolve AppKit colors from the window's appearance and
        // render the whole view in light mode. Pin the appearance on the
        // window and hosting view as well so it cannot fall back.
        let appearance = NSAppearance(named: .darkAqua)
        window.appearance = appearance
        window.contentView?.appearance = appearance
        controller.view.appearance = appearance

        controller.view.translatesAutoresizingMaskIntoConstraints = true
        controller.view.autoresizingMask = []
        window.contentView?.addSubview(controller.view)
        snapshotWindows.append(window)
        return controller
    }

    static func singleBatteryHeadphones() -> SonyHeadphones {
        SonyHeadphones(
            connected: true,
            deviceModel: .left(.wh1000Xm5),
            batteryLevel: 80,
            eqPreset: EqPreset.excited.rawValue,
            supportsEqualizer: true,
            hasAutoPowerOff: true,
            autoPowerOff: AutoPowerOffOption.thirtyMinutes.rawValue,
            firmware: "2.0.0",
            codec: "LDAC",
            hasSpeakToChat: true,
            hasAdaptiveVolume: true,
            adaptiveVolume: true,
            deviceMac: "AA:BB:CC:DD:EE:FF",
            protocolVersion: "v2"
        )
    }

    static func dualBatteryHeadphones() -> SonyHeadphones {
        let state = SonyHeadphones(
            connected: true,
            deviceModel: .left(.wf1000Xm5),
            batteryLevel: -1,
            hasDualBattery: true,
            batteryLeft: 80,
            batteryRight: 75,
            batteryCase: 50,
            codec: "AAC"
        )
        return state
    }

    static func disconnectedStore() -> StoreOf<DisconnectedReducer> {
        Store(initialState: DisconnectedReducer.State()) {
            DisconnectedReducer()
        }
    }

    static func connectingStore() -> StoreOf<DisconnectedReducer> {
        Store(
            initialState: DisconnectedReducer.State(
                uiState: HeadphonesUIState(connecting: true)
            )
        ) {
            DisconnectedReducer()
        }
    }

    static func deviceListStore() -> StoreOf<DisconnectedReducer> {
        Store(
            initialState: DisconnectedReducer.State(
                devices: [
                    DiscoveredDevice(name: "WH-1000XM5", address: "AA:BB:CC:DD:EE:FF"),
                    DiscoveredDevice(name: "WF-1000XM5", address: "11:22:33:44:55:66"),
                ]
            )
        ) {
            DisconnectedReducer()
        }
    }

    static func errorStore() -> StoreOf<DisconnectedReducer> {
        Store(
            initialState: DisconnectedReducer.State(
                uiState: HeadphonesUIState(errorMessage: "Could not connect.")
            )
        ) {
            DisconnectedReducer()
        }
    }

    static func ambientStore(
        mode: SHCAmbientMode,
        focusOnVoiceAvailable: Bool = false,
        focusOnVoiceLoading: Bool
    ) -> StoreOf<AmbientReducer> {
        Store(
            initialState: AmbientReducer.State(
                uiState: Shared(
                    value: HeadphonesUIState(
                        focusOnVoiceLoading: focusOnVoiceLoading,
                        maxAmbientLevel: 20,
                        mode: mode,
                        ambientLevel: 10,
                        focusOnVoice: false,
                        focusOnVoiceAvailable: focusOnVoiceAvailable
                    )
                )
            )
        ) {
            AmbientReducer()
        }
    }

    static func equalizerStore(preset: EqPreset) -> StoreOf<EqualizerReducer> {
        Store(
            initialState: EqualizerReducer.State(
                uiState: Shared(
                    value: HeadphonesUIState(
                        eqPreset: preset.rawValue,
                        eqBands: [2, -1, 0, 3, -2],
                        clearBass: 5
                    )
                )
            )
        ) {
            EqualizerReducer()
        }
    }

    static func dseeStore(dseeLoading: Bool) -> StoreOf<DseeReducer> {
        Store(
            initialState: DseeReducer.State(
                uiState: .init(value: HeadphonesUIState(dsee: dseeLoading))
            ),
            reducer: DseeReducer.init
        )
    }

    static func settingsStore(
        autoPowerOffLoading: Bool,
        adaptiveVolumeLoading: Bool
    ) -> StoreOf<SettingsReducer> {
        Store(
            initialState: SettingsReducer.State(
                uiState: .init(
                    value: HeadphonesUIState(
                        adaptiveVolumeLoading: adaptiveVolumeLoading,
                        autoPowerOffLoading: autoPowerOffLoading,
                        hasAutoPowerOff: true,
                        autoPowerOff: AutoPowerOffOption.thirtyMinutes.rawValue,
                        hasSpeakToChat: true,
                        speakToChat: false,
                        hasAdaptiveVolume: true,
                        adaptiveVolume: true
                    )
                )
            ),
            reducer: SettingsReducer.init
        )
    }

    static func deviceHeroStore(
        headphones: SonyHeadphones
    ) -> StoreOf<DeviceHeroReducer> {
        Store(
            initialState: DeviceHeroReducer.State(
                uiState: .init(value: HeadphonesUIState(headphones))
            ),
            reducer: DeviceHeroReducer.init
        )
    }

    static func connectedStore(
        headphones: SonyHeadphones
    ) -> StoreOf<ConnectedReducer> {
        Store(
            initialState: ConnectedReducer.State(
                headphones: headphones,
                showAbout: false
            ),
            reducer: ConnectedReducer.init
        ) {
            $0.continuousClock = TestClock<Duration>()
            $0.headphonesClient = HeadphonesTestClient(state: headphones)
        }
    }

    static func mainScreenStore(
        state: MainScreenFeature.State,
        snapshot: SonyHeadphones = SonyHeadphones()
    ) -> StoreOf<MainScreenFeature> {
        Store(initialState: state, reducer: MainScreenFeature.init) {
            $0.continuousClock = TestClock<Duration>()
            $0.headphonesClient = HeadphonesTestClient(state: snapshot)
        }
    }
}
