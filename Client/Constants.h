#pragma once

#include <vector>

inline constexpr auto MAX_BLUETOOTH_MESSAGE_SIZE = 2048;
inline constexpr char START_MARKER{ 62 };
inline constexpr char END_MARKER{ 60 };

inline constexpr auto MAC_ADDR_STR_SIZE = 17;

inline constexpr auto SERVICE_UUID = "96CC203E-5068-46ad-B32D-E316F5E069BA";
inline unsigned char SERVICE_UUID_IN_BYTES[] = { // this is the SERVICE_UUID but in bytes
	0x96, 0xcc, 0x20, 0x3e, 0x50, 0x68, 0x46, 0xad,
	0xb3, 0x2d, 0xe3, 0x16, 0xf5, 0xe0, 0x69, 0xba
};

// Second-generation Sony protocol (WH-CH720N, WF/WH-1000XM5, newer XM4/WF-C700N units, etc).
inline constexpr auto SERVICE_UUID_V2 = "956C7B26-D49A-4BA8-B03F-B17D393CB6E2";
inline unsigned char SERVICE_UUID_V2_IN_BYTES[] = { // this is the SERVICE_UUID_V2 but in bytes
	0x95, 0x6c, 0x7b, 0x26, 0xd4, 0x9a, 0x4b, 0xa8,
	0xb0, 0x3f, 0xb1, 0x7d, 0x39, 0x3c, 0xb6, 0xe2
};

enum class SonyProtocolVersion : signed char
{
	V1 = 0,
	V2 = 1
};

