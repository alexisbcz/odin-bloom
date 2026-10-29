package bloom

import "base:runtime"

// BUCKET_SIZE is the number of fingerprint slots in each cuckoo filter bucket.
BUCKET_SIZE :: 4

// MAX_CUCKOO_BUCKETS is the largest bucket count a Cuckoo_Filter accepts (2^36).
MAX_CUCKOO_BUCKETS :: u64(1) << 36

// DEFAULT_MAX_KICKS is how many evictions an insert tries before it gives up.
DEFAULT_MAX_KICKS :: 500

/*
Cuckoo_Filter is a cuckoo filter (Fan, Andersen, Kaminsky and Mitzenmacher,
2014) with buckets of BUCKET_SIZE slots and 16-bit fingerprints. Each item
lives in one of two buckets; inserts evict and relocate fingerprints when
both are full.

Compared with a Bloom filter it supports removal and, at the same memory, has
a lower false positive rate of about `2 * BUCKET_SIZE / 2^16`, or 0.012%.
The same item can be added at most `2 * BUCKET_SIZE` times.

When an insert runs out of evictions, the last displaced fingerprint moves to
a one-entry stash so that no item is lost, and later inserts return `.Full`
until a removal frees room.

Create one with cuckoo_filter_make and release it with cuckoo_filter_destroy.
A Cuckoo_Filter is safe to use from one thread at a time.
*/
Cuckoo_Filter :: struct {
	slots:        []u16,
	bucket_count: u64,
	count:        int,
	seed:         u64,
	max_kicks:    int,
	rng:          u64,
	stash_index:  u64,
	stash_fp:     u16,
	allocator:    runtime.Allocator,
}

/*
cuckoo_filter_make returns a cuckoo filter that can hold at least `capacity`
items. It rounds the bucket count up to a power of two and targets a load
factor of 95%, the practical limit for 4-slot buckets.

Returns:
- f: the filter, owned by the caller; free it with cuckoo_filter_destroy.
- err: `.Invalid_Parameter` when `capacity` is not positive or too large, or
  an allocator error.
*/
cuckoo_filter_make :: proc(capacity: int, seed := DEFAULT_SEED, allocator := context.allocator) -> (f: Cuckoo_Filter, err: Error) {
	// Checked first so that `capacity * 100` below cannot wrap around.
	if capacity <= 0 || u64(capacity) > MAX_CUCKOO_BUCKETS * BUCKET_SIZE {
		return {}, .Invalid_Parameter
	}
	needed := (u64(capacity) * 100 + 95 * BUCKET_SIZE - 1) / (95 * BUCKET_SIZE)
	buckets := u64(1)
	for buckets < needed {
		buckets <<= 1
		if buckets > MAX_CUCKOO_BUCKETS {
			return {}, .Invalid_Parameter
		}
	}
	return cuckoo_filter_make_exact(buckets, seed, allocator)
}

/*
cuckoo_filter_make_exact returns a cuckoo filter with `bucket_count` buckets.

Returns:
- f: the filter, owned by the caller; free it with cuckoo_filter_destroy.
- err: `.Invalid_Parameter` when `bucket_count` is not a power of two in
  `[1, MAX_CUCKOO_BUCKETS]`, or an allocator error.
*/
cuckoo_filter_make_exact :: proc(bucket_count: u64, seed := DEFAULT_SEED, allocator := context.allocator) -> (f: Cuckoo_Filter, err: Error) {
	if bucket_count == 0 || bucket_count > MAX_CUCKOO_BUCKETS || bucket_count & (bucket_count - 1) != 0 {
		return {}, .Invalid_Parameter
	}
	f.slots = make([]u16, int(bucket_count * BUCKET_SIZE), allocator) or_return
	f.bucket_count = bucket_count
	f.seed = seed
	f.max_kicks = DEFAULT_MAX_KICKS
	f.rng = mix64(seed)
	f.allocator = allocator
	return f, nil
}

// cuckoo_filter_destroy frees the buckets and zeroes the filter.
cuckoo_filter_destroy :: proc(f: ^Cuckoo_Filter) {
	delete(f.slots, f.allocator)
	f^ = {}
}

