#include "Headphones.h"
#include "CommandSerializer.h"

#include <stdexcept>
#include <utility>
#include <string>
#include <algorithm>

Headphones::Headphones(BluetoothWrapper& conn) : _conn(conn)
{
}

void Headphones::setAmbientSoundControl(bool val)
{
	std::lock_guard guard(this->_propertyMtx);
	this->_ambientSoundControl.desired = val;
}

bool Headphones::getAmbientSoundControl()
{
	std::lock_guard guard(this->_propertyMtx);
	return this->_ambientSoundControl.current;
}

bool Headphones::isFocusOnVoiceAvailable()
{
	std::lock_guard guard(this->_propertyMtx);
	return this->_ambientSoundControl.current && this->_asmLevel.current > MINIMUM_VOICE_FOCUS_STEP;
}

void Headphones::setFocusOnVoice(bool val)
{
	std::lock_guard guard(this->_propertyMtx);
	this->_focusOnVoice.desired = val;
}

bool Headphones::getFocusOnVoice()
{
	std::lock_guard guard(this->_propertyMtx);
	return this->_focusOnVoice.current;
}

bool Headphones::isSetAsmLevelAvailable()
{
	std::lock_guard guard(this->_propertyMtx);
	return this->_ambientSoundControl.current;
}

void Headphones::setAsmLevel(int val)
{
	std::lock_guard guard(this->_propertyMtx);
	this->_asmLevel.desired = std::clamp(val, 0, 20);
}

int Headphones::getAsmLevel()
{
	std::lock_guard guard(this->_propertyMtx);
	return this->_asmLevel.current;
}

void Headphones::setSurroundPosition(SOUND_POSITION_PRESET val)
{
	std::lock_guard guard(this->_propertyMtx);
	this->_surroundPosition.desired = val;
}

SOUND_POSITION_PRESET Headphones::getSurroundPosition()
{
	std::lock_guard guard(this->_propertyMtx);
	return this->_surroundPosition.current;
}

void Headphones::setVptType(int val)
{
	std::lock_guard guard(this->_propertyMtx);
	this->_vptType.desired = val;
}

int Headphones::getVptType()
{
	std::lock_guard guard(this->_propertyMtx);
	return this->_vptType.current;
}

void Headphones::initDevice()
{
	// Both protocol generations expect an init exchange before they answer state inquiries.
	auto isV1 = this->_conn.getProtocolVersion() == SonyProtocolVersion::V1;
	this->_conn.sendCommandAndReadResponse(
		{ (char)(isV1 ? V1Command::INIT_REQUEST : V2Command::INIT_REQUEST), 0x00 },
		isV1 ? V1Command::INIT_REPLY : V2Command::INIT_REPLY
	);
}

void Headphones::requestBattery()
{
	if (this->_conn.getProtocolVersion() == SonyProtocolVersion::V1)
	{
		// v1 (including WH-1000XM4): 10 00 is the single-battery inquiry. Never substitute the
		// v2 22 00 command here: 0x22 is POWER_OFF on this protocol generation.
		auto resp = this->_conn.sendCommandAndReadResponse(
			{ (char)V1Command::BATTERY_GET, 0x00 },
			V1Command::BATTERY_RET,
			0x00
		);
		if (resp.size() < 4) throw std::runtime_error("Invalid v1 battery response");

		std::lock_guard guard(this->_propertyMtx);
		this->_batteryLevel = (unsigned char)resp[2];
		this->_batteryCharging = resp[3] == 1;
		this->_hasBattery = true;
		return;
	}

	// Single battery (over-ear and most models): GET 22 00 -> RET 23 00 <level> <charging>
	try {
		auto resp = this->_conn.sendCommandAndReadResponse({ (char)V2Command::BATTERY_GET, 0x00 }, V2Command::BATTERY_RET, 0x00);
		if (resp.size() >= 4) {
			std::lock_guard guard(this->_propertyMtx);
			this->_batteryLevel = (unsigned char)resp[2];
			this->_batteryCharging = resp[3] == 1;
			this->_hasBattery = true;
			return; // found a single battery; don't waste time probing the TWS types
		}
	} catch (...) {}

	// TWS earbuds: dual L/R (22 09 -> 23 09 <Llvl> <Lchg> <Rlvl> <Rchg>) and case (22 0a -> 23 0a <lvl> <chg>).
	try {
		auto resp = this->_conn.sendCommandAndReadResponse({ (char)V2Command::BATTERY_GET, 0x09 }, V2Command::BATTERY_RET, 0x09);
		if (resp.size() >= 6) {
			std::lock_guard guard(this->_propertyMtx);
			this->_hasDualBattery = true;
			this->_batteryLeft = (unsigned char)resp[2];
			this->_batteryRight = (unsigned char)resp[4];
			this->_batteryLevel = std::min(this->_batteryLeft, this->_batteryRight);
			this->_hasBattery = true;
		}
	} catch (...) {}

	try {
		auto resp = this->_conn.sendCommandAndReadResponse({ (char)V2Command::BATTERY_GET, 0x0a }, V2Command::BATTERY_RET, 0x0a);
		if (resp.size() >= 4) {
			std::lock_guard guard(this->_propertyMtx);
			this->_batteryCase = (unsigned char)resp[2];
		}
	} catch (...) {}
}

