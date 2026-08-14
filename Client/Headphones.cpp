#include "Headphones.h"
#include "CommandSerializer.h"

#include <stdexcept>
#include <utility>
#include <string>
#include <algorithm>
#include <cctype>

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
	// Both protocol generations expect an init exchange before they answer state inquiries. On v2 the reply
	// (INIT_REPLY, 8 bytes) also says whether the device has command table 2, which gates every multipoint read.
	auto isV1 = this->_conn.getProtocolVersion() == SonyProtocolVersion::V1;
	auto resp = this->_conn.sendCommandAndReadResponse(
		{ (char)(isV1 ? V1Command::INIT_REQUEST : V2Command::INIT_REQUEST), 0x00 },
		isV1 ? V1Command::INIT_REPLY : V2Command::INIT_REPLY
	);
	std::lock_guard guard(this->_propertyMtx);
	this->_initReply = resp;
	this->_table2Supported = !isV1 && resp.size() > V2Command::INIT_REPLY_TABLE2_INDEX
		&& resp[V2Command::INIT_REPLY_TABLE2_INDEX] == 0x00;
}

void Headphones::setDeviceName(const std::string& name)
{
	std::lock_guard guard(this->_propertyMtx);
	this->_deviceName = name;
}

// True for Sony's true-wireless earbuds, which report a battery per earbud instead of one for the
// whole device. Only used to pick the probe order - an unrecognised name still finds both layouts,
// just one timed-out inquiry slower.
bool Headphones::_looksLikeEarbuds() const
{
	std::string name;
	for (char c : this->_deviceName) name.push_back((char)std::tolower((unsigned char)c));
	return name.find("wf-") != std::string::npos || name.find("linkbuds") != std::string::npos;
}

// Reads the per-earbud (and case) levels. Returns false if the device didn't answer this sub-type or
// answered with nothing usable, so the caller can fall back to the other layout.
bool Headphones::_requestDualBattery(unsigned char subType)
{
	Buffer resp;
	try {
		resp = this->_conn.sendCommandAndReadResponse(
			{ (char)V2Command::BATTERY_GET, (char)subType }, V2Command::BATTERY_RET, subType);
	} catch (const std::exception&) {
		return false;
	}
	if (resp.size() < 6) return false;

	const int left = (unsigned char)resp[2];
	const int right = (unsigned char)resp[4];

	// Both zero is still a real answer: both earbuds are docked (level 0 means "not reporting", not empty).
	// Rejecting it would fall through to the DUAL2 and single probes, which time out on these models and
	// stall the command queue for ~5s on every battery poll while the buds sit in the case.
	std::lock_guard guard(this->_propertyMtx);
	this->_hasDualBattery = true;
	this->_hasBattery = true;
	this->_batteryLeft = left > 0 ? left : -1;
	this->_batteryRight = right > 0 ? right : -1;
	this->_batteryLeftCharging = resp[3] == 1;
	this->_batteryRightCharging = resp[5] == 1;
	// Headline level: the emptier of the two earbuds that are actually reporting.
	if (this->_batteryLeft >= 0 && this->_batteryRight >= 0)
		this->_batteryLevel = std::min(this->_batteryLeft, this->_batteryRight);
	else
		this->_batteryLevel = std::max(this->_batteryLeft, this->_batteryRight); // -1 when both are docked
	this->_batteryCharging = this->_batteryLeftCharging || this->_batteryRightCharging;
	return true;
}

