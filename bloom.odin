/*
Package bloom provides probabilistic data structures for membership,
frequency and cardinality questions over large streams.

The package contains five structures:

- Filter: a classic Bloom filter sized from an expected item count and a
  target false positive rate.
- Counting_Filter: a Bloom filter with 8-bit saturating counters that
  supports removal.
- Cuckoo_Filter: a cuckoo filter with 4-slot buckets and 16-bit
  fingerprints that supports removal and has a lower false positive rate
  than a Bloom filter of the same size.
- Hll: HyperLogLog++ with a sparse representation for small
  cardinalities and a dense register array for large ones.
- Count_Min: a Count-Min sketch that over-estimates item frequencies by at
  most `epsilon * total` with probability `1 - delta`.

Every structure can be merged with a compatible peer and serialized to a
compact, checksummed byte format. Each structure stores the allocator it was
created with and has a matching `*_destroy` procedure.

Thread safety: a value is safe to use from one thread at a time. Read-only
procedures such as `filter_contains` may run concurrently with each other but
not with writers.

Example:
	import "shared:bloom"

	main :: proc() {
		f, err := bloom.filter_make(10_000, 0.01)
		if err != nil {
			return
		}
		defer bloom.filter_destroy(&f)
		bloom.filter_add(&f, "odin")
		_ = bloom.filter_contains(&f, "odin") // true
	}
*/
package bloom

import "base:runtime"
import "core:hash"
import "core:hash/xxhash"

/*
Usage_Error lists the ways a call can fail because of its arguments or the
state of the structure.
*/
Usage_Error :: enum {
	None,
	// A sizing argument is out of range: zero, negative, not finite or too large.
	Invalid_Parameter,
	// Two structures cannot be merged because their sizes or seeds differ.
	Incompatible,
	// A removal asked for an item that the structure does not hold.
	Not_Found,
	// A cuckoo filter could not find room for a new item.
	Full,
}

// Decode_Error lists the ways a serialized structure can be rejected.
Decode_Error :: enum {
	None,
	// The input ends before the structure does.
	Truncated,
	// The input does not start with the `OBLM` magic bytes.
	Bad_Magic,
	// The input was written by a newer, unknown format version.
	Unsupported_Version,
	// The input holds a different kind of structure than the one requested.
	Wrong_Kind,
	// The trailing CRC-32 does not match the contents.
	Checksum_Mismatch,
	// The header or payload holds values that no valid structure can have.
	Corrupt,
}

/*
Error is the compound error type returned by every fallible procedure in this
package. `nil` means success. Compare it against a specific variant such as
`bloom.Error(bloom.Usage_Error.Full)`, or use a type switch.
*/
Error :: union #shared_nil {
	Usage_Error,
	Decode_Error,
	runtime.Allocator_Error,
}

/*
FORMAT_VERSION is the version byte written by every `*_serialize` procedure.

Version 2 changed where a Count_Min stores each count, so count_min_deserialize
rejects version 1 input with `.Unsupported_Version`. The other structures read
both versions.
*/
FORMAT_VERSION :: 2

// DEFAULT_SEED is the hash seed used when a constructor is not given one.
DEFAULT_SEED :: u64(0x6f64696e626c6f6f)

@(private)
MAGIC :: [4]u8{'O', 'B', 'L', 'M'}

@(private)
HEADER_SIZE :: 8

@(private)
Kind :: enum u8 {
	Filter          = 1,
	Counting_Filter = 2,
	Cuckoo_Filter   = 3,
	Hyper_Log_Log   = 4,
	Count_Min       = 5,
}

/*
hash_bytes returns the 64-bit hash that every structure in this package
derives its positions from. It is XXH64 of `data` with `seed`.

Use it with the `*_add_hash` procedures when you already hash your items, or
when you want to hash an item once and test it against several structures that
share a seed.
*/
hash_bytes :: proc(data: []byte, seed := DEFAULT_SEED) -> u64 {
	return xxhash.XXH64(data, seed)
}

// hash_string is hash_bytes for a string, without copying it.
hash_string :: proc(s: string, seed := DEFAULT_SEED) -> u64 {
	return xxhash.XXH64(transmute([]byte)s, seed)
}

