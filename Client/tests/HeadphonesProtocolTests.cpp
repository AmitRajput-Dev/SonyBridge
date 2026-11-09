#include "BluetoothWrapper.h"
#include "CommandSerializer.h"
#include "Exceptions.h"
#include "Headphones.h"

#include <algorithm>
#include <cstring>
#include <deque>
#include <functional>
#include <iostream>
#include <memory>
#include <stdexcept>

namespace
{
class FakeV1Connector final : public IBluetoothConnector
{
public:
	int send(char* buf, size_t length) override
	{
		Buffer frame(buf, buf + length);
		if (frame.size() < 2 || frame.front() != START_MARKER || frame.back() != END_MARKER)
			throw std::runtime_error("invalid outbound frame");

		Buffer body(frame.begin() + 1, frame.end() - 1);
		auto message = CommandSerializer::unpackBtMessage(body);
		if (message.dataType != DATA_TYPE::DATA_MDR) return static_cast<int>(length);

		sentPayloads.push_back(message.payload);
		if (notificationBeforeNextAck) {
			queue({ (char)V1Command::AMBIENT_RET, 0x02, 0x11, 0x02, 0x02, 0x01, 0x00, 0x00 }, DATA_TYPE::DATA_MDR, 0);
			notificationBeforeNextAck = false;
		}
		queue({}, DATA_TYPE::ACK, 1 - message.seqNumber);
		queueResponse(message.payload);
		return static_cast<int>(length);
	}

	int recv(char* buf, size_t length) override
	{
		if (incoming.empty()) throw std::runtime_error("fake connector has no queued response");
		auto frame = std::move(incoming.front());
		incoming.pop_front();
		if (!recvPrefix.empty()) {
			frame.insert(frame.begin(), recvPrefix.begin(), recvPrefix.end());
			recvPrefix.clear();
		}
		if (frame.size() > length) throw std::runtime_error("fake response exceeds receive buffer");
		std::memcpy(buf, frame.data(), frame.size());
		return static_cast<int>(frame.size());
	}

	void connect(const std::string&) override { connected = true; }
	void disconnect() noexcept override { connected = false; }
	bool isConnected() noexcept override { return connected; }
	std::vector<BluetoothDevice> getConnectedDevices() override { return {}; }
	SonyProtocolVersion getProtocolVersion() noexcept override { return SonyProtocolVersion::V1; }

	std::vector<Buffer> sentPayloads;
	Buffer recvPrefix;
	bool notificationBeforeNextAck = false;

private:
	void queue(const Buffer& payload, DATA_TYPE type, unsigned char sequence)
	{
		incoming.push_back(CommandSerializer::packageDataForBt(payload, type, sequence));
	}

	void queueResponse(const Buffer& request)
	{
		if (request.empty()) return;
		Buffer response;
		switch ((unsigned char)request[0])
		{
		case V1Command::INIT_REQUEST: response = { (char)V1Command::INIT_REPLY, 0x00, 0x40, 0x10 }; break;
		case V1Command::FW_GET: response = { (char)V1Command::FW_RET, 0x02, 0x05, '3', '.', '0', '.', '1' }; break;
		case V1Command::BATTERY_GET: response = { (char)V1Command::BATTERY_RET, 0x00, 87, 0x00 }; break;
		case V1Command::CODEC_GET: response = { (char)V1Command::CODEC_RET, 0x00, 0x10 }; break;
		case V1Command::EQ_GET: response = { (char)V1Command::EQ_RET, 0x01, 0x10, 0x06, 10, 10, 10, 10, 10, 10 }; break;
		case V1Command::DSEE_GET: response = { (char)V1Command::DSEE_RET, 0x02, 0x00, 0x01 }; break;
		case V1Command::AMBIENT_GET: response = { (char)V1Command::AMBIENT_RET, 0x02, 0x11, 0x02, 0x02, 0x01, 0x00, 0x00 }; break;
		case V1Command::BTNMODE_GET:
			if (request.size() >= 2 && (unsigned char)request[1] == V1Command::SUB_AUTO_POWER_OFF)
				response = { (char)V1Command::BTNMODE_RET, (char)V1Command::SUB_AUTO_POWER_OFF, 0x01, 0x01, 0x01 };
			else if (request.size() >= 2 && (unsigned char)request[1] == V1Command::SUB_SPEAK_TO_CHAT)
				response = { (char)V1Command::BTNMODE_RET, (char)V1Command::SUB_SPEAK_TO_CHAT, 0x01, 0x01 };
			break;
		default: return; // SET commands only need the ACK already queued above.
		}
		if (!response.empty()) queue(response, DATA_TYPE::DATA_MDR, 0);
	}

