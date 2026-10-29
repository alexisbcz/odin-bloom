package bloom

import "base:intrinsics"
import "base:runtime"
import "core:math"

// MAX_FILTER_BITS is the largest bit count a Filter or Counting_Filter accepts (2^40).
MAX_FILTER_BITS :: u64(1) << 40

// MAX_HASHES is the largest number of hash positions per item.
MAX_HASHES :: 64

/*
Filter is a classic Bloom filter: a bit array of `bit_count` bits and
`hash_count` positions per item. It never reports a false negative. The
false positive rate grows as the filter fills up.

Create one with filter_make or filter_make_exact and release it with
filter_destroy. A Filter is safe to use from one thread at a time.
*/
Filter :: struct {
	words:      []u64,
	bit_count:  u64,
	hash_count: int,
	seed:       u64,
	allocator:  runtime.Allocator,
}

/*
optimal_bit_count returns the number of bits `m` that a Bloom filter needs to
hold `expected_items` items at false positive rate `fp_rate`:
`m = ceil(-n * ln(p) / ln(2)^2)`.

Returns 0 when `expected_items <= 0` or `fp_rate` is not in the open
interval (0, 1).
*/
optimal_bit_count :: proc(expected_items: int, fp_rate: f64) -> u64 {
	if expected_items <= 0 || !(fp_rate > 0 && fp_rate < 1) {
		return 0
	}
	m := math.ceil(-f64(expected_items) * math.ln(fp_rate) / (math.LN2 * math.LN2))
	if m >= f64(MAX_FILTER_BITS) {
		return MAX_FILTER_BITS + 1
	}
	return max(u64(m), 1)
}

/*
optimal_hash_count returns the number of hash positions `k` that minimises
the false positive rate of a filter with `bit_count` bits holding
`expected_items` items: `k = round(m / n * ln(2))`, clamped to
`[1, MAX_HASHES]`.

Returns 0 when either argument is zero or negative.
*/
optimal_hash_count :: proc(expected_items: int, bit_count: u64) -> int {
	if expected_items <= 0 || bit_count == 0 {
		return 0
	}
	k := math.round(f64(bit_count) / f64(expected_items) * math.LN2)
	return clamp(int(k), 1, MAX_HASHES)
}

/*
expected_fp_rate returns the theoretical false positive rate
`(1 - e^(-k*n/m))^k` of a filter with `bit_count` bits and `hash_count`
positions after inserting `items` distinct items.
*/
expected_fp_rate :: proc(bit_count: u64, hash_count: int, items: int) -> f64 {
	if bit_count == 0 || hash_count <= 0 {
		return 1
	}
	if items <= 0 {
		return 0
	}
	k := f64(hash_count)
	return math.pow(1 - math.exp(-k * f64(items) / f64(bit_count)), k)
}

/*
filter_make returns a filter sized for `expected_items` items at false
positive rate `fp_rate`, using optimal_bit_count and optimal_hash_count.

Inputs:
- expected_items: how many distinct items you plan to add; must be positive.
- fp_rate: the target false positive rate, in the open interval (0, 1).
- seed: the hash seed. Filters must share a seed to be merged.
- allocator: allocates the bit array.

Returns:
- f: the filter, owned by the caller; free it with filter_destroy.
- err: `.Invalid_Parameter` for out-of-range arguments, or an allocator error.
*/
filter_make :: proc(
	expected_items: int,
	fp_rate: f64,
	seed := DEFAULT_SEED,
	allocator := context.allocator,
) -> (
	f: Filter,
	err: Error,
) {
	m := optimal_bit_count(expected_items, fp_rate)
	if m == 0 {
		return {}, .Invalid_Parameter
	}
	return filter_make_exact(m, optimal_hash_count(expected_items, m), seed, allocator)
}

