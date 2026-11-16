import Bridge
import Client
import ComposableArchitecture
@testable import SonyHeadphonesClient
import Testing

@MainActor struct ConnectedReducerTests {
    private func connectedState() -> SonyHeadphones {
        SonyHeadphones(
            connected: true,
            deviceModel: .left(.wh1000Xm5),
            supportsEqualizer: true
        )
    }

    @Test func snapshotReceivedFoldsSnapshotIntoSharedUIState() async {
        let snapshot = SonyHeadphones(
            connected: true,
            deviceModel: .left(.wh1000Xm5),
            mode: .ambientSound,
            ambientLevel: 12,
            eqPreset: EqPreset.bass.rawValue,
            dsee: true,
            hasAdaptiveVolume: true,
            adaptiveVolume: true
        )

        let store = TestStore(
            initialState: ConnectedReducer.State(headphones: connectedState(), showAbout: false)
        ) {
            ConnectedReducer()
        }

        await store.send(.snapshotReceived(snapshot)) {
            $0.$uiState.withLock { $0 = $0.applying(snapshot) }
        }

        #expect(store.state.uiState.mode == .ambientSound)
        #expect(store.state.uiState.ambientLevel == 12)
        #expect(store.state.uiState.eqPreset == EqPreset.bass.rawValue)
        #expect(store.state.uiState.dsee)
        #expect(store.state.uiState.adaptiveVolume)

        // Every child renders from the very same shared domain state.
        #expect(store.state.deviceHero.uiState == store.state.uiState)
        #expect(store.state.ambient.uiState == store.state.uiState)
        #expect(store.state.equalizer.uiState == store.state.uiState)
        #expect(store.state.dsee.uiState == store.state.uiState)
        #expect(store.state.settings.uiState == store.state.uiState)
    }

    @Test func setModeForwardsToClientAndAppliesSnapshot() async {
        let client = HeadphonesTestClient(state: connectedState())
        let store = TestStore(
            initialState: ConnectedReducer.State(headphones: connectedState(), showAbout: false)
        ) {
            ConnectedReducer()
        } withDependencies: {
            $0.headphonesClient = client
        }

        await store.send(.setMode(.noiseCanceling)) {
            $0.$uiState.withLock {
                $0.mode = .noiseCanceling
                $0.errorMessage = nil
            }
        }
        await store.receive(\.snapshotReceived)

        #expect(store.state.uiState.mode == .noiseCanceling)
        #expect(store.state.ambient.uiState.mode == .noiseCanceling)
        #expect(store.state.deviceHero.uiState.mode == .noiseCanceling)
    }

    @Test func setFocusOnVoiceWaitsForSnapshotInsteadOfUpdatingOptimistically() async {
        let client = HeadphonesTestClient(state: connectedState())
        await client.suspendWrites()
        let store = TestStore(
            initialState: ConnectedReducer.State(headphones: connectedState(), showAbout: false)
        ) {
            ConnectedReducer()
        } withDependencies: {
            $0.headphonesClient = client
        }

        await store.send(.setFocusOnVoice(true)) {
            $0.uiState.focusOnVoiceLoading = true
            $0.uiState.errorMessage = nil
        }
        // The write is still in flight, so the toggle keeps its old value until the device confirms.
        #expect(store.state.uiState.focusOnVoice == false)
        #expect(store.state.ambient.uiState.focusOnVoice == false)
        #expect(store.state.uiState.focusOnVoiceLoading)

        await client.releaseWrites()
        let confirmed = SonyHeadphones(
            connected: true,
            deviceModel: .left(.wh1000Xm5),
            focusOnVoice: true,
            supportsEqualizer: true
        )
        await store.receive(\.snapshotReceived) {
            $0.$uiState.withLock {
                $0 = $0.applying(confirmed)
                $0.focusOnVoiceLoading = false
            }
        }

        #expect(store.state.uiState.focusOnVoice)
        #expect(store.state.ambient.uiState.focusOnVoice)
        #expect(store.state.uiState.focusOnVoiceLoading == false)
    }

