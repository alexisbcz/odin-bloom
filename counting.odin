package bloom

import "base:runtime"
import "core:math"

// COUNTER_MAX is the value at which a Counting_Filter counter saturates.
COUNTER_MAX :: 255

/*
Counting_Filter is a Bloom filter whose positions are 8-bit counters instead
of bits, so items can be removed. A counter that reaches COUNTER_MAX stays
there forever, which keeps removals from causing false negatives.

Create one with counting_filter_make or counting_filter_make_exact and
release it with counting_filter_destroy. A Counting_Filter is safe to use
from one thread at a time.
*/
Counting_Filter :: struct {
	counters:   []u8,
	hash_count: int,
	seed:       u64,
	allocator:  runtime.Allocator,
}

/*
counting_filter_make returns a counting filter sized for `expected_items`
items at false positive rate `fp_rate`. It uses one counter per bit that a
plain Filter would need.

Returns:
- f: the filter, owned by the caller; free it with counting_filter_destroy.
- err: `.Invalid_Parameter` for out-of-range arguments, or an allocator error.
*/
counting_filter_make :: proc(
	expected_items: int,
	fp_rate: f64,
	seed := DEFAULT_SEED,
	allocator := context.allocator,
) -> (
	f: Counting_Filter,
	err: Error,
) {
	m := optimal_bit_count(expected_items, fp_rate)
	if m == 0 {
		return {}, .Invalid_Parameter
	}
	return counting_filter_make_exact(m, optimal_hash_count(expected_items, m), seed, allocator)
}

/*
counting_filter_make_exact returns a counting filter with exactly
`counter_count` counters and `hash_count` positions per item.

Returns:
- f: the filter, owned by the caller; free it with counting_filter_destroy.
- err: `.Invalid_Parameter` when `counter_count` is not in
  `[1, MAX_FILTER_BITS]` or `hash_count` is not in `[1, MAX_HASHES]`, or an
  allocator error.
*/
counting_filter_make_exact :: proc(
	counter_count: u64,
	hash_count: int,
	seed := DEFAULT_SEED,
	allocator := context.allocator,
) -> (
	f: Counting_Filter,
	err: Error,
) {
	if counter_count == 0 || counter_count > MAX_FILTER_BITS || hash_count < 1 || hash_count > MAX_HASHES {
		return {}, .Invalid_Parameter
	}
	f.counters = make([]u8, int(counter_count), allocator) or_return
	f.hash_count = hash_count
	f.seed = seed
	f.allocator = allocator
	return f, nil
}

// counting_filter_destroy frees the counters and zeroes the filter.
counting_filter_destroy :: proc(f: ^Counting_Filter) {
	delete(f.counters, f.allocator)
	f^ = {}
}

// counting_filter_add_hash records one occurrence of the item with hash `h`.
counting_filter_add_hash :: proc(f: ^Counting_Filter, h: u64) {
	n := u64(len(f.counters))
	for i in 0 ..< u64(f.hash_count) {
		c := &f.counters[double_hash(h, i, n)]
		if c^ < COUNTER_MAX {
			c^ += 1
		}
	}
}

// counting_filter_add_bytes records one occurrence of `item`.
counting_filter_add_bytes :: proc(f: ^Counting_Filter, item: []byte) {
	counting_filter_add_hash(f, hash_bytes(item, f.seed))
}

// counting_filter_add_string records one occurrence of `item`.
counting_filter_add_string :: proc(f: ^Counting_Filter, item: string) {
	counting_filter_add_hash(f, hash_string(item, f.seed))
}

// counting_filter_add records one occurrence of a string or byte slice item.
counting_filter_add :: proc {
	counting_filter_add_string,
	counting_filter_add_bytes,
}

