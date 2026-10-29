package bloom_tests

import bloom ".."
import "core:testing"

@(test)
test_counting_add_contains_remove :: proc(t: ^testing.T) {
	f, err := bloom.counting_filter_make(1000, 0.01)
	testing.expect_value(t, err, nil)
	defer bloom.counting_filter_destroy(&f)

	bloom.counting_filter_add(&f, "apple")
	testing.expect(t, bloom.counting_filter_contains(&f, "apple"))
	testing.expect_value(t, bloom.counting_filter_remove(&f, "apple"), nil)
	testing.expect(t, !bloom.counting_filter_contains(&f, "apple"))
}

@(test)
test_counting_remove_absent_is_not_found :: proc(t: ^testing.T) {
	f, _ := bloom.counting_filter_make(1000, 0.01)
	defer bloom.counting_filter_destroy(&f)
	bloom.counting_filter_add(&f, "kept")
	testing.expect_value(t, bloom.counting_filter_remove(&f, "never"), bloom.Error(bloom.Usage_Error.Not_Found))
	testing.expect(t, bloom.counting_filter_contains(&f, "kept"))
}

@(test)
test_counting_remove_twice_after_one_add_fails :: proc(t: ^testing.T) {
	f, _ := bloom.counting_filter_make(1000, 0.01)
	defer bloom.counting_filter_destroy(&f)
	bloom.counting_filter_add(&f, "x")
	testing.expect_value(t, bloom.counting_filter_remove(&f, "x"), nil)
	testing.expect_value(t, bloom.counting_filter_remove(&f, "x"), bloom.Error(bloom.Usage_Error.Not_Found))
}

@(test)
test_counting_count_tracks_multiplicity :: proc(t: ^testing.T) {
	f, _ := bloom.counting_filter_make(1000, 0.001)
	defer bloom.counting_filter_destroy(&f)
	for _ in 0 ..< 5 {
		bloom.counting_filter_add(&f, "five")
	}
	bloom.counting_filter_add(&f, "one")
	testing.expect_value(t, bloom.counting_filter_count(&f, "five"), 5)
	testing.expect_value(t, bloom.counting_filter_count(&f, "one"), 1)
	testing.expect_value(t, bloom.counting_filter_count(&f, "zero"), 0)
	_ = bloom.counting_filter_remove(&f, "five")
	testing.expect_value(t, bloom.counting_filter_count(&f, "five"), 4)
}

@(test)
test_counting_saturated_counters_never_drop :: proc(t: ^testing.T) {
	f, _ := bloom.counting_filter_make_exact(64, 3)
	defer bloom.counting_filter_destroy(&f)
	for _ in 0 ..< 300 {
		bloom.counting_filter_add(&f, "hot")
	}
	testing.expect_value(t, bloom.counting_filter_count(&f, "hot"), bloom.COUNTER_MAX)
	for _ in 0 ..< 300 {
		testing.expect_value(t, bloom.counting_filter_remove(&f, "hot"), nil)
	}
	// Saturated counters stay put, so the item is never falsely reported absent.
	testing.expect(t, bloom.counting_filter_contains(&f, "hot"))
}

@(test)
test_counting_removal_keeps_other_items :: proc(t: ^testing.T) {
	f, _ := bloom.counting_filter_make(5000, 0.01)
	defer bloom.counting_filter_destroy(&f)
	for i in 0 ..< 5000 {
		k := key(i)
		bloom.counting_filter_add(&f, k[:])
	}
	for i in 0 ..< 2500 {
		k := key(i)
		testing.expect_value(t, bloom.counting_filter_remove(&f, k[:]), nil)
	}
	misses := 0
	for i in 2500 ..< 5000 {
		k := key(i)
		if !bloom.counting_filter_contains(&f, k[:]) {
			misses += 1
		}
	}
	testing.expect_value(t, misses, 0)
	est := bloom.counting_filter_estimate_count(&f)
	testing.expectf(t, rel_err(est, 2500) < 0.05, "estimate %v", est)
}

@(test)
test_counting_false_positive_rate_within_bound :: proc(t: ^testing.T) {
	f, _ := bloom.counting_filter_make(10_000, 0.01)
	defer bloom.counting_filter_destroy(&f)
	for i in 0 ..< 10_000 {
		k := key(i)
		bloom.counting_filter_add(&f, k[:])
	}
	hits := 0
	for i in 10_000 ..< 110_000 {
		k := key(i)
		if bloom.counting_filter_contains(&f, k[:]) {
			hits += 1
		}
	}
	rate := f64(hits) / 100_000
	testing.expectf(t, rate < 0.0135, "observed %v", rate)
}

@(test)
test_counting_merge_adds_counters :: proc(t: ^testing.T) {
	a, _ := bloom.counting_filter_make(1000, 0.01)
	defer bloom.counting_filter_destroy(&a)
	b, _ := bloom.counting_filter_make(1000, 0.01)
	defer bloom.counting_filter_destroy(&b)
	bloom.counting_filter_add(&a, "x")
	bloom.counting_filter_add(&b, "x")
	bloom.counting_filter_add(&b, "y")
	testing.expect_value(t, bloom.counting_filter_merge(&a, &b), nil)
	testing.expect_value(t, bloom.counting_filter_count(&a, "x"), 2)
	testing.expect_value(t, bloom.counting_filter_count(&a, "y"), 1)

	c, _ := bloom.counting_filter_make(1000, 0.01, seed = 1)
	defer bloom.counting_filter_destroy(&c)
	testing.expect_value(t, bloom.counting_filter_merge(&a, &c), bloom.Error(bloom.Usage_Error.Incompatible))
}

@(test)
test_counting_to_filter_answers_the_same :: proc(t: ^testing.T) {
	c, _ := bloom.counting_filter_make(2000, 0.01)
	defer bloom.counting_filter_destroy(&c)
	for i in 0 ..< 2000 {
		k := key(i)
		bloom.counting_filter_add(&c, k[:])
	}
	f, err := bloom.counting_filter_to_filter(&c)
	testing.expect_value(t, err, nil)
	defer bloom.filter_destroy(&f)
	for i in 0 ..< 20_000 {
		k := key(i)
		testing.expect_value(t, bloom.filter_contains(&f, k[:]), bloom.counting_filter_contains(&c, k[:]))
	}
}

@(test)
test_counting_serialize_round_trip :: proc(t: ^testing.T) {
	f, _ := bloom.counting_filter_make(100, 0.01)
	defer bloom.counting_filter_destroy(&f)
	bloom.counting_filter_add(&f, "a")
	bloom.counting_filter_add(&f, "a")
	data, err := bloom.counting_filter_serialize(&f)
	testing.expect_value(t, err, nil)
	defer delete(data)
	g, derr := bloom.counting_filter_deserialize(data)
	testing.expect_value(t, derr, nil)
	defer bloom.counting_filter_destroy(&g)
	testing.expect_value(t, bloom.counting_filter_count(&g, "a"), 2)
	testing.expect_value(t, len(g.counters), len(f.counters))

	_, kerr := bloom.filter_deserialize(data)
	testing.expect_value(t, kerr, bloom.Error(bloom.Decode_Error.Wrong_Kind))
}
