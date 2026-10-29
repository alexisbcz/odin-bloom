package bloom

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:slice"

// MIN_PRECISION is the smallest precision an Hll accepts (16 registers).
MIN_PRECISION :: 4

// MAX_PRECISION is the largest precision an Hll accepts (262144 registers).
MAX_PRECISION :: 18

// DEFAULT_PRECISION gives 16384 registers and a standard error of about 0.81%.
DEFAULT_PRECISION :: 14

// SPARSE_PRECISION is the index width of the sparse representation, as in HLL++.
SPARSE_PRECISION :: 25

@(private)
SPARSE_RHO_BITS :: 6

@(private)
SPARSE_RHO_MAX :: 64 - SPARSE_PRECISION + 1

/*
Hll is a HyperLogLog++ cardinality estimator (Heule, Nunkesser and Hall,
2013) over 64-bit hashes.

While few distinct items have been added it uses the sparse representation:
a sorted list of 25-bit indices, which is exact up to hash collisions and much
smaller than the register array. Once the list would use more memory than the
dense registers it converts to `2^precision` 8-bit registers.

Dense estimates use Ertl's improved estimator (2017), which is unbiased
across the whole range without the empirical bias tables of the original
paper. The relative standard error is about `1.04 / sqrt(2^precision)`.

Create one with hll_make and release it with hll_destroy. An Hll is safe to
use from one thread at a time.
*/
Hll :: struct {
	precision: int,
	seed:      u64,
	// Sorted, unique by index. Each entry is `index << 6 | rho`.
	sparse:    [dynamic]u32,
	// Empty while the sketch is sparse.
	registers: []u8,
	allocator: runtime.Allocator,
}

/*
hll_make returns an empty sketch with `2^precision` registers.

Inputs:
- precision: in `[MIN_PRECISION, MAX_PRECISION]`.
- seed: the hash seed. Sketches must share a seed and precision to be merged.
- allocator: allocates the sparse list and later the registers.

Returns:
- h: the sketch, owned by the caller; free it with hll_destroy.
- err: `.Invalid_Parameter` for an out-of-range precision.
*/
hll_make :: proc(precision := DEFAULT_PRECISION, seed := DEFAULT_SEED, allocator := context.allocator) -> (h: Hll, err: Error) {
	if precision < MIN_PRECISION || precision > MAX_PRECISION {
		return {}, .Invalid_Parameter
	}
	h.precision = precision
	h.seed = seed
	h.allocator = allocator
	h.sparse = make([dynamic]u32, allocator)
	return h, nil
}

// hll_destroy frees the sketch's memory and zeroes it.
hll_destroy :: proc(h: ^Hll) {
	delete(h.sparse)
	delete(h.registers, h.allocator)
	h^ = {}
}

// hll_is_sparse reports whether the sketch still uses the sparse representation.
hll_is_sparse :: proc(h: ^Hll) -> bool {
	return len(h.registers) == 0
}

// hll_register_count returns `2^precision`.
hll_register_count :: proc(h: ^Hll) -> int {
	return 1 << uint(h.precision)
}

// hll_standard_error returns the expected relative standard error `1.04 / sqrt(2^precision)`.
hll_standard_error :: proc(h: ^Hll) -> f64 {
	return 1.04 / math.sqrt(f64(hll_register_count(h)))
}

@(private)
hll_sparse_limit :: proc(h: ^Hll) -> int {
	// Four bytes per entry against one byte per dense register.
	return hll_register_count(h) / 4
}

@(private)
sparse_encode :: proc "contextless" (x: u64) -> u32 {
	index := u32(x >> (64 - SPARSE_PRECISION))
	rho := min(u32(intrinsics.count_leading_zeros(x << SPARSE_PRECISION)) + 1, SPARSE_RHO_MAX)
	return index << SPARSE_RHO_BITS | rho
}

// sparse_to_dense maps a sparse entry to the register index and value that
// adding the same hash to a dense sketch would have produced.
@(private)
sparse_to_dense :: proc "contextless" (entry: u32, p: int) -> (index: int, rho: u8) {
	sparse_index := entry >> SPARSE_RHO_BITS
	extra := uint(SPARSE_PRECISION - p)
	index = int(sparse_index >> extra)
	low := sparse_index & ((u32(1) << extra) - 1)
	if low != 0 {
		rho = u8(uint(intrinsics.count_leading_zeros(low)) - (32 - extra) + 1)
	} else {
		rho = u8(extra) + u8(entry & ((1 << SPARSE_RHO_BITS) - 1))
	}
	return index, rho
}

