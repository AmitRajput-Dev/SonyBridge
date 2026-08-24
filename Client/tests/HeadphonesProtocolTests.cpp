#include "BluetoothWrapper.h"
#include "CommandSerializer.h"
#include "Exceptions.h"
#include "Headphones.h"

#include <algorithm>
#include <cstring>
#include <deque>
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

// v2-generation device that supports multipoint the way GadgetBridge proved it on the WH-ULT900N:
// only the touch-sensor 0xd1 GET answers with the multipoint state; every other capability probe
// times out (recv on an empty queue throws), which the probe treats as "unsupported".
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
		// GET d6 d1 -> RET d7 d1 00 <00=on/01=off> (GadgetBridge SonyProtocolImplV2 handleTouchSensor;
		// the enable bit is inverted). The fake reports multipoint currently ON.
		if (message.payload.size() >= 2 && (unsigned char)message.payload[0] == V2Command::TOUCH_GET
			&& (unsigned char)message.payload[1] == V2Command::SUB_MULTIPOINT)
			queue({ (char)V2Command::TOUCH_RET, (char)V2Command::SUB_MULTIPOINT, 0x00, 0x00 }, DATA_TYPE::DATA_MDR, 0);
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

private:
	void queue(const Buffer& payload, DATA_TYPE type, unsigned char sequence)
	{
		incoming.push_back(CommandSerializer::packageDataForBt(payload, type, sequence));
	}

	bool connected = true;
	std::deque<Buffer> incoming;
};

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
	require(!headphones.hasMultipoint(), "multipoint capability must stay unconfirmed on v1");
	const auto hasMultipointFrame = std::any_of(observed->sentPayloads.begin(), observed->sentPayloads.end(), [](const Buffer& payload) {
		return !payload.empty() && ((unsigned char)payload[0] == V2Command::TOUCH_GET ||
			(unsigned char)payload[0] == V2Command::TOUCH_SET ||
			(unsigned char)payload[0] == V2Command::SYSCTL_SET);
	});
	require(!hasMultipointFrame, "XM4 path emitted a v2 multipoint frame (d6/d8/98)");
	bool multipointRejected = false;
	try { headphones.setMultipoint(true); }
	catch (const std::logic_error&) { multipointRejected = true; }
	require(multipointRejected, "setMultipoint on v1 must throw instead of sending");

	// --- v2 multipoint ("Connect to 2 devices"), byte layout proven by GadgetBridge on the WH-ULT900N
	// (SonyProtocolImplV2 commits 8cbc309346, e8520865f3, 5d7b37d1b7) ---
	auto fakeV2 = std::make_unique<FakeV2Connector>();
	auto* observedV2 = fakeV2.get();
	BluetoothWrapper bluetoothV2(std::move(fakeV2));
	Headphones ult900n(bluetoothV2);
	ult900n.probeCapabilities();

	require(ult900n.hasMultipoint(), "v2 multipoint probe (d6 d1) was not recorded");
	require(ult900n.getMultipoint(), "RET d7 d1 00 00 must parse as multipoint ON (enable bit inverted)");
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
	require(!ult900n.getMultipoint(), "multipoint OFF was not mirrored locally");

	ult900n.setMultipoint(true);
	const auto onState = observedV2->sentPayloads[observedV2->sentPayloads.size() - 2];
	const auto onCommit = observedV2->sentPayloads.back();
	require(onState == Buffer({ (char)0xd8, (char)0xd1, 0x00, 0x00 }),
		"multipoint ON state frame must be d8 d1 00 00");
	require(onCommit == Buffer({ (char)0x98, 0x00, 0x06, 0x01 }),
		"multipoint ON must reuse the fixed apply commit 98 00 06 01");
	require(ult900n.getMultipoint(), "multipoint ON was not mirrored locally");

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

	std::cout << "WH-1000XM4 protocol safety tests passed\n";
	return 0;
}
