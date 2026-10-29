// Package bloom_tests holds the unit and statistical tests for bloom. Run them with `odin test tests`.
package bloom_tests

import bloom ".."
import "core:hash"
import "core:math"

// key turns an integer into an 8-byte little-endian item, without allocating.
key :: proc(i: int) -> [8]u8 {
	return transmute([8]u8)u64(i)
}

// item_hash hashes the integer item `i` the way a structure with `seed` does.
item_hash :: proc(i: int, seed := bloom.DEFAULT_SEED) -> u64 {
	k := key(i)
	return bloom.hash_bytes(k[:], seed)
}

// reseal recomputes the trailing CRC-32 after a test tampers with the payload.
reseal :: proc(data: []byte) {
	sum := hash.crc32(data[:len(data) - 4])
	data[len(data) - 4] = u8(sum)
	data[len(data) - 3] = u8(sum >> 8)
	data[len(data) - 2] = u8(sum >> 16)
	data[len(data) - 1] = u8(sum >> 24)
}

// rel_err returns the relative error of `estimate` against `truth`.
rel_err :: proc(estimate: f64, truth: int) -> f64 {
	return math.abs(estimate - f64(truth)) / f64(truth)
}
