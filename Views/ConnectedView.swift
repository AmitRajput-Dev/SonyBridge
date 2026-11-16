import Bridge
import Client
import ComposableArchitecture
import Dependencies
import SwiftUI

// MARK: - ConnectedReducer

@Reducer struct ConnectedReducer {
    @ObservableState struct State: Equatable {
        @Shared
        var uiState: HeadphonesUIState
        var deviceHero: DeviceHeroReducer.State
        var ambient: AmbientReducer.State
        var equalizer: EqualizerReducer.State
        var dsee: DseeReducer.State
        var settings: SettingsReducer.State

        /// Seeds the domain state from the snapshot the client returned on connect.
        ///
        /// `SonyHeadphones` is transport only: it is folded into ``HeadphonesUIState``
        /// here and never stored.
        init(
            headphones: SonyHeadphones,
            showAbout: Bool
        ) {
            let sharedUIState = Shared(value: HeadphonesUIState(headphones))
            self._uiState = sharedUIState
            self.deviceHero = .init(uiState: sharedUIState, showAbout: showAbout)
            self.ambient = .init(uiState: sharedUIState)
            self.equalizer = .init(uiState: sharedUIState)
            self.dsee = .init(uiState: sharedUIState)
            self.settings = .init(uiState: sharedUIState)
        }
    }

    enum Action {
        case deviceHero(DeviceHeroReducer.Action)
        case ambient(AmbientReducer.Action)
        case equalizer(EqualizerReducer.Action)
        case dsee(DseeReducer.Action)
        case settings(SettingsReducer.Action)
        case task
        case refreshStatusRequested
        case snapshotReceived(SonyHeadphones)
        case setError(String?)
        case disconnectButtonTapped
        case setMode(SHCAmbientMode)
        case setLevel(Int)
        case setFocusOnVoice(Bool)
        case setEqualizer(Int)
        case setBand(Int, Int)
        case setClearBass(Int)
        case setDsee(Bool)
        case setAutoPowerOff(AutoPowerOffOption)
        case setSpeakToChat(Bool)
        case setAdaptiveVolume(Bool)
        case dynamicTick
        case dynamicTickResponse(SonyHeadphones)
        case watchTick
        case watchTickResponse(SonyHeadphones)
        case delegate(Delegate)
    }

    enum Delegate {
        case didDisconnect
    }

    enum CancelID { case dynamicPolling, watchConnection }

    @Dependency(\.headphonesClient)
    var client
    @Dependency(\.continuousClock)
    var clock

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
                case .deviceHero(.delegate(.disconnectRequested)):
                    return disconnectEffect()

                case .deviceHero:
                    return .none

                case let .ambient(.delegate(.setMode(mode))):
                    return .send(.setMode(mode))

                case let .ambient(.delegate(.setLevel(level))):
                    return .send(.setLevel(level))

                case let .ambient(.delegate(.setFocusOnVoice(on))):
                    return .send(.setFocusOnVoice(on))

                case .ambient:
                    return .none

                case let .equalizer(.delegate(.setEqualizer(preset))):
                    return .send(.setEqualizer(preset))

                case let .equalizer(.delegate(.setBand(index, value))):
                    return .send(.setBand(index, value))

                case let .equalizer(.delegate(.setClearBass(value))):
                    return .send(.setClearBass(value))

                case .equalizer:
                    return .none

                case let .dsee(.delegate(.setDsee(on))):
                    return .send(.setDsee(on))

                case .dsee:
                    return .none

                case let .settings(.delegate(.setAdaptiveVolume(on))):
                    return .send(.setAdaptiveVolume(on))

                case let .settings(.delegate(.setSpeakToChat(on))):
                    return .send(.setSpeakToChat(on))

                case let .settings(.delegate(.setAutoPowerOff(option))):
                    return .send(.setAutoPowerOff(option))

                case .settings:
                    return .none

                case .task:
                    return .merge(startPolling(), .send(.refreshStatusRequested))

                case .refreshStatusRequested:
                    return .run { send in
                        await send(.snapshotReceived(client.refreshStatus()))
                        await send(.snapshotReceived(client.probeCapabilities()))
                    }

                case let .snapshotReceived(snap):
                    state.$uiState.withLock {
                        $0 = $0.applying(snap)
                        $0.errorMessage = nil
                        $0.focusOnVoiceLoading = false
                        $0.adaptiveVolumeLoading = false
                        $0.autoPowerOffLoading = false
                        $0.dseeLoading = false
                        $0.speakToChatLoading = false
                        $0.eqPresetLoading = false
                    }