// cuckoo_parts splits a hash into a non-zero fingerprint and its first bucket.
@(private)
cuckoo_parts :: proc "contextless" (f: ^Cuckoo_Filter, h: u64) -> (fp: u16, i1: u64) {
	fp = u16(h >> 48)
	if fp == 0 {
		fp = 1
	}
	return fp, h & (f.bucket_count - 1)
}

// cuckoo_alt returns the other bucket of a fingerprint. It is its own inverse.
@(private)
cuckoo_alt :: proc "contextless" (f: ^Cuckoo_Filter, i: u64, fp: u16) -> u64 {
	return (i ~ mix64(u64(fp))) & (f.bucket_count - 1)
}

@(private)
cuckoo_bucket :: proc "contextless" (f: ^Cuckoo_Filter, i: u64) -> []u16 {
	return f.slots[i * BUCKET_SIZE:][:BUCKET_SIZE]
}

@(private)
cuckoo_put :: proc "contextless" (f: ^Cuckoo_Filter, i: u64, fp: u16) -> bool {
	for &s in cuckoo_bucket(f, i) {
		if s == 0 {
			s = fp
			return true
		}
	}
	return false
}

@(private)
cuckoo_has :: proc "contextless" (f: ^Cuckoo_Filter, i: u64, fp: u16) -> bool {
	for s in cuckoo_bucket(f, i) {
		if s == fp {
			return true
		}
	}
	return false
}

@(private)
cuckoo_next_random :: proc "contextless" (f: ^Cuckoo_Filter) -> u64 {
	f.rng += 0x9e3779b97f4a7c15
	return mix64(f.rng)
}

// cuckoo_insert places `fp`, whose candidate buckets are `i1` and its alternate.
@(private)
cuckoo_insert :: proc(f: ^Cuckoo_Filter, i1: u64, fp: u16) -> Error {
	i2 := cuckoo_alt(f, i1, fp)
	if cuckoo_put(f, i1, fp) || cuckoo_put(f, i2, fp) {
		f.count += 1
		return nil
	}
	if f.stash_fp != 0 {
		return .Full
	}
	i := cuckoo_next_random(f) & 1 == 0 ? i1 : i2
	cur := fp
	for _ in 0 ..< f.max_kicks {
		slot := &cuckoo_bucket(f, i)[cuckoo_next_random(f) % BUCKET_SIZE]
		cur, slot^ = slot^, cur
		i = cuckoo_alt(f, i, cur)
		if cuckoo_put(f, i, cur) {
			f.count += 1
			return nil
		}
	}
	// Keep the homeless fingerprint so that no added item goes missing.
	f.stash_fp = cur
	f.stash_index = i
	f.count += 1
	return nil
}

/*
cuckoo_filter_add_hash adds the item with precomputed hash `h`.

Returns `.Full` when the filter has no room left. The filter still holds every
item it held before the call.
*/
cuckoo_filter_add_hash :: proc(f: ^Cuckoo_Filter, h: u64) -> Error {
	if f.bucket_count == 0 {
		return .Full
	}
	fp, i1 := cuckoo_parts(f, h)
	return cuckoo_insert(f, i1, fp)
}

// cuckoo_filter_add_bytes adds `item`. See cuckoo_filter_add_hash.
cuckoo_filter_add_bytes :: proc(f: ^Cuckoo_Filter, item: []byte) -> Error {
	return cuckoo_filter_add_hash(f, hash_bytes(item, f.seed))
}

// cuckoo_filter_add_string adds `item`. See cuckoo_filter_add_hash.
cuckoo_filter_add_string :: proc(f: ^Cuckoo_Filter, item: string) -> Error {
	return cuckoo_filter_add_hash(f, hash_string(item, f.seed))
}

// cuckoo_filter_add adds a string or byte slice item.
cuckoo_filter_add :: proc {
	cuckoo_filter_add_string,
	cuckoo_filter_add_bytes,
}

// cuckoo_filter_contains_hash reports whether the item with hash `h` may be in the filter.
cuckoo_filter_contains_hash :: proc(f: ^Cuckoo_Filter, h: u64) -> bool {
	if f.bucket_count == 0 {
		return false
	}
	fp, i1 := cuckoo_parts(f, h)
	i2 := cuckoo_alt(f, i1, fp)
	if cuckoo_has(f, i1, fp) || cuckoo_has(f, i2, fp) {
		return true
	}
	return f.stash_fp == fp && (f.stash_index == i1 || f.stash_index == i2)
}