// hll_sparse_insert merges one entry into the sorted sparse list.
@(private)
hll_sparse_insert :: proc(h: ^Hll, entry: u32) -> Error {
	key := entry >> SPARSE_RHO_BITS
	pos, found := slice.binary_search_by(h.sparse[:], key, proc(e: u32, k: u32) -> slice.Ordering {
		return slice.cmp(e >> SPARSE_RHO_BITS, k)
	})
	if found {
		h.sparse[pos] = max(h.sparse[pos], entry)
		return nil
	}
	if len(h.sparse) >= hll_sparse_limit(h) {
		hll_to_dense(h) or_return
		index, rho := sparse_to_dense(entry, h.precision)
		h.registers[index] = max(h.registers[index], rho)
		return nil
	}
	inject_at(&h.sparse, pos, entry) or_return
	return nil
}

// hll_to_dense converts a sparse sketch to registers. It is a no-op when dense.
@(private)
hll_to_dense :: proc(h: ^Hll) -> Error {
	if !hll_is_sparse(h) {
		return nil
	}
	h.registers = make([]u8, hll_register_count(h), h.allocator) or_return
	for e in h.sparse {
		index, rho := sparse_to_dense(e, h.precision)
		h.registers[index] = max(h.registers[index], rho)
	}
	delete(h.sparse)
	h.sparse = make([dynamic]u32, h.allocator)
	return nil
}

/*
hll_add_hash records an item by its precomputed 64-bit hash, for example from
hash_bytes. The hash must be uniformly distributed.

Returns an allocator error when the sparse list or the registers cannot grow.
*/
hll_add_hash :: proc(h: ^Hll, x: u64) -> Error {
	if h.precision == 0 {
		return .Invalid_Parameter
	}
	if hll_is_sparse(h) {
		return hll_sparse_insert(h, sparse_encode(x))
	}
	p := uint(h.precision)
	index := x >> (64 - p)
	rho := u8(min(uint(intrinsics.count_leading_zeros(x << p)) + 1, 64 - p + 1))
	h.registers[index] = max(h.registers[index], rho)
	return nil
}

// hll_add_bytes records `item`. See hll_add_hash.
hll_add_bytes :: proc(h: ^Hll, item: []byte) -> Error {
	return hll_add_hash(h, hash_bytes(item, h.seed))
}

// hll_add_string records `item`. See hll_add_hash.
hll_add_string :: proc(h: ^Hll, item: string) -> Error {
	return hll_add_hash(h, hash_string(item, h.seed))
}

// hll_add records a string or byte slice item.
hll_add :: proc {
	hll_add_string,
	hll_add_bytes,
}

@(private)
ertl_sigma :: proc(x: f64) -> f64 {
	if x == 1 {
		return math.INF_F64
	}
	x := x
	y := 1.0
	z := x
	for {
		x *= x
		prev := z
		z += x * y
		y += y
		if z == prev {
			return z
		}
	}
}

@(private)
ertl_tau :: proc(x: f64) -> f64 {
	if x == 0 || x == 1 {
		return 0
	}
	x := x
	y := 1.0
	z := 1 - x
	for {
		x = math.sqrt(x)
		prev := z
		y *= 0.5
		z -= (1 - x) * (1 - x) * y
		if z == prev {
			return z / 3
		}
	}
}

/*
hll_estimate returns the estimated number of distinct items added.

A sparse sketch uses linear counting over `2^SPARSE_PRECISION` buckets, which
is close to exact for small sets. A dense sketch uses Ertl's improved raw
estimator.
*/
hll_estimate :: proc(h: ^Hll) -> f64 {
	if h.precision == 0 {
		return 0
	}
	if hll_is_sparse(h) {
		mp := f64(u64(1) << SPARSE_PRECISION)
		empty := mp - f64(len(h.sparse))
		return mp * math.ln(mp / empty)
	}
	q := 64 - h.precision
	histogram: [66]int
	for r in h.registers {
		histogram[r] += 1
	}
	m := f64(len(h.registers))
	z := m * ertl_tau(1 - f64(histogram[q + 1]) / m)
	for k := q; k >= 1; k -= 1 {
		z = 0.5 * (z + f64(histogram[k]))
	}
	z += m * ertl_sigma(f64(histogram[0]) / m)
	return m * m / (2 * math.LN2 * z)
}

// hll_cardinality returns hll_estimate rounded to the nearest integer.
hll_cardinality :: proc(h: ^Hll) -> u64 {
	return u64(math.round(hll_estimate(h)))
}

// hll_clear forgets every item and returns the sketch to the sparse representation.
hll_clear :: proc(h: ^Hll) {
	delete(h.registers, h.allocator)
	h.registers = nil
	clear(&h.sparse)
}