                    return .none

                case let .setError(message):
                    state.$uiState.withLock {
                        $0.errorMessage = message
                        $0.focusOnVoiceLoading = false
                        $0.adaptiveVolumeLoading = false
                        $0.autoPowerOffLoading = false
                        $0.dseeLoading = false
                        $0.speakToChatLoading = false
                        $0.eqPresetLoading = false
                    }
                    return .none

                case .disconnectButtonTapped:
                    return disconnectEffect()

                case let .setMode(mode):
                    state.$uiState.withLock {
                        $0.mode = mode
                        $0.errorMessage = nil
                    }
                    return .run { send in
                        do {
                            await send(.snapshotReceived(try await client.setMode(mode)))
                        } catch {
                            await send(.setError(error.localizedDescription))
                        }
                    }

                case let .setLevel(level):
                    state.$uiState.withLock {
                        $0.ambientLevel = level
                        $0.errorMessage = nil
                    }
                    return .run { send in
                        do {
                            await send(.snapshotReceived(try await client.setLevel(level)))
                        } catch {
                            await send(.setError(error.localizedDescription))
                        }
                    }

                case let .setFocusOnVoice(on):
                    state.$uiState.withLock {
                        $0.errorMessage = nil
                        $0.focusOnVoiceLoading = true
                    }
                    return .run { send in
                        do {
                            await send(.snapshotReceived(try await client.setFocusOnVoice(on)))
                        } catch {
                            await send(.setError(error.localizedDescription))
                        }
                    }

                case let .setEqualizer(preset):
                    state.$uiState.withLock {
                        $0.eqPresetLoading = true
                        $0.errorMessage = nil
                    }
                    return .run { send in
                        do {
                            await send(.snapshotReceived(try await client.setEqualizer(preset)))
                        } catch {
                            await send(.setError(error.localizedDescription))
                        }
                    }

                case let .setBand(index, value):
                    guard state.uiState.eqBands.indices.contains(index) else { return .none }
                    let (bass, bands) = state.$uiState.withLock { uiState -> (Int, [Int]) in
                        uiState.eqBands[index] = value
                        uiState.eqPreset = EqPreset.manual.rawValue
                        uiState.errorMessage = nil
                        return (uiState.clearBass, uiState.eqBands)
                    }
                    return customEqEffect(bass: bass, bands: bands)

                case let .setClearBass(value):
                    let bands = state.$uiState.withLock { uiState -> [Int] in
                        uiState.clearBass = value
                        uiState.eqPreset = EqPreset.manual.rawValue
                        uiState.errorMessage = nil
                        return uiState.eqBands
                    }
                    return customEqEffect(bass: value, bands: bands)

                case let .setDsee(on):
                    state.$uiState.withLock {
                        $0.errorMessage = nil
                        $0.dseeLoading = true
                    }
                    return .run { send in
                        do {
                            await send(.snapshotReceived(try await client.setDsee(on)))
                        } catch {
                            await send(.setError(error.localizedDescription))
                        }
                    }

                case let .setAutoPowerOff(option):
                    state.$uiState.withLock {
                        $0.errorMessage = nil
                        $0.autoPowerOffLoading = true
                    }
                    return .run { send in
                        do {
                            await send(.snapshotReceived(try await client
                                    .setAutoPowerOff(option.rawValue)))
                        } catch {
                            await send(.setError(error.localizedDescription))
                        }
                    }

                case let .setSpeakToChat(on):
                    state.$uiState.withLock {
                        $0.speakToChatLoading = true
                        $0.errorMessage = nil
                    }
                    return .run { send in
                        do {
                            await send(.snapshotReceived(try await client.setSpeakToChat(on)))
                        } catch {
                            await send(.setError(error.localizedDescription))
                        }
                    }

                case let .setAdaptiveVolume(on):
                    state.$uiState.withLock {
                        $0.adaptiveVolumeLoading = true
                        $0.errorMessage = nil
                    }

                    return .run { send in
                        do {
                            await send(.snapshotReceived(try await client.setAdaptiveVolume(on)))
                        } catch {
                            await send(.setError(error.localizedDescription))
                        }
                    }

                case .dynamicTick:
                    return .run { send in
                        await send(.dynamicTickResponse(client.refreshDynamic()))
                    }

