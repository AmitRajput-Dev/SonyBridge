#include "Headphones.h"
#include "CommandSerializer.h"

#include <stdexcept>

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
	return this->_ambientSoundControl.current;
}

bool Headphones::isFocusOnVoiceAvailable()
{
	return this->_ambientSoundControl.current && this->_asmLevel.current > MINIMUM_VOICE_FOCUS_STEP;
}

void Headphones::setFocusOnVoice(bool val)
{
	std::lock_guard guard(this->_propertyMtx);
	this->_focusOnVoice.desired = val;
}

bool Headphones::getFocusOnVoice()
{
	return this->_focusOnVoice.current;
}

bool Headphones::isSetAsmLevelAvailable()
{
	return this->_ambientSoundControl.current;
}

void Headphones::setAsmLevel(int val)
{
	std::lock_guard guard(this->_propertyMtx);
	this->_asmLevel.desired = val;
}

int Headphones::getAsmLevel()
{
	return this->_asmLevel.current;
}

void Headphones::setSurroundPosition(SOUND_POSITION_PRESET val)
{
	std::lock_guard guard(this->_propertyMtx);
	this->_surroundPosition.desired = val;
}

SOUND_POSITION_PRESET Headphones::getSurroundPosition()
{
	return this->_surroundPosition.current;
}

void Headphones::setVptType(int val)
{
	std::lock_guard guard(this->_propertyMtx);
	this->_vptType.desired = val;
}

int Headphones::getVptType()
{
	return this->_vptType.current;
}

void Headphones::initDevice()
{
	// v2 devices expect an init handshake before they answer GET inquiries. Best-effort: the reply
	// (INIT_REPLY, 8 bytes on v2) is ignored here - we only need the device to enter the ready state.
	this->_conn.sendCommandAndReadResponse(
		{ (char)V2Command::INIT_REQUEST, 0x00 },
		V2Command::INIT_REPLY
	);
}

void Headphones::requestBattery()
{
	// GET: 22 <type=00 single>  ->  RET: 23 <type> <level 0-100> <charging 0/1>
	auto resp = this->_conn.sendCommandAndReadResponse(
		{ (char)V2Command::BATTERY_GET, 0x00 },
		V2Command::BATTERY_RET
	);
	if (resp.size() >= 4)
	{
		std::lock_guard guard(this->_propertyMtx);
		this->_batteryLevel = (unsigned char)resp[2];
		this->_batteryCharging = resp[3] == 1;
	}
}

int Headphones::getBatteryLevel()
{
	return this->_batteryLevel;
}

bool Headphones::isBatteryCharging()
{
	return this->_batteryCharging;
}

