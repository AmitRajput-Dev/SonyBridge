#pragma once

#include "IBluetoothConnector.h"
#include "CommandSerializer.h"
#include "Constants.h"
#include <memory>
#include <vector>
#include <string>
#include <mutex>


//Thread-safety: This class is thread-safe.
class BluetoothWrapper
{
public:
	BluetoothWrapper(std::unique_ptr<IBluetoothConnector> connector);

	BluetoothWrapper(const BluetoothWrapper&) = delete;
	BluetoothWrapper& operator=(const BluetoothWrapper&) = delete;

	BluetoothWrapper(BluetoothWrapper&& other) noexcept;
	BluetoothWrapper& operator=(BluetoothWrapper&& other) noexcept;

	int sendCommand(const std::vector<char>& bytes);

	// Sends an inquiry command and returns the payload of the first DATA_MDR response whose command id
	// (payload[0]) matches retCommandId, skipping the ACK and any unrelated notifications.
	Buffer sendCommandAndReadResponse(const std::vector<char>& bytes, unsigned char retCommandId);

	bool isConnected() noexcept;
	//Try to connect to the headphones
	void connect(const std::string& addr);
	void disconnect() noexcept;

	std::vector<BluetoothDevice> getConnectedDevices();

	//Only valid after a successful connect().
	SonyProtocolVersion getProtocolVersion() noexcept;

private:
	void _waitForAck();
	//Reads and parses exactly one framed message from the connector (replaying buffered leftover bytes first).
	CommandSerializer::Message _readMessage();

	std::unique_ptr<IBluetoothConnector> _connector;
	std::mutex _connectorMtx;
	unsigned int _seqNumber = 0;
	//Bytes read past the current message's END_MARKER in a single recv() call - a recv() can return more
	//than one framed message back-to-back, so these are replayed on the next _waitForAck() instead of dropped.
	Buffer _leftoverBytes;
};