bool Headphones::hasBattery() { std::lock_guard guard(this->_propertyMtx); return this->_hasBattery; }
int Headphones::getBatteryLevel()
{
	std::lock_guard guard(this->_propertyMtx);
	return this->_batteryLevel;
}

bool Headphones::isBatteryCharging()
{
	std::lock_guard guard(this->_propertyMtx);
	return this->_batteryCharging;
}

bool Headphones::hasDualBattery() { std::lock_guard guard(this->_propertyMtx); return this->_hasDualBattery; }
int Headphones::getBatteryLeft() { std::lock_guard guard(this->_propertyMtx); return this->_batteryLeft; }
int Headphones::getBatteryRight() { std::lock_guard guard(this->_propertyMtx); return this->_batteryRight; }
int Headphones::getBatteryCase() { std::lock_guard guard(this->_propertyMtx); return this->_batteryCase; }

void Headphones::requestEqualizer()
{
	auto isV1 = this->_conn.getProtocolVersion() == SonyProtocolVersion::V1;
	auto subtype = isV1 ? 0x01 : 0x00;
	// v1 uses subtype 01; v2 uses subtype 00. Both return the same six-band value layout.
	auto resp = this->_conn.sendCommandAndReadResponse(
		{ (char)(isV1 ? V1Command::EQ_GET : V2Command::EQ_GET), (char)subtype },
		isV1 ? V1Command::EQ_RET : V2Command::EQ_RET,
		subtype
	);
	if (resp.size() >= 3)
	{
		std::lock_guard guard(this->_propertyMtx);
		auto rawPreset = (unsigned char)resp[2];
		this->_eqPreset = (isV1 && rawPreset == V1Command::MANUAL_EQ)
			? EQ_PRESET::MANUAL
			: static_cast<EQ_PRESET>(rawPreset);
		this->_hasEqualizer = true;
		// When band data is present (57 00 <preset> 06 <bass+10> <b1..b5+10>), decode the -10..10 values.
		if (resp.size() >= 10)
		{
			this->_eqClearBass = (unsigned char)resp[4] - 10;
			for (int i = 0; i < 5; i++)
			{
				this->_eqBands[i] = (unsigned char)resp[5 + i] - 10;
			}
		}
	}
}

bool Headphones::hasEqualizer() { std::lock_guard guard(this->_propertyMtx); return this->_hasEqualizer; }
EQ_PRESET Headphones::getEqualizerPreset()
{
	std::lock_guard guard(this->_propertyMtx);
	return this->_eqPreset;
}

void Headphones::setEqualizerPreset(EQ_PRESET preset)
{
	if (!this->hasEqualizer()) throw std::logic_error("Equalizer capability has not been confirmed");
	auto isV1 = this->_conn.getProtocolVersion() == SonyProtocolVersion::V1;
	auto rawPreset = (unsigned char)preset;
	if (isV1 && preset == EQ_PRESET::MANUAL) rawPreset = V1Command::MANUAL_EQ;
	// SET preset: v1 58 01 <preset> 00; v2 58 00 <preset> 00.
	this->_conn.sendCommand({
		(char)(isV1 ? V1Command::EQ_SET : V2Command::EQ_SET),
		(char)(isV1 ? 0x01 : 0x00),
		(char)rawPreset,
		0x00
	});
	std::lock_guard guard(this->_propertyMtx);
	this->_eqPreset = preset;
}

