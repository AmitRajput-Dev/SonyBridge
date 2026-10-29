//
//  HeadphonesBridge.mm
//  Obj-C++ implementation owning the C++ core. Mirrors the connect/apply flow the old ViewController had.
//

#import "HeadphonesBridge.h"
#import <IOBluetoothUI/IOBluetoothUI.h>
#import <IOBluetooth/IOBluetooth.h>

#include <atomic>
#include <memory>
#include "MacOSBluetoothConnector.h"
#include "BluetoothWrapper.h"
#include "Headphones.h"
// RecoverableException comes in transitively via BluetoothWrapper.h -> IBluetoothConnector.h -> Exceptions.h.
// (Exceptions.h isn't a project file reference, so it can't be #included directly from this directory.)

// The dynamic poll fires every 2s; re-read the battery every 15th tick (~30s), which is far more often
// than a headphone battery meaningfully moves but cheap enough not to crowd out the ambient/NC polling.
static const unsigned kBatteryPollEveryNTicks = 15;

@interface SHCPairedDevice ()
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSString *address;
@property (nonatomic, readwrite) NSInteger slot;
@property (nonatomic, readwrite) NSInteger classOfDevice;
@property (nonatomic, readwrite) BOOL playback;
@property (nonatomic, readwrite) BOOL isThisMac;
@end

@implementation SHCPairedDevice
@end

