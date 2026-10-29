package bloom_tests

import bloom ".."
import "core:math"
import "core:testing"

@(test)
test_optimal_bit_count_matches_formula :: proc(t: ^testing.T) {
	// -1000 * ln(0.01) / ln(2)^2 = 9585.06, rounded up.
	testing.expect_value(t, bloom.optimal_bit_count(1000, 0.01), 9586)
	testing.expect_value(t, bloom.optimal_bit_count(1, 0.5), 2)
}

@(test)
test_optimal_hash_count_matches_formula :: proc(t: ^testing.T) {
	testing.expect_value(t, bloom.optimal_hash_count(1000, 9586), 7)
	testing.expect_value(t, bloom.optimal_hash_count(1000, 10), 1)
	testing.expect_value(t, bloom.optimal_hash_count(1, 1 << 20), bloom.MAX_HASHES)
}

@(test)
test_optimal_sizing_rejects_bad_input :: proc(t: ^testing.T) {
	testing.expect_value(t, bloom.optimal_bit_count(0, 0.01), 0)
	testing.expect_value(t, bloom.optimal_bit_count(-5, 0.01), 0)
	testing.expect_value(t, bloom.optimal_bit_count(10, 0), 0)
	testing.expect_value(t, bloom.optimal_bit_count(10, 1), 0)
	testing.expect_value(t, bloom.optimal_bit_count(10, math.nan_f64()), 0)
	testing.expect_value(t, bloom.optimal_hash_count(0, 100), 0)
	testing.expect_value(t, bloom.optimal_hash_count(10, 0), 0)
}

@(test)
test_filter_make_rejects_invalid_parameters :: proc(t: ^testing.T) {
	want := bloom.Error(bloom.Usage_Error.Invalid_Parameter)
	_, err := bloom.filter_make(0, 0.01)
	testing.expect_value(t, err, want)
	_, err = bloom.filter_make(100, 1.5)
	testing.expect_value(t, err, want)
	_, err = bloom.filter_make(max(int), 1e-12)
	testing.expect_value(t, err, want)
	_, err = bloom.filter_make_exact(0, 3)
	testing.expect_value(t, err, want)
	_, err = bloom.filter_make_exact(64, 0)
	testing.expect_value(t, err, want)
	_, err = bloom.filter_make_exact(64, bloom.MAX_HASHES + 1)
	testing.expect_value(t, err, want)
}

@(test)
test_filter_add_and_contains_strings :: proc(t: ^testing.T) {
	f, err := bloom.filter_make(100, 0.01)
	testing.expect_value(t, err, nil)
	defer bloom.filter_destroy(&f)

	testing.expect(t, !bloom.filter_contains(&f, "odin"))
	testing.expect(t, bloom.filter_add(&f, "odin"))
	testing.expect(t, bloom.filter_contains(&f, "odin"))
	testing.expect(t, !bloom.filter_contains(&f, "zig"))
}

@(test)
test_filter_add_reports_whether_bits_changed :: proc(t: ^testing.T) {
	f, _ := bloom.filter_make(100, 0.01)
	defer bloom.filter_destroy(&f)
	testing.expect(t, bloom.filter_add(&f, "a"))
	testing.expect(t, !bloom.filter_add(&f, "a"))
}

@(test)
test_filter_string_and_bytes_agree :: proc(t: ^testing.T) {
	f, _ := bloom.filter_make(100, 0.01)
	defer bloom.filter_destroy(&f)
	bloom.filter_add(&f, transmute([]byte)string("hello"))
	testing.expect(t, bloom.filter_contains(&f, "hello"))
	testing.expect(t, bloom.filter_contains_hash(&f, bloom.hash_string("hello", f.seed)))
}

@(test)
test_filter_has_no_false_negatives :: proc(t: ^testing.T) {
	f, _ := bloom.filter_make(20_000, 0.001)
	defer bloom.filter_destroy(&f)
	for i in 0 ..< 20_000 {
		k := key(i)
		bloom.filter_add(&f, k[:])
	}
	misses := 0
	for i in 0 ..< 20_000 {
		k := key(i)
		if !bloom.filter_contains(&f, k[:]) {
			misses += 1
		}
	}
	testing.expect_value(t, misses, 0)
}