void Headphones::setEqualizerCustom(int clearBass, const std::vector<int>& bands)
{
	if (!this->hasEqualizer()) throw std::logic_error("Equalizer capability has not been confirmed");
	auto isV1 = this->_conn.getProtocolVersion() == SonyProtocolVersion::V1;
	// v1 selects custom EQ with 0xff/subtype 01; v2 uses 0xa0/subtype 00.
	auto clamp = [](int v) { return (char)(unsigned char)(std::max(-10, std::min(10, v)) + 10); };
	Buffer cmd = {
		(char)(isV1 ? V1Command::EQ_SET : V2Command::EQ_SET),
		(char)(isV1 ? 0x01 : 0x00),
		(char)(isV1 ? V1Command::MANUAL_EQ : static_cast<unsigned char>(EQ_PRESET::MANUAL)),
		0x06,
		clamp(clearBass)
	};
	for (int i = 0; i < 5; i++)
	{
		cmd.push_back(clamp(i < (int)bands.size() ? bands[i] : 0));
	}
	this->_conn.sendCommand(cmd);

	std::lock_guard guard(this->_propertyMtx);
	this->_eqPreset = EQ_PRESET::MANUAL;
	this->_eqClearBass = std::clamp(clearBass, -10, 10);
	for (int i = 0; i < 5; i++)
	{
		this->_eqBands[i] = std::clamp(i < (int)bands.size() ? bands[i] : 0, -10, 10);
	}
}

int Headphones::getClearBass()
{
	std::lock_guard guard(this->_propertyMtx);
	return this->_eqClearBass;
}

int Headphones::getEqualizerBand(int index)
{
	std::lock_guard guard(this->_propertyMtx);
	return (index >= 0 && index < (int)this->_eqBands.size()) ? this->_eqBands[index] : 0;
}

void Headphones::requestDsee()
{
	auto isV1 = this->_conn.getProtocolVersion() == SonyProtocolVersion::V1;
	auto subtype = isV1 ? 0x02 : 0x01;
	auto resp = this->_conn.sendCommandAndReadResponse(
		{ (char)(isV1 ? V1Command::DSEE_GET : V2Command::DSEE_GET), (char)subtype },
		isV1 ? V1Command::DSEE_RET : V2Command::DSEE_RET,
		subtype
	);
	if ((!isV1 && resp.size() >= 3) || (isV1 && resp.size() >= 4))
	{
		std::lock_guard guard(this->_propertyMtx);
		this->_dsee = resp[isV1 ? 3 : 2] != 0;
		this->_hasDsee = true;
	}
}

bool Headphones::hasDsee() { std::lock_guard guard(this->_propertyMtx); return this->_hasDsee; }
bool Headphones::getDsee()
{
	std::lock_guard guard(this->_propertyMtx);
	return this->_dsee;
}

void Headphones::setDsee(bool enabled)
{
	if (!this->hasDsee()) throw std::logic_error("DSEE capability has not been confirmed");
	if (this->_conn.getProtocolVersion() == SonyProtocolVersion::V1)
	{
		// v1: e8 02 00 <enabled>
		this->_conn.sendCommand({ (char)V1Command::DSEE_SET, 0x02, 0x00, (char)(enabled ? 0x01 : 0x00) });
	}
	else
	{
		// v2: e8 01 <enabled>
		this->_conn.sendCommand({ (char)V2Command::DSEE_SET, 0x01, (char)(enabled ? 0x01 : 0x00) });
	}
	std::lock_guard guard(this->_propertyMtx);
	this->_dsee = enabled;
}