// Second-generation (v2) inquiry/response command opcodes (the first payload byte).
// Byte layouts reverse-engineered by GadgetBridge (SonyProtocolImplV2); verified against WH-CH720N.
namespace V2Command
{
	inline constexpr unsigned char INIT_REQUEST = 0x00; // payload: 00 00
	inline constexpr unsigned char INIT_REPLY   = 0x01; // reply: 01 ... (8 bytes total => v2 device)
	inline constexpr unsigned char BATTERY_GET  = 0x22; // payload: 22 <sub-type>
	inline constexpr unsigned char BATTERY_RET  = 0x23; // reply: 23 <sub-type> <level 0-100> <charging 0/1>
	inline constexpr unsigned char BATTERY_NTFY = 0x25; // notify: 25 <sub-type> <level> <charging>
	// Battery inquiry sub-types (payload byte 1). A device answers only the ones it actually has, so
	// these have to be probed. TWS earbuds report DUAL (or DUAL2 on the WF-C5xx/C700N line) plus CASE;
	// everything else reports SINGLE. Values and the DUAL byte layout match GadgetBridge's
	// SonyProtocolImplV2.encodeBatteryType() / handleBattery().
	inline constexpr unsigned char BATTERY_SUB_SINGLE = 0x00; // RET 23 00 <level> <charging>
	inline constexpr unsigned char BATTERY_SUB_DUAL2  = 0x01; // WF-C500 / WF-C510 / WF-C700N
	inline constexpr unsigned char BATTERY_SUB_DUAL   = 0x09; // WF-1000XM4 / WF-1000XM5 / LinkBuds
	inline constexpr unsigned char BATTERY_SUB_CASE   = 0x0a; // RET 23 0a <level> <charging>
	// DUAL/DUAL2 reply: 23 <sub> <Llvl> <Lchg> <Rlvl> <Rchg>. A level of 0 means that earbud isn't
	// reporting (docked in the case / powered down) rather than "empty" - treat it as unknown.
	//
	// The reply can be LONGER than the reference layout, so size checks must be lower bounds, never
	// equality. Captured from a WF-1000XM5 (fw 6.1.0), both earbuds out of the case and full:
	//   send 22 09  ->  23 09 64 00 64 00 64 64   (8 bytes; documented layout is 6)
	//   send 22 0a  ->  23 0a 64 00 1e            (5 bytes; documented layout is 4)
	// Confirmed on hardware by docking one earbud and watching the frames change:
	//   right earbud in the case  ->  23 09 64 00 00 00 64 64   (byte [4] = R went 0x64 -> 0x00)
	//   right earbud back out     ->  23 09 64 00 64 00 64 64
	// So bytes [2]/[4] really are the L/R levels, as in the reference layout. The trailing bytes stayed
	// fixed (0x64 0x64 on 22 09, 0x1e on 22 0a) across that change, which rules them out as per-earbud
	// levels but leaves their meaning unknown - don't reuse them without a sample that moves them.
	inline constexpr unsigned char EQ_GET       = 0x56; // payload: 56 00
	inline constexpr unsigned char EQ_RET       = 0x57; // reply: 57 00 <preset> 06 <bass+10> <b1..b5 +10>
	inline constexpr unsigned char EQ_SET       = 0x58; // preset: 58 00 <preset> 00 ; custom: 58 00 A0 06 <bass+10> <b1..b5 +10>
	// AUDIO parameter family. The opcode trio is shared by every audio parameter; the sub-type byte
	// (payload[1]) picks which one, so DSEE and the sound-quality mode differ only in that byte.
	inline constexpr unsigned char AUDIO_GET    = 0xe6; // GET e6 <sub>      -> RET e7 <sub> <value>
	inline constexpr unsigned char AUDIO_RET    = 0xe7;
	inline constexpr unsigned char AUDIO_SET    = 0xe8; // SET e8 <sub> <value>
	inline constexpr unsigned char DSEE_GET     = AUDIO_GET; // payload: e6 01
	inline constexpr unsigned char DSEE_RET     = AUDIO_RET; // reply: e7 01 <enabled 0/1>
	inline constexpr unsigned char DSEE_SET     = AUDIO_SET; // payload: e8 01 <enabled 0/1>
	// AUDIO sub-types (Sony's AudioInquiredType). Only the ones we actually send are listed.
	inline constexpr unsigned char SUB_CONNECTION_MODE      = 0x00; // sound quality mode, plain
	inline constexpr unsigned char SUB_UPSCALING            = 0x01; // DSEE
	inline constexpr unsigned char SUB_CONNECTION_MODE_LDAC = 0x02; // same, on LDAC-capable models
	// Deliberately NOT sent: 0x05 (CONNECTION_MODE_CLASSIC_AUDIO_LE_AUDIO). Its SET carries a fourth byte
	// that also switches the device between Classic and LE Audio, which would drop the link for reasons
	// the user didn't ask for. Devices that only answer 0x05 simply report the feature as unsupported.
	inline constexpr unsigned char FW_GET       = 0x04; // payload: 04 02  -> RET 05 02 <ascii version...>
	inline constexpr unsigned char FW_RET       = 0x05;
	inline constexpr unsigned char CODEC_GET    = 0x12; // payload: 12 02  -> RET 13 02 <codec>
	inline constexpr unsigned char CODEC_RET    = 0x13;
	inline constexpr unsigned char APO_GET      = 0x26; // auto power off. GET 26 05 -> RET 27 05 <c0> <c1>
	inline constexpr unsigned char APO_RET      = 0x27;
	inline constexpr unsigned char APO_SET      = 0x28; // SET 28 05 <c0> <c1>
	// Multiplexed button-mode family: sub-type byte selects the feature (0x0a=adaptive volume, 0x0c=speak-to-chat).
	inline constexpr unsigned char BTNMODE_GET  = 0xf6; // GET f6 <sub> -> RET f7 <sub> ...
	inline constexpr unsigned char BTNMODE_RET  = 0xf7;
	inline constexpr unsigned char BTNMODE_SET  = 0xf8; // SET f8 <sub> <value...>
	inline constexpr unsigned char SUB_ADAPTIVE_VOLUME = 0x0a;
	inline constexpr unsigned char SUB_SPEAK_TO_CHAT   = 0x0c;
}

// Sound quality mode ("Bluetooth connection quality" in the Sony app) - the value byte of the
// AUDIO CONNECTION_MODE sub-types. Sony's PriorMode enum also has LOW_LATENCY_PRIOR_BETA (0x02), which
// no shipping model exposes in its app, so we don't offer it.
enum class PRIOR_MODE : unsigned char
{
	SOUND_QUALITY = 0x00,
	STABLE_CONNECTION = 0x01
};

