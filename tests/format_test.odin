package bloom_tests

import bloom ".."
import "core:mem"
import "core:testing"

@(test)
test_deserialize_rejects_empty_and_short_input :: proc(t: ^testing.T) {
	want := bloom.Error(bloom.Decode_Error.Truncated)
	_, err := bloom.filter_deserialize(nil)
	testing.expect_value(t, err, want)
	short := [?]u8{'O', 'B', 'L', 'M', 1}
	_, err = bloom.filter_deserialize(short[:])
	testing.expect_value(t, err, want)
	_, herr := bloom.hll_deserialize(short[:])
	testing.expect_value(t, herr, want)
}

@(test)
test_deserialize_rejects_bad_magic :: proc(t: ^testing.T) {
	f, _ := bloom.filter_make(10, 0.1)
	defer bloom.filter_destroy(&f)
	data, _ := bloom.filter_serialize(&f)
	defer delete(data)
	data[0] = 'X'
	_, err := bloom.filter_deserialize(data)
	testing.expect_value(t, err, bloom.Error(bloom.Decode_Error.Bad_Magic))
}

@(test)
test_deserialize_rejects_unknown_version :: proc(t: ^testing.T) {
	c, _ := bloom.count_min_make(0.1, 0.1)
	defer bloom.count_min_destroy(&c)
	data, _ := bloom.count_min_serialize(&c)
	defer delete(data)
	data[4] = bloom.FORMAT_VERSION + 1
	reseal(data)
	_, err := bloom.count_min_deserialize(data)
	testing.expect_value(t, err, bloom.Error(bloom.Decode_Error.Unsupported_Version))
}

@(test)
test_deserialize_rejects_wrong_kind :: proc(t: ^testing.T) {
	h, _ := bloom.hll_make()
	defer bloom.hll_destroy(&h)
	data, _ := bloom.hll_serialize(&h)
	defer delete(data)
	want := bloom.Error(bloom.Decode_Error.Wrong_Kind)
	_, e1 := bloom.filter_deserialize(data)
	testing.expect_value(t, e1, want)
	_, e2 := bloom.cuckoo_filter_deserialize(data)
	testing.expect_value(t, e2, want)
	_, e3 := bloom.count_min_deserialize(data)
	testing.expect_value(t, e3, want)
	_, e4 := bloom.counting_filter_deserialize(data)
	testing.expect_value(t, e4, want)
}

@(test)
test_deserialize_detects_bit_flips :: proc(t: ^testing.T) {
	f, _ := bloom.filter_make(1000, 0.01)
	defer bloom.filter_destroy(&f)
	bloom.filter_add(&f, "payload")
	data, _ := bloom.filter_serialize(&f)
	defer delete(data)
	for i in ([?]int{9, 30, len(data) / 2, len(data) - 1}) {
		data[i] ~= 0x10
		_, err := bloom.filter_deserialize(data)
		testing.expectf(t, err == bloom.Error(bloom.Decode_Error.Checksum_Mismatch), "flip at %v gave %v", i, err)
		data[i] ~= 0x10
	}
	g, err := bloom.filter_deserialize(data)
	testing.expect_value(t, err, nil)
	bloom.filter_destroy(&g)
}

@(test)
test_deserialize_rejects_truncated_payload :: proc(t: ^testing.T) {
	c, _ := bloom.count_min_make(0.1, 0.1)
	defer bloom.count_min_destroy(&c)
	data, _ := bloom.count_min_serialize(&c)
	defer delete(data)
	// Drop 8 bytes of counters but keep a valid checksum.
	short := data[:len(data) - 8]
	reseal(short)
	_, err := bloom.count_min_deserialize(short)
	testing.expect_value(t, err, bloom.Error(bloom.Decode_Error.Truncated))
}

@(test)
test_deserialize_rejects_trailing_bytes :: proc(t: ^testing.T) {
	h, _ := bloom.hll_make(4)
	defer bloom.hll_destroy(&h)
	data, _ := bloom.hll_serialize(&h)
	defer delete(data)
	longer := make([]byte, len(data) + 3)
	defer delete(longer)
	copy(longer, data[:len(data) - 4])
	reseal(longer)
	_, err := bloom.hll_deserialize(longer)
	testing.expect_value(t, err, bloom.Error(bloom.Decode_Error.Corrupt))
}