// IOBluetooth formats addresses as "aa-bb-cc-dd-ee-ff"; the headset reports "AA:BB:CC:DD:EE:FF".
static NSString *SHCNormalizedAddress(NSString *address) {
    return [[address uppercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@":"];
}

@implementation HeadphonesBridge {
    std::unique_ptr<BluetoothWrapper> _bt;
    // Queued operations retain the current device state so disconnecting cannot invalidate a raw pointer
    // while a Bluetooth read or write is still completing.
    std::shared_ptr<Headphones> _hp;
    NSString *_deviceName;
    NSString *_deviceMac;
    std::atomic_bool _initialized;
    // Only touched inside blocks on _cmdQueue, which is serial.
    unsigned _dynamicTick;
    // All device I/O runs on this serial queue. Bluetooth commands are stateful, and serializing reads with
    // writes also prevents a slow capability probe from racing a user action or dynamic refresh.
    dispatch_queue_t _cmdQueue;
    IOBluetoothUserNotification *_connectNotification;
    void (^_headsetConnectedHandler)(void);
}

- (instancetype)init {
    if ((self = [super init])) {
        _bt = std::make_unique<BluetoothWrapper>(std::make_unique<MacOSBluetoothConnector>());
        _initialized = false;
        _cmdQueue = dispatch_queue_create("com.sonybridge.commands", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)connected {
    return _bt && _bt->isConnected();
}

- (nullable NSString *)deviceName {
    return _deviceName;
}

- (nullable NSString *)deviceMac {
    return _deviceMac;
}

- (nullable NSString *)protocolVersionString {
    if (!self.connected) return nil;
    return _bt->getProtocolVersion() == SonyProtocolVersion::V2 ? @"v2" : @"v1";
}

- (BOOL)supportsVpt {
    if (!self.connected) return NO;
    return _bt->getProtocolVersion() == SonyProtocolVersion::V1;
}

- (NSInteger)maxAmbientLevel {
    return 20;
}

- (SHCAmbientMode)mode {
    if (!_hp) return SHCAmbientModeOff;
    if (!_hp->getAmbientSoundControl()) return SHCAmbientModeOff;
    return _hp->getAsmLevel() > 0 ? SHCAmbientModeAmbientSound : SHCAmbientModeNoiseCanceling;
}

- (NSInteger)ambientLevel {
    return _hp ? _hp->getAsmLevel() : 0;
}

- (BOOL)focusOnVoice {
    return _hp ? _hp->getFocusOnVoice() : NO;
}

- (BOOL)focusOnVoiceAvailable {
    return _hp ? _hp->isFocusOnVoiceAvailable() : NO;
}

- (NSInteger)batteryLevel {
    return _hp ? _hp->getBatteryLevel() : -1;
}

- (BOOL)batteryCharging {
    return _hp ? _hp->isBatteryCharging() : NO;
}

- (BOOL)hasDualBattery { return _hp && _hp->hasDualBattery(); }
- (NSInteger)batteryLeft { return _hp ? _hp->getBatteryLeft() : -1; }
- (NSInteger)batteryRight { return _hp ? _hp->getBatteryRight() : -1; }
- (NSInteger)batteryCase { return _hp ? _hp->getBatteryCase() : -1; }
- (BOOL)batteryLeftCharging { return _hp && _hp->isBatteryLeftCharging(); }
- (BOOL)batteryRightCharging { return _hp && _hp->isBatteryRightCharging(); }
- (BOOL)batteryCaseCharging { return _hp && _hp->isBatteryCaseCharging(); }

- (NSInteger)eqPreset {
    return _hp ? (NSInteger)_hp->getEqualizerPreset() : 0;
}

- (BOOL)supportsEqualizer {
    return _hp && _hp->hasEqualizer();
}

- (NSInteger)clearBass {
    return _hp ? _hp->getClearBass() : 0;
}

- (BOOL)dsee {
    return _hp ? _hp->getDsee() : NO;
}

- (BOOL)supportsDsee {
    return _hp && _hp->hasDsee();
}

- (NSInteger)equalizerBandCount {
    return _hp ? _hp->getEqualizerBandCount() : 5;
}

- (BOOL)tenBandEqualizer {
    return _hp && _hp->isTenBandEqualizer();
}

- (NSInteger)equalizerBandAtIndex:(NSInteger)index {
    return _hp ? _hp->getEqualizerBand((int)index) : 0;
}

- (BOOL)hasAutoPowerOff { return _hp && _hp->hasAutoPowerOff(); }
- (NSInteger)autoPowerOff { return _hp ? _hp->getAutoPowerOff() : 0; }
- (BOOL)hasFirmware { return _hp && _hp->hasFirmware(); }
- (nullable NSString *)firmware { return _hp ? @(_hp->getFirmware().c_str()) : nil; }
- (BOOL)hasCodec { return _hp && _hp->hasCodec(); }
- (nullable NSString *)codec { return _hp ? @(_hp->getCodec().c_str()) : nil; }
- (BOOL)hasSpeakToChat { return _hp && _hp->hasSpeakToChat(); }
- (BOOL)speakToChat { return _hp && _hp->getSpeakToChat(); }
- (BOOL)hasAdaptiveVolume { return _hp && _hp->hasAdaptiveVolume(); }
- (BOOL)adaptiveVolume { return _hp && _hp->getAdaptiveVolume(); }

- (BOOL)hasPairedDevices { return _hp && _hp->hasPairedDevices(); }
- (BOOL)hasPlaybackPinState { return _hp && _hp->hasPlaybackPinState(); }
- (BOOL)playbackPinned { return _hp && _hp->isPlaybackPinned(); }
- (BOOL)hasMultipointSetting { return _hp && _hp->hasMultipointSetting(); }
- (BOOL)multipointEnabled { return _hp && _hp->getMultipointEnabled(); }
- (BOOL)hasTouchPanelSetting { return _hp && _hp->hasTouchPanelSetting(); }
- (BOOL)touchPanelEnabled { return _hp && _hp->getTouchPanelEnabled(); }
- (NSString *)multipointDiagnostics { return _hp ? @(_hp->getMultipointDiagnostics().c_str()) : @""; }

- (NSArray<SHCPairedDevice *> *)pairedDevices {
    if (!_hp) return @[];
    NSString *hostAddress = SHCNormalizedAddress([[IOBluetoothHostController defaultController] addressAsString] ?: @"");
    NSMutableArray<SHCPairedDevice *> *result = [NSMutableArray array];
    for (const auto &device : _hp->getPairedDevices()) {
        SHCPairedDevice *item = [SHCPairedDevice new];
        // Names are UTF-8 as far as we know; fall back to Latin-1 so a bad byte can't drop the row.
        NSString *name = [[NSString alloc] initWithBytes:device.name.data() length:device.name.size() encoding:NSUTF8StringEncoding]
            ?: [[NSString alloc] initWithBytes:device.name.data() length:device.name.size() encoding:NSISOLatin1StringEncoding];
        item.name = name ?: @"";
        item.address = SHCNormalizedAddress(@(device.address.c_str()));
        item.slot = device.slot;
        item.classOfDevice = device.classOfDevice;
        item.playback = device.playback;
        item.isThisMac = hostAddress.length > 0 && [item.address isEqualToString:hostAddress];
        [result addObject:item];
    }
    return result;
}

static BOOL SHCLooksLikeSonyHeadset(NSString *name) {
    if (name.length == 0) return NO;
    NSArray<NSString *> *prefixes = @[@"WH-", @"WF-", @"WI-", @"MDR-", @"XB", @"LinkBuds", @"ULT"];
    for (NSString *p in prefixes) {
        if ([name hasPrefix:p] || [name containsString:p]) return YES;
    }
    return NO;
}

// A user-renamed headset (e.g. "Birdie") fails the name check, so also accept any paired device whose
// cached SDP records advertise either Sony control service - the same lookup connect() relies on.
static BOOL SHCHasSonyService(IOBluetoothDevice *device) {
    IOBluetoothSDPUUID *v1 = [IOBluetoothSDPUUID uuidWithBytes:(void*)SERVICE_UUID_IN_BYTES length:16];
    IOBluetoothSDPUUID *v2 = [IOBluetoothSDPUUID uuidWithBytes:(void*)SERVICE_UUID_V2_IN_BYTES length:16];
    return [device getServiceRecordForUUID:v1] != nil || [device getServiceRecordForUUID:v2] != nil;
}

static BOOL SHCIsSonyHeadset(IOBluetoothDevice *device) {
    return SHCLooksLikeSonyHeadset([device name]) || SHCHasSonyService(device);
}

// The same test scanAndConnect's first pass uses, so a connect made because this said YES never falls
// through to the device picker.
- (BOOL)hasConnectedSonyHeadset {
    for (IOBluetoothDevice *paired in [IOBluetoothDevice pairedDevices]) {
        if ([paired isConnected] && SHCIsSonyHeadset(paired)) return YES;
    }
    return NO;
}

- (void)watchForHeadsetConnections:(void (^)(void))handler {
    _headsetConnectedHandler = [handler copy];
    if (!_connectNotification) {
        _connectNotification = [IOBluetoothDevice registerForConnectNotifications:self
                                                                         selector:@selector(bluetoothDeviceConnected:device:)];
    }
}

// Any Bluetooth device connecting to the Mac (delivered on the main run loop); only Sony headsets count.
- (void)bluetoothDeviceConnected:(IOBluetoothUserNotification *)notification device:(IOBluetoothDevice *)device {
    if (_headsetConnectedHandler && SHCIsSonyHeadset(device)) _headsetConnectedHandler();
}

- (void)scanAndConnectWithCompletion:(void (^)(BOOL, NSString * _Nullable))completion {
    // Prefer the already system-connected Sony headset (Sony-app "My Device" behaviour) and skip the
    // native picker, which shows a confusing empty list when nothing is connected.
    IOBluetoothDevice *device = nil;
    for (IOBluetoothDevice *paired in [IOBluetoothDevice pairedDevices]) {
        if ([paired isConnected] && SHCIsSonyHeadset(paired)) {
            device = paired;
            break;
        }
    }
    // BLE/audio-only headsets (e.g. ULT WEAR) report isConnected == NO; fall back to any paired Sony headset.
    if (!device) {
        for (IOBluetoothDevice *paired in [IOBluetoothDevice pairedDevices]) {
            if (SHCIsSonyHeadset(paired)) {
                device = paired;
                break;
            }
        }
    }

    if (!device) {
        // Fall back to the native picker if we can't auto-identify a connected Sony device.
        IOBluetoothDeviceSelectorController *selector = [IOBluetoothDeviceSelectorController deviceSelector];
        if ([selector runModal] != kIOBluetoothUISuccess) {
            completion(NO, nil); // user cancelled - not an error
            return;
        }
        device = [[selector getResults] lastObject];
    }

    if (!device) {
        completion(NO, @"No connected Sony headset found. Connect your headphones in macOS Bluetooth settings first.");
        return;
    }

    // A device without an address string would hand std::string a null char* below (undefined
    // behaviour); getConnectedDevices() applies the same guard.
    NSString *address = [device addressString];
    if (!address) {
        completion(NO, @"The selected device has no Bluetooth address.");
        return;
    }

    try {
        _bt->connect([address UTF8String]);
    } catch (RecoverableException &exc) {
        completion(NO, @(exc.what()));
        return;
    }

    // A real RFCOMM open (SDP + link setup, sometimes with encryption renegotiation) can take a few
    // seconds; pump the run loop until it lands or we give up.
    int timeout = 80;
    while (!_bt->isConnected() && timeout >= 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        timeout--;
    }

    if (!_bt->isConnected()) {
        _bt->disconnect();
        completion(NO, @"Connection timed out.");
        return;
    }

    _deviceName = [device nameOrAddress];
    _deviceMac = [device addressString];
    _hp = std::make_shared<Headphones>(*_bt);
    // Lets requestBattery() probe the per-earbud layout first on TWS models (WF-*/LinkBuds).
    _hp->setDeviceName(_deviceName ? [_deviceName UTF8String] : "");
    // A link the headset dropped on its own never went through -disconnect, so reset here: every new
    // Headphones needs the init handshake (its reply also gates the multipoint reads).
    _initialized = false;
    completion(YES, nil);
}

- (void)disconnect {
    if (_bt) _bt->disconnect();
    _hp.reset();
    _deviceName = nil;
    _deviceMac = nil;
    _initialized = false;
}

- (void)refreshStatusWithCompletion:(void (^)(void))completion {
    if (!_hp || !self.connected) { completion(); return; }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        // Every method chooses its command family from the SDP-confirmed protocol version. This is
        // essential for v1: 0x22 powers off an XM4 but requests battery state on v2.
        if (!self->_initialized.load()) {
            try { hp->initDevice(); self->_initialized = true; } catch (std::exception &exc) {}
        }
        try { hp->requestAmbientState(); } catch (std::exception &exc) {}
        try { hp->requestBattery(); } catch (std::exception &exc) {}
        try { hp->requestEqualizer(); } catch (std::exception &exc) {}
        try { hp->requestDsee(); } catch (std::exception &exc) {}
        dispatch_async(dispatch_get_main_queue(), ^{ completion(); });

        // ...then the optional-feature probes and the multipoint discovery (its general-settings slot search),
        // which can each take a couple seconds to time out on a device that doesn't support them. Update the
        // UI again once they've settled. requestMultipoint() is a no-op on v1.
        try { hp->probeCapabilities(); } catch (std::exception &exc) {}
        try { hp->requestMultipoint(); } catch (std::exception &exc) {}
        dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
    });
}

- (void)refreshMultipointWithCompletion:(void (^)(void))completion {
    // GETs only. On v1 that's just the general-settings reads (function list, d0, d6), captured from an XM4.
    if (!_hp || !self.connected || !_initialized.load()) {
        completion();
        return;
    }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        try { hp->requestMultipoint(); } catch (std::exception &exc) {}
        dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
    });
}

