//
//  HeadphonesBridge.mm
//  Obj-C++ implementation owning the C++ core. Mirrors the connect/apply flow the old ViewController had.
//

#import "HeadphonesBridge.h"
#import <IOBluetoothUI/IOBluetoothUI.h>
#import <IOBluetooth/IOBluetooth.h>

#include <memory>
#include "MacOSBluetoothConnector.h"
#include "BluetoothWrapper.h"
#include "Headphones.h"
// RecoverableException comes in transitively via BluetoothWrapper.h -> IBluetoothConnector.h -> Exceptions.h.
// (Exceptions.h isn't a project file reference, so it can't be #included directly from this directory.)

@implementation HeadphonesBridge {
    std::unique_ptr<BluetoothWrapper> _bt;
    std::unique_ptr<Headphones> _hp;
    NSString *_deviceName;
    NSString *_deviceMac;
    BOOL _initialized;
    // All user-initiated commands run on this SERIAL queue so quick successive taps reach the device in
    // order (a concurrent queue let them race and land out of order).
    dispatch_queue_t _cmdQueue;
}

- (instancetype)init {
    if ((self = [super init])) {
        _bt = std::make_unique<BluetoothWrapper>(std::make_unique<MacOSBluetoothConnector>());
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
    if (self.connected && _bt->getProtocolVersion() == SonyProtocolVersion::V2) return 20;
    return 19;
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
    return self.connected && _bt->getProtocolVersion() == SonyProtocolVersion::V2;
}

- (NSInteger)clearBass {
    return _hp ? _hp->getClearBass() : 0;
}

- (BOOL)dsee {
    return _hp ? _hp->getDsee() : NO;
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

    try {
        _bt->connect([[device addressString] UTF8String]);
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
    _hp = std::make_unique<Headphones>(*_bt);
    completion(YES, nil);
}

- (void)disconnect {
    if (_bt) _bt->disconnect();
    _hp.reset();
    _deviceName = nil;
    _deviceMac = nil;
    _initialized = NO;
}

- (void)refreshStatusWithCompletion:(void (^)(void))completion {
    if (!_hp || !self.connected) { completion(); return; }
    Headphones *hp = _hp.get();
    // CRITICAL: the init/battery/EQ inquiries below use v2 opcodes. Opcode 0x22 is BATTERY_LEVEL_REQUEST
    // on v2 but POWER_OFF on v1 - sending it to a v1 device (e.g. WH-1000XM4) powers the headphones off.
    // A v1 device still needs *some* valid handshake traffic right after connect or it drops/powers off on
    // its own, so read its ambient state (read-only 66 02) instead of sending nothing.
    if (_bt->getProtocolVersion() != SonyProtocolVersion::V2) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            try { hp->requestAmbientState(); } catch (std::exception &exc) {}
            dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
        });
        return;
    }
    // Reads run on the global queue (not the serial command queue) so they don't block quick user taps;
    // per-call the connector mutex still serializes actual I/O.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Fast, always-supported reads first, then update the UI immediately...
        try {
            if (!self->_initialized) {
                hp->initDevice();
                self->_initialized = YES;
            }
            hp->requestBattery();
            hp->requestEqualizer();
            hp->requestDsee();
        } catch (std::exception &exc) {}
        dispatch_async(dispatch_get_main_queue(), ^{ completion(); });

        // ...then the optional-feature probes, which can each take a couple seconds to time out on a
        // device that doesn't support them. Update the UI again once they've settled.
        try { hp->probeCapabilities(); } catch (std::exception &exc) {}
        dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
    });
}

- (void)refreshDynamicWithCompletion:(void (^)(void))completion {
    if (!_hp || !self.connected) { completion(); return; }
    Headphones *hp = _hp.get();
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
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
    // The v2 EQ SET opcode differs from v1; only issue it on confirmed v2 devices.
    if (_bt->getProtocolVersion() != SonyProtocolVersion::V2) {
        completion(NO, @"Equalizer control isn't supported on this device yet.");
        return;
    }
    Headphones *hp = _hp.get();
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
    if (!_hp || !self.connected || _bt->getProtocolVersion() != SonyProtocolVersion::V2) {
        completion(NO, @"Equalizer control isn't supported on this device yet.");
        return;
    }
    std::vector<int> cbands;
    for (NSNumber *n in bands) cbands.push_back((int)n.integerValue);
    int cbass = (int)bass;
    Headphones *hp = _hp.get();
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil; BOOL ok = YES;
        try {
            hp->setEqualizerCustom(cbass, cbands);
        } catch (std::exception &exc) { ok = NO; error = @(exc.what()); }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
    });
}

- (void)setDsee:(BOOL)enabled completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected || _bt->getProtocolVersion() != SonyProtocolVersion::V2) {
        completion(NO, @"Not supported on this device.");
        return;
    }
    Headphones *hp = _hp.get();
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

    switch (mode) {
        case SHCAmbientModeOff:
            _hp->setAmbientSoundControl(false);
            break;
        case SHCAmbientModeNoiseCanceling:
            _hp->setAmbientSoundControl(true);
            _hp->setAsmLevel(0);
            _hp->setFocusOnVoice(false);
            break;
        case SHCAmbientModeAmbientSound:
            _hp->setAmbientSoundControl(true);
            _hp->setAsmLevel((int)MAX(level, 1));
            _hp->setFocusOnVoice(focusVoice);
            break;
    }

    Headphones *hp = _hp.get();
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil;
        BOOL ok = YES;
        try {
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
    Headphones *hp = _hp.get();
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil; BOOL ok = YES;
        try { hp->setAutoPowerOff((int)index); } catch (std::exception &exc) { ok = NO; error = @(exc.what()); }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
    });
}

- (void)setSpeakToChat:(BOOL)enabled completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected) { completion(NO, @"Not connected."); return; }
    Headphones *hp = _hp.get();
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil; BOOL ok = YES;
        try { hp->setSpeakToChat(enabled); } catch (std::exception &exc) { ok = NO; error = @(exc.what()); }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
    });
}

- (void)setAdaptiveVolume:(BOOL)enabled completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected) { completion(NO, @"Not connected."); return; }
    Headphones *hp = _hp.get();
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil; BOOL ok = YES;
        try { hp->setAdaptiveVolume(enabled); } catch (std::exception &exc) { ok = NO; error = @(exc.what()); }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
    });
}

@end
