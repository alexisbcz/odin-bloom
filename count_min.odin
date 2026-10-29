package bloom

import "base:runtime"
import "core:math"

// MAX_COUNT_MIN_CELLS is the largest `width * depth` a Count_Min accepts (2^32).
MAX_COUNT_MIN_CELLS :: u64(1) << 32

/*
Count_Min is a Count-Min sketch (Cormode and Muthukrishnan, 2005): `depth`
rows of `width` 64-bit counters. It never under-estimates a frequency. With
`width = ceil(e / epsilon)` and `depth = ceil(ln(1 / delta))`, an estimate
exceeds the true count by more than `epsilon * total` with probability at most
`delta`.

Counters saturate at the largest u64 instead of wrapping. Create one with
count_min_make or count_min_make_exact and release it with count_min_destroy.
A Count_Min is safe to use from one thread at a time.
*/
Count_Min :: struct {
	counters:  []u64,
	width:     u64,
	depth:     int,
	total:     u64,
	seed:      u64,
	allocator: runtime.Allocator,
}

/*
count_min_make returns a sketch whose estimates are within `epsilon * total`
of the true count with probability at least `1 - delta`.

Inputs:
- epsilon: the additive error as a fraction of the total count, in (0, 1).
- delta: the failure probability, in (0, 1).
- seed: the hash seed. Sketches must share a seed and dimensions to be merged.
- allocator: allocates the counters.

Returns:
- c: the sketch, owned by the caller; free it with count_min_destroy.
- err: `.Invalid_Parameter` for out-of-range arguments, or an allocator error.
*/
count_min_make :: proc(
	epsilon: f64,
	delta: f64,
	seed := DEFAULT_SEED,
	allocator := context.allocator,
) -> (
	c: Count_Min,
	err: Error,
) {
	if !(epsilon > 0 && epsilon < 1) || !(delta > 0 && delta < 1) {
		return {}, .Invalid_Parameter
	}
	width := u64(math.ceil(math.E / epsilon))
	depth := int(math.ceil(math.ln(1 / delta)))
	return count_min_make_exact(width, max(depth, 1), seed, allocator)
}

/*
count_min_make_exact returns a sketch with the given dimensions.

Returns:
- c: the sketch, owned by the caller; free it with count_min_destroy.
- err: `.Invalid_Parameter` when a dimension is zero or `width * depth`
  exceeds MAX_COUNT_MIN_CELLS, or an allocator error.
*/
count_min_make_exact :: proc(
	width: u64,
	depth: int,
	seed := DEFAULT_SEED,
	allocator := context.allocator,
) -> (
	c: Count_Min,
	err: Error,
) {
	if width == 0 || depth <= 0 || width > MAX_COUNT_MIN_CELLS || u64(depth) > MAX_COUNT_MIN_CELLS / width {
		return {}, .Invalid_Parameter
	}
	c.counters = make([]u64, int(width) * depth, allocator) or_return
	c.width = width
	c.depth = depth
	c.seed = seed
	c.allocator = allocator
	return c, nil
}

// count_min_destroy frees the counters and zeroes the sketch.
count_min_destroy :: proc(c: ^Count_Min) {
	delete(c.counters, c.allocator)
	c^ = {}
}

@(private)
saturating_add :: proc "contextless" (a, b: u64) -> u64 {
	s := a + b
	return s < a ? max(u64) : s
}

// count_min_add_hash adds `count` occurrences of the item with hash `h`.
count_min_add_hash :: proc(c: ^Count_Min, h: u64, count: u64 = 1) {
	for row in 0 ..< c.depth {
		cell := &c.counters[u64(row) * c.width + double_hash(h, u64(row), c.width)]
		cell^ = saturating_add(cell^, count)
	}
	c.total = saturating_add(c.total, count)
}

// count_min_add_bytes adds `count` occurrences of `item`.
count_min_add_bytes :: proc(c: ^Count_Min, item: []byte, count: u64 = 1) {
	count_min_add_hash(c, hash_bytes(item, c.seed), count)
}

// count_min_add_string adds `count` occurrences of `item`.
count_min_add_string :: proc(c: ^Count_Min, item: string, count: u64 = 1) {
	count_min_add_hash(c, hash_string(item, c.seed), count)
}

