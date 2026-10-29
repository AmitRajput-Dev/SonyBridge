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
	Buffer speakToChatReply = { (char)V1Command::BTNMODE_RET, (char)V1Command::SUB_SPEAK_TO_CHAT, 0x01, 0x01 };
	bool multipointDeclines = false;
	bool alertsEnabled = false;

private:
	void queue(const Buffer& payload, DATA_TYPE type, unsigned char sequence)
	{
		incoming.push_back(CommandSerializer::packageDataForBt(payload, type, sequence));
	}

	// d1 <slot> 02(boolean) <len>name <len>summary 01 00
	static Buffer generalSetting(unsigned char slot, const std::string& name, const std::string& summary)
	{
		Buffer reply = { (char)V1Command::GS_RET_CAPABILITY, (char)slot, (char)V1Command::GS_TYPE_BOOLEAN, (char)name.size() };
		reply.insert(reply.end(), name.begin(), name.end());
		reply.push_back((char)summary.size());
		reply.insert(reply.end(), summary.begin(), summary.end());
		reply.push_back(0x01);
		reply.push_back(0x00);
		return reply;
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
				response = speakToChatReply;
			break;
		// General settings, as a WH-1000XM4 on fw 3.0.1 answered them (multipoint in d2, touch panel in d1).
		case V1Command::SUPPORT_FUNCTION_GET:
			response = { (char)V1Command::SUPPORT_FUNCTION_RET, 0x00, 0x17, 0x71, 0x38, 0x62, (char)0xf5, (char)0x81, 0x51,
				(char)0xa1, (char)0xe1, (char)0xe2, (char)0xd2, (char)0xf6, (char)0xd1, (char)0xf4, (char)0xf3, 0x39, 0x12,
				0x13, 0x11, 0x30, (char)0xc1, 0x14, 0x22, 0x21 };
			break;
		case V1Command::GS_GET_CAPABILITY:
			if (request.size() >= 2 && (unsigned char)request[1] == 0xd2)
				response = generalSetting(0xd2, "MULTIPOINT_SETTING", "MULTIPOINT_SETTING_SUMMARY");
			else if (request.size() >= 2 && (unsigned char)request[1] == 0xd1)
				response = generalSetting(0xd1, "TOUCH_PANEL_SETTING", "");
			break;
		case V1Command::ALERT_SET_STATUS:
			if (request.size() >= 3 && (unsigned char)request[1] == V1Command::ALERT_FORMAT_FIXED)
				alertsEnabled = request[2] == V1Command::ALERT_STATUS_ENABLE;
			return;
		case V1Command::GS_GET_PARAM:
			if (request.size() >= 2) response = { (char)V1Command::GS_RET_PARAM, request[1], 0x01, 0x01 };
			break;
		case V1Command::GS_SET_PARAM:
			// Changing multipoint is held until confirmed: 99 01 <06 on / 07 off> 01, but only once alerts are
			// enabled (94 01 00). Otherwise an XM4 on fw 3.0.1 notifies its unchanged value, d9 d2 01 01.
			if (request.size() >= 4 && (unsigned char)request[1] == 0xd2)
				response = (multipointDeclines || !alertsEnabled)
					? Buffer({ (char)0xd9, (char)0xd2, 0x01, 0x01 })
					: Buffer({ (char)V1Command::ALERT_NTFY, (char)V1Command::ALERT_FORMAT_FIXED,
						(char)(request[3] ? V1Command::ALERT_MULTIPOINT_ON : V1Command::ALERT_MULTIPOINT_OFF), 0x01 });
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

	// Captured from a WH-1000XM4 on fw 3.0.1: its Speak-to-Chat GET reply carries kind 00, not 01
	// (f7 05 00 00 when off, f7 05 00 01 when on), so the capability must still be confirmed.
	for (char on : { 0x00, 0x01 })
	{
		auto xm4 = std::make_unique<FakeV1Connector>();
		xm4->speakToChatReply = { (char)V1Command::BTNMODE_RET, (char)V1Command::SUB_SPEAK_TO_CHAT, 0x00, on };
		BluetoothWrapper xm4Bluetooth(std::move(xm4));
		Headphones xm4Headphones(xm4Bluetooth);
		xm4Headphones.initDevice();
		xm4Headphones.probeCapabilities();
		require(xm4Headphones.hasSpeakToChat(), "XM4 fw 3.0.1 Speak-to-Chat reply (kind 00) was rejected");
		require(xm4Headphones.getSpeakToChat() == (on != 0), "XM4 fw 3.0.1 Speak-to-Chat state was misread");
	}

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

	// XM4 multipoint and touch panel: the v1 general-settings layout, found by name from the function list.
	headphones.requestMultipoint();
	require(headphones.hasMultipointSetting() && headphones.getMultipointEnabled(), "XM4 multipoint setting was not read");
	require(headphones.hasTouchPanelSetting() && headphones.getTouchPanelEnabled(), "XM4 touch panel setting was not read");
	const auto hasV2SettingRead = std::any_of(observed->sentPayloads.begin(), observed->sentPayloads.end(), [](const Buffer& payload) {
		return payload.size() == 2 && (unsigned char)payload[0] == V1Command::GS_GET_CAPABILITY;
	});
	require(!hasV2SettingRead, "XM4 general-settings name read must carry the display language byte");

	headphones.setMultipoint(false);
	const auto& confirm = observed->sentPayloads.back();
	const auto& multipointWrite = observed->sentPayloads[observed->sentPayloads.size() - 2];
	require(observed->sentPayloads[observed->sentPayloads.size() - 3] == Buffer({ (char)V1Command::ALERT_SET_STATUS, 0x01, 0x00 }),
		"XM4 multipoint change was not preceded by 94 01 00 (without it the headset declines)");
	require(multipointWrite == Buffer({ (char)V1Command::GS_SET_PARAM, (char)0xd2, 0x01, 0x00 }),
		"XM4 multipoint off did not use d8 <slot> 01 00");
	require(confirm == Buffer({ (char)V1Command::ALERT_SET, 0x01, (char)V1Command::ALERT_MULTIPOINT_OFF, 0x01 }),
		"XM4 multipoint off confirmation was not answered with 98 01 07 01");
	require(!headphones.getMultipointEnabled(), "XM4 multipoint state did not follow the write");

	// A declined change must not be reported as applied: the state is read back and the write throws.
	{
		auto declining = std::make_unique<FakeV1Connector>();
		declining->multipointDeclines = true;
		BluetoothWrapper decliningBluetooth(std::move(declining));
		Headphones decliningHeadphones(decliningBluetooth);
		decliningHeadphones.initDevice();
		decliningHeadphones.requestMultipoint();
		bool declined = false;
		try { decliningHeadphones.setMultipoint(false); }
		catch (const RecoverableException&) { declined = true; }
		require(declined, "a declined XM4 multipoint change was reported as applied");
		require(decliningHeadphones.getMultipointEnabled(), "a declined XM4 multipoint change left the state flipped");
	}

	headphones.setTouchPanel(false);
	require(observed->sentPayloads.back() == Buffer({ (char)V1Command::GS_SET_PARAM, (char)0xd1, 0x01, 0x00 }),
		"XM4 touch panel off did not use d8 <slot> 01 00");

	const auto hasV2MultipointCommit = std::any_of(observed->sentPayloads.begin(), observed->sentPayloads.end(), [](const Buffer& payload) {
		return payload.size() >= 2 && (unsigned char)payload[0] == V2Command::SYSCTL_SET && payload[1] == 0x00;
	});
	require(!hasV2MultipointCommit, "XM4 path emitted the v2 multipoint commit (98 00 ...)");

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

	std::cout << "XM4 / multipoint / XM6 protocol tests passed\n";
	return 0;
}