                case let .dynamicTickResponse(snap):
                    state.$uiState.withLock {
                        $0 = $0.applying(snap)
                        $0.errorMessage = nil
                    }
                    return .none

                case .watchTick:
                    return .run { send in
                        await send(.watchTickResponse(client.pollConnection()))
                    }

                case let .watchTickResponse(snap):
                    state.$uiState.withLock {
                        $0 = $0.applying(snap)
                        $0.errorMessage = nil
                    }
                    if snap.connected {
                        return .none
                    }
                    return .merge(
                        .cancel(id: CancelID.dynamicPolling),
                        .cancel(id: CancelID.watchConnection),
                        .send(.delegate(.didDisconnect))
                    )

                case .delegate:
                    return .none
            }
        }

        Scope(state: \.deviceHero, action: \.deviceHero) {
            DeviceHeroReducer()
        }
        Scope(state: \.ambient, action: \.ambient) {
            AmbientReducer()
        }
        Scope(state: \.equalizer, action: \.equalizer) {
            EqualizerReducer()
        }
        Scope(state: \.dsee, action: \.dsee) {
            DseeReducer()
        }
        Scope(state: \.settings, action: \.settings) {
            SettingsReducer()
        }
    }

    private func disconnectEffect() -> Effect<Action> {
        .merge(
            .cancel(id: CancelID.dynamicPolling),
            .cancel(id: CancelID.watchConnection),
            .run { send in
                _ = await client.disconnect()
                await send(.delegate(.didDisconnect))
            }
        )
    }

    /// Manual EQ (preset byte 0xA0 = 160). Called as the user drags a band or clear-bass slider.
    private func customEqEffect(bass: Int, bands: [Int]) -> Effect<Action> {
        .run { send in
            do {
                await send(.snapshotReceived(try await client.setCustomEq(
                    bass: bass,
                    bands: bands
                )))
            } catch {
                await send(.setError(error.localizedDescription))
            }
        }
    }

    /// Polls the button-changeable state so the app stays in sync when you use
    /// the headphone's own controls, and watches the connection so a headset
    /// dropping RFCOMM on its own doesn't leave a stale "Connected".
    private func startPolling() -> Effect<Action> {
        .merge(
            .concatenate(
                .cancel(id: CancelID.dynamicPolling),
                .run { send in
                    while true {
                        try await clock.sleep(for: .seconds(2))
                        await send(.dynamicTick)
                    }
                }
                .cancellable(id: CancelID.dynamicPolling)
            ),
            .concatenate(
                .cancel(id: CancelID.watchConnection),
                .run { send in
                    while true {
                        try await clock.sleep(for: .seconds(1.5))
                        await send(.watchTick)
                    }
                }
                .cancellable(id: CancelID.watchConnection)
            )
        )
    }
}

// MARK: - ConnectedView

struct ConnectedView: View {
    let store: StoreOf<ConnectedReducer>

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                DeviceHeroView(store: store.scope(state: \.deviceHero, action: \.deviceHero))
                AmbientView(store: store.scope(state: \.ambient, action: \.ambient))
                if store.uiState.supportsEqualizer {
                    EqualizerView(
                        store: store.scope(state: \.equalizer, action: \.equalizer)
                    )
                    DseeView(store: store.scope(state: \.dsee, action: \.dsee))
                }
                if store.uiState.hasAdaptiveVolume || store.uiState.hasSpeakToChat
                    || store.uiState.hasAutoPowerOff {
                    SettingsView(store: store.scope(state: \.settings, action: \.settings))
                }
                if let error = store.uiState.errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red.opacity(0.9))
                }
            }
            .padding(20)
        }
        .task { store.send(.task) }
    }
}

#Preview {
    ConnectedView(
        store: Store(
            initialState: .init(
                headphones: SonyHeadphones(
                    connected: true,
                    deviceModel: .left(.wh1000Xm5),
                    batteryLevel: 80,
                    eqPreset: EqPreset.excited.rawValue,
                    supportsEqualizer: true,
                    hasAutoPowerOff: true,
                    autoPowerOff: AutoPowerOffOption.thirtyMinutes.rawValue,
                    codec: "LDAC",
                    hasSpeakToChat: true,
                    hasAdaptiveVolume: true,
                    adaptiveVolume: true
                ),
                showAbout: false
            ),
            reducer: ConnectedReducer.init
        )
    )
}

#Preview {
    ConnectedView(
        store: Store(
            initialState: .init(headphones: .init(), showAbout: false),
            reducer: ConnectedReducer.init
        )
    )
}
