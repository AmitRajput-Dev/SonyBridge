#!/bin/sh
set -eu

client_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
fuzz_dir="$client_dir/fuzz"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/sonybridge-fuzz.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT INT TERM

binary="$work_dir/fuzz-command-serializer"
corpus="$work_dir/corpus"
artifacts="$work_dir/artifacts"
mkdir -p "$corpus" "$artifacts"

# Empty input is a required parser boundary seed.
: > "$corpus/empty"
for seed in "$fuzz_dir"/seeds/*.hex; do
	name=$(basename "$seed" .hex)
	xxd -r -p "$seed" "$corpus/$name"
done

# Apple's clang++ ships without the libFuzzer runtime; the failure only shows at
# link time, so probe with a real link. Fall back to a Homebrew LLVM clang++, and
# if none exists run the deterministic mutation driver instead of libFuzzer.
probe="$work_dir/fuzzer-probe"
printf 'extern "C" int LLVMFuzzerTestOneInput(const unsigned char*, unsigned long) { return 0; }\n' > "$probe.cpp"
cxx="${CXX:-clang++}"
have_libfuzzer=1
if ! "$cxx" -fsanitize=fuzzer "$probe.cpp" -o "$probe" 2>/dev/null; then
	have_libfuzzer=0
	for candidate in /opt/homebrew/opt/llvm*/bin/clang++ /usr/local/opt/llvm*/bin/clang++; do
		if [ -x "$candidate" ] && "$candidate" -fsanitize=fuzzer "$probe.cpp" -o "$probe" 2>/dev/null; then
			cxx="$candidate"
			have_libfuzzer=1
			break
		fi
	done
fi

# Keep -max_len in lockstep with MAX_BLUETOOTH_MESSAGE_SIZE in Constants.h.
max_len=$(sed -n 's/.*MAX_BLUETOOTH_MESSAGE_SIZE = \([0-9]*\).*/\1/p' "$client_dir/Constants.h")

export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1"

if [ "$have_libfuzzer" -eq 1 ]; then
	# Apple's ASan lacks leak detection; only enable it for LLVM clang builds.
	export ASAN_OPTIONS="abort_on_error=1:detect_leaks=1:symbolize=1"
	export LSAN_OPTIONS="suppressions=$fuzz_dir/lsan.supp"

	"$cxx" -std=c++20 -g -O1 \
		-fsanitize=fuzzer,address,undefined \
		-fno-sanitize-recover=all -fno-omit-frame-pointer \
		-I"$client_dir" \
		"$fuzz_dir/FuzzCommandSerializer.cpp" \
		"$client_dir/ByteMagic.cpp" \
		"$client_dir/CommandSerializer.cpp" \
		-o "$binary"

	"$binary" \
		-max_total_time="${FUZZ_SECONDS:-60}" \
		-max_len="$max_len" \
		-timeout=5 \
		-use_value_profile=1 \
		-print_final_stats=1 \
		-dict="$fuzz_dir/dictionaries/sony_protocol.dict" \
		-artifact_prefix="$artifacts/" \
		"$corpus"
else
	echo "libFuzzer unavailable; running deterministic mutation driver" >&2
	export ASAN_OPTIONS="abort_on_error=1:symbolize=1"
	"$cxx" -std=c++20 -g -O1 \
		-fsanitize=address,undefined \
		-fno-sanitize-recover=all -fno-omit-frame-pointer \
		-I"$client_dir" \
		"$fuzz_dir/driver_main.cpp" \
		"$fuzz_dir/FuzzCommandSerializer.cpp" \
		"$client_dir/ByteMagic.cpp" \
		"$client_dir/CommandSerializer.cpp" \
		-o "$binary"

	"$binary" -iterations="${FUZZ_ITERATIONS:-1500000}" "$corpus"/*
fi
