#pragma once
#include <stdio.h>
#include "../IBluetoothConnector.h"
#include "IOBluetooth/IOBluetooth.h"
#include "Constants.h"
#include <thread>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <future>

class MacOSBluetoothConnector final : public IBluetoothConnector
{
public:
    MacOSBluetoothConnector();
    ~MacOSBluetoothConnector();
    static void connectToMac(MacOSBluetoothConnector* MacOSBluetoothConnector, std::promise<void> connectPromise) noexcept(false);
    virtual void connect(const std::string& addrStr) noexcept(false);
    virtual int send(char* buf, size_t length) noexcept(false);
    virtual int recv(char* buf, size_t length) noexcept(false);
    virtual void disconnect() noexcept;
    virtual bool isConnected() noexcept;
    virtual void closeConnection();
    virtual SonyProtocolVersion getProtocolVersion() noexcept;

    // Called by the Objective-C RFCOMM delegate when the peer closes the channel. This callback runs
    // on the connector thread, so it must only signal shutdown; joining that same thread would abort.
    void handleChannelClosed() noexcept;

    virtual std::vector<BluetoothDevice> getConnectedDevices() noexcept(false);
    std::deque<std::vector<unsigned char>> receivedBytes;
    std::mutex receiveDataMutex;
    std::condition_variable receiveDataConditionVariable;
    std::atomic<bool> running = false;
    std::mutex disconnectionMutex;
    std::condition_variable disconnectionConditionVariable;
    //Set on the connectToMac background thread before the connect promise resolves; safe to read from
    //any thread afterwards (the future's get() synchronizes-with the promise's set_value()).
    SonyProtocolVersion protocolVersion = SonyProtocolVersion::V1;

private:
    void *rfcommDevice = nullptr;
    std::atomic<void*> rfcommchannel{nullptr};
    std::thread uthread;
};
