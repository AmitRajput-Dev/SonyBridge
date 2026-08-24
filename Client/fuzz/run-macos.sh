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

clang++ -std=c++20 -g -O1 \
	-fsanitize=fuzzer,address,undefined \
	-fno-sanitize-recover=all -fno-omit-frame-pointer \
	-I"$client_dir" \
	"$fuzz_dir/FuzzCommandSerializer.cpp" \
	"$client_dir/ByteMagic.cpp" \
	"$client_dir/CommandSerializer.cpp" \
	-o "$binary"

export ASAN_OPTIONS="abort_on_error=1:detect_leaks=1:symbolize=1"
export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1"

"$binary" \
	-max_total_time="${FUZZ_SECONDS:-60}" \
	-max_len="$MAX_BLUETOOTH_MESSAGE_SIZE" \
	-timeout=5 \
	-use_value_profile=1 \
	-print_final_stats=1 \
	-dict="$fuzz_dir/dictionaries/sony_protocol.dict" \
	-artifact_prefix="$artifacts/" \
	"$corpus"