// cuckoo_filter_contains_bytes reports whether `item` may be in the filter.
cuckoo_filter_contains_bytes :: proc(f: ^Cuckoo_Filter, item: []byte) -> bool {
	return cuckoo_filter_contains_hash(f, hash_bytes(item, f.seed))
}

// cuckoo_filter_contains_string reports whether `item` may be in the filter.
cuckoo_filter_contains_string :: proc(f: ^Cuckoo_Filter, item: string) -> bool {
	return cuckoo_filter_contains_hash(f, hash_string(item, f.seed))
}

// cuckoo_filter_contains tests a string or byte slice item.
cuckoo_filter_contains :: proc {
	cuckoo_filter_contains_string,
	cuckoo_filter_contains_bytes,
}

/*
cuckoo_filter_remove_hash removes one copy of the item with hash `h`.

Only remove items that you added: removing a false positive deletes another
item's fingerprint. Returns `.Not_Found` when no matching fingerprint exists.
*/
cuckoo_filter_remove_hash :: proc(f: ^Cuckoo_Filter, h: u64) -> Error {
	if f.bucket_count == 0 {
		return .Not_Found
	}
	fp, i1 := cuckoo_parts(f, h)
	i2 := cuckoo_alt(f, i1, fp)
	if f.stash_fp == fp && (f.stash_index == i1 || f.stash_index == i2) {
		f.stash_fp = 0
		f.stash_index = 0
		f.count -= 1
		return nil
	}
	for i in ([2]u64{i1, i2}) {
		for &s in cuckoo_bucket(f, i) {
			if s == fp {
				s = 0
				f.count -= 1
				cuckoo_unstash(f)
				return nil
			}
		}
	}
	return .Not_Found
}

// cuckoo_unstash moves the stashed fingerprint back into a bucket if one has room.
@(private)
cuckoo_unstash :: proc(f: ^Cuckoo_Filter) {
	if f.stash_fp == 0 {
		return
	}
	fp, i := f.stash_fp, f.stash_index
	if cuckoo_put(f, i, fp) || cuckoo_put(f, cuckoo_alt(f, i, fp), fp) {
		f.stash_fp = 0
		f.stash_index = 0
	}
}

// cuckoo_filter_remove_bytes removes one copy of `item`. See cuckoo_filter_remove_hash.
cuckoo_filter_remove_bytes :: proc(f: ^Cuckoo_Filter, item: []byte) -> Error {
	return cuckoo_filter_remove_hash(f, hash_bytes(item, f.seed))
}

// cuckoo_filter_remove_string removes one copy of `item`. See cuckoo_filter_remove_hash.
cuckoo_filter_remove_string :: proc(f: ^Cuckoo_Filter, item: string) -> Error {
	return cuckoo_filter_remove_hash(f, hash_string(item, f.seed))
}

// cuckoo_filter_remove removes one copy of a string or byte slice item.
cuckoo_filter_remove :: proc {
	cuckoo_filter_remove_string,
	cuckoo_filter_remove_bytes,
}

// cuckoo_filter_count returns how many items the filter holds.
cuckoo_filter_count :: proc(f: ^Cuckoo_Filter) -> int {
	return f.count
}

// cuckoo_filter_capacity returns the total number of fingerprint slots.
cuckoo_filter_capacity :: proc(f: ^Cuckoo_Filter) -> int {
	return len(f.slots)
}

// cuckoo_filter_load_factor returns `count / capacity`, in `[0, 1]`.
cuckoo_filter_load_factor :: proc(f: ^Cuckoo_Filter) -> f64 {
	if len(f.slots) == 0 {
		return 0
	}
	return f64(f.count) / f64(len(f.slots))
}

// cuckoo_filter_clear removes every item.
cuckoo_filter_clear :: proc(f: ^Cuckoo_Filter) {
	for &s in f.slots {
		s = 0
	}
	f.count = 0
	f.stash_fp = 0
	f.stash_index = 0
}

