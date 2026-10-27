#pragma once

#include <cstddef>
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

// Second-generation Sony protocol (WH-CH720N, WF/WH-1000XM5, WF-C700N, etc).
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

// First-generation MDR protocol used by the WH-1000XM4 and earlier models. Several values overlap
// with v2 but mean something entirely different, so call sites must select a namespace only after
// the SDP service UUID has established the protocol version.
namespace V1Command
{
	inline constexpr unsigned char INIT_REQUEST = 0x00;
	inline constexpr unsigned char INIT_REPLY   = 0x01;
	inline constexpr unsigned char FW_GET       = 0x04;
	inline constexpr unsigned char FW_RET       = 0x05;
	inline constexpr unsigned char BATTERY_GET  = 0x10;
	inline constexpr unsigned char BATTERY_RET  = 0x11;
	inline constexpr unsigned char CODEC_GET    = 0x18;
	inline constexpr unsigned char CODEC_RET    = 0x19;
	inline constexpr unsigned char POWER_OFF    = 0x22;
	inline constexpr unsigned char EQ_GET       = 0x56;
	inline constexpr unsigned char EQ_RET       = 0x57;
	inline constexpr unsigned char EQ_SET       = 0x58;
	inline constexpr unsigned char AMBIENT_GET  = 0x66;
	inline constexpr unsigned char AMBIENT_RET  = 0x67;
	inline constexpr unsigned char AMBIENT_SET  = 0x68;
	inline constexpr unsigned char DSEE_GET     = 0xe6;
	inline constexpr unsigned char DSEE_RET     = 0xe7;
	inline constexpr unsigned char DSEE_SET     = 0xe8;
	inline constexpr unsigned char BTNMODE_GET  = 0xf6;
	inline constexpr unsigned char BTNMODE_RET  = 0xf7;
	inline constexpr unsigned char BTNMODE_SET  = 0xf8;
	inline constexpr unsigned char SUB_AUTO_POWER_OFF = 0x04;
	inline constexpr unsigned char SUB_SPEAK_TO_CHAT  = 0x05;
	inline constexpr unsigned char MANUAL_EQ = 0xff;
}

// Second-generation (v2) inquiry/response command opcodes (the first payload byte).
// Byte layouts reverse-engineered by GadgetBridge (SonyProtocolImplV2); verified against WH-CH720N.
namespace V2Command
{
	inline constexpr unsigned char INIT_REQUEST = 0x00; // payload: 00 00
	inline constexpr unsigned char INIT_REPLY   = 0x01; // reply: 01 ... (8 bytes total => v2 device)
	inline constexpr unsigned char BATTERY_GET  = 0x22; // payload: 22 <type: 00=single>
	inline constexpr unsigned char BATTERY_RET  = 0x23; // reply: 23 <type> <level 0-100> <charging 0/1>
	inline constexpr unsigned char BATTERY_NTFY = 0x25; // notify: 25 <type> <level> <charging>
	inline constexpr unsigned char EQ_GET       = 0x56; // payload: 56 00
	inline constexpr unsigned char EQ_RET       = 0x57; // reply: 57 00 <preset> 06 <bass+10> <b1..b5 +10>
	inline constexpr unsigned char EQ_SET       = 0x58; // preset: 58 00 <preset> 00 ; custom: 58 00 A0 06 <bass+10> <b1..b5 +10>
	inline constexpr unsigned char DSEE_GET     = 0xe6; // payload: e6 01
	inline constexpr unsigned char DSEE_RET     = 0xe7; // reply: e7 01 <enabled 0/1>
	inline constexpr unsigned char DSEE_SET     = 0xe8; // payload: e8 01 <enabled 0/1>
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
	// INIT_REPLY layout: 01 <type> <protocol version, 4 bytes BE> <table1: 00=yes> <table2: 00=yes>
	inline constexpr size_t INIT_REPLY_TABLE2_INDEX = 7;
	// General settings: up to four device-defined boolean/list settings in slots D1..D4. Which slot holds
	// what is per-model, so the slot is found by name via GS_GET_CAPABILITY. Values: 00=ON, 01=OFF.
	inline constexpr unsigned char GS_GET_CAPABILITY = 0xd0; // d0 <slot> <display language 01=English>
	inline constexpr unsigned char GS_RET_CAPABILITY = 0xd1; // d1 <slot> <type> <fmt> <len>name <len>summary
	inline constexpr unsigned char GS_GET_PARAM      = 0xd6; // d6 <slot>
	inline constexpr unsigned char GS_RET_PARAM      = 0xd7; // d7 <slot> <type 00=boolean> <value>
	inline constexpr unsigned char GS_SLOT_FIRST     = 0xd1;
	inline constexpr unsigned char GS_SLOT_LAST      = 0xd4;
	inline constexpr unsigned char GS_DISPLAY_LANGUAGE_ENGLISH = 0x01;
	// SET d8 <slot> 00 <00=ON/01=OFF>. For the multipoint slot the change is committed with the fixed
	// system-control frame 98 00 06 01 (identical bytes for ON and OFF); its RET (97 00 06 xx) always reports
	// 01, so it is never used as a state source. Order and bytes from GadgetBridge's hardware-verified
	// WH-ULT900N support (SonyProtocolImplV2, commits 8cbc309346, e8520865f3, 5d7b37d1b7).
	inline constexpr unsigned char GS_SET_PARAM      = 0xd8;
	inline constexpr unsigned char SYSCTL_SET        = 0x98;
	inline constexpr unsigned char SUB_SYSCTL_MULTIPOINT = 0x06;
}