    @Test func setAdaptiveVolumeWaitsForSnapshotInsteadOfUpdatingOptimistically() async {
        let state = SonyHeadphones(
            connected: true,
            deviceModel: .left(.wh1000Xm5),
            supportsEqualizer: true,
            hasAdaptiveVolume: true
        )
        let client = HeadphonesTestClient(state: state)
        await client.suspendWrites()
        let store = TestStore(
            initialState: ConnectedReducer.State(headphones: state, showAbout: false)
        ) {
            ConnectedReducer()
        } withDependencies: {
            $0.headphonesClient = client
        }

        await store.send(.setAdaptiveVolume(true)) {
            $0.uiState.adaptiveVolumeLoading = true
            $0.uiState.errorMessage = nil
        }
        // The write is still in flight, so the toggle keeps its old value until the device confirms.
        #expect(store.state.uiState.adaptiveVolume == false)
        #expect(store.state.settings.uiState.adaptiveVolume == false)
        #expect(store.state.uiState.adaptiveVolumeLoading)

        await client.releaseWrites()
        let confirmed = SonyHeadphones(
            connected: true,
            deviceModel: .left(.wh1000Xm5),
            supportsEqualizer: true,
            hasAdaptiveVolume: true,
            adaptiveVolume: true
        )
        await store.receive(\.snapshotReceived) {
            $0.$uiState.withLock {
                $0 = $0.applying(confirmed)
                $0.adaptiveVolumeLoading = false
            }
        }

        #expect(store.state.uiState.adaptiveVolume)
        #expect(store.state.settings.uiState.adaptiveVolume)
        #expect(store.state.uiState.adaptiveVolumeLoading == false)
    }

