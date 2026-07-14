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

@interface HeadphonesBridge : NSObject

@property (nonatomic, readonly) BOOL connected;
@property (nonatomic, copy, readonly, nullable) NSString *deviceName;
@property (nonatomic, copy, readonly, nullable) NSString *deviceMac;
@property (nonatomic, copy, readonly, nullable) NSString *protocolVersionString; // "v1" / "v2"

// Only meaningful while connected.
@property (nonatomic, readonly) BOOL supportsVpt;        // v1 protocol devices only
@property (nonatomic, readonly) NSInteger maxAmbientLevel; // 19 (v1) or 20 (v2)

// Current on-device state, mirrored from the last successful command.
@property (nonatomic, readonly) SHCAmbientMode mode;
@property (nonatomic, readonly) NSInteger ambientLevel;
@property (nonatomic, readonly) BOOL focusOnVoice;
@property (nonatomic, readonly) BOOL focusOnVoiceAvailable;

@property (nonatomic, readonly) NSInteger batteryLevel;   // -1 until known
@property (nonatomic, readonly) BOOL batteryCharging;
@property (nonatomic, readonly) NSInteger eqPreset;       // raw preset byte (EQ_PRESET)
@property (nonatomic, readonly) BOOL supportsEqualizer;   // v2 devices only
@property (nonatomic, readonly) NSInteger clearBass;      // -10..10
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

// Re-reads the fast-changing state (ambient/NC, level, EQ, DSEE) so changes made with the headphone's
// own button show up in the app. Called on a timer while connected.
- (void)refreshDynamicWithCompletion:(void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END
