import Client
import ComposableArchitecture
@testable import SonyHeadphonesClient
import Testing

@MainActor struct DisconnectedReducerTests {
    private var emptyListHintDefault: String.LocalizationValue {
        "No paired Sony headphones found. Pair them in macOS Bluetooth settings first."
    }

    @Test func autoConnectSuccessDelegatesDidConnect() async {
        let connected = SonyHeadphones(
            connected: true,
            deviceModel: .left(.wh1000Xm5)
        )

        let store = TestStore(initialState: DisconnectedReducer.State()) {
            DisconnectedReducer()
        } withDependencies: {
            $0.headphonesClient = HeadphonesTestClient(state: connected)
        }

        await store.send(.connectButtonTapped) {
            $0.uiState.connecting = true
        }
        await store.receive(\.autoConnectResponse) {
            $0.uiState.connecting = false
        }
        await store.receive(\.delegate)
    }

    @Test func emptyDeviceListShowsHint() async {
        let client = HeadphonesTestClient()
        await client.setAutoConnectSucceeds(false)
        let store = TestStore(initialState: DisconnectedReducer.State()) {
            DisconnectedReducer()
        } withDependencies: {
            $0.headphonesClient = client
        }

        await store.send(.connectButtonTapped) {
            $0.uiState.connecting = true
        }
        await store.receive(\.autoConnectResponse) {
            $0.uiState.connecting = false
        }
        await store.receive(\.devicesResponse) {
            $0.uiState.errorMessage = String(
                localized: "DisconnectedView.emptyListHint",
                defaultValue: emptyListHintDefault
            )
        }
    }

    @Test func deviceTappedConnectsToThatAddress() async {
        let device = DiscoveredDevice(name: "WH-1000XM5", address: "AA:BB:CC:DD:EE:FF")
        let client = HeadphonesTestClient()
        await client.setStubbedDevices([device])

        let store = TestStore(
            initialState: DisconnectedReducer.State(devices: [device])
        ) {
            DisconnectedReducer()
        } withDependencies: {
            $0.headphonesClient = client
        }

        await store.send(.deviceTapped(device)) {
            $0.uiState.connecting = true
            $0.uiState.errorMessage = nil
        }
        await store.receive(\.connectionResponse) {
            $0.uiState.connecting = false
            $0.devices = []
        }
        await store.receive(\.delegate)
    }

    @Test func failedConnectionSurfacesErrorMessage() async {
        let device = DiscoveredDevice(name: "WH-1000XM5", address: "AA:BB:CC:DD:EE:FF")
        let client = HeadphonesTestClient()
        await client.setStubbedDevices([device])
        await client.setConnectionError("Could not connect.")

        let store = TestStore(
            initialState: DisconnectedReducer.State(devices: [device])
        ) {
            DisconnectedReducer()
        } withDependencies: {
            $0.headphonesClient = client
        }

        await store.send(.deviceTapped(device)) {
            $0.uiState.connecting = true
            $0.uiState.errorMessage = nil
        }
        await store.receive(\.connectionFailed) {
            $0.uiState.connecting = false
            $0.uiState.errorMessage = "Could not connect."
        }
    }

    @Test func connectButtonTappedStartsConnectingAndClearsPreviousError() async {
        let client = HeadphonesTestClient()
        await client.setAutoConnectSucceeds(false)
        let store = TestStore(
            initialState: DisconnectedReducer.State(
                uiState: HeadphonesUIState(errorMessage: "Boom")
            )
        ) {
            DisconnectedReducer()
        } withDependencies: {
            $0.headphonesClient = client
        }

        await store.send(.connectButtonTapped) {
            $0.uiState.connecting = true
            $0.uiState.errorMessage = nil
            $0.devices = []
        }
        await store.receive(\.autoConnectResponse) {
            $0.uiState.connecting = false
        }
        await store.receive(\.devicesResponse) {
            $0.uiState.errorMessage = String(
                localized: "DisconnectedView.emptyListHint",
                defaultValue: emptyListHintDefault
            )
        }
    }
}