    @Test func setAutoPowerOffWaitsForSnapshotInsteadOfUpdatingOptimistically() async {
        let state = SonyHeadphones(
            connected: true,
            deviceModel: .left(.wh1000Xm5),
            supportsEqualizer: true,
            hasAutoPowerOff: true
        )
        let client = HeadphonesTestClient(state: state)
        await client.suspendWrites()
        let store = TestStore(
            initialState: ConnectedReducer.State(headphones: state, showAbout: false)
        ) {
            ConnectedReducer()
        } withDependencies: {
            $0.headphonesClient = client
        }

        await store.send(.setAutoPowerOff(.thirtyMinutes)) {
            $0.uiState.autoPowerOffLoading = true
            $0.uiState.errorMessage = nil
        }
        // The write is still in flight, so the picker keeps its old value until the device confirms.
        #expect(store.state.uiState.autoPowerOff == AutoPowerOffOption.off.rawValue)
        #expect(store.state.settings.uiState.autoPowerOff == AutoPowerOffOption.off.rawValue)
        #expect(store.state.uiState.autoPowerOffLoading)

        await client.releaseWrites()
        let confirmed = SonyHeadphones(
            connected: true,
            deviceModel: .left(.wh1000Xm5),
            supportsEqualizer: true,
            hasAutoPowerOff: true,
            autoPowerOff: AutoPowerOffOption.thirtyMinutes.rawValue
        )
        await store.receive(\.snapshotReceived) {
            $0.$uiState.withLock {
                $0 = $0.applying(confirmed)
                $0.autoPowerOffLoading = false
            }
        }

        #expect(store.state.uiState.autoPowerOff == AutoPowerOffOption.thirtyMinutes.rawValue)
        #expect(
            store.state.settings.uiState.autoPowerOff
                == AutoPowerOffOption.thirtyMinutes.rawValue
        )
        #expect(store.state.uiState.autoPowerOffLoading == false)
    }

    @Test func setDseeWaitsForSnapshotInsteadOfUpdatingOptimistically() async {
        let state = SonyHeadphones(
            connected: true,
            deviceModel: .left(.wh1000Xm5),
            supportsEqualizer: true
        )
        let client = HeadphonesTestClient(state: state)
        await client.suspendWrites()
        let store = TestStore(
            initialState: ConnectedReducer.State(headphones: state, showAbout: false)
        ) {
            ConnectedReducer()
        } withDependencies: {
            $0.headphonesClient = client
        }

        await store.send(.setDsee(true)) {
            $0.uiState.dseeLoading = true
            $0.uiState.errorMessage = nil
        }
        // The write is still in flight, so the toggle keeps its old value until the device confirms.
        #expect(store.state.uiState.dsee == false)
        #expect(store.state.dsee.uiState.dsee == false)
        #expect(store.state.uiState.dseeLoading)

        await client.releaseWrites()
        let confirmed = SonyHeadphones(
            connected: true,
            deviceModel: .left(.wh1000Xm5),
            supportsEqualizer: true,
            dsee: true
        )
        await store.receive(\.snapshotReceived) {
            $0.$uiState.withLock {
                $0 = $0.applying(confirmed)
                $0.dseeLoading = false
            }
        }

        #expect(store.state.uiState.dsee)
        #expect(store.state.dsee.uiState.dsee)
        #expect(store.state.uiState.dseeLoading == false)
    }

    @Test func setSpeakToChatClearsLoadingFlagWhenSnapshotArrives() async {
        let state = SonyHeadphones(
            connected: true,
            deviceModel: .left(.wh1000Xm5),
            supportsEqualizer: true,
            hasSpeakToChat: true
        )
        let client = HeadphonesTestClient(state: state)
        await client.suspendWrites()
        let store = TestStore(
            initialState: ConnectedReducer.State(headphones: state, showAbout: false)
        ) {
            ConnectedReducer()
        } withDependencies: {
            $0.headphonesClient = client
        }

        await store.send(.setSpeakToChat(true)) {
            $0.uiState.speakToChatLoading = true
            $0.uiState.errorMessage = nil
        }
        #expect(store.state.uiState.speakToChatLoading)

        await client.releaseWrites()
        let confirmed = SonyHeadphones(
            connected: true,
            deviceModel: .left(.wh1000Xm5),
            supportsEqualizer: true,
            hasSpeakToChat: true,
            speakToChat: true
        )
        await store.receive(\.snapshotReceived) {
            $0.$uiState.withLock {
                $0 = $0.applying(confirmed)
                $0.speakToChatLoading = false
            }
        }

        #expect(store.state.uiState.speakToChat)
        #expect(store.state.uiState.speakToChatLoading == false)
    }

    @Test func setBandIgnoresOutOfRangeIndex() async {
        let store = TestStore(
            initialState: ConnectedReducer.State(headphones: connectedState(), showAbout: false)
        ) {
            ConnectedReducer()
        }

        await store.send(.setBand(9, 3))
    }

    @Test func setBandSendsCustomEqualizerToClient() async {
        let client = HeadphonesTestClient(state: connectedState())
        let store = TestStore(
            initialState: ConnectedReducer.State(headphones: connectedState(), showAbout: false)
        ) {
            ConnectedReducer()
        } withDependencies: {
            $0.headphonesClient = client
        }

        await store.send(.setBand(0, 5)) {
            $0.$uiState.withLock {
                $0.eqBands[0] = 5
                $0.eqPreset = EqPreset.manual.rawValue
                $0.errorMessage = nil
            }
        }
        await store.receive(\.snapshotReceived)

        #expect(store.state.equalizer.uiState.eqBands[0] == 5)
        #expect(store.state.equalizer.uiState.eqPreset == EqPreset.manual.rawValue)
    }

    @Test func disconnectButtonTappedDelegatesDidDisconnect() async {
        let client = HeadphonesTestClient(state: connectedState())
        let store = TestStore(
            initialState: ConnectedReducer.State(headphones: connectedState(), showAbout: false)
        ) {
            ConnectedReducer()
        } withDependencies: {
            $0.headphonesClient = client
        }

        await store.send(.disconnectButtonTapped)
        await store.receive(\.delegate)
    }

    @Test func watchTickReportsDisconnectWhenHeadphonesDropOff() async {
        let client = HeadphonesTestClient(state: SonyHeadphones())
        let store = TestStore(
            initialState: ConnectedReducer.State(headphones: connectedState(), showAbout: false)
        ) {
            ConnectedReducer()
        } withDependencies: {
            $0.headphonesClient = client
        }

        await store.send(.watchTick)
        await store.receive(\.watchTickResponse) {
            $0.$uiState.withLock { $0 = $0.applying(SonyHeadphones()) }
        }
        await store.receive(\.delegate)

        #expect(store.state.ambient.uiState.connected == false)
    }
}