/*
filter_make_exact returns a filter with exactly `bit_count` bits and
`hash_count` positions per item.

Inputs:
- bit_count: in `[1, MAX_FILTER_BITS]`.
- hash_count: in `[1, MAX_HASHES]`.
- seed: the hash seed.
- allocator: allocates the bit array.

Returns:
- f: the filter, owned by the caller; free it with filter_destroy.
- err: `.Invalid_Parameter` for out-of-range arguments, or an allocator error.
*/
filter_make_exact :: proc(
	bit_count: u64,
	hash_count: int,
	seed := DEFAULT_SEED,
	allocator := context.allocator,
) -> (
	f: Filter,
	err: Error,
) {
	if bit_count == 0 || bit_count > MAX_FILTER_BITS || hash_count < 1 || hash_count > MAX_HASHES {
		return {}, .Invalid_Parameter
	}
	f.words = make([]u64, int((bit_count + 63) / 64), allocator) or_return
	f.bit_count = bit_count
	f.hash_count = hash_count
	f.seed = seed
	f.allocator = allocator
	return f, nil
}

// filter_destroy frees the bit array and zeroes the filter.
filter_destroy :: proc(f: ^Filter) {
	delete(f.words, f.allocator)
	f^ = {}
}

/*
filter_add_hash records an item by its precomputed hash_bytes value.

Returns `true` when at least one bit changed, which means the item was
certainly not in the filter before.
*/
filter_add_hash :: proc(f: ^Filter, h: u64) -> (added: bool) {
	for i in 0 ..< u64(f.hash_count) {
		pos := double_hash(h, i, f.bit_count)
		word := &f.words[pos >> 6]
		bit := u64(1) << (pos & 63)
		if word^ & bit == 0 {
			added = true
			word^ |= bit
		}
	}
	return added
}

// filter_add_bytes records `item`. See filter_add_hash for the result.
filter_add_bytes :: proc(f: ^Filter, item: []byte) -> (added: bool) {
	return filter_add_hash(f, hash_bytes(item, f.seed))
}

// filter_add_string records `item`. See filter_add_hash for the result.
filter_add_string :: proc(f: ^Filter, item: string) -> (added: bool) {
	return filter_add_hash(f, hash_string(item, f.seed))
}

// filter_add records a string or byte slice item.
filter_add :: proc {
	filter_add_string,
	filter_add_bytes,
}

/*
filter_contains_hash reports whether an item with hash `h` may be in the
filter. `false` is always correct; `true` is wrong with roughly the false
positive rate.
*/
filter_contains_hash :: proc(f: ^Filter, h: u64) -> bool {
	if f.bit_count == 0 {
		return false
	}
	for i in 0 ..< u64(f.hash_count) {
		pos := double_hash(h, i, f.bit_count)
		if f.words[pos >> 6] & (u64(1) << (pos & 63)) == 0 {
			return false
		}
	}
	return true
}

// filter_contains_bytes reports whether `item` may be in the filter.
filter_contains_bytes :: proc(f: ^Filter, item: []byte) -> bool {
	return filter_contains_hash(f, hash_bytes(item, f.seed))
}

// filter_contains_string reports whether `item` may be in the filter.
filter_contains_string :: proc(f: ^Filter, item: string) -> bool {
	return filter_contains_hash(f, hash_string(item, f.seed))
}

// filter_contains tests a string or byte slice item.
filter_contains :: proc {
	filter_contains_string,
	filter_contains_bytes,
}

// filter_popcount returns how many bits of the filter are set.
filter_popcount :: proc(f: ^Filter) -> u64 {
	n: u64
	for w in f.words {
		n += u64(intrinsics.count_ones(w))
	}
	return n
}

// filter_fill_ratio returns the fraction of bits that are set, in `[0, 1]`.
filter_fill_ratio :: proc(f: ^Filter) -> f64 {
	if f.bit_count == 0 {
		return 0
	}
	return f64(filter_popcount(f)) / f64(f.bit_count)
}

/*
filter_estimate_count estimates how many distinct items were added, with the
Swamidass and Baldi formula `-m / k * ln(1 - X / m)` where `X` is the number
of set bits. Returns `math.INF_F64` when every bit is set.
*/
filter_estimate_count :: proc(f: ^Filter) -> f64 {
	if f.bit_count == 0 {
		return 0
	}
	x := f64(filter_popcount(f))
	m := f64(f.bit_count)
	if x >= m {
		return math.INF_F64
	}
	return -m / f64(f.hash_count) * math.ln(1 - x / m)
}