static NSString *_Nullable SHCSourceSwitchError(int result) {
    switch (result) {
        case V2Table2Command::RESULT_SUCCESS: return nil;
        case V2Table2Command::RESULT_FAIL_CALLING: return @"The headset refused: a call is in progress.";
        case V2Table2Command::RESULT_FAIL_A2DP_NOT_CONNECTED: return @"The headset refused: that device isn't connected for audio.";
        case V2Table2Command::RESULT_FAIL_VOICE_ASSISTANT: return @"The headset refused: the voice assistant has priority.";
        case V2Table2Command::RESULT_NO_CONFIRMATION: return @"The headset didn't confirm the change. Showing the state it reports now.";
        default: return [NSString stringWithFormat:@"The headset refused the change (result %d).", result];
    }
}

- (void)runMultipointWrite:(int (^)(Headphones *hp))write completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected || _bt->getProtocolVersion() != SonyProtocolVersion::V2 || !_initialized.load()) {
        completion(NO, @"Not connected.");
        return;
    }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil;
        try {
            error = SHCSourceSwitchError(write(hp.get()));
        } catch (std::exception &exc) {
            error = @(exc.what());
        }
        try { hp->requestMultipoint(); } catch (std::exception &exc) {}
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error == nil, error); });
    });
}

