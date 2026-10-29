package bloom_tests

import bloom ".."
import "core:testing"

@(test)
test_cuckoo_make_rounds_to_power_of_two :: proc(t: ^testing.T) {
	f, err := bloom.cuckoo_filter_make(1000)
	testing.expect_value(t, err, nil)
	defer bloom.cuckoo_filter_destroy(&f)
	// 1000 / (4 * 0.95) = 263.2, so 512 buckets.
	testing.expect_value(t, f.bucket_count, 512)
	testing.expect_value(t, bloom.cuckoo_filter_capacity(&f), 2048)
}

@(test)
test_cuckoo_make_rejects_invalid_parameters :: proc(t: ^testing.T) {
	want := bloom.Error(bloom.Usage_Error.Invalid_Parameter)
	_, err := bloom.cuckoo_filter_make(0)
	testing.expect_value(t, err, want)
	_, err = bloom.cuckoo_filter_make(-1)
	testing.expect_value(t, err, want)
	_, err = bloom.cuckoo_filter_make_exact(3)
	testing.expect_value(t, err, want)
	_, err = bloom.cuckoo_filter_make_exact(0)
	testing.expect_value(t, err, want)
}

@(test)
test_cuckoo_add_contains_remove :: proc(t: ^testing.T) {
	f, _ := bloom.cuckoo_filter_make(100)
	defer bloom.cuckoo_filter_destroy(&f)
	testing.expect_value(t, bloom.cuckoo_filter_add(&f, "cuckoo"), nil)
	testing.expect(t, bloom.cuckoo_filter_contains(&f, "cuckoo"))
	testing.expect_value(t, bloom.cuckoo_filter_count(&f), 1)
	testing.expect_value(t, bloom.cuckoo_filter_remove(&f, "cuckoo"), nil)
	testing.expect(t, !bloom.cuckoo_filter_contains(&f, "cuckoo"))
	testing.expect_value(t, bloom.cuckoo_filter_count(&f), 0)
}

@(test)
test_cuckoo_remove_absent_is_not_found :: proc(t: ^testing.T) {
	f, _ := bloom.cuckoo_filter_make(100)
	defer bloom.cuckoo_filter_destroy(&f)
	testing.expect_value(t, bloom.cuckoo_filter_remove(&f, "ghost"), bloom.Error(bloom.Usage_Error.Not_Found))
	zero: bloom.Cuckoo_Filter
	testing.expect_value(t, bloom.cuckoo_filter_remove(&zero, "ghost"), bloom.Error(bloom.Usage_Error.Not_Found))
	testing.expect_value(t, bloom.cuckoo_filter_add(&zero, "ghost"), bloom.Error(bloom.Usage_Error.Full))
	testing.expect(t, !bloom.cuckoo_filter_contains(&zero, "ghost"))
}

@(test)
test_cuckoo_no_false_negatives_at_high_load :: proc(t: ^testing.T) {
	f, _ := bloom.cuckoo_filter_make_exact(4096)
	defer bloom.cuckoo_filter_destroy(&f)
	n := int(0.93 * f64(bloom.cuckoo_filter_capacity(&f)))
	for i in 0 ..< n {
		k := key(i)
		testing.expect_value(t, bloom.cuckoo_filter_add(&f, k[:]), nil)
	}
	testing.expect_value(t, bloom.cuckoo_filter_count(&f), n)
	misses := 0
	for i in 0 ..< n {
		k := key(i)
		if !bloom.cuckoo_filter_contains(&f, k[:]) {
			misses += 1
		}
	}
	testing.expect_value(t, misses, 0)
	testing.expect(t, bloom.cuckoo_filter_load_factor(&f) > 0.92)
}

@(test)
test_cuckoo_false_positive_rate_within_bound :: proc(t: ^testing.T) {
	f, _ := bloom.cuckoo_filter_make(50_000)
	defer bloom.cuckoo_filter_destroy(&f)
	for i in 0 ..< 50_000 {
		k := key(i)
		_ = bloom.cuckoo_filter_add(&f, k[:])
	}
	// Upper bound 2b/2^f = 8/65536 at full load; allow sampling noise.
	probes := 500_000
	hits := 0
	for i in 50_000 ..< 50_000 + probes {
		k := key(i)
		if bloom.cuckoo_filter_contains(&f, k[:]) {
			hits += 1
		}
	}
	rate := f64(hits) / f64(probes)
	testing.expectf(t, rate < 2.0 * 8.0 / 65536.0, "observed %v", rate)
}

@(test)
test_cuckoo_reports_full_and_keeps_items :: proc(t: ^testing.T) {
	f, _ := bloom.cuckoo_filter_make_exact(16)
	defer bloom.cuckoo_filter_destroy(&f)
	added := 0
	full := false
	for i in 0 ..< 1000 {
		k := key(i)
		err := bloom.cuckoo_filter_add(&f, k[:])
		if err == bloom.Error(bloom.Usage_Error.Full) {
			full = true
			break
		}
		testing.expect_value(t, err, nil)
		added += 1
	}
	testing.expect(t, full)
	testing.expect_value(t, bloom.cuckoo_filter_count(&f), added)
	for i in 0 ..< added {
		k := key(i)
		testing.expectf(t, bloom.cuckoo_filter_contains(&f, k[:]), "lost item %v", i)
	}
	// Removing an item frees room again.
	k := key(0)
	testing.expect_value(t, bloom.cuckoo_filter_remove(&f, k[:]), nil)
	k = key(5000)
	testing.expect_value(t, bloom.cuckoo_filter_add(&f, k[:]), nil)
}