// Second command table (frame DATA_TYPE::DATA_MDR_NO2 = 0x0e) on v2 devices: multipoint / paired-device
// management. Layouts from mos9527/SonyHeadphonesClient (ProtocolV2T2.hpp, generated from Sound Connect)
// and WF-1000XM5 / WH-1000XM6 captures.
// NEVER send these with DATA_MDR (0x0c): in table 1, 0x30-0x3f are the firmware-update (UPDT) commands.
namespace V2Table2Command
{
	inline constexpr unsigned char SUPPORT_FUNCTION_GET = 0x06; // 06 00
	inline constexpr unsigned char SUPPORT_FUNCTION_RET = 0x07; // 07 00 <n> (<function> <priority>) x n
	inline constexpr unsigned char PERI_GET_PARAM       = 0x36; // 36 <inquired type>
	inline constexpr unsigned char PERI_RET_PARAM       = 0x37;
	inline constexpr unsigned char PERI_SET_PARAM       = 0x38; // 38 01 <00=fix playback, 01=free>
	inline constexpr unsigned char PERI_NTFY_PARAM      = 0x39; // 39 01 <value> <result>
	inline constexpr unsigned char PERI_SET_EXTENDED_PARAM  = 0x3c; // 3c 01 <target address, 17 ASCII>
	inline constexpr unsigned char PERI_NTFY_EXTENDED_PARAM = 0x3d; // 3d 01 <result> <target address>

	// Source-switch results (switch / fix writes). NO_CONFIRMATION is ours: no notify within the timeout.
	inline constexpr int RESULT_SUCCESS = 0x00;
	inline constexpr int RESULT_FAIL = 0x01;
	inline constexpr int RESULT_FAIL_CALLING = 0x02;
	inline constexpr int RESULT_FAIL_A2DP_NOT_CONNECTED = 0x03;
	inline constexpr int RESULT_FAIL_VOICE_ASSISTANT = 0x04;
	inline constexpr int RESULT_NO_CONFIRMATION = -1;

	// Inquired types (payload[1] of the PERI_* commands).
	inline constexpr unsigned char PERI_DEVICES_CLASSIC = 0x00;   // device list without class of device
	inline constexpr unsigned char PERI_SOURCE_SWITCH   = 0x01;   // 37 01 <1=switching free, 0=playback fixed>
	inline constexpr unsigned char PERI_DEVICES_WITH_COD = 0x02;  // device list with class of device

	// Function ids in the SUPPORT_FUNCTION_RET list.
	inline constexpr unsigned char FN_DEVICES_CLASSIC    = 0x30;
	inline constexpr unsigned char FN_SOURCE_SWITCH      = 0x31;
	inline constexpr unsigned char FN_DEVICES_WITH_COD   = 0x32;
	inline constexpr unsigned char FN_DEVICES_WITH_COD_LE = 0x33;

	inline constexpr size_t BT_ADDRESS_LENGTH = 17; // ASCII "XX:XX:XX:XX:XX:XX", no terminator
}

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
