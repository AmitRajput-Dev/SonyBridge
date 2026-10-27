#include "CommandSerializer.h"
#include "Constants.h"
#include "Exceptions.h"

#include <cstddef>
#include <cstdint>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

// Metamorphic (relational) tests for the Sony v1 wire protocol layer.
//
// The conformance suite pins 18 exact golden frames and the fuzzer proves the
// inbound parser is crash-free; this suite covers the gap between them:
// properties that must hold across *transformations* of programmatically
// generated inputs, not just for pinned examples.
//
//   P1  Round-trip: unpack(strip_markers(pack(p, dt, seq))) == (p, dt, seq & 0xFF),
//       and pack's output matches an independent re-implementation of the
//       documented frame layout (structure, declared size, checksum).
//   P2  Escaping transparency: every escapable byte (60/61/62) survives a
//       round trip at every payload position, and the packed frame interior
//       never contains a raw frame marker (60/62).
//   P3  Sequence-number domain: seq 0..255 round-trips exactly; wider values
//       are truncated mod 256, byte-identically to packing (seq & 0xFF).
//   P4  Framing: dropping or adding a single byte at either end of a valid
//       body is rejected, as is unpacking a frame with its markers attached.
//   P5  Determinism / inverse consistency: packing is byte-identical across
//       calls, and re-packing an unpacked message reproduces the original frame.
//   P6  Corruption rejection: for the frames tested here, replacing any single
//       body byte with any other value (and, for a large frame, flipping any
//       single bit) makes unpack throw RecoverableException. Note: single-byte
//       edits of the *unescaped* image are always caught (mod-256 sum changes
//       whenever one byte changes); wire-level edits also shift length/framing,
//       and this section verifies rejection exhaustively over this corpus.
//   P7  Size boundary: pack succeeds iff the escaped frame fits in
//       MAX_BLUETOOTH_MESSAGE_SIZE, measured on the escaped size (payload
//       bytes that escape count double), and every returned frame fits.
//
// Everything is deterministic: fixed-seed splitmix64, no wall clock, no I/O.