/*
filter_current_fp_rate estimates the false positive rate of the filter in its
current state as `fill_ratio ^ k`.
*/
filter_current_fp_rate :: proc(f: ^Filter) -> f64 {
	return math.pow(filter_fill_ratio(f), f64(f.hash_count))
}

// filter_clear removes every item, keeping the bit array.
filter_clear :: proc(f: ^Filter) {
	for &w in f.words {
		w = 0
	}
}

@(private)
filter_compatible :: proc(a, b: ^Filter) -> bool {
	return a.bit_count == b.bit_count && a.hash_count == b.hash_count && a.seed == b.seed
}

/*
filter_merge adds every item of `src` into `dst` with a bitwise OR, so `dst`
becomes the filter of the union of both sets.

Returns `.Incompatible` when the filters differ in bit count, hash count or
seed. `dst` is unchanged in that case.
*/
filter_merge :: proc(dst, src: ^Filter) -> Error {
	if !filter_compatible(dst, src) {
		return .Incompatible
	}
	for &w, i in dst.words {
		w |= src.words[i]
	}
	return nil
}

/*
filter_intersect keeps in `dst` only the bits also set in `src`. The result
answers `true` for every item in both sets, with a false positive rate no
higher than that of `dst`.

Returns `.Incompatible` when the filters differ in bit count, hash count or
seed. `dst` is unchanged in that case.
*/
filter_intersect :: proc(dst, src: ^Filter) -> Error {
	if !filter_compatible(dst, src) {
		return .Incompatible
	}
	for &w, i in dst.words {
		w &= src.words[i]
	}
	return nil
}

/*
filter_clone returns a deep copy of `f` that uses `allocator`.

Returns:
- c: the copy, owned by the caller; free it with filter_destroy.
- err: an allocator error.
*/
filter_clone :: proc(f: ^Filter, allocator := context.allocator) -> (c: Filter, err: Error) {
	c = f^
	c.allocator = allocator
	c.words = make([]u64, len(f.words), allocator) or_return
	copy(c.words, f.words)
	return c, nil
}

/*
filter_serialize encodes `f` in the package's binary format: an 8-byte
header, the bit count, hash count and seed, the bit array in little-endian
64-bit words, and a CRC-32.

Returns:
- data: the encoding, owned by the caller; free it with `delete(data, allocator)`.
- err: an allocator error.
*/
filter_serialize :: proc(f: ^Filter, allocator := context.allocator) -> (data: []byte, err: Error) {
	w: Writer
	writer_init(&w, .Filter, 20 + 8 * len(f.words), allocator) or_return
	defer if err != nil {
		delete(w.buf)
	}
	write_u64(&w, f.bit_count) or_return
	write_u32(&w, u32(f.hash_count)) or_return
	write_u64(&w, f.seed) or_return
	for word in f.words {
		write_u64(&w, word) or_return
	}
	return writer_finish(&w)
}

/*
filter_deserialize decodes a filter written by filter_serialize. The result
copies everything it needs, so `data` may be freed right after the call.

Returns:
- f: the filter, owned by the caller; free it with filter_destroy.
- err: a Decode_Error for malformed input, or an allocator error.
*/
filter_deserialize :: proc(data: []byte, allocator := context.allocator) -> (f: Filter, err: Error) {
	r := reader_open(data, .Filter) or_return
	bits := read_u64(&r) or_return
	k := read_u32(&r) or_return
	seed := read_u64(&r) or_return
	if bits == 0 || bits > MAX_FILTER_BITS || k == 0 || k > MAX_HASHES {
		return {}, .Corrupt
	}
	n_words := int((bits + 63) / 64)
	if len(r.data) - r.pos != n_words * 8 {
		if len(r.data) - r.pos < n_words * 8 {
			return {}, Decode_Error.Truncated
		}
		return {}, Decode_Error.Corrupt
	}
	f = filter_make_exact(bits, int(k), seed, allocator) or_return
	for &word in f.words {
		word, _ = read_u64(&r)
	}
	if extra := bits & 63; extra != 0 && f.words[n_words - 1] >> extra != 0 {
		filter_destroy(&f)
		return {}, .Corrupt
	}
	return f, nil
}