void Headphones::requestAmbientState()
{
	// The NCASM inquired-type differs by protocol generation (v2=0x17, v1=0x02), and so does the reply
	// layout. Sending the wrong one is what left v1 devices (WH-1000XM4) without valid handshake traffic.
	auto protocolVersion = this->_conn.getProtocolVersion();
	if (protocolVersion == SonyProtocolVersion::V2)
	{
		// GET: 66 17  ->  RET: 67 17 01 <effect> <settingType 0=NC/1=Ambient> <voice> <level>
		auto resp = this->_conn.sendCommandAndReadResponse({ 0x66, 0x17 }, 0x67);
		if (resp.size() >= 7)
		{
			bool on = resp[3] != 0;
			bool ambient = resp[4] != 0;
			bool voice = resp[5] != 0;
			int level = (unsigned char)resp[6];
			std::lock_guard guard(this->_propertyMtx);
			// Update both current and desired so the UI reflects reality and isChanged() stays false.
			this->_ambientSoundControl.current = this->_ambientSoundControl.desired = on;
			this->_asmLevel.current = this->_asmLevel.desired = ambient ? level : 0;
			this->_focusOnVoice.current = this->_focusOnVoice.desired = voice;
		}
	}
	else
	{
		// v1: 67 02 <effect> <setting type> <setting value> <asm type> <voice> <level>.
		auto resp = this->_conn.sendCommandAndReadResponse(
			{ (char)V1Command::AMBIENT_GET, 0x02 }, V1Command::AMBIENT_RET, 0x02);
		if (resp.size() == 8)
		{
			bool enabled = resp[2] != 0;
			auto settingType = (unsigned char)resp[3];
			auto settingValue = (unsigned char)resp[4];
			int level = (unsigned char)resp[7];
			bool ambient = enabled && settingValue == 0x00 && level > 0;
			bool voice = resp[6] != 0;

			std::lock_guard guard(this->_propertyMtx);
			if (settingType <= static_cast<unsigned char>(NC_ASM_SETTING_TYPE::DUAL_SINGLE_OFF))
				this->_ncAsmSettingType = static_cast<NC_ASM_SETTING_TYPE>(settingType);
			if ((unsigned char)resp[5] <= static_cast<unsigned char>(ASM_SETTING_TYPE::LEVEL_ADJUSTMENT))
				this->_asmSettingType = static_cast<ASM_SETTING_TYPE>((unsigned char)resp[5]);
			this->_ambientSoundControl.current = this->_ambientSoundControl.desired = enabled;
			this->_asmLevel.current = this->_asmLevel.desired = ambient ? level : 0;
			this->_focusOnVoice.current = this->_focusOnVoice.desired = ambient && voice;
		}
	}
}

// --- Optional features (auto power off, firmware, codec, speak-to-chat, adaptive volume) ---

namespace
{
	// Auto-power-off 2-byte codes, indexed 0=Off,1=5min,2=30min,3=1h,4=3h,5=when-taken-off.
	const std::pair<unsigned char, unsigned char> APO_CODES[] = {
		{ 0x11, 0x00 }, { 0x00, 0x00 }, { 0x01, 0x01 }, { 0x02, 0x02 }, { 0x03, 0x03 }, { 0x10, 0x00 }
	};

	int apoIndexFromCode(unsigned char c0, unsigned char c1)
	{
		for (int i = 0; i < 6; i++)
		{
			if (APO_CODES[i].first == c0 && APO_CODES[i].second == c1) return i;
		}
		return 0;
	}

	std::string codecName(unsigned char code)
	{
		switch (code)
		{
			case 0x01: return "SBC";
			case 0x02: return "AAC";
			case 0x10: return "LDAC";
			case 0x20: return "aptX";
			case 0x21: return "aptX HD";
			default:   return "";
		}
	}
}