namespace
{
size_t g_checks = 0;

void require(bool condition, const std::string& message)
{
	g_checks++;
	if (!condition) throw std::runtime_error(message);
}

// Fixed-seed splitmix64 so every run sees the exact same corpus.
uint64_t g_rngState = 0x5b7a1e0fd2c3a9e4ULL;

unsigned char nextByte()
{
	g_rngState += 0x9e3779b97f4a7c15ULL;
	uint64_t z = g_rngState;
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return static_cast<unsigned char>((z ^ (z >> 31)) & 0xff);
}

Buffer randomPayload(size_t n)
{
	Buffer ret;
	ret.reserve(n);
	for (size_t i = 0; i < n; i++)
		ret.push_back(static_cast<char>(nextByte()));
	return ret;
}

std::string hexDump(const Buffer& b)
{
	std::ostringstream oss;
	oss << std::hex;
	for (auto c : b) oss << ((unsigned)(unsigned char)c < 16 ? "0" : "") << (unsigned)(unsigned char)c << " ";
	return oss.str();
}

constexpr unsigned char SENTRY = 61;

// Independent re-implementation of the documented unescape (from the format
// comment in CommandSerializer.h), used to structurally verify pack's output
// without calling the production _unescapeSpecials.
std::vector<unsigned char> refUnescape(const Buffer& body)
{
	std::vector<unsigned char> out;
	for (size_t i = 0; i < body.size(); i++)
	{
		auto b = static_cast<unsigned char>(body[i]);
		if (b == SENTRY)
		{
			require(i + 1 < body.size(), "packed frame ends with a dangling escape sentry");
			auto n = static_cast<unsigned char>(body[++i]);
			if (n == 44) out.push_back(60);
			else if (n == 45) out.push_back(61);
			else if (n == 46) out.push_back(62);
			else require(false, "packed frame contains an invalid escape pair");
		}
		else
		{
			out.push_back(b);
		}
	}
	return out;
}

Buffer stripMarkers(const Buffer& frame)
{
	require(frame.size() >= 2, "packed frame is too small to carry both markers");
	require(frame.front() == START_MARKER, "packed frame does not start with the start marker");
	require(frame.back() == END_MARKER, "packed frame does not end with the end marker");
	return Buffer(frame.begin() + 1, frame.end() - 1);
}

enum class Outcome { Parsed, Recoverable, OtherError };

Outcome tryUnpack(const Buffer& body, CommandSerializer::Message* out = nullptr)
{
	try
	{
		auto msg = CommandSerializer::unpackBtMessage(body);
		if (out) *out = msg;
		return Outcome::Parsed;
	}
	catch (const RecoverableException&) { return Outcome::Recoverable; }
	catch (...) { return Outcome::OtherError; }
}

struct Case
{
	Buffer payload;
	unsigned char dataType;
	unsigned int seq;
};

// Every declared DATA_TYPE value.
const unsigned char DATA_TYPES[] = { 0, 1, 2, 9, 10, 12, 13, 14, 16, 18, 25, 26, 28, 29, 30, 45 };
const unsigned int SEQS[] = { 0, 1, 2, 60, 61, 62, 127, 128, 254, 255 };

std::vector<Case> buildCorpus()
{
	std::vector<Case> corpus;
	const size_t sizes[] = { 0, 1, 2, 3, 4, 7, 8, 16, 63, 64, 255, 256, 257, 1024 };
	size_t dtIdx = 0, seqIdx = 0;
	for (auto n : sizes)
	{
		corpus.push_back({ randomPayload(n),
			DATA_TYPES[dtIdx++ % (sizeof(DATA_TYPES))],
			SEQS[seqIdx++ % (sizeof(SEQS) / sizeof(SEQS[0]))] });
	}
	// Payloads whose checksum byte lands exactly on 60/61/62 (dt=12, seq=1:
	// 14 + b == 60/61/62), so the escaped-checksum path is exercised too.
	for (unsigned char b : { 46, 47, 48 })
		corpus.push_back({ Buffer{ static_cast<char>(b) }, 12, 1 });
	// Escape-dense and sentry-adjacent patterns.
	corpus.push_back({ Buffer{ 60, 61, 62, 60, 61, 62 }, 12, 0 });
	corpus.push_back({ Buffer{ 61, 44, 61, 45, 61, 46 }, 12, 0 });
	corpus.push_back({ Buffer{ 44, 45, 46 }, 12, 0 });
	return corpus;
}

// P1 + P5 for one case: structural validation against the independent
// re-implementation, production round trip, determinism, and repack identity.
void checkRoundTrip(const Case& c)
{
	const auto frame = CommandSerializer::packageDataForBt(c.payload, static_cast<DATA_TYPE>(c.dataType), c.seq);
	const auto frameAgain = CommandSerializer::packageDataForBt(c.payload, static_cast<DATA_TYPE>(c.dataType), c.seq);
	require(frame == frameAgain, "packing the same input twice was not byte-identical");
	require(frame.size() <= MAX_BLUETOOTH_MESSAGE_SIZE, "pack returned a frame larger than MAX_BLUETOOTH_MESSAGE_SIZE");

	const auto body = stripMarkers(frame);
	// The interior must never contain a raw frame marker, or the transport
	// could not find frame boundaries unambiguously.
	for (auto ch : body)
		require(ch != START_MARKER && ch != END_MARKER,
			"packed frame interior contains a raw frame marker: " + hexDump(frame));

	// Structural check against the documented layout, independently unescaped.
	const auto ref = refUnescape(body);
	require(ref.size() == 7 + c.payload.size(), "unescaped frame size does not match header + payload + checksum");
	require(ref[0] == c.dataType, "frame does not begin with the data type byte");
	require(ref[1] == (c.seq & 0xFF), "frame seq byte does not match the requested sequence number");
	const uint32_t declared = ((uint32_t)ref[2] << 24) | ((uint32_t)ref[3] << 16) | ((uint32_t)ref[4] << 8) | (uint32_t)ref[5];
	require(declared == c.payload.size(), "declared big-endian size does not match the payload length");
	for (size_t i = 0; i < c.payload.size(); i++)
		require(ref[6 + i] == static_cast<unsigned char>(c.payload[i]), "payload byte was altered by packing");
	unsigned char sum = 0;
	for (size_t i = 0; i < 6 + c.payload.size(); i++) sum = static_cast<unsigned char>(sum + ref[i]);
	require(sum == ref[6 + c.payload.size()], "checksum byte does not equal the mod-256 sum of the frame");

	// Production round trip.
	CommandSerializer::Message msg;
	require(tryUnpack(body, &msg) == Outcome::Parsed, "unpack rejected a freshly packed frame: " + hexDump(frame));
	require(static_cast<unsigned char>(msg.dataType) == c.dataType, "round-tripped data type differs");
	require(msg.seqNumber == (c.seq & 0xFF), "round-tripped sequence number differs");
	require(msg.payload == c.payload, "round-tripped payload differs: " + hexDump(frame));

	// Inverse consistency: packing the unpacked message reproduces the frame.
	const auto repacked = CommandSerializer::packageDataForBt(msg.payload, msg.dataType, msg.seqNumber);
	require(repacked == frame, "re-packing an unpacked message did not reproduce the original frame");
}

size_t testRoundTripCorpus(const std::vector<Case>& corpus)
{
	for (const auto& c : corpus) checkRoundTrip(c);
	return corpus.size();
}

// P2: every escapable byte, at every position, in several payload sizes.
size_t testEscapingTransparency()
{
	size_t cases = 0;
	size_t dtIdx = 0, seqIdx = 0;
	for (unsigned char special : { 60, 61, 62 })
	{
		for (size_t n : { 1, 2, 3, 5, 17 })
		{
			for (size_t pos = 0; pos < n; pos++)
			{
				Buffer payload(n, 0x41);
				payload[pos] = static_cast<char>(special);
				checkRoundTrip({ payload,
					DATA_TYPES[dtIdx++ % sizeof(DATA_TYPES)],
					SEQS[seqIdx++ % (sizeof(SEQS) / sizeof(SEQS[0]))] });
				cases++;
			}
		}
		// Payloads made entirely of one escapable byte.
		for (size_t n : { 1, 2, 3, 8, 64 })
		{
			checkRoundTrip({ Buffer(n, static_cast<char>(special)), 12, 3 });
			cases++;
		}
	}
	return cases;
}

// P3: seq 0..255 round-trips exactly; wider seqs truncate mod 256.
size_t testSeqDomain()
{
	size_t cases = 0;
	const Buffer payload{ 0x01, 0x02 };
	for (unsigned int seq = 0; seq <= 255; seq++)
	{
		checkRoundTrip({ payload, 12, seq });
		cases++;
	}
	for (unsigned int wide : { 256u, 300u, 65536u + 5u, 0xDEADBEEFu, 0xFFFFFFFFu })
	{
		const auto packedWide = CommandSerializer::packageDataForBt(payload, DATA_TYPE::DATA_MDR, wide);
		const auto packedTrunc = CommandSerializer::packageDataForBt(payload, DATA_TYPE::DATA_MDR, wide & 0xFF);
		require(packedWide == packedTrunc, "wide sequence number was not truncated mod 256 consistently");
		cases++;
	}
	return cases;
}

// P4: one-byte framing damage at either end is rejected, and unpack does not
// accept a frame that still carries its start/end markers.
size_t testFraming(const std::vector<Case>& corpus)
{
	size_t cases = 0;
	for (const auto& c : corpus)
	{
		const auto frame = CommandSerializer::packageDataForBt(c.payload, static_cast<DATA_TYPE>(c.dataType), c.seq);
		const auto body = stripMarkers(frame);

		Buffer truncated(body.begin(), body.end() - 1);
		require(tryUnpack(truncated) == Outcome::Recoverable,
			"body truncated by one byte was not rejected: " + hexDump(frame));

		Buffer headless(body.begin() + 1, body.end());
		require(tryUnpack(headless) == Outcome::Recoverable,
			"body with first byte dropped was not rejected: " + hexDump(frame));

		for (char extra : { (char)0x00, (char)SENTRY })
		{
			Buffer extended = body;
			extended.push_back(extra);
			require(tryUnpack(extended) == Outcome::Recoverable,
				"body extended by one byte was not rejected: " + hexDump(frame));
		}

		Buffer prefixed{ 0x00 };
		prefixed.insert(prefixed.end(), body.begin(), body.end());
		require(tryUnpack(prefixed) == Outcome::Recoverable,
			"body with a prepended byte was not rejected: " + hexDump(frame));

		require(tryUnpack(frame) == Outcome::Recoverable,
			"frame with markers still attached was not rejected: " + hexDump(frame));
		cases += 6;
	}
	return cases;
}

// P6: exhaustive single-byte corruption. Every replacement of every body byte
// (and every single-bit flip on a large frame) must be rejected with
// RecoverableException - never parsed, never a non-recoverable escape.
size_t testCorruptionRejection()
{
	size_t cases = 0;
	const std::vector<Case> targets = {
		{ Buffer{}, 12, 0 },
		{ Buffer{ 0x11, 0x22, 0x33 }, 1, 7 },
		{ Buffer{ 60, 61, 62, 44, 45, 46 }, 12, 61 },
		{ randomPayload(64), 13, 200 },
	};
	for (const auto& c : targets)
	{
		const auto frame = CommandSerializer::packageDataForBt(c.payload, static_cast<DATA_TYPE>(c.dataType), c.seq);
		const auto body = stripMarkers(frame);
		for (size_t pos = 0; pos < body.size(); pos++)
		{
			Buffer corrupted = body;
			for (int v = 0; v <= 255; v++)
			{
				if (static_cast<char>(v) == body[pos]) continue;
				corrupted[pos] = static_cast<char>(v);
				const auto outcome = tryUnpack(corrupted);
				if (outcome != Outcome::Recoverable)
				{
					std::ostringstream oss;
					oss << (outcome == Outcome::Parsed ? "silently accepted" : "threw a non-recoverable error for")
						<< " a corrupted frame: pos " << pos << " -> " << v << " in body " << hexDump(body);
					require(false, oss.str());
				}
				g_checks++;
				cases++;
			}
		}
	}

	// Single-bit flips across a large frame (payload well past one MTU chunk
	// of typical commands, still under the 2048 frame cap).
	const auto bigPayload = randomPayload(512);
	const auto bigFrame = CommandSerializer::packageDataForBt(bigPayload, DATA_TYPE::DATA_MDR, 1);
	const auto bigBody = stripMarkers(bigFrame);
	for (size_t pos = 0; pos < bigBody.size(); pos++)
	{
		Buffer corrupted = bigBody;
		for (int bit = 0; bit < 8; bit++)
		{
			corrupted[pos] = static_cast<char>(bigBody[pos] ^ (1 << bit));
			const auto outcome = tryUnpack(corrupted);
			if (outcome != Outcome::Recoverable)
			{
				std::ostringstream oss;
				oss << (outcome == Outcome::Parsed ? "silently accepted" : "threw a non-recoverable error for")
					<< " a bit-flipped frame: pos " << pos << " bit " << bit;
				require(false, oss.str());
			}
			g_checks++;
			cases++;
		}
	}
	return cases;
}

// P7: the 2048 cap applies to the escaped frame, so the payload budget depends
// on content: plain bytes cost 1 wire byte, escapable bytes cost 2.
size_t testSizeBoundary()
{
	size_t cases = 0;

	// Plain payload: overhead is 9 bytes (2 markers + 6 header + 1 checksum,
	// none of which escape for these inputs), so 2039 fits exactly and 2040
	// overflows.
	checkRoundTrip({ Buffer(2039, 0x41), 12, 1 });
	const auto maxFrame = CommandSerializer::packageDataForBt(Buffer(2039, 0x41), DATA_TYPE::DATA_MDR, 1);
	require(maxFrame.size() == MAX_BLUETOOTH_MESSAGE_SIZE, "largest plain payload did not produce an exactly full frame");
	cases++;

	for (size_t n : { 2040, 2100, 4096 })
	{
		bool threw = false;
		try { CommandSerializer::packageDataForBt(Buffer(n, 0x41), DATA_TYPE::DATA_MDR, 1); }
		catch (const std::exception&) { threw = true; }
		require(threw, "oversized plain payload was not rejected");
		cases++;
	}

	// All-escapable payload: each byte costs two wire bytes, so the budget
	// halves. 1016 bytes of 60 fits (frame 2041); 1020 does not (frame 2049).
	checkRoundTrip({ Buffer(1016, 60), 12, 1 });
	cases++;
	{
		bool threw = false;
		try { CommandSerializer::packageDataForBt(Buffer(1020, 60), DATA_TYPE::DATA_MDR, 1); }
		catch (const std::exception&) { threw = true; }
		require(threw, "oversized escape-heavy payload was not rejected despite escaping inflation");
		cases++;
	}
	return cases;
}
}

int main()
{
	try
	{
		const auto corpus = buildCorpus();
		const auto roundTrips = testRoundTripCorpus(corpus);
		const auto escapes = testEscapingTransparency();
		const auto seqs = testSeqDomain();
		const auto framings = testFraming(corpus);
		const auto corruptions = testCorruptionRejection();
		const auto boundaries = testSizeBoundary();

		std::cout << "Sony protocol metamorphic tests passed: "
			<< roundTrips << " round-trip, "
			<< escapes << " escaping, "
			<< seqs << " seq-domain, "
			<< framings << " framing, "
			<< corruptions << " corruption, "
			<< boundaries << " boundary cases ("
			<< g_checks << " checks)\n";
		return 0;
	}
	catch (const std::exception& e)
	{
		std::cerr << "METAMORPHIC TEST FAILURE: " << e.what() << "\n";
		return 1;
	}
}
