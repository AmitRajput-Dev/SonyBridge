#include "BluetoothWrapper.h"

// How many frames one transaction will read before giving up. The device interleaves ACKs and
// unsolicited notifications with the reply we're after, so a handful of unrelated frames is normal;
// this only bounds a device that never sends what we asked for.
static constexpr int MAX_FRAMES_PER_TRANSACTION = 16;

BluetoothWrapper::BluetoothWrapper(std::unique_ptr<IBluetoothConnector> connector)
{
	this->_connector.swap(connector);
}

BluetoothWrapper::BluetoothWrapper(BluetoothWrapper&& other) noexcept
{
	this->_connector.swap(other._connector);
	this->_seqNumber = other._seqNumber;
	this->_leftoverBytes = std::move(other._leftoverBytes);
}

BluetoothWrapper& BluetoothWrapper::operator=(BluetoothWrapper&& other) noexcept
{
	//self assignment
	if (this == &other) return *this;

	this->_connector.swap(other._connector);
	this->_seqNumber = other._seqNumber;
	this->_leftoverBytes = std::move(other._leftoverBytes);

	return *this;
}

int BluetoothWrapper::sendCommand(const std::vector<char>& bytes)
{
	std::lock_guard guard(this->_connectorMtx);
	auto data = CommandSerializer::packageDataForBt(bytes, DATA_TYPE::DATA_MDR, this->_seqNumber++);
	auto bytesSent = this->_connector->send(data.data(), data.size());

	this->_waitForAck();

	return bytesSent;
}

bool BluetoothWrapper::isConnected() noexcept
{
	return this->_connector->isConnected();
}

void BluetoothWrapper::connect(const std::string& addr)
{
	std::lock_guard guard(this->_connectorMtx);
	this->_connector->connect(addr);
}

void BluetoothWrapper::disconnect() noexcept
{
	std::lock_guard guard(this->_connectorMtx);
	this->_seqNumber = 0;
	this->_leftoverBytes.clear();
	this->_connector->disconnect();
}


std::vector<BluetoothDevice> BluetoothWrapper::getConnectedDevices()
{
	return this->_connector->getConnectedDevices();
}

SonyProtocolVersion BluetoothWrapper::getProtocolVersion() noexcept
{
	return this->_connector->getProtocolVersion();
}

Buffer BluetoothWrapper::sendCommandAndReadResponse(const std::vector<char>& bytes, unsigned char retCommandId, int retSubType)
{
	std::lock_guard guard(this->_connectorMtx);
	auto data = CommandSerializer::packageDataForBt(bytes, DATA_TYPE::DATA_MDR, this->_seqNumber++);
	this->_connector->send(data.data(), data.size());

	// The device replies with an ACK and then the RET frame; unrelated notifications may interleave.
	for (int i = 0; i < MAX_FRAMES_PER_TRANSACTION; i++)
	{
		auto msg = this->_readMessage();
		if (msg.dataType == DATA_TYPE::ACK)
		{
			this->_seqNumber = msg.seqNumber;
			continue;
		}
		if (msg.dataType == DATA_TYPE::DATA_MDR && !msg.payload.empty()
			&& (unsigned char)msg.payload[0] == retCommandId
			&& (retSubType < 0 || (msg.payload.size() >= 2 && (unsigned char)msg.payload[1] == retSubType)))
		{
			return msg.payload;
		}
	}
	throw RecoverableException("No matching response received from device", true);
}

void BluetoothWrapper::_waitForAck()
{
	// The device answers a command with an ACK, but it also pushes unsolicited notifications of its own
	// (a state change, a press of the headset's own button) that can arrive first. Reading exactly one
	// frame and assuming it was the ACK left the response stream one frame behind for the rest of the
	// session, and took _seqNumber from the wrong frame - the device dedupes on that sequence number, so
	// it then silently ignored the next command while the UI snapped back to the old value.
	// Skipped notifications are still acked back to the device by _readMessage().
	for (int i = 0; i < MAX_FRAMES_PER_TRANSACTION; i++)
	{
		auto msg = this->_readMessage();
		if (msg.dataType == DATA_TYPE::ACK)
		{
			this->_seqNumber = msg.seqNumber;
			return;
		}
	}
	throw RecoverableException("No ack received from device", true);
}