@(test)
test_filter_false_positive_rate_within_bound :: proc(t: ^testing.T) {
	// For each target rate, fill to capacity and probe 200k absent items.
	targets := [?]f64{0.1, 0.01, 0.001}
	for p in targets {
		n := 10_000
		f, err := bloom.filter_make(n, p)
		testing.expect_value(t, err, nil)
		defer bloom.filter_destroy(&f)
		for i in 0 ..< n {
			k := key(i)
			bloom.filter_add(&f, k[:])
		}
		probes := 200_000
		hits := 0
		for i in n ..< n + probes {
			k := key(i)
			if bloom.filter_contains(&f, k[:]) {
				hits += 1
			}
		}
		observed := f64(hits) / f64(probes)
		// Binomial standard deviation of the observed rate, then allow 5 sigma.
		sigma := math.sqrt(p * (1 - p) / f64(probes))
		testing.expectf(t, observed <= p * 1.1 + 5 * sigma, "p=%v observed=%v", p, observed)
		testing.expectf(t, observed >= p * 0.5, "p=%v observed=%v suspiciously low", p, observed)
	}
}

@(test)
test_filter_observed_rate_tracks_theory :: proc(t: ^testing.T) {
	f, _ := bloom.filter_make_exact(1 << 16, 4)
	defer bloom.filter_destroy(&f)
	n := 8000
	for i in 0 ..< n {
		k := key(i)
		bloom.filter_add(&f, k[:])
	}
	theory := bloom.expected_fp_rate(1 << 16, 4, n)
	current := bloom.filter_current_fp_rate(&f)
	testing.expectf(t, math.abs(current - theory) / theory < 0.05, "theory=%v current=%v", theory, current)
}

@(test)
test_filter_estimate_count_is_close :: proc(t: ^testing.T) {
	f, _ := bloom.filter_make(50_000, 0.01)
	defer bloom.filter_destroy(&f)
	n := 30_000
	for i in 0 ..< n {
		k := key(i)
		bloom.filter_add(&f, k[:])
	}
	est := bloom.filter_estimate_count(&f)
	testing.expectf(t, rel_err(est, n) < 0.02, "estimate %v for %v", est, n)
}

@(test)
test_filter_estimate_count_saturated_is_infinite :: proc(t: ^testing.T) {
	f, _ := bloom.filter_make_exact(8, 1)
	defer bloom.filter_destroy(&f)
	for i in 0 ..< 1000 {
		k := key(i)
		bloom.filter_add(&f, k[:])
	}
	testing.expect_value(t, bloom.filter_fill_ratio(&f), 1)
	testing.expect(t, math.is_inf(bloom.filter_estimate_count(&f), 1))
}

@(test)
test_filter_merge_is_union :: proc(t: ^testing.T) {
	a, _ := bloom.filter_make(1000, 0.01)
	defer bloom.filter_destroy(&a)
	b, _ := bloom.filter_make(1000, 0.01)
	defer bloom.filter_destroy(&b)
	bloom.filter_add(&a, "left")
	bloom.filter_add(&b, "right")
	testing.expect_value(t, bloom.filter_merge(&a, &b), nil)
	testing.expect(t, bloom.filter_contains(&a, "left"))
	testing.expect(t, bloom.filter_contains(&a, "right"))
}

@(test)
test_filter_merge_rejects_incompatible :: proc(t: ^testing.T) {
	a, _ := bloom.filter_make(1000, 0.01)
	defer bloom.filter_destroy(&a)
	b, _ := bloom.filter_make(2000, 0.01)
	defer bloom.filter_destroy(&b)
	c, _ := bloom.filter_make(1000, 0.01, seed = 7)
	defer bloom.filter_destroy(&c)
	want := bloom.Error(bloom.Usage_Error.Incompatible)
	testing.expect_value(t, bloom.filter_merge(&a, &b), want)
	testing.expect_value(t, bloom.filter_merge(&a, &c), want)
	testing.expect_value(t, bloom.filter_intersect(&a, &c), want)
	testing.expect_value(t, bloom.filter_popcount(&a), 0)
}

