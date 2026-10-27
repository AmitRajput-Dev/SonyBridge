//
//  HeadphonesBridge.h
//  Pure Objective-C interface over the C++ BluetoothWrapper/Headphones core so SwiftUI can drive it
//  through the bridging header. No C++ types leak into this header.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SHCAmbientMode) {
    SHCAmbientModeOff = 0,
    SHCAmbientModeNoiseCanceling = 1,
    SHCAmbientModeAmbientSound = 2,
};

// One entry of the headset's paired-device list (multipoint).
@interface SHCPairedDevice : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *address;      // "XX:XX:XX:XX:XX:XX"
@property (nonatomic, readonly) NSInteger slot;               // 0 = paired only, 1/2 = connected
@property (nonatomic, readonly) NSInteger classOfDevice;      // 24-bit Bluetooth CoD, -1 if not reported
@property (nonatomic, readonly) BOOL playback;                // holds the playback right
@property (nonatomic, readonly) BOOL isThisMac;
@end

@interface HeadphonesBridge : NSObject

@property (nonatomic, readonly) BOOL connected;
@property (nonatomic, copy, readonly, nullable) NSString *deviceName;
@property (nonatomic, copy, readonly, nullable) NSString *deviceMac;
@property (nonatomic, copy, readonly, nullable) NSString *protocolVersionString; // "v1" / "v2"

// Only meaningful while connected.
@property (nonatomic, readonly) BOOL supportsVpt;        // v1 protocol devices only
@property (nonatomic, readonly) NSInteger maxAmbientLevel; // 1...20 on supported devices

// Current on-device state, mirrored from the last successful command.
@property (nonatomic, readonly) SHCAmbientMode mode;
@property (nonatomic, readonly) NSInteger ambientLevel;
@property (nonatomic, readonly) BOOL focusOnVoice;
@property (nonatomic, readonly) BOOL focusOnVoiceAvailable;

@property (nonatomic, readonly) NSInteger batteryLevel;   // -1 until known
@property (nonatomic, readonly) BOOL batteryCharging;
@property (nonatomic, readonly) BOOL hasDualBattery;      // TWS earbuds
@property (nonatomic, readonly) NSInteger batteryLeft;    // -1 if n/a
@property (nonatomic, readonly) NSInteger batteryRight;
@property (nonatomic, readonly) NSInteger batteryCase;
@property (nonatomic, readonly) BOOL batteryLeftCharging;
@property (nonatomic, readonly) BOOL batteryRightCharging;
@property (nonatomic, readonly) BOOL batteryCaseCharging;
@property (nonatomic, readonly) NSInteger eqPreset;       // raw preset byte (EQ_PRESET)
@property (nonatomic, readonly) BOOL supportsEqualizer;   // true after a successful read-only probe
@property (nonatomic, readonly) NSInteger clearBass;      // -10..10
@property (nonatomic, readonly) NSInteger equalizerBandCount; // 5, or 10 on the ten-band layout
@property (nonatomic, readonly) BOOL tenBandEqualizer;   // WH-1000XM6: raw 0..12 bands, no clear bass
@property (nonatomic, readonly) BOOL supportsDsee;        // true after a successful read-only probe
@property (nonatomic, readonly) BOOL dsee;                // DSEE / audio upsampling

// Optional features (present only if the device answered the capability probe on connect).
@property (nonatomic, readonly) BOOL hasAutoPowerOff;
@property (nonatomic, readonly) NSInteger autoPowerOff;   // 0=Off,1=5m,2=30m,3=1h,4=3h,5=when taken off
@property (nonatomic, readonly) BOOL hasFirmware;
@property (nonatomic, copy, readonly, nullable) NSString *firmware;
@property (nonatomic, readonly) BOOL hasCodec;
@property (nonatomic, copy, readonly, nullable) NSString *codec;
@property (nonatomic, readonly) BOOL hasSpeakToChat;
@property (nonatomic, readonly) BOOL speakToChat;
@property (nonatomic, readonly) BOOL hasAdaptiveVolume;
@property (nonatomic, readonly) BOOL adaptiveVolume;