CommandSerializer::Message BluetoothWrapper::_readMessage()
{
	bool ongoingMessage = false;
	bool messageFinished = false;
	char buf[MAX_BLUETOOTH_MESSAGE_SIZE] = { 0 };
	Buffer msgBytes;

	do
	{
		int numRecvd;
		if (!this->_leftoverBytes.empty())
		{
			// A previous recv() already delivered the start of this (or a later) message; replay it
			// instead of blocking on the socket again.
			numRecvd = static_cast<int>(std::min(this->_leftoverBytes.size(), sizeof(buf)));
			std::copy(this->_leftoverBytes.begin(), this->_leftoverBytes.begin() + numRecvd, buf);
			this->_leftoverBytes.erase(this->_leftoverBytes.begin(), this->_leftoverBytes.begin() + numRecvd);
		}
		else
		{
			numRecvd = this->_connector->recv(buf, sizeof(buf));
		}

		// Every 60/61/62 inside a frame is escaped, so a START_MARKER can only ever begin one. That makes
		// resyncing unambiguous, which is what matters after a brief link glitch garbles or truncates a
		// chunk: bytes before the first START_MARKER are the tail of a frame we can no longer parse, and
		// a second START_MARKER means the frame we were collecting never finished. Both cases resync on
		// the new marker here. Previously the first silently concatenated garbage into the message and
		// the second threw, in either case leaving the parser stranded mid-stream for the rest of the
		// session - every command after that failed and the UI kept snapping back to the old value.
		size_t messageStart = ongoingMessage ? 0 : static_cast<size_t>(numRecvd);
		size_t messageEnd = static_cast<size_t>(numRecvd);

		for (size_t i = 0; i < static_cast<size_t>(numRecvd); i++)
		{
			if (buf[i] == START_MARKER)
			{
				// Whatever we had collected was a truncated frame, not the start of this one.
				msgBytes.clear();
				messageStart = i + 1;
				messageEnd = static_cast<size_t>(numRecvd);
				ongoingMessage = true;
			}
			else if (ongoingMessage && buf[i] == END_MARKER)
			{
				messageEnd = i;
				ongoingMessage = false;
				messageFinished = true;
				// A single recv() can return more than one framed message back-to-back; keep whatever's
				// past this message's END_MARKER for the next read instead of dropping it.
				this->_leftoverBytes.assign(buf + i + 1, buf + numRecvd);
				break;
			}
		}

		if (messageStart < messageEnd)
		{
			msgBytes.insert(msgBytes.end(), buf + messageStart, buf + messageEnd);
		}

		// Bail out on a stream that keeps delivering bytes but never an END_MARKER, so the next read can
		// resync on the next START_MARKER instead of growing this buffer forever.
		if (msgBytes.size() > MAX_BLUETOOTH_MESSAGE_SIZE)
		{
			throw RecoverableException("Invalid: message exceeded the maximum size without an end marker", true);
		}
	} while (!messageFinished);

	auto msg = CommandSerializer::unpackBtMessage(msgBytes);

	// The device retransmits any DATA_MDR frame it sends until the host ACKs it. The ack carries the
	// toggled 1-bit sequence number (1 - deviceSeq), matching the device's own ack-to-us behaviour.
	if (msg.dataType == DATA_TYPE::DATA_MDR)
	{
		auto ack = CommandSerializer::packageDataForBt({}, DATA_TYPE::ACK, (unsigned char)(1 - msg.seqNumber));
		this->_connector->send(ack.data(), ack.size());
	}

	return msg;
}