	bool connected = true;
	std::deque<Buffer> incoming;
};

// v2-generation device scripted per test through `reply`: a request it returns an empty buffer for gets
// only the ACK, so the read times out (recv on an empty queue throws), which callers treat as "unsupported".
class FakeV2Connector final : public IBluetoothConnector
{
public:
	int send(char* buf, size_t length) override
	{
		Buffer frame(buf, buf + length);
		if (frame.size() < 2 || frame.front() != START_MARKER || frame.back() != END_MARKER)
			throw std::runtime_error("invalid outbound frame");

		Buffer body(frame.begin() + 1, frame.end() - 1);
		auto message = CommandSerializer::unpackBtMessage(body);
		if (message.dataType != DATA_TYPE::DATA_MDR) return static_cast<int>(length);

		sentPayloads.push_back(message.payload);
		queue({}, DATA_TYPE::ACK, 1 - message.seqNumber);
		auto response = reply ? reply(message.payload) : Buffer{};
		if (!response.empty()) queue(response, DATA_TYPE::DATA_MDR, 0);
		return static_cast<int>(length);
	}

	int recv(char* buf, size_t length) override
	{
		if (incoming.empty()) throw std::runtime_error("fake connector has no queued response");
		auto frame = std::move(incoming.front());
		incoming.pop_front();
		if (frame.size() > length) throw std::runtime_error("fake response exceeds receive buffer");
		std::memcpy(buf, frame.data(), frame.size());
		return static_cast<int>(frame.size());
	}

	void connect(const std::string&) override { connected = true; }
	void disconnect() noexcept override { connected = false; }
	bool isConnected() noexcept override { return connected; }
	std::vector<BluetoothDevice> getConnectedDevices() override { return {}; }
	SonyProtocolVersion getProtocolVersion() noexcept override { return SonyProtocolVersion::V2; }

	std::vector<Buffer> sentPayloads;
	std::function<Buffer(const Buffer&)> reply;

	bool sent(const Buffer& payload) const
	{
		return std::find(sentPayloads.begin(), sentPayloads.end(), payload) != sentPayloads.end();
	}

private:
	void queue(const Buffer& payload, DATA_TYPE type, unsigned char sequence)
	{
		incoming.push_back(CommandSerializer::packageDataForBt(payload, type, sequence));
	}

	bool connected = true;
	std::deque<Buffer> incoming;
};

Buffer bytes(std::initializer_list<int> values)
{
	Buffer out;
	for (int v : values) out.push_back((char)v);
	return out;
}

void require(bool condition, const char* message)
{
	if (!condition) throw std::runtime_error(message);
}

// A malformed inbound frame must surface as a RecoverableException (caught at every call
// site and shown in the UI) rather than a bare std::runtime_error. If a future call site
// narrowed its catch to RecoverableException, a plain runtime_error here would reach
// std::terminate on attacker-controlled input.
template <typename Fn>
void expectRecoverable(Fn&& fn, const char* message)
{
	try { fn(); }
	catch (const RecoverableException&) { return; }
	catch (...) { throw std::runtime_error(message); }
	throw std::runtime_error(message);
}
}

