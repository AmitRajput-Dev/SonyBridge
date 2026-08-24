#!/bin/sh
set -eu

client_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_binary="${TMPDIR:-/tmp}/sonybridge-xm4-protocol-tests"
conformance_binary="${TMPDIR:-/tmp}/sonybridge-protocol-conformance-tests"
metamorphic_binary="${TMPDIR:-/tmp}/sonybridge-metamorphic-protocol-tests"
mac_connector_binary="${TMPDIR:-/tmp}/sonybridge-mac-connector-buffer-tests"

clang++ -std=c++20 -pthread -I"$client_dir" \
    "$client_dir/tests/HeadphonesProtocolTests.cpp" \
    "$client_dir/BluetoothWrapper.cpp" \
    "$client_dir/ByteMagic.cpp" \
    "$client_dir/CommandSerializer.cpp" \
    "$client_dir/Headphones.cpp" \
    -o "$test_binary"

"$test_binary"

clang++ -std=c++20 -Wall -Wextra -Werror -I"$client_dir" \
    "$client_dir/tests/ProtocolConformanceTests.cpp" \
    "$client_dir/ByteMagic.cpp" \
    "$client_dir/CommandSerializer.cpp" \
    -o "$conformance_binary"

"$conformance_binary" "$client_dir/tests/conformance/fixtures/xm4_v1_frames.golden"

clang++ -std=c++20 -Wall -Wextra -Werror -I"$client_dir" \
    "$client_dir/tests/MetamorphicProtocolTests.cpp" \
    "$client_dir/ByteMagic.cpp" \
    "$client_dir/CommandSerializer.cpp" \
    -o "$metamorphic_binary"

"$metamorphic_binary"

# Offline receive-buffer tests for the macOS connector (no Bluetooth channel is opened).
clang++ -std=c++20 -fobjc-arc -pthread -I"$client_dir" -I"$client_dir/macos" \
    "$client_dir/tests/MacConnectorBufferTests.mm" \
    "$client_dir/macos/MacOSBluetoothConnector.mm" \
    -framework IOBluetooth -framework Foundation \
    -o "$mac_connector_binary"

"$mac_connector_binary"