- (void)switchPlaybackToAddress:(NSString *)address fix:(BOOL)fix completion:(void (^)(BOOL, NSString * _Nullable))completion {
    std::string target = address.UTF8String ?: "";
    [self runMultipointWrite:^int(Headphones *hp) {
        // Decide from the state as of this queued write, not the tap: a poll or the phone may have moved
        // playback in between, and a stale "already playing" would fix playback to the wrong device.
        bool alreadyPlaying = false;
        for (const auto &device : hp->getPairedDevices()) {
            if (device.playback && strcasecmp(device.address.c_str(), target.c_str()) == 0) alreadyPlaying = true;
        }
        bool pinned = hp->isPlaybackPinned();
        if (!fix) {
            // The headset keeps "fixed" on across a switch (the fix moves to the new device), so a plain
            // switch frees it afterwards. A refused switch leaves the fix untouched.
            int result = hp->switchPlaybackDevice(target);
            if (result != V2Table2Command::RESULT_SUCCESS || !pinned) return result;
            return hp->setPlaybackPinned(false);
        }
        // A fixed playback device may refuse a switch, so free it first.
        BOOL unfixed = NO;
        if (pinned && !alreadyPlaying) {
            int result = hp->setPlaybackPinned(false);
            if (result != V2Table2Command::RESULT_SUCCESS) return result;
            unfixed = YES;
        }
        if (!alreadyPlaying) {
            int result = hp->switchPlaybackDevice(target);
            if (result != V2Table2Command::RESULT_SUCCESS) {
                // Don't leave the old device unfixed after a refused switch (e.g. mid-call).
                if (unfixed) hp->setPlaybackPinned(true);
                return result;
            }
        }
        return hp->setPlaybackPinned(true);
    } completion:completion];
}