// mix64 is the SplitMix64 finalizer. It turns one 64-bit hash into a second,
// independent-looking one for double hashing.
@(private)
mix64 :: proc "contextless" (x: u64) -> u64 {
	z := x + 0x9e3779b97f4a7c15
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

// double_hash returns the `i`th of a family of positions in `[0, n)` derived
// from one 64-bit hash, following Kirsch and Mitzenmacher.
@(private)
double_hash :: proc "contextless" (h: u64, i: u64, n: u64) -> u64 {
	h1 := h
	h2 := mix64(h) | 1
	return (h1 + i * h2) % n
}

// Writer builds a serialized structure: header, payload and trailing CRC-32.
@(private)
Writer :: struct {
	buf: [dynamic]byte,
}

@(private)
writer_init :: proc(w: ^Writer, kind: Kind, payload_hint: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	w.buf = make([dynamic]byte, 0, HEADER_SIZE + payload_hint + 4, allocator) or_return
	magic := MAGIC
	append(&w.buf, ..magic[:]) or_return
	append(&w.buf, u8(FORMAT_VERSION), u8(kind), 0, 0) or_return
	return nil
}

@(private)
write_u8 :: proc(w: ^Writer, v: u8) -> runtime.Allocator_Error {
	_, err := append(&w.buf, v)
	return err
}

@(private)
write_u16 :: proc(w: ^Writer, v: u16) -> runtime.Allocator_Error {
	_, err := append(&w.buf, u8(v), u8(v >> 8))
	return err
}

@(private)
write_u32 :: proc(w: ^Writer, v: u32) -> runtime.Allocator_Error {
	_, err := append(&w.buf, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
	return err
}

@(private)
write_u64 :: proc(w: ^Writer, v: u64) -> runtime.Allocator_Error {
	write_u32(w, u32(v)) or_return
	return write_u32(w, u32(v >> 32))
}

@(private)
write_bytes :: proc(w: ^Writer, b: []byte) -> runtime.Allocator_Error {
	_, err := append(&w.buf, ..b)
	return err
}

// writer_finish appends the checksum and hands the buffer to the caller. On
// failure the caller still owns `w.buf` and must delete it.
@(private)
writer_finish :: proc(w: ^Writer) -> (data: []byte, err: runtime.Allocator_Error) {
	sum := hash.crc32(w.buf[:])
	write_u32(w, sum) or_return
	shrink(&w.buf)
	return w.buf[:], nil
}

// Reader walks a serialized structure after its header and checksum were verified.
@(private)
Reader :: struct {
	data: []byte,
	pos:  int,
}

// reader_open checks the magic, version, kind and checksum, and returns a
// reader positioned at the start of the payload. Versions below `min_version`
// are rejected as unsupported.
@(private)
reader_open :: proc(data: []byte, kind: Kind, min_version: u8 = 1) -> (r: Reader, err: Decode_Error) {
	if len(data) < HEADER_SIZE + 4 {
		return {}, .Truncated
	}
	magic := MAGIC
	for b, i in magic {
		if data[i] != b {
			return {}, .Bad_Magic
		}
	}
	if data[4] < min_version || data[4] == 0 || data[4] > FORMAT_VERSION {
		return {}, .Unsupported_Version
	}
	if data[5] != u8(kind) {
		return {}, .Wrong_Kind
	}
	if data[6] != 0 || data[7] != 0 {
		return {}, .Corrupt
	}
	body := data[:len(data) - 4]
	tail := data[len(data) - 4:]
	stored := u32(tail[0]) | u32(tail[1]) << 8 | u32(tail[2]) << 16 | u32(tail[3]) << 24
	if hash.crc32(body) != stored {
		return {}, .Checksum_Mismatch
	}
	return Reader{data = body, pos = HEADER_SIZE}, .None
}

@(private)
read_u8 :: proc(r: ^Reader) -> (v: u8, err: Decode_Error) {
	if r.pos + 1 > len(r.data) {
		return 0, .Truncated
	}
	v = r.data[r.pos]
	r.pos += 1
	return v, .None
}

@(private)
read_u16 :: proc(r: ^Reader) -> (v: u16, err: Decode_Error) {
	if r.pos + 2 > len(r.data) {
		return 0, .Truncated
	}
	v = u16(r.data[r.pos]) | u16(r.data[r.pos + 1]) << 8
	r.pos += 2
	return v, .None
}

@(private)
read_u32 :: proc(r: ^Reader) -> (v: u32, err: Decode_Error) {
	if r.pos + 4 > len(r.data) {
		return 0, .Truncated
	}
	b := r.data[r.pos:]
	v = u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
	r.pos += 4
	return v, .None
}

@(private)
read_u64 :: proc(r: ^Reader) -> (v: u64, err: Decode_Error) {
	lo := read_u32(r) or_return
	hi := read_u32(r) or_return
	return u64(lo) | u64(hi) << 32, .None
}

// read_bytes returns a view of the next `n` bytes without copying.
@(private)
read_bytes :: proc(r: ^Reader, n: int) -> (b: []byte, err: Decode_Error) {
	if n < 0 || n > len(r.data) - r.pos {
		return nil, .Truncated
	}
	b = r.data[r.pos:r.pos + n]
	r.pos += n
	return b, .None
}

// reader_done reports Corrupt when bytes remain after the payload.
@(private)
reader_done :: proc(r: ^Reader) -> Decode_Error {
	if r.pos != len(r.data) {
		return .Corrupt
	}
	return .None
}
