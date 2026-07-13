#include "BluetoothWrapper.h"

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

Buffer BluetoothWrapper::sendCommandAndReadResponse(const std::vector<char>& bytes, unsigned char retCommandId)
{
	std::lock_guard guard(this->_connectorMtx);
	auto data = CommandSerializer::packageDataForBt(bytes, DATA_TYPE::DATA_MDR, this->_seqNumber++);
	this->_connector->send(data.data(), data.size());

	// The device replies with an ACK and then the RET frame; unrelated notifications may interleave.
	for (int i = 0; i < 16; i++)
	{
		auto msg = this->_readMessage();
		if (msg.dataType == DATA_TYPE::ACK)
		{
			this->_seqNumber = msg.seqNumber;
			continue;
		}
		if (msg.dataType == DATA_TYPE::DATA_MDR && !msg.payload.empty()
			&& (unsigned char)msg.payload[0] == retCommandId)
		{
			return msg.payload;
		}
	}
	throw RecoverableException("No matching response received from device", true);
}

void BluetoothWrapper::_waitForAck()
{
	auto msg = this->_readMessage();
	this->_seqNumber = msg.seqNumber;
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

		size_t messageStart = 0;
		size_t messageEnd = numRecvd;

		for (size_t i = 0; i < numRecvd; i++)
		{
			if (buf[i] == START_MARKER)
			{
				if (ongoingMessage)
				{
					throw RecoverableException("Invalid: Multiple start markers without an end marker", true);
				}
				messageStart = i + 1;
				ongoingMessage = true;
			}
			else if (ongoingMessage && buf[i] == END_MARKER)
			{
				messageEnd = i;
				ongoingMessage = false;
				messageFinished = true;
				// A single recv() can return more than one framed message back-to-back; keep whatever's
				// past this message's END_MARKER for the next _waitForAck() call instead of dropping it.
				this->_leftoverBytes.assign(buf + i + 1, buf + numRecvd);
				break;
			}
		}

		msgBytes.insert(msgBytes.end(), buf + messageStart, buf + messageEnd);
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

