#include "CommandSerializer.h"

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <exception>

namespace
{
	using CommandSerializer::Message;

	[[noreturn]] void failInvariant()
	{
		std::abort();
	}

	void requireEqual(const Message& expected, const Message& actual)
	{
		if (expected.dataType != actual.dataType ||
			expected.seqNumber != actual.seqNumber ||
			expected.payload != actual.payload)
		{
			failInvariant();
		}
	}
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
	if (size > MAX_BLUETOOTH_MESSAGE_SIZE)
	{
		return 0;
	}

	Buffer input;
	if (size != 0)
	{
		input.assign(reinterpret_cast<const char*>(data),
			reinterpret_cast<const char*>(data) + size);
	}

	// Exercise the untrusted inbound parser directly. Malformed frames are expected
	// to throw; sanitizer findings and invariant failures are not.
	try
	{
		auto decoded = CommandSerializer::unpackBtMessage(input);
		try
		{
			auto packaged = CommandSerializer::packageDataForBt(
				decoded.payload, decoded.dataType, static_cast<unsigned char>(decoded.seqNumber));
			Buffer body(packaged.begin() + 1, packaged.end() - 1);
			requireEqual(decoded, CommandSerializer::unpackBtMessage(body));
		}
		catch (const std::exception&)
		{
			// An accepted inbound frame can be larger than the outbound framing limit
			// after canonical escaping. That size rejection is expected behavior.
		}
	}
	catch (const std::exception&)
	{
	}

	// Turn arbitrary bytes into structured payloads to reach the packager and its
	// escaping logic quickly, then verify every package that fits can be decoded.
	if (size >= 2)
	{
		Buffer payload;
		if (size > 2)
		{
			payload.assign(reinterpret_cast<const char*>(data) + 2,
				reinterpret_cast<const char*>(data) + size);
		}
		const auto dataType = static_cast<DATA_TYPE>(static_cast<signed char>(data[0]));
		const auto sequence = data[1];

		try
		{
			auto packaged = CommandSerializer::packageDataForBt(payload, dataType, sequence);
			Buffer body(packaged.begin() + 1, packaged.end() - 1);
			Message expected{ dataType, sequence, payload };
			requireEqual(expected, CommandSerializer::unpackBtMessage(body));
		}
		catch (const std::exception&)
		{
			// Oversized escaped output is an expected packager rejection.
		}
	}

	return 0;
}