@(test)
test_cuckoo_allows_bounded_duplicates :: proc(t: ^testing.T) {
	f, _ := bloom.cuckoo_filter_make(1000)
	defer bloom.cuckoo_filter_destroy(&f)
	for _ in 0 ..< 2 * bloom.BUCKET_SIZE {
		testing.expect_value(t, bloom.cuckoo_filter_add(&f, "dup"), nil)
	}
	for _ in 0 ..< 2 * bloom.BUCKET_SIZE {
		testing.expect_value(t, bloom.cuckoo_filter_remove(&f, "dup"), nil)
	}
	testing.expect(t, !bloom.cuckoo_filter_contains(&f, "dup"))
}

@(test)
test_cuckoo_merge_and_incompatible :: proc(t: ^testing.T) {
	a, _ := bloom.cuckoo_filter_make(1000)
	defer bloom.cuckoo_filter_destroy(&a)
	b, _ := bloom.cuckoo_filter_make(1000)
	defer bloom.cuckoo_filter_destroy(&b)
	for i in 0 ..< 300 {
		k := key(i)
		_ = bloom.cuckoo_filter_add(&a, k[:])
		k = key(i + 300)
		_ = bloom.cuckoo_filter_add(&b, k[:])
	}
	testing.expect_value(t, bloom.cuckoo_filter_merge(&a, &b), nil)
	testing.expect_value(t, bloom.cuckoo_filter_count(&a), 600)
	for i in 0 ..< 600 {
		k := key(i)
		testing.expect(t, bloom.cuckoo_filter_contains(&a, k[:]))
	}

	c, _ := bloom.cuckoo_filter_make(5000)
	defer bloom.cuckoo_filter_destroy(&c)
	testing.expect_value(t, bloom.cuckoo_filter_merge(&a, &c), bloom.Error(bloom.Usage_Error.Incompatible))
}

@(test)
test_cuckoo_merge_into_full_filter_fails :: proc(t: ^testing.T) {
	a, _ := bloom.cuckoo_filter_make_exact(4)
	defer bloom.cuckoo_filter_destroy(&a)
	b, _ := bloom.cuckoo_filter_make_exact(4)
	defer bloom.cuckoo_filter_destroy(&b)
	for i in 0 ..< 14 {
		k := key(i)
		_ = bloom.cuckoo_filter_add(&a, k[:])
		k = key(i + 100)
		_ = bloom.cuckoo_filter_add(&b, k[:])
	}
	testing.expect_value(t, bloom.cuckoo_filter_merge(&a, &b), bloom.Error(bloom.Usage_Error.Full))
}

@(test)
test_cuckoo_serialize_round_trip :: proc(t: ^testing.T) {
	f, _ := bloom.cuckoo_filter_make(1000, seed = 5)
	defer bloom.cuckoo_filter_destroy(&f)
	for i in 0 ..< 800 {
		k := key(i)
		_ = bloom.cuckoo_filter_add(&f, k[:])
	}
	data, err := bloom.cuckoo_filter_serialize(&f)
	testing.expect_value(t, err, nil)
	defer delete(data)
	g, derr := bloom.cuckoo_filter_deserialize(data)
	testing.expect_value(t, derr, nil)
	defer bloom.cuckoo_filter_destroy(&g)
	testing.expect_value(t, bloom.cuckoo_filter_count(&g), 800)
	for i in 0 ..< 800 {
		k := key(i)
		testing.expect(t, bloom.cuckoo_filter_contains(&g, k[:]))
	}
}

@(test)
test_cuckoo_deserialize_rejects_wrong_count :: proc(t: ^testing.T) {
	f, _ := bloom.cuckoo_filter_make(10)
	defer bloom.cuckoo_filter_destroy(&f)
	_ = bloom.cuckoo_filter_add(&f, "one")
	data, _ := bloom.cuckoo_filter_serialize(&f)
	defer delete(data)
	// The item count follows the header, bucket count and seed.
	data[24] = 9
	reseal(data)
	_, err := bloom.cuckoo_filter_deserialize(data)
	testing.expect_value(t, err, bloom.Error(bloom.Decode_Error.Corrupt))
}

@(test)
test_cuckoo_deserialize_rejects_non_power_of_two :: proc(t: ^testing.T) {
	f, _ := bloom.cuckoo_filter_make_exact(4)
	defer bloom.cuckoo_filter_destroy(&f)
	data, _ := bloom.cuckoo_filter_serialize(&f)
	defer delete(data)
	data[8] = 3
	reseal(data)
	_, err := bloom.cuckoo_filter_deserialize(data)
	testing.expect_value(t, err, bloom.Error(bloom.Decode_Error.Corrupt))
}