// v2 equalizer preset ids (byte value sent/received at EQ payload[2]).
enum class EQ_PRESET : unsigned char
{
	OFF = 0x00,
	BRIGHT = 0x10,
	EXCITED = 0x11,
	MELLOW = 0x12,
	RELAXED = 0x13,
	VOCAL = 0x14,
	TREBLE_BOOST = 0x15,
	BASS_BOOST = 0x16,
	SPEECH = 0x17,
	MANUAL = 0xa0
};

#define APP_NAME "SonyBridge " __HEADPHONES_APP_VERSION__
#define APP_NAME_W (L"" APP_NAME)

using Buffer = std::vector<char>;

enum class DATA_TYPE : signed char
{
	DATA = 0,
	ACK = 1,
    DATA_MC_NO1 = 2,
    DATA_ICD = 9,
    DATA_EV = 10,
	DATA_MDR = 12,
    DATA_COMMON = 13,
    DATA_MDR_NO2 = 14,
    SHOT =  16,
    SHOT_MC_NO1 =  18,
    SHOT_ICD =  25,
    SHOT_EV =  26,
    SHOT_MDR =  28,
    SHOT_COMMON =  29,
    SHOT_MDR_NO2 = 30,
    LARGE_DATA_COMMON =  45,
    UNKNOWN = -1
};


enum class NC_ASM_INQUIRED_TYPE : signed char
{
	NO_USE = 0,
	NOISE_CANCELLING = 1,
	NOISE_CANCELLING_AND_AMBIENT_SOUND_MODE = 2,
	AMBIENT_SOUND_MODE = 3
};

enum class NC_ASM_EFFECT : signed char
{
	OFF = 0,
	ON = 1,
	ADJUSTMENT_IN_PROGRESS = 16,
	ADJUSTMENT_COMPLETION = 17
};

enum class NC_ASM_SETTING_TYPE : signed char
{
	ON_OFF = 0,
	LEVEL_ADJUSTMENT = 1,
	DUAL_SINGLE_OFF = 2
};

// v2 protocol reuses the NCASM_SET_PARAM command id but with a different byte layout and
// different meaning for this field than NC_ASM_SETTING_TYPE (v1) - kept as a separate enum
// rather than overloading NC_ASM_SETTING_TYPE's values.
enum class NC_ASM_SETTING_TYPE_V2 : signed char
{
	NOISE_CANCELLING = 0,
	AMBIENT_SOUND = 1
};

enum class ASM_SETTING_TYPE : signed char
{
	ON_OFF = 0,
	LEVEL_ADJUSTMENT = 1
};

enum class ASM_ID : signed char
{
	NORMAL = 0,
	VOICE = 1
};

enum class NC_DUAL_SINGLE_VALUE : signed char
{
	OFF = 0,
	SINGLE = 1,
	DUAL = 2
};

enum class COMMAND_TYPE : signed char
{
	VPT_SET_PARAM = 72,
	NCASM_SET_PARAM = 104
};

enum class VPT_PRESET_ID : signed char
{
	OFF = 0,
	OUTDOOR_FESTIVAL = 1,
	ARENA = 2,
	CONCERT_HALL = 3,
	CLUB = 4
	//Note: Sony reserved 5~15 "for future"
};

enum class SOUND_POSITION_PRESET : signed char
{
	OFF = 0,
	FRONT_LEFT = 1,
	FRONT_RIGHT = 2,
	FRONT = 3,
	REAR_LEFT = 17,
	REAR_RIGHT = 18,
	OUT_OF_RANGE = -1
};

//Needed for converting the ImGui Combo index into the VPT index.
inline const SOUND_POSITION_PRESET SOUND_POSITION_PRESET_ARRAY[] = {
	SOUND_POSITION_PRESET::OFF,
	SOUND_POSITION_PRESET::FRONT_LEFT,
	SOUND_POSITION_PRESET::FRONT_RIGHT,
	SOUND_POSITION_PRESET::FRONT,
	SOUND_POSITION_PRESET::REAR_LEFT,
	SOUND_POSITION_PRESET::REAR_RIGHT,
	SOUND_POSITION_PRESET::OUT_OF_RANGE
};

enum class VPT_INQUIRED_TYPE : signed char
{
	NO_USE = 0,
	VPT = 1,
	SOUND_POSITION = 2,
	OUT_OF_RANGE = -1
};