@(test)
test_filter_intersect_keeps_common_items :: proc(t: ^testing.T) {
	a, _ := bloom.filter_make(1000, 0.001)
	defer bloom.filter_destroy(&a)
	b, _ := bloom.filter_make(1000, 0.001)
	defer bloom.filter_destroy(&b)
	bloom.filter_add(&a, "both")
	bloom.filter_add(&a, "only-a")
	bloom.filter_add(&b, "both")
	bloom.filter_add(&b, "only-b")
	testing.expect_value(t, bloom.filter_intersect(&a, &b), nil)
	testing.expect(t, bloom.filter_contains(&a, "both"))
	testing.expect(t, !bloom.filter_contains(&a, "only-a"))
	testing.expect(t, !bloom.filter_contains(&a, "only-b"))
}

@(test)
test_filter_clear_empties :: proc(t: ^testing.T) {
	f, _ := bloom.filter_make(100, 0.01)
	defer bloom.filter_destroy(&f)
	bloom.filter_add(&f, "x")
	bloom.filter_clear(&f)
	testing.expect(t, !bloom.filter_contains(&f, "x"))
	testing.expect_value(t, bloom.filter_popcount(&f), 0)
	testing.expect_value(t, bloom.filter_estimate_count(&f), 0)
}

@(test)
test_filter_clone_is_independent :: proc(t: ^testing.T) {
	f, _ := bloom.filter_make(100, 0.01)
	defer bloom.filter_destroy(&f)
	bloom.filter_add(&f, "x")
	c, err := bloom.filter_clone(&f)
	testing.expect_value(t, err, nil)
	defer bloom.filter_destroy(&c)
	bloom.filter_add(&c, "y")
	testing.expect(t, bloom.filter_contains(&c, "x"))
	testing.expect(t, !bloom.filter_contains(&f, "y"))
}

@(test)
test_filter_zero_value_is_safe :: proc(t: ^testing.T) {
	f: bloom.Filter
	testing.expect(t, !bloom.filter_contains(&f, "x"))
	testing.expect_value(t, bloom.filter_fill_ratio(&f), 0)
	testing.expect_value(t, bloom.filter_estimate_count(&f), 0)
	bloom.filter_destroy(&f)
}

@(test)
test_filter_serialize_round_trip :: proc(t: ^testing.T) {
	f, _ := bloom.filter_make(500, 0.01, seed = 99)
	defer bloom.filter_destroy(&f)
	for i in 0 ..< 500 {
		k := key(i)
		bloom.filter_add(&f, k[:])
	}
	data, err := bloom.filter_serialize(&f)
	testing.expect_value(t, err, nil)
	defer delete(data)

	g, derr := bloom.filter_deserialize(data)
	testing.expect_value(t, derr, nil)
	defer bloom.filter_destroy(&g)
	testing.expect_value(t, g.bit_count, f.bit_count)
	testing.expect_value(t, g.hash_count, f.hash_count)
	testing.expect_value(t, g.seed, f.seed)
	testing.expect_value(t, bloom.filter_popcount(&g), bloom.filter_popcount(&f))
	for i in 0 ..< 500 {
		k := key(i)
		testing.expect(t, bloom.filter_contains(&g, k[:]))
	}
}

@(test)
test_filter_deserialize_rejects_bits_past_end :: proc(t: ^testing.T) {
	f, _ := bloom.filter_make_exact(10, 2)
	defer bloom.filter_destroy(&f)
	data, _ := bloom.filter_serialize(&f)
	defer delete(data)
	// Set bit 63 of the only word: past the 10 valid bits.
	data[len(data) - 5] = 0x80
	reseal(data)
	_, err := bloom.filter_deserialize(data)
	testing.expect_value(t, err, bloom.Error(bloom.Decode_Error.Corrupt))
}

@(test)
test_filter_deserialize_rejects_zero_hash_count :: proc(t: ^testing.T) {
	f, _ := bloom.filter_make_exact(64, 2)
	defer bloom.filter_destroy(&f)
	data, _ := bloom.filter_serialize(&f)
	defer delete(data)
	// The hash count follows the 8-byte header and the 8-byte bit count.
	data[16] = 0
	reseal(data)
	_, err := bloom.filter_deserialize(data)
	testing.expect_value(t, err, bloom.Error(bloom.Decode_Error.Corrupt))
}
