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

    // Called by the Objective-C RFCOMM delegate when the peer closes the channel. Delegate callbacks
    // are delivered on the main thread's run loop (the connector thread never pumps one), so this
    // must only signal shutdown; disconnect()'s close-and-join runs on whichever thread invokes it.
    void handleChannelClosed() noexcept;

    // Called by the Objective-C RFCOMM delegate for every received data frame. Drops zero-length
    // frames (recv() returning 0 reads as "connection closed" upstream) and caps the total buffered
    // bytes so a device streaming unsolicited frames while nothing is reading can't grow memory
    // without bound. Public so the offline buffer tests can drive it without a live channel.
    void enqueueReceivedData(const unsigned char* data, size_t length);

    // recv() only runs during a command exchange, so the queue must be bounded. Protocol frames are
    // at most MAX_BLUETOOTH_MESSAGE_SIZE; 16 of them is far more than any legitimate burst.
    static constexpr size_t RECEIVE_BUFFER_CAP = MAX_BLUETOOTH_MESSAGE_SIZE * 16;

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
    //Total bytes across receivedBytes; guarded by receiveDataMutex.
    size_t receivedBytesTotal = 0;
};