int main()
{
	auto fake = std::make_unique<FakeV1Connector>();
	auto* observed = fake.get();
	BluetoothWrapper bluetooth(std::move(fake));
	Headphones headphones(bluetooth);

	// RFCOMM stacks may deliver harmless transport noise before a start marker. It must not become part
	// of the checksum-protected Sony frame.
	observed->recvPrefix = { 0x00, 0x7f };
	headphones.initDevice();
	headphones.requestAmbientState();
	headphones.requestBattery();
	headphones.requestEqualizer();
	headphones.requestDsee();
	headphones.probeCapabilities();

	require(headphones.hasBattery(), "v1 battery capability was not recorded");
	require(headphones.getBatteryLevel() == 87, "v1 battery response was not parsed");
	require(headphones.hasEqualizer(), "v1 equalizer capability was not recorded");
	require(headphones.getEqualizerPreset() == EQ_PRESET::BRIGHT, "v1 equalizer response was not parsed");
	require(headphones.hasDsee() && headphones.getDsee(), "v1 DSEE response was not parsed");
	require(headphones.getAmbientSoundControl(), "v1 ANC response was not parsed");
	require(headphones.getAsmLevel() == 0, "v1 ANC response was mistaken for ambient sound");
	require(headphones.hasFirmware() && headphones.getFirmware() == "3.0.1", "v1 firmware response was not parsed");
	require(headphones.hasCodec() && headphones.getCodec() == "LDAC", "v1 codec response was not parsed");
	require(headphones.hasAutoPowerOff() && headphones.getAutoPowerOff() == 2, "v1 auto-power-off response was not parsed");
	require(headphones.hasSpeakToChat() && headphones.getSpeakToChat(), "v1 Speak-to-Chat response was not parsed");

	const auto hasV1BatteryRequest = std::any_of(observed->sentPayloads.begin(), observed->sentPayloads.end(), [](const Buffer& payload) {
		return payload.size() >= 2 && (unsigned char)payload[0] == V1Command::BATTERY_GET && payload[1] == 0x00;
	});
	const auto hasDangerousV2BatteryRequest = std::any_of(observed->sentPayloads.begin(), observed->sentPayloads.end(), [](const Buffer& payload) {
		return !payload.empty() && (unsigned char)payload[0] == V2Command::BATTERY_GET;
	});
	require(hasV1BatteryRequest, "XM4 path did not issue the v1 battery inquiry");
	require(!hasDangerousV2BatteryRequest, "XM4 path emitted v2 battery / v1 power-off opcode 0x22");

	headphones.setAmbientSoundControl(true);
	headphones.setAsmLevel(20);
	headphones.setFocusOnVoice(false);
	headphones.setChanges();
	const auto hasLevel20 = std::any_of(observed->sentPayloads.begin(), observed->sentPayloads.end(), [](const Buffer& payload) {
		return payload.size() == 8 && (unsigned char)payload[0] == V1Command::AMBIENT_SET &&
			(unsigned char)payload[7] == 20;
	});
	require(hasLevel20,
		"XM4 ambient level 20 was not serialized correctly");

	headphones.setAsmLevel(1);
	headphones.setChanges();
	const auto& ambientLevelOne = observed->sentPayloads.back();
	require(ambientLevelOne.size() == 8 && (unsigned char)ambientLevelOne[4] == 0x00 &&
		(unsigned char)ambientLevelOne[7] == 0x01,
		"XM4 ambient level 1 was mistaken for wind/noise cancellation");

	headphones.setEqualizerCustom(3, { -2, -1, 0, 1, 2 });
	require(!observed->sentPayloads.empty(), "custom EQ command was not sent");
	const auto& customEq = observed->sentPayloads.back();
	require(customEq.size() == 10 && (unsigned char)customEq[0] == V1Command::EQ_SET,
		"custom EQ did not use the v1 command");
	require((unsigned char)customEq[1] == 0x01 && (unsigned char)customEq[2] == V1Command::MANUAL_EQ,
		"custom EQ did not use the v1 subtype and manual preset byte");

	observed->notificationBeforeNextAck = true;
	headphones.setDsee(false);
	const auto& dsee = observed->sentPayloads.back();
	require(dsee.size() == 4 && (unsigned char)dsee[0] == V1Command::DSEE_SET &&
		(unsigned char)dsee[1] == 0x02 && (unsigned char)dsee[3] == 0x00,
		"DSEE did not use the v1 command layout");

	headphones.setSpeakToChat(false);
	const auto& speakToChat = observed->sentPayloads.back();
	require(speakToChat.size() == 4 && (unsigned char)speakToChat[0] == V1Command::BTNMODE_SET &&
		(unsigned char)speakToChat[1] == V1Command::SUB_SPEAK_TO_CHAT && (unsigned char)speakToChat[3] == 0x00,
		"Speak-to-Chat did not use the v1 command layout");

	// Multipoint has no proven v1 frames (GadgetBridge SonyProtocolImplV1: "Connect two devices not
	// implemented for V1"), so the XM4 path must never probe or set it.
	headphones.requestMultipoint();
	require(!headphones.hasMultipointSetting(), "multipoint capability must stay unconfirmed on v1");
	const auto hasMultipointFrame = std::any_of(observed->sentPayloads.begin(), observed->sentPayloads.end(), [](const Buffer& payload) {
		return !payload.empty() && ((unsigned char)payload[0] == V2Command::GS_GET_CAPABILITY ||
			(unsigned char)payload[0] == V2Command::GS_GET_PARAM ||
			(unsigned char)payload[0] == V2Command::GS_SET_PARAM ||
			(unsigned char)payload[0] == V2Command::SYSCTL_SET);
	});
	require(!hasMultipointFrame, "XM4 path emitted a v2 multipoint frame (d0/d6/d8/98)");
	bool multipointRejected = false;
	try { headphones.setMultipoint(true); }
	catch (const std::exception&) { multipointRejected = true; }
	require(multipointRejected, "setMultipoint on v1 must throw instead of sending");
	// ULT mode is a v2-only inquiry; the v1 probe pass must never send it.
	require(!headphones.hasUltMode() && std::none_of(observed->sentPayloads.begin(), observed->sentPayloads.end(),
		[](const Buffer& p) { return p.size() >= 2 && (unsigned char)p[0] == 0x56 && p[1] == 0x03; }),
		"v1 probe must not send the 56 03 ULT inquiry");

	// --- v2 multipoint ("Connect to 2 devices"), byte layout proven by GadgetBridge on the WH-ULT900N
	// (SonyProtocolImplV2 commits 8cbc309346, e8520865f3, 5d7b37d1b7) ---
	// The setting lives in a per-model general-settings slot, found by name; the ULT900N uses D1.
	auto fakeV2 = std::make_unique<FakeV2Connector>();
	auto* observedV2 = fakeV2.get();
	observedV2->reply = [](const Buffer& request) -> Buffer {
		if (request == bytes({ 0xd0, 0xd1, 0x01 })) {
			std::string name = "MULTIPOINT_SETTING";
			Buffer response = bytes({ 0xd1, 0xd1, 0x00, 0x00, (int)name.size() });
			response.insert(response.end(), name.begin(), name.end());
			response.push_back(0x00);
			return response;
		}
		if (request == bytes({ 0xd6, 0xd1 })) return bytes({ 0xd7, 0xd1, 0x00, 0x00 }); // 00 = ON (inverted)
		return {};
	};
	BluetoothWrapper bluetoothV2(std::move(fakeV2));
	Headphones ult900n(bluetoothV2);
	ult900n.probeCapabilities();
	ult900n.requestMultipoint();

	require(ult900n.hasMultipointSetting(), "MULTIPOINT_SETTING slot D1 was not found by name");
	require(ult900n.getMultipointEnabled(), "RET d7 d1 00 00 must parse as multipoint ON (enable bit inverted)");
	require(!ult900n.hasSpeakToChat() && !ult900n.hasAdaptiveVolume(),
		"unanswered v2 probes must stay unsupported");

	ult900n.setMultipoint(false);
	require(observedV2->sentPayloads.size() >= 2, "multipoint OFF did not send both frames");
	const auto offState = observedV2->sentPayloads[observedV2->sentPayloads.size() - 2];
	const auto offCommit = observedV2->sentPayloads.back();
	require(offState == Buffer({ (char)0xd8, (char)0xd1, 0x00, 0x01 }),
		"multipoint OFF state frame must be d8 d1 00 01");
	require(offCommit == Buffer({ (char)0x98, 0x00, 0x06, 0x01 }),
		"multipoint apply commit must be the fixed 98 00 06 01");
	require(!ult900n.getMultipointEnabled(), "multipoint OFF was not mirrored locally");

	ult900n.setMultipoint(true);
	const auto onState = observedV2->sentPayloads[observedV2->sentPayloads.size() - 2];
	const auto onCommit = observedV2->sentPayloads.back();
	require(onState == Buffer({ (char)0xd8, (char)0xd1, 0x00, 0x00 }),
		"multipoint ON state frame must be d8 d1 00 00");
	require(onCommit == Buffer({ (char)0x98, 0x00, 0x06, 0x01 }),
		"multipoint ON must reuse the fixed apply commit 98 00 06 01");
	require(ult900n.getMultipointEnabled(), "multipoint ON was not mirrored locally");

	// --- WH-1000XM6 (issue #11): noise control reads via 0x19, the equalizer is the ten-band 0x04 layout.
	// Frames captured on fw 3.1.5 by marconvcm/sony-device-center (#44, #74). ---
	auto fakeXm6 = std::make_unique<FakeV2Connector>();
	auto* observedXm6 = fakeXm6.get();
	observedXm6->reply = [](const Buffer& request) -> Buffer {
		if (request == bytes({ 0x66, 0x17 })) return bytes({ 0x67, 0x17, 0x00, 0x00, 0x00, 0x00, 0x00 });
		if (request == bytes({ 0x66, 0x19 })) return bytes({ 0x67, 0x19, 0x01, 0x01, 0x01, 0x00, 0x0a, 0x00, 0x00 });
		if (request == bytes({ 0x56, 0x04 })) return bytes({ 0x57, 0x04, 0xa0, 0x0a, 6, 6, 6, 6, 6, 6, 6, 6, 6, 12 });
		return {};
	};
	BluetoothWrapper bluetoothXm6(std::move(fakeXm6));
	Headphones xm6(bluetoothXm6);
	xm6.setDeviceName("WH-1000XM6");

	xm6.requestAmbientState();
	require(observedXm6->sent(bytes({ 0x66, 0x19 })) && !observedXm6->sent(bytes({ 0x66, 0x17 })),
		"XM6 noise control must be read via 66 19");
	require(xm6.getAmbientSoundControl() && xm6.getAsmLevel() == 10, "XM6 67 19 reply (Ambient, level 10) was not parsed");

	xm6.requestEqualizer();
	require(xm6.hasEqualizer() && xm6.isTenBandEqualizer(), "XM6 ten-band equalizer was not recognised");
	require(xm6.getEqualizerBandCount() == 10 && xm6.getEqualizerBand(0) == 6 && xm6.getEqualizerBand(9) == 12,
		"XM6 raw ten-band values were not decoded");
	require(xm6.getEqualizerPreset() == EQ_PRESET::MANUAL, "XM6 custom preset byte was not decoded");

	xm6.setEqualizerCustom(5, { 0, 1, 2, 3, 4, 5, 6, 7, 8, 13 });
	require(observedXm6->sentPayloads.back() == bytes({ 0x58, 0x04, 0xa0, 0x0a, 0, 1, 2, 3, 4, 5, 6, 7, 8, 12 }),
		"XM6 custom EQ must be 58 04 a0 0a <10 raw bands clamped to 0..12>, no clear bass");
	xm6.setEqualizerPreset(EQ_PRESET::OFF);
	require(observedXm6->sent(bytes({ 0x58, 0x04, 0x00, 0x00 })), "XM6 preset must use inquired type 04");

	// Any other v2 headset that answered 66 17 with zeros must not be read as "Off" either.
	auto fakeZeros = std::make_unique<FakeV2Connector>();
	fakeZeros->reply = [](const Buffer& request) -> Buffer {
		if (request == bytes({ 0x66, 0x17 })) return bytes({ 0x67, 0x17, 0x00, 0x00, 0x00, 0x00, 0x00 });
		return {};
	};
	BluetoothWrapper bluetoothZeros(std::move(fakeZeros));
	Headphones zeros(bluetoothZeros);
	zeros.setDeviceName("WH-1000XM5");
	zeros.setAmbientSoundControl(true);
	zeros.setAsmLevel(7);
	zeros.setFocusOnVoice(false);
	zeros.setChanges();
	zeros.requestAmbientState();
	require(zeros.getAmbientSoundControl() && zeros.getAsmLevel() == 7, "a zeroed 67 17 reply overwrote the state");

	// --- ULT mode (ULT WEAR), EQ inquired type 03: 57 03 <preset> <ult> <count> <bands...> ---
	// Layout from Sound Connect's PRESET_EQ_AND_ULT_MODE (mos9527/SonyHeadphonesClient ProtocolV2T1.hpp).
	{
		Buffer ultReply = bytes({ 0x57, 0x03, 0xa0, 0x01, 0x06, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f });
		auto fakeUlt = std::make_unique<FakeV2Connector>();
		auto* observedUlt = fakeUlt.get();
		observedUlt->reply = [&ultReply](const Buffer& request) -> Buffer {
			if (request == bytes({ 0x56, 0x03 })) return ultReply;
			return {};
		};
		BluetoothWrapper bluetoothUlt(std::move(fakeUlt));
		Headphones ult(bluetoothUlt);
		ult.setDeviceName("Sony ULT WEAR");
		ult.probeCapabilities();
		require(ult.hasUltMode() && ult.getUltMode() == ULT_MODE::ULT1, "57 03 a0 01 ... must parse as ULT 1");

		// Diagnostics stay empty until the first multipoint read (macOS shows "loading" while empty), then
		// carry the raw ULT exchange.
		require(ult.getMultipointDiagnostics().empty(), "the ULT probe must not make the diagnostics non-empty");
		ult.requestMultipoint();
		require(ult.getMultipointDiagnostics().find("ult T1 56 03 -> 57 03 a0 01 06") != std::string::npos,
			"the diagnostics must include the raw 56 03 exchange");

		// The 57 03 reply is also the EQ state: clear bass first, then 400..16k.
		require(ult.hasEqualizer() && ult.getEqualizerPreset() == EQ_PRESET::MANUAL
			&& ult.getClearBass() == 0 && ult.getEqualizerBand(0) == 1 && ult.getEqualizerBand(4) == 5,
			"57 03 a0 01 06 0a 0b 0c 0d 0e 0f must decode as clear bass 0, bands +1..+5");
		observedUlt->sentPayloads.clear();
		ult.requestEqualizer();
		require(observedUlt->sent(bytes({ 0x56, 0x03 })) && !observedUlt->sent(bytes({ 0x56, 0x00 })),
			"a ULT device's equalizer must be read through 56 03");
		ult.setEqualizerCustom(3, { -2, -1, 0, 1, 2 });
		require(observedUlt->sentPayloads.back() == bytes({ 0x58, 0x03, 0xa0, 0x01, 0x06, 0x0d, 0x08, 0x09, 0x0a, 0x0b, 0x0c }),
			"ULT custom EQ must be 58 03 a0 <current ult> 06 <clear bass +10> <400..16k +10>");
		require(ult.getClearBass() == 3 && ult.getEqualizerBand(0) == -2, "ULT custom EQ cache was not updated");

		// Manual EQ: the custom curve is echoed back verbatim (count + bands), after a fresh read.
		observedUlt->sentPayloads.clear();
		ult.setUltMode(ULT_MODE::ULT2);
		require(observedUlt->sentPayloads.size() == 2 && observedUlt->sentPayloads[0] == bytes({ 0x56, 0x03 }),
			"setUltMode must re-read 56 03 right before writing");
		require(observedUlt->sentPayloads[1] == bytes({ 0x58, 0x03, 0xa0, 0x02, 0x06, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f }),
			"ULT 2 on Manual EQ must be 58 03 a0 02 <count + bands echoed verbatim>");
		require(ult.getUltMode() == ULT_MODE::ULT2, "ULT mode cache was not updated after the write");

		// The EQ changed elsewhere (now the Bright preset): the fresh read wins, and a preset carries no bands.
		ultReply = bytes({ 0x57, 0x03, 0x10, 0x02, 0x06, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a });
		ult.setUltMode(ULT_MODE::OFF);
		require(observedUlt->sentPayloads.back() == bytes({ 0x58, 0x03, 0x10, 0x00, 0x00 }),
			"ULT off on a preset must be 58 03 <current preset> 00 00");

		// The poll follows the physical button.
		ultReply = bytes({ 0x57, 0x03, 0x10, 0x01, 0x00 });
		ult.requestUltMode();
		require(ult.getUltMode() == ULT_MODE::ULT1, "a ULT button change was not picked up by requestUltMode");

		// Manual EQ but the reply lacks its bands: refuse rather than wipe the custom curve.
		ultReply = bytes({ 0x57, 0x03, 0xa0, 0x01 });
		size_t sentBefore = observedUlt->sentPayloads.size();
		bool truncatedRejected = false;
		try { ult.setUltMode(ULT_MODE::ULT2); } catch (const RecoverableException&) { truncatedRejected = true; }
		require(truncatedRejected && observedUlt->sentPayloads.size() == sentBefore + 1
			&& observedUlt->sentPayloads.back() == bytes({ 0x56, 0x03 }),
			"setUltMode must not write when the Manual EQ reply has no bands");

		// The link dies before the write: the transport's own exception (with shouldDisconnect) reaches the
		// caller so the GUI drops the dead connection, nothing is written, and the diagnostics keep the last
		// answered exchange next to the failure.
		ultReply = {};
		sentBefore = observedUlt->sentPayloads.size();
		// (The fake's own timeout is a plain runtime_error; on a real link it is RecoverableException(..., true).)
		std::string writeError;
		try { ult.setUltMode(ULT_MODE::OFF); } catch (const std::exception& exc) { writeError = exc.what(); }
		require(writeError == "fake connector has no queued response" && observedUlt->sentPayloads.size() == sentBefore + 1,
			"a failed re-read must rethrow the transport's exception (not a fresh one) and send no 58 03");
		auto diagnostics = ult.getMultipointDiagnostics();
		require(diagnostics.find("ult T1 56 03 -> 57 03") != std::string::npos
			&& diagnostics.find("ult T1 56 03 -> (") != std::string::npos,
			"a ULT timeout must not hide the last answered exchange in the diagnostics");

				// Captured from a ULT WEAR (fw 2.1.0). Its 57 00 showed the first five of these values one slot late, and
		// writing the sixth byte here moved the treble, so: clear bass +7, then 400..16k.
		// The device name alone makes the first equalizer read use 56 03 (never 56 00) on this model.
		auto fakeCaptured = std::make_unique<FakeV2Connector>();
		fakeCaptured->reply = [](const Buffer& request) -> Buffer {
			if (request == bytes({ 0x56, 0x03 })) return bytes({ 0x57, 0x03, 0xa0, 0x01, 0x06, 0x11, 0x0c, 0x08, 0x0b, 0x0d, 0x0f });
			return {};
		};
		auto* observedCaptured = fakeCaptured.get();
		BluetoothWrapper bluetoothCaptured(std::move(fakeCaptured));
		Headphones captured(bluetoothCaptured);
		captured.setDeviceName("Sony ULT WEAR");
		captured.requestEqualizer();
		require(observedCaptured->sent(bytes({ 0x56, 0x03 })) && !observedCaptured->sent(bytes({ 0x56, 0x00 })),
			"a ULT WEAR's first equalizer read must use 56 03, not the shifted 56 00");
		require(captured.hasEqualizer() && captured.getClearBass() == 7 && captured.getEqualizerBand(0) == 2
			&& captured.getEqualizerBand(1) == -2 && captured.getEqualizerBand(2) == 1 && captured.getEqualizerBand(3) == 3
			&& captured.getEqualizerBand(4) == 5,
			"captured ULT WEAR reply must decode as clear bass +7, then +2 -2 +1 +3 +5");

				// Clear Bass on its own (Bass Control slider): fresh read, then the headset's own preset, ULT mode and
		// five bands go back byte for byte with only the clear-bass byte replaced.
		require(captured.hasUltClearBass(), "a 57 03 reply with six band bytes must enable Clear Bass control");
		observedCaptured->sentPayloads.clear();
		captured.setClearBass(-3);
		require(observedCaptured->sentPayloads.size() == 2 && observedCaptured->sentPayloads[0] == bytes({ 0x56, 0x03 })
			&& observedCaptured->sentPayloads[1] == bytes({ 0x58, 0x03, 0xa0, 0x01, 0x06, 0x07, 0x0c, 0x08, 0x0b, 0x0d, 0x0f }),
			"Clear Bass -3 must be 58 03 a0 01 06 07 <400..16k echoed>");
		require(captured.getClearBass() == -3, "Clear Bass cache was not updated");

		// On a preset whose reply carries its curve, the preset byte goes back unchanged.
		auto fakePreset = std::make_unique<FakeV2Connector>();
		auto* observedPreset = fakePreset.get();
		Buffer presetReply = bytes({ 0x57, 0x03, 0x10, 0x02, 0x06, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f });
		fakePreset->reply = [&presetReply](const Buffer& request) -> Buffer {
			if (request == bytes({ 0x56, 0x03 })) return presetReply;
			return {};
		};
		BluetoothWrapper bluetoothPreset(std::move(fakePreset));
		Headphones preset(bluetoothPreset);
		preset.setDeviceName("Sony ULT WEAR");
		preset.requestUltMode();
		preset.setClearBass(25);
		require(observedPreset->sentPayloads.back() == bytes({ 0x58, 0x03, 0x10, 0x02, 0x06, 0x14, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f }),
			"Clear Bass on a preset must keep the preset and ULT bytes, clamp to +10");

		// A reply without band bytes: refuse rather than guess the curve.
		presetReply = bytes({ 0x57, 0x03, 0x10, 0x02, 0x00 });
		size_t presetSent = observedPreset->sentPayloads.size();
		bool noBandsRejected = false;
		try { preset.setClearBass(1); } catch (const RecoverableException&) { noBandsRejected = true; }
		require(noBandsRejected && observedPreset->sentPayloads.size() == presetSent + 1,
			"Clear Bass must not write when the reply carries no band bytes");

				// An unknown ULT status byte is not a ULT reply.
		auto fakeOdd = std::make_unique<FakeV2Connector>();
		fakeOdd->reply = [](const Buffer& request) -> Buffer {
			if (request == bytes({ 0x56, 0x03 })) return bytes({ 0x57, 0x03, 0x00, 0x07, 0x00 });
			return {};
		};
		BluetoothWrapper bluetoothOdd(std::move(fakeOdd));
		Headphones odd(bluetoothOdd);
		odd.setDeviceName("Sony ULT WEAR");
		odd.requestUltMode();
		require(!odd.hasUltMode(), "a ULT status past 02 must not be taken as ULT support");
		bool oddCbRejected = false;
		try { odd.setClearBass(1); } catch (const std::logic_error&) { oddCbRejected = true; }
		require(!odd.hasUltClearBass() && oddCbRejected, "setClearBass must throw without the six-band ULT layout");

		// A ULT WEAR that doesn't answer 56 03 never gets a 58 03.
		auto fakeNoUlt = std::make_unique<FakeV2Connector>();
		auto* observedNoUlt = fakeNoUlt.get();
		BluetoothWrapper bluetoothNoUlt(std::move(fakeNoUlt));
		Headphones noUlt(bluetoothNoUlt);
		noUlt.setDeviceName("Sony ULT WEAR");
		noUlt.probeCapabilities();
		bool ultRejected = false;
		try { noUlt.setUltMode(ULT_MODE::ULT1); } catch (const std::logic_error&) { ultRejected = true; }
		require(!noUlt.hasUltMode() && ultRejected && std::none_of(observedNoUlt->sentPayloads.begin(),
			observedNoUlt->sentPayloads.end(), [](const Buffer& p) { return p.size() >= 2 && (unsigned char)p[0] == 0x58; }),
			"setUltMode must throw without sending on a device that never answered 56 03");
	}

	// --- ULT code is ULT WEAR only: other v2 models never see 56 03 / 58 03, even if they'd answer ---
	for (const char* otherModel : { "WH-1000XM5", "WH-CH720N", "WF-1000XM5", "" })
	{
		auto fakeOther = std::make_unique<FakeV2Connector>();
		auto* observedOther = fakeOther.get();
		fakeOther->reply = [](const Buffer& request) -> Buffer {
			if (request == bytes({ 0x56, 0x03 })) return bytes({ 0x57, 0x03, 0xa0, 0x01, 0x06, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f });
			if (request == bytes({ 0x56, 0x00 })) return bytes({ 0x57, 0x00, 0xa0, 0x06, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f });
			return {};
		};
		BluetoothWrapper bluetoothOther(std::move(fakeOther));
		Headphones other(bluetoothOther);
		other.setDeviceName(otherModel);
		other.requestEqualizer();
		require(other.getClearBass() == 0 && other.getEqualizerBand(0) == 1,
			"a non-ULT model must keep decoding 57 00 as clear bass first");
		other.probeCapabilities();
		other.requestUltMode();
		other.setEqualizerCustom(3, { -2, -1, 0, 1, 2 });
		bool ultWriteRejected = false, clearBassRejected = false;
		try { other.setUltMode(ULT_MODE::ULT1); } catch (const std::logic_error&) { ultWriteRejected = true; }
		try { other.setClearBass(1); } catch (const std::logic_error&) { clearBassRejected = true; }
		bool sentUlt = std::any_of(observedOther->sentPayloads.begin(), observedOther->sentPayloads.end(),
			[](const Buffer& p) { return p.size() >= 2 && ((unsigned char)p[0] == 0x56 || (unsigned char)p[0] == 0x58) && p[1] == 0x03; });
		require(!sentUlt && !other.hasUltMode() && !other.hasUltClearBass() && ultWriteRejected && clearBassRejected,
			"a non-ULT model must never be sent 56 03 / 58 03 or offer ULT / Clear Bass control");
		require(std::find(observedOther->sentPayloads.begin(), observedOther->sentPayloads.end(),
				bytes({ 0x58, 0x00, 0xa0, 0x06, 0x0d, 0x08, 0x09, 0x0a, 0x0b, 0x0c })) != observedOther->sentPayloads.end(),
			"a non-ULT model must keep writing custom EQ as 58 00 a0 06 <clear bass> <bands>");
		require(other.getMultipointDiagnostics().empty() || other.getMultipointDiagnostics().find("ult ") == std::string::npos,
			"a non-ULT model's diagnostics must not mention ULT");
	}

	// Malformed inbound frames on the untrusted parser path must throw the recoverable type.
	// 61 (0x3D) is the escape sentry; a lone one at buffer end and one followed by a
	// non-escapable byte are the two unescape rejection paths.
	constexpr char ESCAPE_SENTRY = 61;
	expectRecoverable([&] { CommandSerializer::unpackBtMessage(Buffer{ ESCAPE_SENTRY }); },
		"dangling escape byte did not throw RecoverableException");
	expectRecoverable([&] { CommandSerializer::unpackBtMessage(Buffer{ ESCAPE_SENTRY, 0x00 }); },
		"unexpected escaped byte did not throw RecoverableException");
	expectRecoverable([] { CommandSerializer::unpackBtMessage(Buffer{ 0x00, 0x00, 0x00 }); },
		"under-minimum-size frame did not throw RecoverableException");

	std::cout << "XM4 / multipoint / XM6 / ULT mode protocol tests passed\n";
	return 0;
}
