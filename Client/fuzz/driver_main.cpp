// Standalone deterministic driver for toolchains without libFuzzer.
// Replays every corpus seed plus the empty input, then runs bounded
// structured mutation (bit/byte flips, truncation, length-field tampering,
// escape/marker injection, seed splicing) through LLVMFuzzerTestOneInput.
// Build with -fsanitize=address,undefined -fno-sanitize-recover=all.
// Not compiled into the libFuzzer target; see run-macos.sh fallback path.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size);

namespace
{
	constexpr size_t kMaxInput = 2048; // mirrors MAX_BLUETOOTH_MESSAGE_SIZE

	uint64_t rngState = 0x9e3779b97f4a7c15ull;

	uint64_t nextRand()
	{
		// xorshift64* — deterministic across runs and platforms.
		rngState ^= rngState >> 12;
		rngState ^= rngState << 25;
		rngState ^= rngState >> 27;
		return rngState * 0x2545f4914f6cdd1dull;
	}

	void runOne(const std::vector<uint8_t>& input)
	{
		LLVMFuzzerTestOneInput(input.data(), input.size());
	}

	void mutate(std::vector<uint8_t>& buf)
	{
		// Bytes the protocol treats specially: markers, escape sentry, escape codes.
		static const uint8_t special[] = { 0x3c, 0x3d, 0x3e, 0x2c, 0x2d, 0x2e, 0x00, 0xff };

		switch (nextRand() % 8)
		{
		case 0: // bit flip
			if (!buf.empty())
			{
				buf[nextRand() % buf.size()] ^= static_cast<uint8_t>(1u << (nextRand() % 8));
			}
			break;

		case 1: // byte overwrite with random value
			if (!buf.empty())
			{
				buf[nextRand() % buf.size()] = static_cast<uint8_t>(nextRand());
			}
			break;

		case 2: // truncate
			if (!buf.empty())
			{
				buf.resize(nextRand() % buf.size());
			}
			break;

		case 3: // length-field tampering (bytes 2..5 of the unescaped header)
			if (buf.size() >= 6)
			{
				buf[2 + nextRand() % 4] = static_cast<uint8_t>(nextRand());
			}
			break;

		case 4: // escape/marker injection at a random position
			{
				size_t pos = buf.empty() ? 0 : nextRand() % buf.size();
				buf.insert(buf.begin() + pos, special[nextRand() % sizeof(special)]);
			}
			break;

		case 5: // overwrite with a special byte
			if (!buf.empty())
			{
				buf[nextRand() % buf.size()] = special[nextRand() % sizeof(special)];
			}
			break;

		case 6: // append random tail
			{
				size_t extra = nextRand() % 16 + 1;
				for (size_t i = 0; i < extra && buf.size() < kMaxInput; i++)
				{
					buf.push_back(static_cast<uint8_t>(nextRand()));
				}
			}
			break;

		case 7: // duplicate a random chunk (grows structure, keeps checksummed prefixes)
			if (!buf.empty())
			{
				size_t start = nextRand() % buf.size();
				size_t len = nextRand() % (buf.size() - start) + 1;
				if (buf.size() + len <= kMaxInput)
				{
					std::vector<uint8_t> chunk(buf.begin() + start, buf.begin() + start + len);
					buf.insert(buf.begin() + start, chunk.begin(), chunk.end());
				}
			}
			break;
		}

		if (buf.size() > kMaxInput)
		{
			buf.resize(kMaxInput);
		}
	}
}

int main(int argc, char** argv)
{
	std::vector<std::vector<uint8_t>> seeds;
	seeds.push_back({}); // empty input is a required boundary case

	for (int i = 1; i < argc; i++)
	{
		if (std::strncmp(argv[i], "-iterations=", 12) == 0)
		{
			continue; // handled below
		}
		std::ifstream f(argv[i], std::ios::binary);
		if (!f)
		{
			std::fprintf(stderr, "cannot read seed %s\n", argv[i]);
			return 2;
		}
		std::vector<uint8_t> data((std::istreambuf_iterator<char>(f)),
			std::istreambuf_iterator<char>());
		seeds.push_back(std::move(data));
	}

	unsigned long long iterations = 1500000;
	for (int i = 1; i < argc; i++)
	{
		if (std::strncmp(argv[i], "-iterations=", 12) == 0)
		{
			iterations = std::strtoull(argv[i] + 12, nullptr, 10);
		}
	}

	// Replay every seed unmodified first.
	for (const auto& s : seeds)
	{
		runOne(s);
	}

	// Structured mutation: pick a seed (or a splice of two), apply 1-4 mutations.
	std::vector<uint8_t> buf;
	for (unsigned long long i = 0; i < iterations; i++)
	{
		const auto& base = seeds[nextRand() % seeds.size()];
		buf = base;
		if (nextRand() % 4 == 0 && seeds.size() > 1)
		{
			const auto& other = seeds[nextRand() % seeds.size()];
			size_t cut = buf.empty() ? 0 : nextRand() % (buf.size() + 1);
			buf.resize(cut);
			if (!other.empty())
			{
				size_t take = nextRand() % (other.size() + 1);
				buf.insert(buf.end(), other.begin(), other.begin() + take);
			}
		}
		size_t rounds = nextRand() % 4 + 1;
		for (size_t r = 0; r < rounds; r++)
		{
			mutate(buf);
		}
		runOne(buf);

		if ((i + 1) % 250000 == 0)
		{
			std::fprintf(stderr, "iter %llu\n", i + 1);
		}
	}

	std::fprintf(stderr, "done: %llu mutation iterations + %zu seed replays\n",
		iterations, seeds.size());
	return 0;
}
