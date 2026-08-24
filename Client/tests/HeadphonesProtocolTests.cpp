#include "BluetoothWrapper.h"
#include "CommandSerializer.h"
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

void require(bool condition, const char* message)
{
	if (!condition) throw std::runtime_error(message);
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

	std::cout << "WH-1000XM4 protocol safety tests passed\n";
	return 0;
}