bool Headphones::_requestSingleBattery(unsigned char subType, int& levelOut, bool& chargingOut)
{
	Buffer resp;
	try {
		resp = this->_conn.sendCommandAndReadResponse(
			{ (char)V2Command::BATTERY_GET, (char)subType }, V2Command::BATTERY_RET, subType);
	} catch (const std::exception&) {
		return false;
	}
	if (resp.size() < 4) return false;
	levelOut = (unsigned char)resp[2];
	chargingOut = resp[3] == 1;
	return true;
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

	// A device only answers the battery sub-types it supports, and an unsupported inquiry costs a
	// full recv timeout, so probe the layout this model is likely to use first. Crucially the dual
	// probe must come before the single one on earbuds: some TWS models *do* answer the single
	// inquiry (with a combined or zero level), and taking that answer would hide the per-earbud
	// levels entirely.
	if (this->_looksLikeEarbuds())
	{
		if (this->_requestDualBattery(V2Command::BATTERY_SUB_DUAL)
			|| this->_requestDualBattery(V2Command::BATTERY_SUB_DUAL2))
		{
			int caseLevel = -1; bool caseCharging = false;
			if (this->_requestSingleBattery(V2Command::BATTERY_SUB_CASE, caseLevel, caseCharging)) {
				std::lock_guard guard(this->_propertyMtx);
				// The case reports 0 while it's disconnected from the buds; keep the last known value.
				if (caseLevel > 0) {
					this->_batteryCase = caseLevel;
					this->_batteryCaseCharging = caseCharging;
				}
			}
			return;
		}
	}

	// Single battery (over-ear and most other models).
	int level = -1; bool charging = false;
	if (this->_requestSingleBattery(V2Command::BATTERY_SUB_SINGLE, level, charging)) {
		std::lock_guard guard(this->_propertyMtx);
		this->_batteryLevel = level;
		this->_batteryCharging = charging;
		this->_hasBattery = true;
		return;
	}

	// Unrecognised name that turned out to be earbuds after all.
	if (!this->_looksLikeEarbuds()) {
		if (this->_requestDualBattery(V2Command::BATTERY_SUB_DUAL)
			|| this->_requestDualBattery(V2Command::BATTERY_SUB_DUAL2))
		{
			int caseLevel = -1; bool caseCharging = false;
			if (this->_requestSingleBattery(V2Command::BATTERY_SUB_CASE, caseLevel, caseCharging)) {
				std::lock_guard guard(this->_propertyMtx);
				if (caseLevel > 0) {
					this->_batteryCase = caseLevel;
					this->_batteryCaseCharging = caseCharging;
				}
			}
		}
	}
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
bool Headphones::isBatteryLeftCharging() { std::lock_guard guard(this->_propertyMtx); return this->_batteryLeftCharging; }
bool Headphones::isBatteryRightCharging() { std::lock_guard guard(this->_propertyMtx); return this->_batteryRightCharging; }
bool Headphones::isBatteryCaseCharging() { std::lock_guard guard(this->_propertyMtx); return this->_batteryCaseCharging; }

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

// --- Multipoint ---

namespace
{
	std::string hexString(const Buffer& bytes)
	{
		static const char digits[] = "0123456789abcdef";
		std::string out;
		for (size_t i = 0; i < bytes.size(); i++)
		{
			auto b = (unsigned char)bytes[i];
			if (i > 0) out += ' ';
			out += digits[b >> 4];
			out += digits[b & 0x0f];
		}
		return out;
	}

	// 37 <type> <count> { <address, 17 ASCII> <slot> [<class of device, 3 bytes BE>] <name length> <name> } x count <playback slot>
	// Returns false (and leaves `out` untouched) on any length mismatch, so a misread never reaches the UI.
	bool parsePairedDevices(const Buffer& resp, bool withClassOfDevice, std::vector<PairedDevice>& out)
	{
		if (resp.size() < 4) return false;
		size_t pos = 2;
		size_t count = (unsigned char)resp[pos++];
		std::vector<PairedDevice> devices;
		for (size_t i = 0; i < count; i++)
		{
			size_t fixed = V2Table2Command::BT_ADDRESS_LENGTH + 1 + (withClassOfDevice ? 3 : 0) + 1;
			if (pos + fixed > resp.size()) return false;
			PairedDevice device;
			device.address.assign(resp.begin() + pos, resp.begin() + pos + V2Table2Command::BT_ADDRESS_LENGTH);
			pos += V2Table2Command::BT_ADDRESS_LENGTH;
			device.slot = (unsigned char)resp[pos++];
			if (withClassOfDevice)
			{
				device.classOfDevice = ((unsigned char)resp[pos] << 16) | ((unsigned char)resp[pos + 1] << 8) | (unsigned char)resp[pos + 2];
				pos += 3;
			}
			size_t nameLength = (unsigned char)resp[pos++];
			if (pos + nameLength > resp.size()) return false;
			device.name.assign(resp.begin() + pos, resp.begin() + pos + nameLength);
			pos += nameLength;
			devices.push_back(device);
		}
		if (pos + 1 != resp.size()) return false;
		// The trailing byte is the slot (1/2) that holds playback, not an index into the list.
		int playbackSlot = (unsigned char)resp[pos];
		for (auto& device : devices)
		{
			device.playback = device.slot != 0 && device.slot == playbackSlot;
		}
		out = devices;
		return true;
	}
}

void Headphones::requestMultipoint()
{
	if (this->_conn.getProtocolVersion() != SonyProtocolVersion::V2) return;

	Buffer initReply;
	bool table2Supported;
	bool functionsRead;
	std::vector<unsigned char> functions;
	bool slotSearched;
	int slot;
	std::string discoveryLog;
	{
		std::lock_guard guard(this->_propertyMtx);
		initReply = this->_initReply;
		table2Supported = this->_table2Supported;
		functionsRead = this->_table2FunctionsRead;
		functions = this->_table2Functions;
		slotSearched = this->_multipointSlotSearched;
		slot = this->_multipointSlot;
		discoveryLog = this->_multipointDiscoveryLog;
	}

	// One-time discovery reads (support functions, slot search) go to discoveryLog so a later refresh
	// still shows them; per-refresh reads go to log.
	std::string log;
	std::string* target = &discoveryLog;
	auto read = [&](const Buffer& cmd, unsigned char retCommandId, int retSubType, DATA_TYPE dataType) -> Buffer {
		std::string label = dataType == DATA_TYPE::DATA_MDR_NO2 ? "T2 " : "T1 ";
		try
		{
			auto resp = this->_conn.sendCommandAndReadResponse(cmd, retCommandId, retSubType, dataType);
			*target += label + hexString(cmd) + " -> " + hexString(resp) + "\n";
			return resp;
		}
		catch (const std::exception& exc)
		{
			*target += label + hexString(cmd) + " -> (" + exc.what() + ")\n";
			return {};
		}
	};

	bool hasPairedDevices = false; std::vector<PairedDevice> pairedDevices;
	bool hasPinState = false; bool pinned = false;
	if (!table2Supported)
	{
		log += "table 2 not advertised in the init reply; skipped the device list\n";
	}
	else
	{
		if (!functionsRead)
		{
			target = &discoveryLog;
			// 07 00 <n> (<function> <priority>) x n
			auto resp = read({ (char)V2Table2Command::SUPPORT_FUNCTION_GET, 0x00 },
				V2Table2Command::SUPPORT_FUNCTION_RET, 0x00, DATA_TYPE::DATA_MDR_NO2);
			if (resp.size() >= 3)
			{
				size_t count = (unsigned char)resp[2];
				for (size_t i = 0; i < count && 3 + i * 2 < resp.size(); i++)
				{
					functions.push_back((unsigned char)resp[3 + i * 2]);
				}
				functionsRead = true;
			}
		}
		target = &log;
		auto supports = [&](unsigned char function) {
			return std::find(functions.begin(), functions.end(), function) != functions.end();
		};

		bool withClassOfDevice = supports(V2Table2Command::FN_DEVICES_WITH_COD) || supports(V2Table2Command::FN_DEVICES_WITH_COD_LE);
		if (withClassOfDevice || supports(V2Table2Command::FN_DEVICES_CLASSIC))
		{
			unsigned char type = withClassOfDevice ? V2Table2Command::PERI_DEVICES_WITH_COD : V2Table2Command::PERI_DEVICES_CLASSIC;
			auto resp = read({ (char)V2Table2Command::PERI_GET_PARAM, (char)type },
				V2Table2Command::PERI_RET_PARAM, type, DATA_TYPE::DATA_MDR_NO2);
			hasPairedDevices = parsePairedDevices(resp, withClassOfDevice, pairedDevices);
			if (!resp.empty() && !hasPairedDevices) log += "device list: unexpected layout\n";
		}

		if (supports(V2Table2Command::FN_SOURCE_SWITCH))
		{
			// 37 01 <value>: 1 = playback switches freely, 0 = playback device fixed.
			auto resp = read({ (char)V2Table2Command::PERI_GET_PARAM, (char)V2Table2Command::PERI_SOURCE_SWITCH },
				V2Table2Command::PERI_RET_PARAM, V2Table2Command::PERI_SOURCE_SWITCH, DATA_TYPE::DATA_MDR_NO2);
			if (resp.size() >= 3)
			{
				hasPinState = true;
				pinned = resp[2] == 0x00;
			}
		}
	}

	// The multipoint on/off switch is a table 1 general setting whose slot (D1..D4) differs per model:
	// find it by name once per connection, then just read its value.
	if (!slotSearched)
	{
		target = &discoveryLog;
		for (int candidate = V2Command::GS_SLOT_FIRST; candidate <= V2Command::GS_SLOT_LAST; candidate++)
		{
			// d1 <slot> <type 00=boolean> <format> <name length> <name> <summary length> <summary>
			auto resp = read({ (char)V2Command::GS_GET_CAPABILITY, (char)candidate, (char)V2Command::GS_DISPLAY_LANGUAGE_ENGLISH },
				V2Command::GS_RET_CAPABILITY, candidate, DATA_TYPE::DATA_MDR);
			if (resp.size() < 5 || resp[2] != 0x00) continue;
			size_t nameLength = (unsigned char)resp[4];
			if (5 + nameLength > resp.size()) continue;
			if (std::string(resp.begin() + 5, resp.begin() + 5 + nameLength) == "MULTIPOINT_SETTING")
			{
				slot = candidate;
				break;
			}
		}
		slotSearched = true;
	}
	target = &log;

	bool hasMultipointSetting = false; bool multipointEnabled = false;
	if (slot > 0)
	{
		// d7 <slot> <type 00=boolean> <value 00=ON 01=OFF>
		auto resp = read({ (char)V2Command::GS_GET_PARAM, (char)slot }, V2Command::GS_RET_PARAM, slot, DATA_TYPE::DATA_MDR);
		if (resp.size() >= 4 && resp[2] == 0x00)
		{
			hasMultipointSetting = true;
			multipointEnabled = resp[3] == 0x00;
		}
	}

	std::lock_guard guard(this->_propertyMtx);
	this->_table2FunctionsRead = functionsRead;
	this->_table2Functions = functions;
	this->_multipointSlotSearched = slotSearched;
	this->_multipointSlot = slot;
	this->_hasPairedDevices = hasPairedDevices;
	this->_pairedDevices = pairedDevices;
	this->_hasPlaybackPinState = hasPinState;
	this->_playbackPinned = pinned;
	this->_hasMultipointSetting = hasMultipointSetting;
	this->_multipointEnabled = multipointEnabled;
	this->_multipointDiscoveryLog = discoveryLog;
	this->_multipointDiagnostics = "init " + (initReply.empty() ? std::string("(no reply)") : hexString(initReply)) + "\n"
		+ discoveryLog + this->_multipointWriteLog + log;
}

int Headphones::switchPlaybackDevice(const std::string& address)
{
	std::string target;
	{
		std::lock_guard guard(this->_propertyMtx);
		bool supported = this->_table2Supported && std::find(this->_table2Functions.begin(), this->_table2Functions.end(),
			V2Table2Command::FN_SOURCE_SWITCH) != this->_table2Functions.end();
		if (!supported) throw RecoverableException("This headset doesn't support switching the playback device.");
		auto sameAddress = [&](const std::string& other) {
			return other.size() == address.size() && std::equal(other.begin(), other.end(), address.begin(),
				[](char a, char b) { return std::toupper((unsigned char)a) == std::toupper((unsigned char)b); });
		};
		for (const auto& device : this->_pairedDevices)
		{
			if (device.slot != 0 && sameAddress(device.address)) target = device.address;
		}
	}
	if (target.size() != V2Table2Command::BT_ADDRESS_LENGTH)
	{
		throw RecoverableException("That device isn't connected to the headset.");
	}

	// SET: 3c 01 <address, exactly as the headset reported it>  ->  NTFY: 3d 01 <result> <address>
	Buffer cmd = { (char)V2Table2Command::PERI_SET_EXTENDED_PARAM, (char)V2Table2Command::PERI_SOURCE_SWITCH };
	cmd.insert(cmd.end(), target.begin(), target.end());
	int result = V2Table2Command::RESULT_NO_CONFIRMATION;
	std::string line = "W T2 " + hexString(cmd) + " -> ";
	try
	{
		auto resp = this->_conn.sendCommandAndReadResponse(cmd, V2Table2Command::PERI_NTFY_EXTENDED_PARAM,
			V2Table2Command::PERI_SOURCE_SWITCH, DATA_TYPE::DATA_MDR_NO2);
		line += hexString(resp);
		if (resp.size() >= 3) result = (unsigned char)resp[2];
	}
	catch (const std::exception& exc)
	{
		line += std::string("(") + exc.what() + ")";
	}
	std::lock_guard guard(this->_propertyMtx);
	this->_multipointWriteLog += line + "\n";
	return result;
}

int Headphones::setPlaybackPinned(bool pinned)
{
	{
		std::lock_guard guard(this->_propertyMtx);
		if (!this->_hasPlaybackPinState) throw RecoverableException("This headset doesn't support fixing the playback device.");
	}

	// SET: 38 01 <00=fixed, 01=free>  ->  NTFY: 39 01 <value> <result>
	char value = pinned ? 0x00 : 0x01;
	Buffer cmd = { (char)V2Table2Command::PERI_SET_PARAM, (char)V2Table2Command::PERI_SOURCE_SWITCH, value };
	int result = V2Table2Command::RESULT_NO_CONFIRMATION;
	std::string line = "W T2 " + hexString(cmd) + " -> ";
	try
	{
		auto resp = this->_conn.sendCommandAndReadResponse(cmd, V2Table2Command::PERI_NTFY_PARAM,
			V2Table2Command::PERI_SOURCE_SWITCH, DATA_TYPE::DATA_MDR_NO2);
		line += hexString(resp);
		if (resp.size() >= 4) result = (unsigned char)resp[3];
		else if (resp.size() == 3) result = resp[2] == value ? V2Table2Command::RESULT_SUCCESS : V2Table2Command::RESULT_FAIL;
	}
	catch (const std::exception& exc)
	{
		line += std::string("(") + exc.what() + ")";
	}
	std::lock_guard guard(this->_propertyMtx);
	this->_multipointWriteLog += line + "\n";
	return result;
}

bool Headphones::hasPairedDevices() { std::lock_guard g(this->_propertyMtx); return this->_hasPairedDevices; }
std::vector<PairedDevice> Headphones::getPairedDevices() { std::lock_guard g(this->_propertyMtx); return this->_pairedDevices; }
bool Headphones::hasPlaybackPinState() { std::lock_guard g(this->_propertyMtx); return this->_hasPlaybackPinState; }
bool Headphones::isPlaybackPinned() { std::lock_guard g(this->_propertyMtx); return this->_playbackPinned; }
bool Headphones::hasMultipointSetting() { std::lock_guard g(this->_propertyMtx); return this->_hasMultipointSetting; }
bool Headphones::getMultipointEnabled() { std::lock_guard g(this->_propertyMtx); return this->_multipointEnabled; }
std::string Headphones::getMultipointDiagnostics() { std::lock_guard g(this->_propertyMtx); return this->_multipointDiagnostics; }

void Headphones::setMultipoint(bool enabled)
{
	int slot;
	{
		std::lock_guard guard(this->_propertyMtx);
		if (!this->_hasMultipointSetting) throw RecoverableException("This headset doesn't report a multipoint setting.");
		slot = this->_multipointSlot;
	}
	// The state frame goes first (d8 <slot> 00 <00=on/01=off>), then the fixed apply commit 98 00 06 01.
	// sendCommand waits for each ACK, which reproduces GadgetBridge's frame/ack interleaving.
	this->_conn.sendCommand({ (char)V2Command::GS_SET_PARAM, (char)slot, 0x00, (char)(enabled ? 0x00 : 0x01) });
	this->_conn.sendCommand({ (char)V2Command::SYSCTL_SET, 0x00, (char)V2Command::SUB_SYSCTL_MULTIPOINT, 0x01 });
	std::lock_guard guard(this->_propertyMtx);
	this->_multipointEnabled = enabled;
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