- (void)setPlaybackPinned:(BOOL)pinned completion:(void (^)(BOOL, NSString * _Nullable))completion {
    [self runMultipointWrite:^int(Headphones *hp) {
        return hp->setPlaybackPinned(pinned);
    } completion:completion];
}

- (void)refreshDynamicWithCompletion:(void (^)(void))completion {
    if (!_hp || !self.connected) { completion(); return; }
    auto hp = _hp;
    BOOL isV2 = _bt->getProtocolVersion() == SonyProtocolVersion::V2;
    dispatch_async(_cmdQueue, ^{
        // The headphone's physical button only changes ambient/NC, so that's all we poll (keeps traffic low).
        // requestAmbientState() is protocol-aware (v2 uses 66 17, v1 uses 66 02), so this is safe on both.
        try { hp->requestAmbientState(); } catch (std::exception &exc) {}
        // Battery drains, earbuds get docked and the case charges them, so re-read it too - but only
        // every Nth poll, since it costs up to three inquiries on TWS. v2 only: 0x22 is POWER_OFF on v1.
        if (isV2 && self->_dynamicTick++ % kBatteryPollEveryNTicks == 0) {
            try { hp->requestBattery(); } catch (std::exception &exc) {}
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
    });
}

- (void)setEqualizerPreset:(NSInteger)preset completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected) {
        completion(NO, @"Not connected.");
        return;
    }
    if (!_hp->hasEqualizer()) {
        completion(NO, @"Equalizer control isn't supported on this device yet.");
        return;
    }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil;
        BOOL ok = YES;
        try {
            hp->setEqualizerPreset(static_cast<EQ_PRESET>((unsigned char)preset));
        } catch (std::exception &exc) {
            ok = NO;
            error = @(exc.what());
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(ok, error);
        });
    });
}