@(test)
test_deserialize_rejects_nonzero_reserved_bytes :: proc(t: ^testing.T) {
	f, _ := bloom.cuckoo_filter_make(8)
	defer bloom.cuckoo_filter_destroy(&f)
	data, _ := bloom.cuckoo_filter_serialize(&f)
	defer delete(data)
	data[6] = 1
	reseal(data)
	_, err := bloom.cuckoo_filter_deserialize(data)
	testing.expect_value(t, err, bloom.Error(bloom.Decode_Error.Corrupt))
}

@(test)
test_allocation_failure_is_reported :: proc(t: ^testing.T) {
	buf: [64]byte
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	alloc := mem.arena_allocator(&arena)
	_, err := bloom.filter_make(100_000, 0.01, allocator = alloc)
	testing.expect_value(t, err, bloom.Error(mem.Allocator_Error.Out_Of_Memory))
	_, cerr := bloom.count_min_make(0.001, 0.001, allocator = alloc)
	testing.expect_value(t, cerr, bloom.Error(mem.Allocator_Error.Out_Of_Memory))
}

@(test)
test_hll_reports_allocation_failure_on_growth :: proc(t: ^testing.T) {
	buf: [256]byte
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	h, err := bloom.hll_make(12, allocator = mem.arena_allocator(&arena))
	testing.expect_value(t, err, nil)
	failed := false
	for i in 0 ..< 10_000 {
		if bloom.hll_add_hash(&h, item_hash(i)) != nil {
			failed = true
			break
		}
	}
	testing.expect(t, failed)
}

@(test)
test_every_structure_frees_all_memory :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	{
		f, _ := bloom.filter_make(1000, 0.01, allocator = alloc)
		bloom.filter_add(&f, "x")
		c, _ := bloom.filter_clone(&f, alloc)
		data, _ := bloom.filter_serialize(&f, alloc)
		g, _ := bloom.filter_deserialize(data, alloc)
		delete(data, alloc)
		bloom.filter_destroy(&g)
		bloom.filter_destroy(&c)
		bloom.filter_destroy(&f)
	}
	{
		f, _ := bloom.counting_filter_make(1000, 0.01, allocator = alloc)
		bloom.counting_filter_add(&f, "x")
		p, _ := bloom.counting_filter_to_filter(&f, alloc)
		data, _ := bloom.counting_filter_serialize(&f, alloc)
		g, _ := bloom.counting_filter_deserialize(data, alloc)
		delete(data, alloc)
		bloom.counting_filter_destroy(&g)
		bloom.filter_destroy(&p)
		bloom.counting_filter_destroy(&f)
	}
	{
		f, _ := bloom.cuckoo_filter_make(1000, allocator = alloc)
		_ = bloom.cuckoo_filter_add(&f, "x")
		data, _ := bloom.cuckoo_filter_serialize(&f, alloc)
		g, _ := bloom.cuckoo_filter_deserialize(data, alloc)
		delete(data, alloc)
		bloom.cuckoo_filter_destroy(&g)
		bloom.cuckoo_filter_destroy(&f)
	}
	{
		h, _ := bloom.hll_make(8, allocator = alloc)
		for i in 0 ..< 1000 {
			bloom.hll_add_hash(&h, item_hash(i))
		}
		c, _ := bloom.hll_clone(&h, alloc)
		data, _ := bloom.hll_serialize(&h, alloc)
		g, _ := bloom.hll_deserialize(data, alloc)
		bad := make([]byte, len(data), alloc)
		copy(bad, data)
		bad[len(bad) - 5] = 255
		reseal(bad)
		_, berr := bloom.hll_deserialize(bad, alloc)
		testing.expect_value(t, berr, bloom.Error(bloom.Decode_Error.Corrupt))
		delete(bad, alloc)
		delete(data, alloc)
		bloom.hll_clear(&c)
		bloom.hll_destroy(&g)
		bloom.hll_destroy(&c)
		bloom.hll_destroy(&h)
	}
	{
		c, _ := bloom.count_min_make(0.01, 0.01, allocator = alloc)
		bloom.count_min_add(&c, "x")
		data, _ := bloom.count_min_serialize(&c, alloc)
		g, _ := bloom.count_min_deserialize(data, alloc)
		delete(data, alloc)
		bloom.count_min_destroy(&g)
		bloom.count_min_destroy(&c)
	}

	testing.expectf(t, len(track.allocation_map) == 0, "%v allocations leaked", len(track.allocation_map))
	testing.expectf(t, len(track.bad_free_array) == 0, "%v bad frees", len(track.bad_free_array))
}
