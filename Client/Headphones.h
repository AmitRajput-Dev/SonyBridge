#include "SingleInstanceFuture.h"
#include "BluetoothWrapper.h"
#include "Constants.h"

#include <mutex>
#include <string>
#include <vector>

// One entry of the headset's paired-device list (multipoint, v2 table 2).
struct PairedDevice
{
	std::string address;    // "XX:XX:XX:XX:XX:XX", as the headset reports it
	std::string name;       // may be empty
	int slot = 0;           // multipoint slot: 0 = paired but not connected, 1/2 = connected
	int classOfDevice = -1; // 24-bit Bluetooth class of device; -1 if not reported, 0xFFFFFF for paired-only
	bool playback = false;  // currently holds the playback (A2DP) right
};

template <class T>
struct Property {
	T current;
	T desired;

	void fulfill();
	bool isFulfilled();
};

class Headphones {
public:
	Headphones(BluetoothWrapper& conn);

	void setAmbientSoundControl(bool val);
	bool getAmbientSoundControl();

	bool isFocusOnVoiceAvailable();
	void setFocusOnVoice(bool val);
	bool getFocusOnVoice();

	bool isSetAsmLevelAvailable();
	void setAsmLevel(int val);
	int getAsmLevel();

	void setSurroundPosition(SOUND_POSITION_PRESET val);
	SOUND_POSITION_PRESET getSurroundPosition();

	void setVptType(int val);
	int getVptType();

	// Handshake the device expects before it answers inquiry (GET) commands.
	void initDevice();

	// Battery. getBatteryLevel() returns -1 until requestBattery() succeeds.
	// For TWS earbuds requestBattery() also fills the per-earbud + case levels (hasDualBattery()).
	void requestBattery();
	bool hasBattery();
	int getBatteryLevel();
	bool isBatteryCharging();
	bool hasDualBattery();
	int getBatteryLeft();   // -1 if n/a
	int getBatteryRight();
	int getBatteryCase();

	// Equalizer. Wire subtypes and the custom-preset byte differ between protocol generations.
	void requestEqualizer();
	bool hasEqualizer();
	EQ_PRESET getEqualizerPreset();
	void setEqualizerPreset(EQ_PRESET preset);
	// Custom (manual) EQ: 5 band values + clear bass, each in [-10, 10]. Selects the MANUAL preset.
	void setEqualizerCustom(int clearBass, const std::vector<int>& bands);
	int getClearBass();
	int getEqualizerBand(int index); // 0..4

	// DSEE / audio upsampling.
	void requestDsee();
	bool hasDsee();
	bool getDsee();
	void setDsee(bool enabled);

	// Reads the device's current ambient/NC state into the *current* properties (for live polling so
	// changes made with the headphone's own button are reflected in the app).
	void requestAmbientState();

	// Optional features. probeCapabilities() sends each GET on connect; a feature is "supported" only if
	// the device answers (otherwise we must never send its SET - see the WH-1000XM4 power-off incident).
	void probeCapabilities();

	bool hasAutoPowerOff();
	int getAutoPowerOff();               // index into the option list (0=Off,1=5m,2=30m,3=1h,4=3h,5=when taken off)
	void setAutoPowerOff(int index);

	bool hasFirmware();
	std::string getFirmware();
	bool hasCodec();
	std::string getCodec();

	bool hasSpeakToChat();
	bool getSpeakToChat();
	void setSpeakToChat(bool enabled);

	bool hasAdaptiveVolume();
	bool getAdaptiveVolume();
	void setAdaptiveVolume(bool enabled);

	// Multipoint (v2). requestMultipoint() sends only GETs, and the table 2 reads only when initDevice()'s reply
	// says the device has command table 2. Each piece is exposed only if the device answered it.
	void requestMultipoint();
	bool hasPairedDevices();
	std::vector<PairedDevice> getPairedDevices();
	bool hasPlaybackPinState();
	bool isPlaybackPinned();
	bool hasMultipointSetting();
	bool getMultipointEnabled();
	// Hex log of the init reply and every multipoint request/reply from the last requestMultipoint(),
	// for bringing the protocol up on models nobody has captured yet.
	std::string getMultipointDiagnostics();

	// Multipoint writes. Each sends exactly one command and returns a V2Table2Command::RESULT_* code. They
	// throw RecoverableException (without sending) unless requestMultipoint() saw the device advertise
	// source-switch control. Call requestMultipoint() afterwards to read back the real state.
	// switchPlaybackDevice: the address must be a connected device from the last device list.
	int switchPlaybackDevice(const std::string& address);
	int setPlaybackPinned(bool pinned);
	// "Connect to 2 devices". The setting is device-persistent, so the app never enforces a default. Throws
	// (without sending) unless requestMultipoint() found the MULTIPOINT_SETTING general-settings slot.
	void setMultipoint(bool enabled);

	bool isChanged();
	void setChanges();
private:
	Property<bool> _ambientSoundControl = { false, false };
	Property<bool> _focusOnVoice = { false, false };
	Property<int> _asmLevel = { 0, 0 };
	NC_ASM_SETTING_TYPE _ncAsmSettingType = NC_ASM_SETTING_TYPE::DUAL_SINGLE_OFF;
	ASM_SETTING_TYPE _asmSettingType = ASM_SETTING_TYPE::LEVEL_ADJUSTMENT;
	Property<SOUND_POSITION_PRESET> _surroundPosition = { SOUND_POSITION_PRESET::OUT_OF_RANGE, SOUND_POSITION_PRESET::OFF };
	Property<int> _vptType = { 0, 0 };

	int _batteryLevel = -1;
	bool _hasBattery = false;
	bool _batteryCharging = false;
	bool _hasDualBattery = false;
	int _batteryLeft = -1;
	int _batteryRight = -1;
	int _batteryCase = -1;
	EQ_PRESET _eqPreset = EQ_PRESET::OFF;
	bool _hasEqualizer = false;
	std::vector<int> _eqBands = { 0, 0, 0, 0, 0 };
	int _eqClearBass = 0;
	bool _dsee = false;
	bool _hasDsee = false;

	bool _hasAutoPowerOff = false; int _autoPowerOff = 0;
	bool _hasFirmware = false; std::string _firmware;
	bool _hasCodec = false; std::string _codec;
	bool _hasSpeakToChat = false; bool _speakToChat = false;
	bool _hasAdaptiveVolume = false; bool _adaptiveVolume = false;

	Buffer _initReply;
	bool _table2Supported = false;
	bool _table2FunctionsRead = false; std::vector<unsigned char> _table2Functions;
	bool _hasPairedDevices = false; std::vector<PairedDevice> _pairedDevices;
	bool _hasPlaybackPinState = false; bool _playbackPinned = false;
	bool _multipointSlotSearched = false; int _multipointSlot = -1;
	bool _hasMultipointSetting = false; bool _multipointEnabled = false;
	std::string _multipointDiscoveryLog;
	std::string _multipointWriteLog;
	std::string _multipointDiagnostics;

	std::mutex _propertyMtx;

	BluetoothWrapper& _conn;
};

template<class T>
inline void Property<T>::fulfill()
{
	this->current = this->desired;
}

template<class T>
inline bool Property<T>::isFulfilled()
{
	return this->desired == this->current;
}