void Headphones::probeCapabilities()
{
	// Each GET is best-effort: an unsupported feature times out (recv timeout -> throw) and stays unsupported,
	// so we never expose or send a command the device can't handle.
	if (this->_conn.getProtocolVersion() == SonyProtocolVersion::V1)
	{
		try {
			auto r = this->_conn.sendCommandAndReadResponse({ (char)V1Command::FW_GET, 0x02 }, V1Command::FW_RET, 0x02);
			if (r.size() > 3) { std::lock_guard g(this->_propertyMtx); this->_firmware = std::string(r.begin() + 3, r.end()); this->_hasFirmware = true; }
		} catch (...) {}

		try {
			auto r = this->_conn.sendCommandAndReadResponse({ (char)V1Command::CODEC_GET, 0x00 }, V1Command::CODEC_RET, 0x00);
			if (r.size() >= 3) { auto n = codecName((unsigned char)r[2]); if (!n.empty()) { std::lock_guard g(this->_propertyMtx); this->_codec = n; this->_hasCodec = true; } }
		} catch (...) {}

		try {
			auto r = this->_conn.sendCommandAndReadResponse({ (char)V1Command::BTNMODE_GET, (char)V1Command::SUB_AUTO_POWER_OFF }, V1Command::BTNMODE_RET, V1Command::SUB_AUTO_POWER_OFF);
			if (r.size() >= 5) { std::lock_guard g(this->_propertyMtx); this->_autoPowerOff = apoIndexFromCode((unsigned char)r[3], (unsigned char)r[4]); this->_hasAutoPowerOff = true; }
		} catch (...) {}

		try {
			auto r = this->_conn.sendCommandAndReadResponse({ (char)V1Command::BTNMODE_GET, (char)V1Command::SUB_SPEAK_TO_CHAT }, V1Command::BTNMODE_RET, V1Command::SUB_SPEAK_TO_CHAT);
			if (r.size() >= 4 && r[2] == 0x01) { std::lock_guard g(this->_propertyMtx); this->_speakToChat = r[3] != 0; this->_hasSpeakToChat = true; }
		} catch (...) {}
		return;
	}

	try {
		auto r = this->_conn.sendCommandAndReadResponse({ (char)V2Command::FW_GET, 0x02 }, V2Command::FW_RET);
		if (r.size() > 3) { std::lock_guard g(this->_propertyMtx); this->_firmware = std::string(r.begin() + 3, r.end()); this->_hasFirmware = true; }
	} catch (...) {}

	try {
		auto r = this->_conn.sendCommandAndReadResponse({ (char)V2Command::CODEC_GET, 0x02 }, V2Command::CODEC_RET);
		if (r.size() >= 3) { auto n = codecName((unsigned char)r[2]); if (!n.empty()) { std::lock_guard g(this->_propertyMtx); this->_codec = n; this->_hasCodec = true; } }
	} catch (...) {}

	try {
		auto r = this->_conn.sendCommandAndReadResponse({ (char)V2Command::APO_GET, 0x05 }, V2Command::APO_RET);
		if (r.size() >= 4) { std::lock_guard g(this->_propertyMtx); this->_autoPowerOff = apoIndexFromCode((unsigned char)r[2], (unsigned char)r[3]); this->_hasAutoPowerOff = true; }
	} catch (...) {}

	try {
		auto r = this->_conn.sendCommandAndReadResponse({ (char)V2Command::BTNMODE_GET, (char)V2Command::SUB_ADAPTIVE_VOLUME }, V2Command::BTNMODE_RET, V2Command::SUB_ADAPTIVE_VOLUME);
		if (r.size() >= 3) { std::lock_guard g(this->_propertyMtx); this->_adaptiveVolume = (r[2] == 0); this->_hasAdaptiveVolume = true; }
	} catch (...) {}

	try {
		auto r = this->_conn.sendCommandAndReadResponse({ (char)V2Command::BTNMODE_GET, (char)V2Command::SUB_SPEAK_TO_CHAT }, V2Command::BTNMODE_RET, V2Command::SUB_SPEAK_TO_CHAT);
		if (r.size() >= 3) { std::lock_guard g(this->_propertyMtx); this->_speakToChat = (r[2] == 0); this->_hasSpeakToChat = true; }
	} catch (...) {}
}

bool Headphones::hasAutoPowerOff() { std::lock_guard guard(this->_propertyMtx); return this->_hasAutoPowerOff; }
int Headphones::getAutoPowerOff() { std::lock_guard guard(this->_propertyMtx); return this->_autoPowerOff; }
void Headphones::setAutoPowerOff(int index)
{
	if (index < 0 || index > 5) throw std::invalid_argument("Invalid auto power-off option");
	if (!this->hasAutoPowerOff()) throw std::logic_error("Auto power-off capability has not been confirmed");
	if (this->_conn.getProtocolVersion() == SonyProtocolVersion::V1)
	{
		this->_conn.sendCommand({ (char)V1Command::BTNMODE_SET, (char)V1Command::SUB_AUTO_POWER_OFF, 0x01, (char)APO_CODES[index].first, (char)APO_CODES[index].second });
	}
	else
	{
		this->_conn.sendCommand({ (char)V2Command::APO_SET, 0x05, (char)APO_CODES[index].first, (char)APO_CODES[index].second });
	}
	std::lock_guard guard(this->_propertyMtx);
	this->_autoPowerOff = index;
}