void Headphones::requestEqualizer()
{
	// GET: 56 00  ->  RET: 57 00 <preset> 06 <bass+10> <b1..b5 +10>
	auto resp = this->_conn.sendCommandAndReadResponse(
		{ (char)V2Command::EQ_GET, 0x00 },
		V2Command::EQ_RET
	);
	if (resp.size() >= 3)
	{
		std::lock_guard guard(this->_propertyMtx);
		this->_eqPreset = static_cast<EQ_PRESET>((unsigned char)resp[2]);
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

EQ_PRESET Headphones::getEqualizerPreset()
{
	return this->_eqPreset;
}

void Headphones::setEqualizerPreset(EQ_PRESET preset)
{
	// SET preset: 58 00 <preset> 00
	this->_conn.sendCommand({
		(char)V2Command::EQ_SET,
		0x00,
		(char)static_cast<unsigned char>(preset),
		0x00
	});
	std::lock_guard guard(this->_propertyMtx);
	this->_eqPreset = preset;
}

void Headphones::setEqualizerCustom(int clearBass, const std::vector<int>& bands)
{
	// SET custom: 58 00 A0 06 <clearBass+10> <b1..b5 +10>  (0xA0 = MANUAL preset; values clamped to [-10,10])
	auto clamp = [](int v) { return (char)(unsigned char)(std::max(-10, std::min(10, v)) + 10); };
	Buffer cmd = {
		(char)V2Command::EQ_SET,
		0x00,
		(char)static_cast<unsigned char>(EQ_PRESET::MANUAL),
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
	this->_eqClearBass = clearBass;
	for (int i = 0; i < 5; i++)
	{
		this->_eqBands[i] = i < (int)bands.size() ? bands[i] : 0;
	}
}

int Headphones::getClearBass()
{
	return this->_eqClearBass;
}

int Headphones::getEqualizerBand(int index)
{
	return (index >= 0 && index < (int)this->_eqBands.size()) ? this->_eqBands[index] : 0;
}

void Headphones::requestDsee()
{
	// GET: e6 01  ->  RET: e7 01 <enabled 0/1>
	auto resp = this->_conn.sendCommandAndReadResponse(
		{ (char)V2Command::DSEE_GET, 0x01 },
		V2Command::DSEE_RET
	);
	if (resp.size() >= 3)
	{
		std::lock_guard guard(this->_propertyMtx);
		this->_dsee = resp[2] != 0;
	}
}

bool Headphones::getDsee()
{
	return this->_dsee;
}

void Headphones::setDsee(bool enabled)
{
	// SET: e8 01 <enabled 0/1>
	this->_conn.sendCommand({
		(char)V2Command::DSEE_SET,
		0x01,
		(char)(enabled ? 0x01 : 0x00)
	});
	std::lock_guard guard(this->_propertyMtx);
	this->_dsee = enabled;
}

bool Headphones::isChanged()
{
	return !(this->_ambientSoundControl.isFulfilled() && this->_asmLevel.isFulfilled() && this->_focusOnVoice.isFulfilled() && this->_surroundPosition.isFulfilled() && this->_vptType.isFulfilled());
}

void Headphones::setChanges()
{
	auto protocolVersion = this->_conn.getProtocolVersion();

	if (!(this->_ambientSoundControl.isFulfilled() && this->_focusOnVoice.isFulfilled() && this->_asmLevel.isFulfilled()))
	{
		if (protocolVersion == SonyProtocolVersion::V2)
		{
			// v2 has no separate "disabled" level - NC vs Ambient Sound is its own field, and level is 1-based.
			char asmLevel = static_cast<char>(this->_asmLevel.desired > 0 ? this->_asmLevel.desired : 1);

			this->_conn.sendCommand(CommandSerializer::serializeNcAndAsmSettingV2(
				this->_ambientSoundControl.desired ? NC_ASM_EFFECT::ON : NC_ASM_EFFECT::OFF,
				this->_asmLevel.desired > 0 ? NC_ASM_SETTING_TYPE_V2::AMBIENT_SOUND : NC_ASM_SETTING_TYPE_V2::NOISE_CANCELLING,
				this->_focusOnVoice.desired ? ASM_ID::VOICE : ASM_ID::NORMAL,
				asmLevel
			));
		}
		else
		{
			auto ncAsmEffect = this->_ambientSoundControl.desired ? NC_ASM_EFFECT::ADJUSTMENT_COMPLETION : NC_ASM_EFFECT::OFF;
			auto asmId = this->_focusOnVoice.desired ? ASM_ID::VOICE : ASM_ID::NORMAL;
			auto asmLevel = this->_ambientSoundControl.desired ? this->_asmLevel.desired : ASM_LEVEL_DISABLED;

			this->_conn.sendCommand(CommandSerializer::serializeNcAndAsmSetting(
				ncAsmEffect,
				NC_ASM_SETTING_TYPE::LEVEL_ADJUSTMENT,
				ASM_SETTING_TYPE::LEVEL_ADJUSTMENT,
				asmId,
				asmLevel
			));
		}

		std::lock_guard guard(this->_propertyMtx);
		this->_ambientSoundControl.fulfill();
		this->_asmLevel.fulfill();
		this->_focusOnVoice.fulfill();
	}

	// VPT/Surround has no known v2 command and no hardware on v2-only devices like the CH720N - v1 only.
	if (protocolVersion == SonyProtocolVersion::V1 && !(this->_vptType.isFulfilled() && this->_surroundPosition.isFulfilled())) {
		VPT_INQUIRED_TYPE command;
		unsigned char preset;

		if (this->_vptType.desired != 0) {
			command = VPT_INQUIRED_TYPE::VPT;
			preset = static_cast<unsigned char>(this->_vptType.desired);
		}
		else if (this->_surroundPosition.desired != SOUND_POSITION_PRESET::OFF) {
			command = VPT_INQUIRED_TYPE::SOUND_POSITION;
			preset = static_cast<unsigned char>(this->_surroundPosition.desired);
		}
		else {
			// Just used that one because it seems like it disables both
			if (this->_surroundPosition.current != SOUND_POSITION_PRESET::OFF) {
				command = VPT_INQUIRED_TYPE::SOUND_POSITION;
				preset = static_cast<unsigned char>(SOUND_POSITION_PRESET::OFF);
			}
			else if (this->_vptType.current != 0) {
				command = VPT_INQUIRED_TYPE::VPT;
				preset = 0;
			}
			else {
				throw std::logic_error("it's impossible that both values were changed to zero and were also previously zero");
			}
		}

		this->_conn.sendCommand(CommandSerializer::serializeVPTSetting(command, preset));

		std::lock_guard guard(this->_propertyMtx);
		this->_vptType.fulfill();
		this->_surroundPosition.fulfill();
	}
}
