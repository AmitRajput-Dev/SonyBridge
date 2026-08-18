#include "SingleInstanceFuture.h"
#include "BluetoothWrapper.h"
#include "Constants.h"

#include <mutex>

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

	// Handshake the device expects before it answers inquiry (GET) commands on the v2 protocol.
	void initDevice();

	// Model name of the connected device (e.g. "WF-1000XM5"). Only a hint: it picks which battery
	// layout to probe first, so set it before the first requestBattery() to save a timed-out inquiry.
	void setDeviceName(const std::string& name);

	// Battery (v2 inquiry). getBatteryLevel() returns -1 until requestBattery() succeeds.
	// For TWS earbuds requestBattery() also fills the per-earbud + case levels (hasDualBattery()).
	void requestBattery();
	int getBatteryLevel();       // for earbuds: the emptier of the two
	bool isBatteryCharging();
	bool hasDualBattery();
	int getBatteryLeft();   // -1 if n/a
	int getBatteryRight();
	int getBatteryCase();
	bool isBatteryLeftCharging();
	bool isBatteryRightCharging();
	bool isBatteryCaseCharging();

	// Equalizer (v2). requestEqualizer() reads current state; setEqualizerPreset() pushes a preset immediately.
	void requestEqualizer();
	EQ_PRESET getEqualizerPreset();
	void setEqualizerPreset(EQ_PRESET preset);
	// Custom (manual) EQ: 5 band values + clear bass, each in [-10, 10]. Selects the MANUAL preset.
	void setEqualizerCustom(int clearBass, const std::vector<int>& bands);
	int getClearBass();
	int getEqualizerBand(int index); // 0..4

	// DSEE / audio upsampling (v2).
	void requestDsee();
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

	// Sound quality mode: prioritise sound quality vs. a stable connection. Changing it makes the
	// headphones re-negotiate the A2DP link, so the RFCOMM connection drops right after the write -
	// callers should expect a disconnect rather than treat it as a failure.
	bool hasSoundQualityMode();
	PRIOR_MODE getSoundQualityMode();
	void setSoundQualityMode(PRIOR_MODE mode);

	bool isChanged();
	void setChanges();

	// Rolls a failed ambient/NC write back to the last known device state. Must be called when
	// setChanges() throws - see the comment on the definition.
	void discardAmbientChanges();
private:
	Property<bool> _ambientSoundControl = { 0 };
	Property<bool> _focusOnVoice = { 0 };
	Property<int> _asmLevel = { 0 };
	Property<SOUND_POSITION_PRESET> _surroundPosition = { SOUND_POSITION_PRESET::OUT_OF_RANGE, SOUND_POSITION_PRESET::OFF };
	Property<int> _vptType = { 0 };

	int _batteryLevel = -1;
	bool _batteryCharging = false;
	bool _hasDualBattery = false;
	int _batteryLeft = -1;
	int _batteryRight = -1;
	int _batteryCase = -1;
	bool _batteryLeftCharging = false;
	bool _batteryRightCharging = false;
	bool _batteryCaseCharging = false;
	std::string _deviceName;

	bool _looksLikeEarbuds() const;
	// Both return false if the device didn't answer that battery sub-type.
	bool _requestDualBattery(unsigned char subType);
	bool _requestSingleBattery(unsigned char subType, int& levelOut, bool& chargingOut);
	EQ_PRESET _eqPreset = EQ_PRESET::OFF;
	std::vector<int> _eqBands = { 0, 0, 0, 0, 0 };
	int _eqClearBass = 0;
	bool _dsee = false;

	bool _hasAutoPowerOff = false; int _autoPowerOff = 0;
	bool _hasFirmware = false; std::string _firmware;
	bool _hasCodec = false; std::string _codec;
	bool _hasSpeakToChat = false; bool _speakToChat = false;
	bool _hasAdaptiveVolume = false; bool _adaptiveVolume = false;
	// Which AUDIO sub-type this device answered on: SET has to go back out on the same one.
	bool _hasSoundQualityMode = false;
	unsigned char _soundQualityModeSubType = V2Command::SUB_CONNECTION_MODE;
	PRIOR_MODE _soundQualityMode = PRIOR_MODE::SOUND_QUALITY;

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
