#include "MacOSBluetoothConnector.h"

MacOSBluetoothConnector::MacOSBluetoothConnector()
{
    
}
MacOSBluetoothConnector::~MacOSBluetoothConnector()
{
    // A failed or remotely closed connection can leave a finished-but-joinable std::thread even when
    // isConnected() is false. Always perform the idempotent cleanup before the thread is destroyed.
    disconnect();
}

@interface AsyncCommDelegate : NSObject <IOBluetoothRFCOMMChannelDelegate> {
@public
    MacOSBluetoothConnector* delegateCPP;
}
@end

@implementation AsyncCommDelegate {
}
- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)rfcommChannel{
#ifdef SHC_DEBUG_PROTOCOL
    fprintf(stderr, "[connect] rfcommChannelClosed\n");
#endif
    delegateCPP->handleChannelClosed();
}

#ifdef SHC_DEBUG_PROTOCOL
- (void)rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)rfcommChannel status:(IOReturn)error {
    fprintf(stderr, "[connect] rfcommChannelOpenComplete status=0x%x\n", error);
}
#endif

-(void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)rfcommChannel data:(void *)dataPointer length:(size_t)dataLength
{
    delegateCPP->enqueueReceivedData((const unsigned char*)dataPointer, dataLength);
}


@end

#ifdef SHC_DEBUG_PROTOCOL
static void _debugHexDump(const char* label, const char* buf, size_t length)
{
    fprintf(stderr, "[%s] ", label);
    for (size_t i = 0; i < length; i++)
    {
        fprintf(stderr, "%02x ", (unsigned char)buf[i]);
    }
    fprintf(stderr, "\n");
}
#endif

int MacOSBluetoothConnector::send(char* buf, size_t length)
{
#ifdef SHC_DEBUG_PROTOCOL
    _debugHexDump("send", buf, length);
#endif
    IOBluetoothRFCOMMChannel *channel = nil;
    {
        std::lock_guard<std::mutex> g(channelMtx);
        channel = (__bridge IOBluetoothRFCOMMChannel*)rfcommchannel;
    }
    if (channel == nil) throw RecoverableException("Bluetooth connection is closed", false);
    [channel writeSync:(void*)buf length:length];
    return (int)length;
}


