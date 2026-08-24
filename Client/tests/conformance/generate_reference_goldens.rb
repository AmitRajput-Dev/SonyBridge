# frozen_string_literal: true

# Clean-room generator for the deterministic frame facts documented in PROVENANCE.md.
# Usage: ruby generate_reference_goldens.rb [xm4_v1|ult900n_v2_multipoint]
def frame(data_type, sequence, payload)
  body = [data_type, sequence, 0, 0, 0, payload.length] + payload
  body << body.sum.modulo(256)
  escaped = body.flat_map { |byte| [0x3c, 0x3d, 0x3e].include?(byte) ? [0x3d, byte & 0xef] : [byte] }
  [0x3e] + escaped + [0x3c]
end

XM4_V1_CASES = {
  ack_seq1: [0x01, 1, []], escape_triplet: [0x0c, 0, [0x3c, 0x3d, 0x3e]],
  init: [0x0c, 0, [0x00, 0x00]], firmware_get: [0x0c, 0, [0x04, 0x02]],
  battery_get: [0x0c, 0, [0x10, 0x00]], codec_get: [0x0c, 0, [0x18, 0x00]],
  eq_get: [0x0c, 0, [0x56, 0x01]], eq_preset_bright: [0x0c, 0, [0x58, 0x01, 0x10, 0x00]],
  eq_custom: [0x0c, 0, [0x58, 0x01, 0xff, 0x06, 13, 8, 9, 10, 11, 12]],
  ambient_get: [0x0c, 0, [0x66, 0x02]], ambient_level1: [0x0c, 0, [0x68, 0x02, 0x11, 0x02, 0, 1, 0, 1]],
  ambient_level20: [0x0c, 0, [0x68, 0x02, 0x11, 0x02, 0, 1, 0, 20]],
  noise_cancel: [0x0c, 0, [0x68, 0x02, 0x11, 0x02, 2, 1, 0, 0]],
  dsee_get: [0x0c, 0, [0xe6, 0x02]], dsee_off: [0x0c, 0, [0xe8, 0x02, 0, 0]],
  auto_power_get: [0x0c, 0, [0xf6, 0x04]], speak_get: [0x0c, 0, [0xf6, 0x05]],
  speak_off: [0x0c, 0, [0xf8, 0x05, 1, 0]]
}.freeze

# v2 multipoint ("Connect to 2 devices simultaneously") payload facts, pinned from GadgetBridge
# SonyProtocolImplV2 as hardware-verified on the WH-ULT900N (see PROVENANCE.md):
# state rides touch-sensor subtype d1 with an inverted enable bit; SETs are followed by the fixed
# system-control apply commit 98 00 06 01 regardless of direction.
ULT900N_V2_MULTIPOINT_CASES = {
  mp_probe_get: [0x0c, 0, [0xd6, 0xd1]],
  mp_ret_on: [0x0c, 0, [0xd7, 0xd1, 0x00, 0x00]],
  mp_ret_off: [0x0c, 0, [0xd7, 0xd1, 0x00, 0x01]],
  mp_set_on: [0x0c, 0, [0xd8, 0xd1, 0x00, 0x00]],
  mp_set_off: [0x0c, 0, [0xd8, 0xd1, 0x00, 0x01]],
  mp_apply_commit: [0x0c, 0, [0x98, 0x00, 0x06, 0x01]]
}.freeze

cases = (ARGV[0] || 'xm4_v1') == 'ult900n_v2_multipoint' ? ULT900N_V2_MULTIPOINT_CASES : XM4_V1_CASES

puts '# id|data_type|sequence|payload|complete_frame'
cases.each do |name, (data_type, sequence, payload)|
  hex = ->(bytes) { bytes.map { |byte| format('%02x', byte) }.join(' ') }
  puts [name, format('%02x', data_type), sequence, hex.call(payload), hex.call(frame(data_type, sequence, payload))].join('|')
end