// count_min_add adds occurrences of a string or byte slice item.
count_min_add :: proc {
	count_min_add_string,
	count_min_add_bytes,
}

/*
count_min_estimate_hash returns the smallest counter of the item with hash
`h` across all rows. It is never below the true count.
*/
count_min_estimate_hash :: proc(c: ^Count_Min, h: u64) -> u64 {
	if c.depth == 0 {
		return 0
	}
	lowest := max(u64)
	for row in 0 ..< c.depth {
		lowest = min(lowest, c.counters[u64(row) * c.width + double_hash(h, u64(row), c.width)])
	}
	return lowest
}

// count_min_estimate_bytes returns the frequency estimate of `item`.
count_min_estimate_bytes :: proc(c: ^Count_Min, item: []byte) -> u64 {
	return count_min_estimate_hash(c, hash_bytes(item, c.seed))
}

// count_min_estimate_string returns the frequency estimate of `item`.
count_min_estimate_string :: proc(c: ^Count_Min, item: string) -> u64 {
	return count_min_estimate_hash(c, hash_string(item, c.seed))
}

// count_min_estimate returns the frequency estimate of a string or byte slice item.
count_min_estimate :: proc {
	count_min_estimate_string,
	count_min_estimate_bytes,
}

// count_min_total returns the sum of every count added.
count_min_total :: proc(c: ^Count_Min) -> u64 {
	return c.total
}

// count_min_error_bound returns `e / width * total`, the additive error that
// an estimate stays under with probability `1 - e^-depth`.
count_min_error_bound :: proc(c: ^Count_Min) -> f64 {
	if c.width == 0 {
		return 0
	}
	return math.E / f64(c.width) * f64(c.total)
}

// count_min_clear sets every counter and the total to zero.
count_min_clear :: proc(c: ^Count_Min) {
	for &v in c.counters {
		v = 0
	}
	c.total = 0
}

/*
count_min_merge adds the counters of `src` into `dst`, so that `dst` sketches
the concatenation of both streams.

Returns `.Incompatible` when the dimensions or seeds differ.
*/
count_min_merge :: proc(dst, src: ^Count_Min) -> Error {
	if dst.width != src.width || dst.depth != src.depth || dst.seed != src.seed {
		return .Incompatible
	}
	for &v, i in dst.counters {
		v = saturating_add(v, src.counters[i])
	}
	dst.total = saturating_add(dst.total, src.total)
	return nil
}

/*
count_min_serialize encodes `c` in the package's binary format.

Returns:
- data: the encoding, owned by the caller; free it with `delete(data, allocator)`.
- err: an allocator error.
*/
count_min_serialize :: proc(c: ^Count_Min, allocator := context.allocator) -> (data: []byte, err: Error) {
	w: Writer
	writer_init(&w, .Count_Min, 28 + 8 * len(c.counters), allocator) or_return
	defer if err != nil {
		delete(w.buf)
	}
	write_u64(&w, c.width) or_return
	write_u32(&w, u32(c.depth)) or_return
	write_u64(&w, c.seed) or_return
	write_u64(&w, c.total) or_return
	for v in c.counters {
		write_u64(&w, v) or_return
	}
	return writer_finish(&w)
}

/*
count_min_deserialize decodes a sketch written by count_min_serialize. The
result does not reference `data`.

Returns:
- c: the sketch, owned by the caller; free it with count_min_destroy.
- err: a Decode_Error for malformed input, or an allocator error.
*/
count_min_deserialize :: proc(data: []byte, allocator := context.allocator) -> (c: Count_Min, err: Error) {
	r := reader_open(data, .Count_Min) or_return
	width := read_u64(&r) or_return
	depth := read_u32(&r) or_return
	seed := read_u64(&r) or_return
	total := read_u64(&r) or_return
	if width == 0 || depth == 0 || width > MAX_COUNT_MIN_CELLS || u64(depth) > MAX_COUNT_MIN_CELLS / width {
		return {}, .Corrupt
	}
	cells := width * u64(depth)
	remaining := u64(len(r.data) - r.pos)
	if remaining < 8 * cells {
		return {}, .Truncated
	}
	if remaining > 8 * cells {
		return {}, .Corrupt
	}
	c = count_min_make_exact(width, int(depth), seed, allocator) or_return
	for &v in c.counters {
		v, _ = read_u64(&r)
	}
	c.total = total
	return c, nil
}