void MacOSBluetoothConnector::connectToMac(MacOSBluetoothConnector* macOSBluetoothConnector, std::promise<void> connectPromise)
{
    // get device
    IOBluetoothDevice *device = (__bridge IOBluetoothDevice *)macOSBluetoothConnector->rfcommDevice;
    // create new channel
    IOBluetoothRFCOMMChannel *channel = [[IOBluetoothRFCOMMChannel alloc] init];

    // try the v1 service UUID first, then fall back to the v2 (newer-generation) UUID.
    IOBluetoothSDPUUID *sppServiceUUIDV1 = [IOBluetoothSDPUUID uuidWithBytes:(void*)SERVICE_UUID_IN_BYTES length: 16];
    IOBluetoothSDPServiceRecord *sppServiceRecord = [device getServiceRecordForUUID:sppServiceUUIDV1];
    SonyProtocolVersion protocolVersion = SonyProtocolVersion::V1;
#ifdef SHC_DEBUG_PROTOCOL
    fprintf(stderr, "[connect] v1 getServiceRecordForUUID -> %s\n", sppServiceRecord == nil ? "nil" : "found");
#endif

    if (sppServiceRecord == nil) {
        IOBluetoothSDPUUID *sppServiceUUIDV2 = [IOBluetoothSDPUUID uuidWithBytes:(void*)SERVICE_UUID_V2_IN_BYTES length: 16];
        sppServiceRecord = [device getServiceRecordForUUID:sppServiceUUIDV2];
        protocolVersion = SonyProtocolVersion::V2;
#ifdef SHC_DEBUG_PROTOCOL
        fprintf(stderr, "[connect] v2 getServiceRecordForUUID -> %s\n", sppServiceRecord == nil ? "nil" : "found");
#endif
    }

    if (sppServiceRecord == nil) {
        RecoverableException exc = RecoverableException("Couldn't find the Sony service record on this device (neither protocol version) - is this a supported headset?", false);
        std::exception_ptr excPtr = std::make_exception_ptr(exc);
        connectPromise.set_exception(excPtr);
        return;
    }

    // get rfcommChannelID from sppServiceRecord
    UInt8 rfcommChannelID = 0;
    IOReturn channelIdStatus = [sppServiceRecord getRFCOMMChannelID:&rfcommChannelID];
#ifdef SHC_DEBUG_PROTOCOL
    fprintf(stderr, "[connect] protocolVersion=%s getRFCOMMChannelID -> 0x%x, channelID=%u\n", protocolVersion == SonyProtocolVersion::V2 ? "V2" : "V1", channelIdStatus, (unsigned)rfcommChannelID);
#endif
    if (channelIdStatus != kIOReturnSuccess) {
        RecoverableException exc = RecoverableException("Found the Sony service record, but it has no RFCOMM channel.", false);
        std::exception_ptr excPtr = std::make_exception_ptr(exc);
        connectPromise.set_exception(excPtr);
        return;
    }
    // setup delegate
    AsyncCommDelegate* asyncCommDelegate = [[AsyncCommDelegate alloc] init];
    asyncCommDelegate->delegateCPP = macOSBluetoothConnector;
    // try to open channel
    macOSBluetoothConnector->running = true;
    IOReturn openResult = [device openRFCOMMChannelAsync:&channel withChannelID:rfcommChannelID delegate:asyncCommDelegate];
#ifdef SHC_DEBUG_PROTOCOL
    fprintf(stderr, "[connect] openRFCOMMChannelAsync -> 0x%x\n", openResult);
#endif
    if ( openResult != kIOReturnSuccess ) {
        macOSBluetoothConnector->running = false;
        RecoverableException exc = RecoverableException("Could not open the rfcomm.", false);
        std::exception_ptr excPtr = std::make_exception_ptr(exc);
        connectPromise.set_exception(excPtr);
        return;
    }
    // store the channel
    {
        std::lock_guard<std::mutex> g(macOSBluetoothConnector->channelMtx);
        macOSBluetoothConnector->rfcommchannel = (void*)CFBridgingRetain(channel);
    }
    macOSBluetoothConnector->protocolVersion = protocolVersion;

    // tell the other tread that we are done connecting
    connectPromise.set_value();

    // Park until disconnect. Every delegate callback (data and channel-closed) is delivered on
    // the main thread's run loop — this thread's run loop has no sources, so there is nothing
    // to pump here. This frame's `channel` reference keeps the RFCOMM channel alive for the
    // whole connection; the wait returns exactly once, when a running=false setter notifies.
    // Setters must store running=false while holding disconnectionMutex (see disconnect()),
    // or a notify landing between this predicate check and the block would be lost forever.
    std::unique_lock<std::mutex> lk(macOSBluetoothConnector->disconnectionMutex);
    macOSBluetoothConnector->disconnectionConditionVariable.wait(
        lk, [&]() { return !macOSBluetoothConnector->running; });

    lk.unlock();
}
void MacOSBluetoothConnector::connect(const std::string& addrStr){
    // Reconnects must reap the previous worker first. Assigning over a joinable std::thread terminates.
    if (uthread.joinable()) {
        disconnect();
    }
    // convert mac address to nsstring
    NSString *addressNSString = [NSString stringWithCString:addrStr.c_str() encoding:[NSString defaultCStringEncoding]];
    // get device based on mac address
    IOBluetoothDevice *device = [IOBluetoothDevice deviceWithAddressString:addressNSString];
    // if device is not connected
    if (![device isConnected]) {
        [device openConnection];
    }
    std::promise<void> connectPromise;
    std::future<void> connectFuture = connectPromise.get_future();

    // store the device in a variable
    rfcommDevice = (__bridge void*) device;
    uthread = std::thread(MacOSBluetoothConnector::connectToMac, this, std::move(connectPromise));
    
    // Wait until SDP lookup and the asynchronous open request have started. If setup fails, reap the
    // worker before propagating the exception so destruction cannot encounter a joinable thread.
    try {
        connectFuture.get();
    } catch (...) {
        // running=false must be stored under disconnectionMutex: connectToMac's untimed wait
        // would otherwise miss a notify racing its predicate check and never wake.
        {
            std::lock_guard<std::mutex> g(disconnectionMutex);
            running = false;
        }
        disconnectionConditionVariable.notify_all();
        receiveDataConditionVariable.notify_all();
        if (uthread.joinable()) uthread.join();
        throw;
    }
}

void MacOSBluetoothConnector::enqueueReceivedData(const unsigned char* data, size_t length)
{
    // A zero-length RFCOMM frame carries no message bytes; queuing it would make recv() return 0,
    // which BluetoothWrapper treats as a closed connection.
    if (length == 0) return;

    std::lock_guard<std::mutex> g(receiveDataMutex);
    receivedBytes.emplace_back(data, data + length);
    receivedBytesTotal += length;

    // Nothing drains the queue between command exchanges, so a flooding device would otherwise grow
    // it without bound. Drop the oldest chunks past the cap (never the newest one); the wrapper's
    // START/END marker scan resynchronizes on whatever survives.
    while (receivedBytesTotal > RECEIVE_BUFFER_CAP && receivedBytes.size() > 1) {
        receivedBytesTotal -= receivedBytes.front().size();
        receivedBytes.pop_front();
    }

    receiveDataConditionVariable.notify_one();
}

