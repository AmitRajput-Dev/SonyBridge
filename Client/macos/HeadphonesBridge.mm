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

@implementation HeadphonesBridge {
    std::unique_ptr<BluetoothWrapper> _bt;
    // Queued operations retain the current device state so disconnecting cannot invalidate a raw pointer
    // while a Bluetooth read or write is still completing.
    std::shared_ptr<Headphones> _hp;
    NSString *_deviceName;
    NSString *_deviceMac;
    std::atomic_bool _initialized;
    // All device I/O runs on this serial queue. Bluetooth commands are stateful, and serializing reads with
    // writes also prevents a slow capability probe from racing a user action or dynamic refresh.
    dispatch_queue_t _cmdQueue;
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
- (BOOL)hasMultipoint { return _hp && _hp->hasMultipoint(); }
- (BOOL)multipoint { return _hp && _hp->getMultipoint(); }

static BOOL SHCLooksLikeSonyHeadset(NSString *name) {
    if (name.length == 0) return NO;
    NSArray<NSString *> *prefixes = @[@"WH-", @"WF-", @"WI-", @"MDR-", @"XB", @"LinkBuds"];
    for (NSString *p in prefixes) {
        if ([name hasPrefix:p] || [name containsString:p]) return YES;
    }
    return NO;
}

- (void)scanAndConnectWithCompletion:(void (^)(BOOL, NSString * _Nullable))completion {
    // Prefer the already system-connected Sony headset (Sony-app "My Device" behaviour) and skip the
    // native picker, which shows a confusing empty list when nothing is connected.
    IOBluetoothDevice *device = nil;
    for (IOBluetoothDevice *paired in [IOBluetoothDevice pairedDevices]) {
        if ([paired isConnected] && SHCLooksLikeSonyHeadset([paired name])) {
            device = paired;
            break;
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

        // ...then the optional-feature probes, which can each take a couple seconds to time out on a
        // device that doesn't support them. Update the UI again once they've settled.
        try { hp->probeCapabilities(); } catch (std::exception &exc) {}
        dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
    });
}

- (void)refreshDynamicWithCompletion:(void (^)(void))completion {
    if (!_hp || !self.connected) { completion(); return; }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        // The headphone's physical button only changes ambient/NC, so that's all we poll (keeps traffic low).
        // requestAmbientState() is protocol-aware (v2 uses 66 17, v1 uses 66 02), so this is safe on both.
        try { hp->requestAmbientState(); } catch (std::exception &exc) {}
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

@end