/*
hll_merge folds `src` into `dst`, so that `dst` estimates the cardinality of
the union of both streams. A sparse `dst` becomes dense when the merged list
outgrows the sparse limit.

Returns `.Incompatible` when the precisions or seeds differ, or an allocator
error.
*/
hll_merge :: proc(dst, src: ^Hll) -> Error {
	if dst.precision != src.precision || dst.seed != src.seed || dst.precision == 0 {
		return .Incompatible
	}
	if hll_is_sparse(src) {
		for e in src.sparse {
			if hll_is_sparse(dst) {
				hll_sparse_insert(dst, e) or_return
			} else {
				index, rho := sparse_to_dense(e, dst.precision)
				dst.registers[index] = max(dst.registers[index], rho)
			}
		}
		return nil
	}
	hll_to_dense(dst) or_return
	for &r, i in dst.registers {
		r = max(r, src.registers[i])
	}
	return nil
}

/*
hll_clone returns a deep copy of `h` that uses `allocator`.

Returns:
- c: the copy, owned by the caller; free it with hll_destroy.
- err: an allocator error.
*/
hll_clone :: proc(h: ^Hll, allocator := context.allocator) -> (c: Hll, err: Error) {
	c.precision = h.precision
	c.seed = h.seed
	c.allocator = allocator
	defer if err != nil {
		hll_destroy(&c)
	}
	c.sparse = make([dynamic]u32, 0, len(h.sparse), allocator) or_return
	append(&c.sparse, ..h.sparse[:]) or_return
	if !hll_is_sparse(h) {
		c.registers = make([]u8, len(h.registers), allocator) or_return
		copy(c.registers, h.registers)
	}
	return c, nil
}

@(private)
HLL_SPARSE :: 0

@(private)
HLL_DENSE :: 1

/*
hll_serialize encodes `h` in the package's binary format. A sparse sketch
stores its list, a dense one its registers.

Returns:
- data: the encoding, owned by the caller; free it with `delete(data, allocator)`.
- err: an allocator error.
*/
hll_serialize :: proc(h: ^Hll, allocator := context.allocator) -> (data: []byte, err: Error) {
	w: Writer
	writer_init(&w, .Hyper_Log_Log, 14 + max(4 * len(h.sparse), len(h.registers)), allocator) or_return
	defer if err != nil {
		delete(w.buf)
	}
	write_u8(&w, u8(h.precision)) or_return
	write_u64(&w, h.seed) or_return
	if hll_is_sparse(h) {
		write_u8(&w, HLL_SPARSE) or_return
		write_u32(&w, u32(len(h.sparse))) or_return
		for e in h.sparse {
			write_u32(&w, e) or_return
		}
	} else {
		write_u8(&w, HLL_DENSE) or_return
		write_bytes(&w, h.registers) or_return
	}
	return writer_finish(&w)
}

/*
hll_deserialize decodes a sketch written by hll_serialize. The result does not
reference `data`.

Returns:
- h: the sketch, owned by the caller; free it with hll_destroy.
- err: a Decode_Error for malformed input, or an allocator error.
*/
hll_deserialize :: proc(data: []byte, allocator := context.allocator) -> (h: Hll, err: Error) {
	r := reader_open(data, .Hyper_Log_Log) or_return
	p := int(read_u8(&r) or_return)
	seed := read_u64(&r) or_return
	mode := read_u8(&r) or_return
	if p < MIN_PRECISION || p > MAX_PRECISION || mode > HLL_DENSE {
		return {}, .Corrupt
	}
	h = hll_make(p, seed, allocator) or_return
	defer if err != nil {
		hll_destroy(&h)
	}
	if mode == HLL_SPARSE {
		n := int(read_u32(&r) or_return)
		if n > hll_sparse_limit(&h) {
			return h, .Corrupt
		}
		if n * 4 > len(r.data) - r.pos {
			return h, .Truncated
		}
		reserve(&h.sparse, n) or_return
		prev := i64(-1)
		for _ in 0 ..< n {
			e, _ := read_u32(&r)
			rho := e & ((1 << SPARSE_RHO_BITS) - 1)
			key := i64(e >> SPARSE_RHO_BITS)
			if e >> 31 != 0 || rho == 0 || rho > SPARSE_RHO_MAX || key <= prev {
				return h, .Corrupt
			}
			prev = key
			append(&h.sparse, e) or_return
		}
	} else {
		m := hll_register_count(&h)
		regs := read_bytes(&r, m) or_return
		limit := u8(64 - p + 1)
		for v in regs {
			if v > limit {
				return h, .Corrupt
			}
		}
		h.registers = make([]u8, m, allocator) or_return
		copy(h.registers, regs)
	}
	reader_done(&r) or_return
	return h, nil
}