int MacOSBluetoothConnector::recv(char* buf, size_t length)
{
    // wait for newly received data, but time out so an unanswered inquiry (probing an unsupported
    // feature) or a dropped link doesn't block the caller forever.
    std::unique_lock<std::mutex> g(receiveDataMutex);
    bool gotData = receiveDataConditionVariable.wait_for(g, std::chrono::milliseconds(2500),
        [this]{ return !receivedBytes.empty() || !running; });
    if (!running && receivedBytes.empty()) {
        throw RecoverableException("Bluetooth connection closed", false);
    }
    if (!gotData || receivedBytes.empty()) {
        throw RecoverableException("recv timed out", false);
    }

    // fill the buf with the new data
    std::vector<unsigned char> receivedVector = receivedBytes.front();
    receivedBytes.pop_front();
    receivedBytesTotal -= receivedVector.size();

    size_t lengthCopied = std::min(length, receivedVector.size());

    // copy the first amount of bytes
    std::memcpy(buf, receivedVector.data(), lengthCopied);

    // too much data, save it for next time
    if (receivedVector.size() > length){
        receivedVector.erase(receivedVector.begin(), receivedVector.begin() + lengthCopied);
        receivedBytes.push_front(receivedVector);
        receivedBytesTotal += receivedVector.size();
    }

#ifdef SHC_DEBUG_PROTOCOL
    _debugHexDump("recv", buf, lengthCopied);
#endif

    return (int)lengthCopied;
}

SonyProtocolVersion MacOSBluetoothConnector::getProtocolVersion() noexcept
{
    return protocolVersion;
}

std::vector<BluetoothDevice> MacOSBluetoothConnector::getConnectedDevices()
{
    // create the output vector
    std::vector<BluetoothDevice> res;
    // List every paired device, not just ones macOS reports as connected: [isConnected] returns NO for
    // headsets connected only for audio/BLE (e.g. Sony ULT WEAR), which hid them from the picker. connect()
    // opens the RFCOMM link on demand, so a paired-but-"disconnected" device still works.
    for (IOBluetoothDevice* device in [IOBluetoothDevice pairedDevices]) {
        if (![device addressString]) continue;
        BluetoothDevice dev;
        dev.mac = [[device addressString] UTF8String];
        dev.name = [device name] ? [[device name] UTF8String] : "Unknown Device";
        res.push_back(dev);
    }
    
    return res;
}

void MacOSBluetoothConnector::disconnect() noexcept
{
    // running=false must be stored under disconnectionMutex: connectToMac's untimed wait
    // would otherwise miss a notify racing its predicate check and never wake.
    {
        std::lock_guard<std::mutex> g(disconnectionMutex);
        running = false;
    }
    disconnectionConditionVariable.notify_all();
    receiveDataConditionVariable.notify_all();
    closeConnection();

    if (uthread.joinable()) {
        // The delegate only calls handleChannelClosed(), but retain this guard so future callbacks cannot
        // accidentally reintroduce a self-join termination.
        if (uthread.get_id() == std::this_thread::get_id()) {
            uthread.detach();
        } else {
            uthread.join();
        }
    }

    std::lock_guard<std::mutex> g(receiveDataMutex);
    receivedBytes.clear();
    receivedBytesTotal = 0;
}
void MacOSBluetoothConnector::closeConnection() {
    // Only one close path owns the channel pointer. A remote-close callback clears it first.
    IOBluetoothRFCOMMChannel *chan = nil;
    {
        std::lock_guard<std::mutex> g(channelMtx);
        chan = (IOBluetoothRFCOMMChannel*)CFBridgingRelease(rfcommchannel);
        rfcommchannel = nullptr;
    }
    if (chan == nil) return;
    [chan setDelegate: nil];
    // close the channel
    [chan closeChannel];
}

void MacOSBluetoothConnector::handleChannelClosed() noexcept
{
    {
        std::lock_guard<std::mutex> g(channelMtx);
        if (rfcommchannel) CFRelease(rfcommchannel);
        rfcommchannel = nullptr;
    }
    // running=false must be stored under disconnectionMutex: connectToMac's untimed wait
    // would otherwise miss a notify racing its predicate check and never wake.
    {
        std::lock_guard<std::mutex> g(disconnectionMutex);
        running = false;
    }
    disconnectionConditionVariable.notify_all();
    receiveDataConditionVariable.notify_all();
}


bool MacOSBluetoothConnector::isConnected() noexcept
{
    if (!running)
        return false;
    std::lock_guard<std::mutex> g(channelMtx);
    IOBluetoothRFCOMMChannel *chan = (__bridge IOBluetoothRFCOMMChannel*)rfcommchannel;
    return chan != nil && chan.isOpen;
}
