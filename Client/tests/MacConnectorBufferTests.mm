// Offline tests for MacOSBluetoothConnector's receive buffering (enqueueReceivedData/recv).
// No RFCOMM channel is ever opened; frames are injected exactly as the IOBluetooth data
// delegate would deliver them.

#include "MacOSBluetoothConnector.h"

#include <cstring>
#include <iostream>
#include <numeric>
#include <stdexcept>
#include <vector>

namespace
{
void require(bool condition, const char* message)
{
	if (!condition) throw std::runtime_error(message);
}

size_t bufferedTotal(MacOSBluetoothConnector& connector)
{
	std::lock_guard<std::mutex> g(connector.receiveDataMutex);
	size_t total = 0;
	for (const auto& chunk : connector.receivedBytes) total += chunk.size();
	return total;
}
}

int main()
{
	// A zero-length frame must be dropped: recv() returning 0 reads as "connection closed" in
	// BluetoothWrapper, so buffering it would fabricate a disconnect.
	{
		MacOSBluetoothConnector connector;
		connector.running = true;
		connector.enqueueReceivedData(nullptr, 0);
		require(connector.receivedBytes.empty(), "zero-length frame was buffered");

		const unsigned char payload[] = { 0x3e, 0x01, 0x02, 0x3c };
		connector.enqueueReceivedData(payload, sizeof(payload));
		char buf[16] = { 0 };
		int numRecvd = connector.recv(buf, sizeof(buf));
		require(numRecvd == 4 && std::memcmp(buf, payload, 4) == 0,
			"frame after a zero-length frame was not delivered intact");
	}

	// A device streaming unsolicited frames while nothing is reading must not grow the buffer
	// without bound; the oldest chunks are dropped and the newest survive.
	{
		MacOSBluetoothConnector connector;
		connector.running = true;
		std::vector<unsigned char> chunk(1000);
		for (int i = 0; i < 200; i++)
		{
			std::fill(chunk.begin(), chunk.end(), (unsigned char)i);
			connector.enqueueReceivedData(chunk.data(), chunk.size());
		}
		require(bufferedTotal(connector) <= MacOSBluetoothConnector::RECEIVE_BUFFER_CAP,
			"receive buffer exceeded RECEIVE_BUFFER_CAP under flood");
		require(!connector.receivedBytes.empty() && connector.receivedBytes.back().front() == 199,
			"flood dropped the newest chunk instead of the oldest");
	}

	// Splitting an oversized chunk across recv() calls must keep the byte accounting consistent,
	// so the cap still holds after partial reads.
	{
		MacOSBluetoothConnector connector;
		connector.running = true;
		std::vector<unsigned char> big(3000);
		std::iota(big.begin(), big.end(), 0);
		connector.enqueueReceivedData(big.data(), big.size());

		char buf[2048];
		int first = connector.recv(buf, sizeof(buf));
		require(first == 2048 && (unsigned char)buf[2047] == (unsigned char)2047,
			"first partial read returned wrong data");
		require(bufferedTotal(connector) == 3000 - 2048, "split remainder was not re-buffered");

		int second = connector.recv(buf, sizeof(buf));
		require(second == 3000 - 2048 && (unsigned char)buf[0] == (unsigned char)2048,
			"second partial read returned wrong data");
		require(bufferedTotal(connector) == 0, "buffer not empty after draining the split chunk");

		// The cap must still be measured correctly after the split bookkeeping.
		std::vector<unsigned char> chunk(1000);
		for (int i = 0; i < 200; i++) connector.enqueueReceivedData(chunk.data(), chunk.size());
		require(bufferedTotal(connector) <= MacOSBluetoothConnector::RECEIVE_BUFFER_CAP,
			"receive buffer exceeded the cap after split reads");
	}

	std::cout << "macOS connector receive-buffer tests passed\n";
	return 0;
}