/*
cuckoo_filter_merge adds every item of `src` into `dst`.

`dst` and `src` may be the same filter, which adds a second copy of every
item. That case copies the buckets first, using the filter's allocator.

Returns `.Incompatible` when the filters differ in bucket count or seed, and
`dst` is unchanged. Returns `.Full` when `dst` runs out of room; `dst` then
holds all of its own items and some of the items of `src`. Returns an
allocator error when a self-merge cannot copy the buckets; `dst` is unchanged.
*/
cuckoo_filter_merge :: proc(dst, src: ^Cuckoo_Filter) -> Error {
	if dst.bucket_count != src.bucket_count || dst.seed != src.seed {
		return .Incompatible
	}
	if dst.count + src.count > len(dst.slots) + 1 {
		return .Full
	}
	// Inserting into the filter being read moves fingerprints under the loop,
	// so a self-merge reads from a snapshot.
	slots := src.slots
	stash_fp, stash_index := src.stash_fp, src.stash_index
	if dst == src {
		slots = make([]u16, len(src.slots), dst.allocator) or_return
		copy(slots, src.slots)
	}
	defer if dst == src {
		delete(slots, dst.allocator)
	}
	for fp, n in slots {
		if fp != 0 {
			cuckoo_insert(dst, u64(n / BUCKET_SIZE), fp) or_return
		}
	}
	if stash_fp != 0 {
		cuckoo_insert(dst, stash_index, stash_fp) or_return
	}
	return nil
}

/*
cuckoo_filter_serialize encodes `f` in the package's binary format.

Returns:
- data: the encoding, owned by the caller; free it with `delete(data, allocator)`.
- err: an allocator error.
*/
cuckoo_filter_serialize :: proc(f: ^Cuckoo_Filter, allocator := context.allocator) -> (data: []byte, err: Error) {
	w: Writer
	writer_init(&w, .Cuckoo_Filter, 46 + 2 * len(f.slots), allocator) or_return
	defer if err != nil {
		delete(w.buf)
	}
	write_u64(&w, f.bucket_count) or_return
	write_u64(&w, f.seed) or_return
	write_u64(&w, u64(f.count)) or_return
	write_u32(&w, u32(f.max_kicks)) or_return
	write_u64(&w, f.rng) or_return
	write_u64(&w, f.stash_index) or_return
	write_u16(&w, f.stash_fp) or_return
	for s in f.slots {
		write_u16(&w, s) or_return
	}
	return writer_finish(&w)
}

/*
cuckoo_filter_deserialize decodes a filter written by cuckoo_filter_serialize.
The result does not reference `data`.

Returns:
- f: the filter, owned by the caller; free it with cuckoo_filter_destroy.
- err: a Decode_Error for malformed input, or an allocator error.
*/
cuckoo_filter_deserialize :: proc(data: []byte, allocator := context.allocator) -> (f: Cuckoo_Filter, err: Error) {
	r := reader_open(data, .Cuckoo_Filter) or_return
	buckets := read_u64(&r) or_return
	seed := read_u64(&r) or_return
	count := read_u64(&r) or_return
	kicks := read_u32(&r) or_return
	rng := read_u64(&r) or_return
	stash_index := read_u64(&r) or_return
	stash_fp := read_u16(&r) or_return
	if buckets == 0 || buckets > MAX_CUCKOO_BUCKETS || buckets & (buckets - 1) != 0 || kicks == 0 {
		return {}, .Corrupt
	}
	if stash_index >= buckets || (stash_fp == 0 && stash_index != 0) {
		return {}, .Corrupt
	}
	remaining := u64(len(r.data) - r.pos)
	if remaining < 2 * BUCKET_SIZE * buckets {
		return {}, .Truncated
	}
	if remaining > 2 * BUCKET_SIZE * buckets {
		return {}, .Corrupt
	}
	f = cuckoo_filter_make_exact(buckets, seed, allocator) or_return
	f.max_kicks = int(kicks)
	f.rng = rng
	f.stash_index = stash_index
	f.stash_fp = stash_fp
	used := u64(stash_fp != 0 ? 1 : 0)
	for &s in f.slots {
		s, _ = read_u16(&r)
		if s != 0 {
			used += 1
		}
	}
	if used != count {
		cuckoo_filter_destroy(&f)
		return {}, .Corrupt
	}
	f.count = int(count)
	return f, nil
}