// Multipoint (v2 devices that answered the reads on connect or on refreshMultipoint).
@property (nonatomic, readonly) BOOL hasPairedDevices;
@property (nonatomic, copy, readonly) NSArray<SHCPairedDevice *> *pairedDevices;
@property (nonatomic, readonly) BOOL hasPlaybackPinState;
@property (nonatomic, readonly) BOOL playbackPinned;
@property (nonatomic, readonly) BOOL hasMultipointSetting;
@property (nonatomic, readonly) BOOL multipointEnabled;
@property (nonatomic, copy, readonly) NSString *multipointDiagnostics; // hex log of the last multipoint reads

// Runs the native Bluetooth device picker (modal, main thread) and connects to the chosen device.
// completion is called on the main thread.
- (void)scanAndConnectWithCompletion:(void (^)(BOOL ok, NSString * _Nullable error))completion;

- (void)disconnect;

// Pushes the desired ambient/NC state to the device on a background thread; completion on main thread.
- (void)applyMode:(SHCAmbientMode)mode
            level:(NSInteger)level
       focusVoice:(BOOL)focusVoice
       completion:(void (^)(BOOL ok, NSString * _Nullable error))completion;

// Runs the init handshake (once) then reads battery + equalizer on a background thread; completion on main.
- (void)refreshStatusWithCompletion:(void (^)(void))completion;

// Pushes an equalizer preset (raw EQ_PRESET byte) to the device; completion on main.
- (void)setEqualizerPreset:(NSInteger)preset completion:(void (^)(BOOL ok, NSString * _Nullable error))completion;

// Current custom EQ band value (-10..10) for band 0..4.
- (NSInteger)equalizerBandAtIndex:(NSInteger)index;

// Pushes manual/custom EQ (clear bass + 5 bands, each -10..10) to the device.
- (void)setCustomEqualizerBass:(NSInteger)bass bands:(NSArray<NSNumber *> *)bands completion:(void (^)(BOOL ok, NSString * _Nullable error))completion;

// Toggles DSEE / audio upsampling.
- (void)setDsee:(BOOL)enabled completion:(void (^)(BOOL ok, NSString * _Nullable error))completion;

- (void)setAutoPowerOff:(NSInteger)index completion:(void (^)(BOOL ok, NSString * _Nullable error))completion;
- (void)setSpeakToChat:(BOOL)enabled completion:(void (^)(BOOL ok, NSString * _Nullable error))completion;
- (void)setAdaptiveVolume:(BOOL)enabled completion:(void (^)(BOOL ok, NSString * _Nullable error))completion;
- (void)setMultipoint:(BOOL)enabled completion:(void (^)(BOOL ok, NSString * _Nullable error))completion;

// Re-reads the fast-changing state (ambient/NC, level, EQ, DSEE) so changes made with the headphone's
// own button show up in the app. Called on a timer while connected.
- (void)refreshDynamicWithCompletion:(void (^)(void))completion;

// Re-reads the paired-device list, pinned state and multipoint switch (GETs only); completion on main.
- (void)refreshMultipointWithCompletion:(void (^)(void))completion;

// Moves playback to a connected device (address from pairedDevices). With fix=YES it is Sound Connect's
// "Switch playback device and fix": unfix if fixed, switch (skipped if it already plays), then fix -
// stopping at the first refused step. With fix=NO it switches, then unfixes if playback was fixed, so it
// ends switching freely. State is re-read from the headset afterwards; completion on main.
- (void)switchPlaybackToAddress:(NSString *)address fix:(BOOL)fix completion:(void (^)(BOOL ok, NSString * _Nullable error))completion;

// Fixes (pins) or frees the current playback device; one write, then a re-read. Completion on main.
- (void)setPlaybackPinned:(BOOL)pinned completion:(void (^)(BOOL ok, NSString * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
