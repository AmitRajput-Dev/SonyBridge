import Client
import ComposableArchitecture
import Dependencies
import Foundation
import SwiftUI

// MARK: - DisconnectedReducer

@Reducer struct DisconnectedReducer {
    @ObservableState struct State: Equatable {
        var uiState: HeadphonesUIState = .init()
        var devices: [DiscoveredDevice] = []
    }

    enum Action {
        case connectButtonTapped
        case autoConnectResponse(SonyHeadphones)
        case autoConnectFailed(String)
        case devicesResponse([DiscoveredDevice])
        case deviceTapped(DiscoveredDevice)
        case connectionResponse(SonyHeadphones)
        case connectionFailed(String)
        case delegate(Delegate)
    }

    enum Delegate {
        case didConnect(SonyHeadphones)
    }

    @Dependency(\.headphonesClient)
    var client

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
                case .connectButtonTapped:
                    state.uiState.connecting = true
                    state.uiState.errorMessage = nil
                    state.devices = []
                    return .run { send in
                        do {
                            await send(.autoConnectResponse(try await client.connectToAutoDevice()))
                        } catch {
                            await send(.autoConnectFailed(error.localizedDescription))
                        }
                    }

                case let .autoConnectResponse(snap):
                    if snap.connected {
                        state.uiState.connecting = false
                        return .send(.delegate(.didConnect(snap)))
                    }
                    state.uiState.connecting = false
                    return .run { send in
                        await send(.devicesResponse(client.pairedDevices()))
                    }

                case let .autoConnectFailed(message):
                    state.uiState.connecting = false
                    state.uiState.errorMessage = message
                    return .run { send in
                        await send(.devicesResponse(client.pairedDevices()))
                    }

                case let .devicesResponse(devices):
                    state.devices = devices
                    if devices.isEmpty {
                        state.uiState.errorMessage = String(
                            localized: "DisconnectedView.emptyListHint",
                            // swiftlint:disable:next line_length
                            defaultValue: "No paired Sony headphones found. Pair them in macOS Bluetooth settings first."
                        )
                    }
                    return .none

                case let .deviceTapped(device):
                    state.uiState.connecting = true
                    state.uiState.errorMessage = nil
                    return .run { send in
                        do {
                            await send(.connectionResponse(try await client
                                    .connect(address: device.address)))
                        } catch {
                            await send(.connectionFailed(error.localizedDescription))
                        }
                    }

                case let .connectionResponse(snap):
                    state.uiState.connecting = false
                    if snap.connected {
                        state.devices = []
                        return .send(.delegate(.didConnect(snap)))
                    }
                    return .none

                case let .connectionFailed(message):
                    state.uiState.connecting = false
                    state.uiState.errorMessage = message
                    return .none

                case .delegate:
                    return .none
            }
        }
    }
}

// MARK: - DisconnectedView

struct DisconnectedView: View {
    let store: StoreOf<DisconnectedReducer>

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "headphones")
                .font(.system(size: 64, weight: .thin))
                .foregroundColor(.foregroundSecondary)
            Text("DisconnectedView.title")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.foregroundSecondary)
            if let errorMessage = store.uiState.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            if !store.devices.isEmpty {
                deviceList
            }
            Button(action: { store.send(.connectButtonTapped) }) {
                Text(store.uiState
                    .connecting ? "DisconnectedView.connecting" : "DisconnectedView.connect")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.highlight)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(store.uiState.connecting)
            .padding(.horizontal, 40)
            Spacer()
        }
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DisconnectedView.devicesTitle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.foregroundSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            ForEach(store.devices) { device in
                Button(action: { store.send(.deviceTapped(device)) }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.foreground)
                            Text(device.address)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundColor(.foregroundSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.foregroundSecondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(store.uiState.connecting)
            }
        }
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 40)
    }
}

#Preview {
    DisconnectedView(
        store: Store(
            initialState: .init(uiState: .init(connecting: true)),
            reducer: DisconnectedReducer.init
        )
    )
}

#Preview {
    DisconnectedView(
        store: Store(
            initialState: .init(uiState: .init(errorMessage: "Error")),
            reducer: DisconnectedReducer.init
        )
    )
}

#Preview {
    DisconnectedView(
        store: Store(
            initialState: DisconnectedReducer.State(
                devices: [
                    DiscoveredDevice(name: "WH-1000XM5", address: "AA:BB:CC:DD:EE:FF"),
                    DiscoveredDevice(name: "WF-1000XM5", address: "11:22:33:44:55:66"),
                ]
            )
        ) {
            DisconnectedReducer()
        }
    )
}