/*
counting_filter_remove_hash removes one occurrence of the item with hash `h`.

Only remove items that you added. Removing an item that was never added but
tests positive (a false positive) decrements counters that belong to other
items and can cause false negatives later.

Returns `.Not_Found` when the item is certainly absent. The filter is
unchanged in that case.
*/
counting_filter_remove_hash :: proc(f: ^Counting_Filter, h: u64) -> Error {
	n := u64(len(f.counters))
	if n == 0 {
		return .Not_Found
	}
	positions: [MAX_HASHES]u64
	k := f.hash_count
	for i in 0 ..< k {
		positions[i] = double_hash(h, u64(i), n)
	}
	// A position can repeat, and then the add incremented it more than once.
	for i in 0 ..< k {
		c := f.counters[positions[i]]
		if c == COUNTER_MAX {
			continue
		}
		needed := 0
		for j in 0 ..< k {
			if positions[j] == positions[i] {
				needed += 1
			}
		}
		if int(c) < needed {
			return .Not_Found
		}
	}
	for i in 0 ..< k {
		c := &f.counters[positions[i]]
		if c^ != COUNTER_MAX {
			c^ -= 1
		}
	}
	return nil
}

// counting_filter_remove_bytes removes one occurrence of `item`. See counting_filter_remove_hash.
counting_filter_remove_bytes :: proc(f: ^Counting_Filter, item: []byte) -> Error {
	return counting_filter_remove_hash(f, hash_bytes(item, f.seed))
}

// counting_filter_remove_string removes one occurrence of `item`. See counting_filter_remove_hash.
counting_filter_remove_string :: proc(f: ^Counting_Filter, item: string) -> Error {
	return counting_filter_remove_hash(f, hash_string(item, f.seed))
}

// counting_filter_remove removes one occurrence of a string or byte slice item.
counting_filter_remove :: proc {
	counting_filter_remove_string,
	counting_filter_remove_bytes,
}

/*
counting_filter_count_hash returns the smallest counter among the item's
positions. It is an upper bound on how many times the item was added, as long
as no counter saturated and removals only targeted added items. A result of 0
means the item is certainly absent.
*/
counting_filter_count_hash :: proc(f: ^Counting_Filter, h: u64) -> int {
	n := u64(len(f.counters))
	if n == 0 {
		return 0
	}
	lowest := COUNTER_MAX
	for i in 0 ..< u64(f.hash_count) {
		lowest = min(lowest, int(f.counters[double_hash(h, i, n)]))
	}
	return lowest
}

// counting_filter_count_bytes is counting_filter_count_hash for a byte slice item.
counting_filter_count_bytes :: proc(f: ^Counting_Filter, item: []byte) -> int {
	return counting_filter_count_hash(f, hash_bytes(item, f.seed))
}

// counting_filter_count_string is counting_filter_count_hash for a string item.
counting_filter_count_string :: proc(f: ^Counting_Filter, item: string) -> int {
	return counting_filter_count_hash(f, hash_string(item, f.seed))
}

// counting_filter_count returns the occurrence upper bound for a string or byte slice item.
counting_filter_count :: proc {
	counting_filter_count_string,
	counting_filter_count_bytes,
}

// counting_filter_contains_hash reports whether the item with hash `h` may be in the filter.
counting_filter_contains_hash :: proc(f: ^Counting_Filter, h: u64) -> bool {
	return counting_filter_count_hash(f, h) > 0
}

// counting_filter_contains_bytes reports whether `item` may be in the filter.
counting_filter_contains_bytes :: proc(f: ^Counting_Filter, item: []byte) -> bool {
	return counting_filter_count_hash(f, hash_bytes(item, f.seed)) > 0
}

// counting_filter_contains_string reports whether `item` may be in the filter.
counting_filter_contains_string :: proc(f: ^Counting_Filter, item: string) -> bool {
	return counting_filter_count_hash(f, hash_string(item, f.seed)) > 0
}

// counting_filter_contains tests a string or byte slice item.
counting_filter_contains :: proc {
	counting_filter_contains_string,
	counting_filter_contains_bytes,
}