- (void)setCustomEqualizerBass:(NSInteger)bass bands:(NSArray<NSNumber *> *)bands completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected || !_hp->hasEqualizer()) {
        completion(NO, @"Equalizer control isn't supported on this device yet.");
        return;
    }
    std::vector<int> cbands;
    for (NSNumber *n in bands) cbands.push_back((int)n.integerValue);
    int cbass = (int)bass;
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil; BOOL ok = YES;
        try {
            hp->setEqualizerCustom(cbass, cbands);
        } catch (std::exception &exc) { ok = NO; error = @(exc.what()); }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
    });
}

- (void)setDsee:(BOOL)enabled completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected || !_hp->hasDsee()) {
        completion(NO, @"Not supported on this device.");
        return;
    }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil; BOOL ok = YES;
        try {
            hp->setDsee(enabled);
        } catch (std::exception &exc) { ok = NO; error = @(exc.what()); }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
    });
}

- (void)applyMode:(SHCAmbientMode)mode
            level:(NSInteger)level
       focusVoice:(BOOL)focusVoice
       completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected) {
        completion(NO, @"Not connected.");
        return;
    }

    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil;
        BOOL ok = YES;
        try {
            switch (mode) {
                case SHCAmbientModeOff:
                    hp->setAmbientSoundControl(false);
                    break;
                case SHCAmbientModeNoiseCanceling:
                    hp->setAmbientSoundControl(true);
                    hp->setAsmLevel(0);
                    hp->setFocusOnVoice(false);
                    break;
                case SHCAmbientModeAmbientSound:
                    hp->setAmbientSoundControl(true);
                    hp->setAsmLevel((int)MAX(level, 1));
                    hp->setFocusOnVoice(focusVoice);
                    break;
            }
            if (hp->isChanged()) hp->setChanges();
        } catch (RecoverableException &exc) {
            ok = NO;
            error = @(exc.what());
        } catch (std::exception &exc) {
            ok = NO;
            error = @(exc.what());
        }
        // The write never landed, so stop it counting as pending - otherwise the ambient read-back stays
        // suppressed and the UI freezes on a value the headphones never took.
        if (!ok) hp->discardAmbientChanges();
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(ok, error);
        });
    });
}

- (void)setAutoPowerOff:(NSInteger)index completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected) { completion(NO, @"Not connected."); return; }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil; BOOL ok = YES;
        try { hp->setAutoPowerOff((int)index); } catch (std::exception &exc) { ok = NO; error = @(exc.what()); }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
    });
}

- (void)setSpeakToChat:(BOOL)enabled completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected) { completion(NO, @"Not connected."); return; }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil; BOOL ok = YES;
        try { hp->setSpeakToChat(enabled); } catch (std::exception &exc) { ok = NO; error = @(exc.what()); }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
    });
}

- (void)setAdaptiveVolume:(BOOL)enabled completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected) { completion(NO, @"Not connected."); return; }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil; BOOL ok = YES;
        try { hp->setAdaptiveVolume(enabled); } catch (std::exception &exc) { ok = NO; error = @(exc.what()); }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
    });
}

- (void)setMultipoint:(BOOL)enabled completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected) { completion(NO, @"Not connected."); return; }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil; BOOL ok = YES;
        try { hp->setMultipoint(enabled); } catch (std::exception &exc) { ok = NO; error = @(exc.what()); }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
    });
}

- (void)setTouchPanel:(BOOL)enabled completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected) { completion(NO, @"Not connected."); return; }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil; BOOL ok = YES;
        try { hp->setTouchPanel(enabled); } catch (std::exception &exc) { ok = NO; error = @(exc.what()); }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
    });
}

@end