bool Headphones::hasFirmware() { std::lock_guard guard(this->_propertyMtx); return this->_hasFirmware; }
std::string Headphones::getFirmware() { std::lock_guard guard(this->_propertyMtx); return this->_firmware; }
bool Headphones::hasCodec() { std::lock_guard guard(this->_propertyMtx); return this->_hasCodec; }
std::string Headphones::getCodec() { std::lock_guard guard(this->_propertyMtx); return this->_codec; }

bool Headphones::hasSpeakToChat() { std::lock_guard guard(this->_propertyMtx); return this->_hasSpeakToChat; }
bool Headphones::getSpeakToChat() { std::lock_guard guard(this->_propertyMtx); return this->_speakToChat; }
void Headphones::setSpeakToChat(bool enabled)
{
	if (!this->hasSpeakToChat()) throw std::logic_error("Speak-to-Chat capability has not been confirmed");
	if (this->_conn.getProtocolVersion() == SonyProtocolVersion::V1)
	{
		this->_conn.sendCommand({ (char)V1Command::BTNMODE_SET, (char)V1Command::SUB_SPEAK_TO_CHAT, 0x01, (char)(enabled ? 0x01 : 0x00) });
	}
	else
	{
		// v2 enable bit is inverted.
		this->_conn.sendCommand({ (char)V2Command::BTNMODE_SET, (char)V2Command::SUB_SPEAK_TO_CHAT, (char)(enabled ? 0x00 : 0x01), 0x01 });
	}
	std::lock_guard guard(this->_propertyMtx);
	this->_speakToChat = enabled;
}

bool Headphones::hasAdaptiveVolume() { std::lock_guard guard(this->_propertyMtx); return this->_hasAdaptiveVolume; }
bool Headphones::getAdaptiveVolume() { std::lock_guard guard(this->_propertyMtx); return this->_adaptiveVolume; }
void Headphones::setAdaptiveVolume(bool enabled)
{
	if (this->_conn.getProtocolVersion() != SonyProtocolVersion::V2 || !this->hasAdaptiveVolume())
		throw std::logic_error("Adaptive volume capability has not been confirmed");
	// SET: f8 0a <enabled? 0:1>  (inverted)
	this->_conn.sendCommand({ (char)V2Command::BTNMODE_SET, (char)V2Command::SUB_ADAPTIVE_VOLUME, (char)(enabled ? 0x00 : 0x01) });
	std::lock_guard guard(this->_propertyMtx);
	this->_adaptiveVolume = enabled;
}

bool Headphones::isChanged()
{
	std::lock_guard guard(this->_propertyMtx);
	auto ambientChanged = !(this->_ambientSoundControl.isFulfilled() && this->_asmLevel.isFulfilled() && this->_focusOnVoice.isFulfilled());
	auto vptChanged = this->_conn.getProtocolVersion() == SonyProtocolVersion::V1 &&
		!(this->_surroundPosition.isFulfilled() && this->_vptType.isFulfilled());
	return ambientChanged || vptChanged;
}