// counting_filter_clear sets every counter to zero.
counting_filter_clear :: proc(f: ^Counting_Filter) {
	for &c in f.counters {
		c = 0
	}
}

/*
counting_filter_merge adds the counters of `src` into `dst`, saturating at
COUNTER_MAX. Afterwards `dst` holds the multiset union of both filters.

Returns `.Incompatible` when the filters differ in size, hash count or seed.
*/
counting_filter_merge :: proc(dst, src: ^Counting_Filter) -> Error {
	if len(dst.counters) != len(src.counters) || dst.hash_count != src.hash_count || dst.seed != src.seed {
		return .Incompatible
	}
	for &c, i in dst.counters {
		c = u8(min(int(c) + int(src.counters[i]), COUNTER_MAX))
	}
	return nil
}

/*
counting_filter_to_filter returns a plain Filter with a bit set wherever `f`
has a non-zero counter. The result answers membership exactly like `f` and
uses an eighth of the memory, but it cannot remove items.

Returns:
- out: the filter, owned by the caller; free it with filter_destroy.
- err: an allocator error.
*/
counting_filter_to_filter :: proc(f: ^Counting_Filter, allocator := context.allocator) -> (out: Filter, err: Error) {
	out = filter_make_exact(u64(len(f.counters)), f.hash_count, f.seed, allocator) or_return
	for c, i in f.counters {
		if c != 0 {
			out.words[i >> 6] |= u64(1) << (uint(i) & 63)
		}
	}
	return out, nil
}

/*
counting_filter_estimate_count estimates how many distinct items the filter
holds from the number of non-zero counters, like filter_estimate_count.
*/
counting_filter_estimate_count :: proc(f: ^Counting_Filter) -> f64 {
	m := f64(len(f.counters))
	if m == 0 {
		return 0
	}
	x := 0
	for c in f.counters {
		if c != 0 {
			x += 1
		}
	}
	if f64(x) >= m {
		return math.INF_F64
	}
	return -m / f64(f.hash_count) * math.ln(1 - f64(x) / m)
}

/*
counting_filter_serialize encodes `f` in the package's binary format.

Returns:
- data: the encoding, owned by the caller; free it with `delete(data, allocator)`.
- err: an allocator error.
*/
counting_filter_serialize :: proc(f: ^Counting_Filter, allocator := context.allocator) -> (data: []byte, err: Error) {
	w: Writer
	writer_init(&w, .Counting_Filter, 20 + len(f.counters), allocator) or_return
	defer if err != nil {
		delete(w.buf)
	}
	write_u64(&w, u64(len(f.counters))) or_return
	write_u32(&w, u32(f.hash_count)) or_return
	write_u64(&w, f.seed) or_return
	write_bytes(&w, f.counters) or_return
	return writer_finish(&w)
}

/*
counting_filter_deserialize decodes a filter written by
counting_filter_serialize. The result does not reference `data`.

Returns:
- f: the filter, owned by the caller; free it with counting_filter_destroy.
- err: a Decode_Error for malformed input, or an allocator error.
*/
counting_filter_deserialize :: proc(data: []byte, allocator := context.allocator) -> (f: Counting_Filter, err: Error) {
	r := reader_open(data, .Counting_Filter) or_return
	n := read_u64(&r) or_return
	k := read_u32(&r) or_return
	seed := read_u64(&r) or_return
	if n == 0 || n > MAX_FILTER_BITS || k == 0 || k > MAX_HASHES {
		return {}, .Corrupt
	}
	remaining := u64(len(r.data) - r.pos)
	if remaining < n {
		return {}, .Truncated
	}
	if remaining > n {
		return {}, .Corrupt
	}
	f = counting_filter_make_exact(n, int(k), seed, allocator) or_return
	src, _ := read_bytes(&r, int(n))
	copy(f.counters, src)
	return f, nil
}
