#include "CommandSerializer.h"

#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace
{
struct Fixture
{
	std::string name;
	unsigned int dataType;
	unsigned int sequence;
	Buffer payload;
	Buffer frame;
};

Buffer parseHex(const std::string& text)
{
	Buffer bytes;
	std::istringstream input(text);
	unsigned int value;
	while (input >> std::hex >> value)
	{
		if (value > 0xff) throw std::runtime_error("fixture contains a non-byte value");
		bytes.push_back(static_cast<char>(value));
	}
	if (!input.eof()) throw std::runtime_error("fixture contains invalid hex");
	return bytes;
}

std::string toHex(const Buffer& bytes)
{
	std::ostringstream output;
	for (size_t i = 0; i < bytes.size(); i++)
	{
		if (i != 0) output << ' ';
		output << std::hex << std::setw(2) << std::setfill('0')
			<< static_cast<unsigned int>(static_cast<unsigned char>(bytes[i]));
	}
	return output.str();
}

std::vector<Fixture> loadFixtures(const std::string& path)
{
	std::ifstream input(path);
	if (!input) throw std::runtime_error("could not open golden fixture: " + path);

	std::vector<Fixture> fixtures;
	std::string line;
	while (std::getline(input, line))
	{
		if (line.empty() || line[0] == '#') continue;
		std::istringstream row(line);
		std::string name, type, sequence, payload, frame;
		if (!std::getline(row, name, '|') || !std::getline(row, type, '|') ||
			!std::getline(row, sequence, '|') || !std::getline(row, payload, '|') ||
			!std::getline(row, frame))
			throw std::runtime_error("invalid fixture row: " + line);
		fixtures.push_back({ name, static_cast<unsigned int>(std::stoul(type, nullptr, 16)),
			static_cast<unsigned int>(std::stoul(sequence)), parseHex(payload), parseHex(frame) });
	}
	return fixtures;
}

std::string renderFixtures(const std::vector<Fixture>& fixtures, const std::vector<Buffer>& frames)
{
	std::ostringstream output;
	output << "# id|data_type|sequence|payload|complete_frame\n";
	for (size_t i = 0; i < fixtures.size(); i++)
	{
		output << fixtures[i].name << '|' << std::hex << std::setw(2) << std::setfill('0')
			<< fixtures[i].dataType << '|' << std::dec << fixtures[i].sequence << '|'
			<< toHex(fixtures[i].payload) << '|' << toHex(frames[i]) << '\n';
	}
	return output.str();
}

void require(bool condition, const std::string& message)
{
	if (!condition) throw std::runtime_error(message);
}

template<typename Func>
void requireReject(Func operation, const char* name)
{
	try { operation(); }
	catch (const std::exception&) { return; }
	throw std::runtime_error(std::string("malformed frame was accepted: ") + name);
}
}

int main(int argc, char** argv)
{
	if (argc != 2) throw std::runtime_error("usage: protocol-conformance-tests <golden-file>");
	const std::string fixturePath = argv[1];
	auto fixtures = loadFixtures(fixturePath);
	require(!fixtures.empty(), "golden fixture has no cases");

	std::vector<Buffer> actualFrames;
	bool mismatch = false;
	for (const auto& fixture : fixtures)
	{
		auto actual = CommandSerializer::packageDataForBt(fixture.payload,
			static_cast<DATA_TYPE>(fixture.dataType), fixture.sequence);
		actualFrames.push_back(actual);
		if (actual != fixture.frame)
		{
			mismatch = true;
			std::cerr << fixture.name << " golden mismatch\nexpected: " << toHex(fixture.frame)
				<< "\nactual:   " << toHex(actual) << '\n';
		}

		require(actual.front() == START_MARKER && actual.back() == END_MARKER,
			fixture.name + " is not framed");
		Buffer body(actual.begin() + 1, actual.end() - 1);
		auto decoded = CommandSerializer::unpackBtMessage(body);
		require(static_cast<unsigned int>(decoded.dataType) == fixture.dataType,
			fixture.name + " data type did not round-trip");
		require(decoded.seqNumber == fixture.sequence, fixture.name + " sequence did not round-trip");
		require(decoded.payload == fixture.payload, fixture.name + " payload did not round-trip");
	}

	if (const char* update = std::getenv("UPDATE_GOLDENS"); update && std::string(update) == "1")
	{
		std::ofstream output(fixturePath, std::ios::trunc);
		output << renderFixtures(fixtures, actualFrames);
		std::cout << "Updated golden fixture; review the diff before accepting it.\n";
		mismatch = false;
	}
	else if (mismatch)
	{
		std::ofstream actual(fixturePath + ".actual", std::ios::trunc);
		actual << renderFixtures(fixtures, actualFrames);
		throw std::runtime_error("golden mismatch; inspect the .actual file");
	}

	requireReject([] { CommandSerializer::unpackBtMessage({}); }, "empty");
	requireReject([] { CommandSerializer::unpackBtMessage({ 0x3d }); }, "dangling escape");
	requireReject([] { CommandSerializer::unpackBtMessage({ 0x0c, 0, 0, 0, 0, 2, 0, 0 }); }, "missing checksum");
	requireReject([] { CommandSerializer::unpackBtMessage({ 0x0c, 0, 0, 0, 0, 0, 0x0c, 0 }); }, "trailing data");
	requireReject([] { CommandSerializer::unpackBtMessage({ 0x0c, 0, 0, 0, 0, 0, 0x00 }); }, "bad checksum");

	std::cout << fixtures.size() << " Sony protocol golden cases passed\n";
	return 0;
}