void Headphones::setChanges()
{
	auto protocolVersion = this->_conn.getProtocolVersion();
	Property<bool> ambientSoundControl;
	Property<bool> focusOnVoice;
	Property<int> asmLevelProperty;
	NC_ASM_SETTING_TYPE ncAsmSettingType;
	ASM_SETTING_TYPE asmSettingType;
	{
		std::lock_guard guard(this->_propertyMtx);
		ambientSoundControl = this->_ambientSoundControl;
		focusOnVoice = this->_focusOnVoice;
		asmLevelProperty = this->_asmLevel;
		ncAsmSettingType = this->_ncAsmSettingType;
		asmSettingType = this->_asmSettingType;
	}

	if (!(ambientSoundControl.isFulfilled() && focusOnVoice.isFulfilled() && asmLevelProperty.isFulfilled()))
	{
		if (protocolVersion == SonyProtocolVersion::V2)
		{
			// v2 has no separate "disabled" level - NC vs Ambient Sound is its own field, and level is 1-based.
			char asmLevel = static_cast<char>(asmLevelProperty.desired > 0 ? asmLevelProperty.desired : 1);

			this->_conn.sendCommand(CommandSerializer::serializeNcAndAsmSettingV2(
				ambientSoundControl.desired ? NC_ASM_EFFECT::ON : NC_ASM_EFFECT::OFF,
				asmLevelProperty.desired > 0 ? NC_ASM_SETTING_TYPE_V2::AMBIENT_SOUND : NC_ASM_SETTING_TYPE_V2::NOISE_CANCELLING,
				focusOnVoice.desired ? ASM_ID::VOICE : ASM_ID::NORMAL,
				asmLevel
			));
		}
		else
		{
			auto ncAsmEffect = ambientSoundControl.desired ? NC_ASM_EFFECT::ADJUSTMENT_COMPLETION : NC_ASM_EFFECT::OFF;
			auto asmId = focusOnVoice.desired ? ASM_ID::VOICE : ASM_ID::NORMAL;
			auto asmLevel = ambientSoundControl.desired ? asmLevelProperty.desired : 0;
			auto noiseCancelling = ambientSoundControl.desired && asmLevelProperty.desired == 0;
			auto ncValue = noiseCancelling
				? (ncAsmSettingType == NC_ASM_SETTING_TYPE::DUAL_SINGLE_OFF ? NC_DUAL_SINGLE_VALUE::DUAL : NC_DUAL_SINGLE_VALUE::SINGLE)
				: NC_DUAL_SINGLE_VALUE::OFF;

			this->_conn.sendCommand(CommandSerializer::serializeNcAndAsmSetting(
				ncAsmEffect,
				ncAsmSettingType,
				ncValue,
				asmSettingType,
				asmId,
				asmLevel
			));
		}

		std::lock_guard guard(this->_propertyMtx);
		if (this->_ambientSoundControl.desired == ambientSoundControl.desired) this->_ambientSoundControl.fulfill();
		if (this->_asmLevel.desired == asmLevelProperty.desired) this->_asmLevel.fulfill();
		if (this->_focusOnVoice.desired == focusOnVoice.desired) this->_focusOnVoice.fulfill();
	}

	// VPT/Surround has no known v2 command and no hardware on v2-only devices like the CH720N - v1 only.
	Property<int> vptType;
	Property<SOUND_POSITION_PRESET> surroundPosition;
	{
		std::lock_guard guard(this->_propertyMtx);
		vptType = this->_vptType;
		surroundPosition = this->_surroundPosition;
	}
	if (protocolVersion == SonyProtocolVersion::V1 && !(vptType.isFulfilled() && surroundPosition.isFulfilled())) {
		VPT_INQUIRED_TYPE command;
		unsigned char preset;

		if (vptType.desired != 0) {
			command = VPT_INQUIRED_TYPE::VPT;
			preset = static_cast<unsigned char>(vptType.desired);
		}
		else if (surroundPosition.desired != SOUND_POSITION_PRESET::OFF) {
			command = VPT_INQUIRED_TYPE::SOUND_POSITION;
			preset = static_cast<unsigned char>(surroundPosition.desired);
		}
		else {
			// Just used that one because it seems like it disables both
			if (surroundPosition.current != SOUND_POSITION_PRESET::OFF) {
				command = VPT_INQUIRED_TYPE::SOUND_POSITION;
				preset = static_cast<unsigned char>(SOUND_POSITION_PRESET::OFF);
			}
			else if (vptType.current != 0) {
				command = VPT_INQUIRED_TYPE::VPT;
				preset = 0;
			}
			else {
				throw std::logic_error("it's impossible that both values were changed to zero and were also previously zero");
			}
		}

		this->_conn.sendCommand(CommandSerializer::serializeVPTSetting(command, preset));

		std::lock_guard guard(this->_propertyMtx);
		if (this->_vptType.desired == vptType.desired) this->_vptType.fulfill();
		if (this->_surroundPosition.desired == surroundPosition.desired) this->_surroundPosition.fulfill();
	}
}
