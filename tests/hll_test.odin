package bloom_tests

import bloom ".."
import "base:intrinsics"
import "core:math"
import "core:slice"
import "core:testing"

@(test)
test_hll_make_rejects_bad_precision :: proc(t: ^testing.T) {
	want := bloom.Error(bloom.Usage_Error.Invalid_Parameter)
	_, err := bloom.hll_make(3)
	testing.expect_value(t, err, want)
	_, err = bloom.hll_make(19)
	testing.expect_value(t, err, want)
}

@(test)
test_hll_empty_estimates_zero :: proc(t: ^testing.T) {
	h, err := bloom.hll_make()
	testing.expect_value(t, err, nil)
	defer bloom.hll_destroy(&h)
	testing.expect(t, bloom.hll_is_sparse(&h))
	testing.expect_value(t, bloom.hll_cardinality(&h), 0)
	zero: bloom.Hll
	testing.expect_value(t, bloom.hll_estimate(&zero), 0)
	testing.expect_value(t, bloom.hll_add(&zero, "x"), bloom.Error(bloom.Usage_Error.Invalid_Parameter))
}

@(test)
test_hll_duplicates_do_not_count :: proc(t: ^testing.T) {
	h, _ := bloom.hll_make()
	defer bloom.hll_destroy(&h)
	for _ in 0 ..< 1000 {
		testing.expect_value(t, bloom.hll_add(&h, "same"), nil)
	}
	testing.expect_value(t, bloom.hll_cardinality(&h), 1)
}

@(test)
test_hll_sparse_is_near_exact_for_small_sets :: proc(t: ^testing.T) {
	h, _ := bloom.hll_make(14)
	defer bloom.hll_destroy(&h)
	n := 3000
	for i in 0 ..< n {
		k := key(i)
		bloom.hll_add(&h, k[:])
	}
	testing.expect(t, bloom.hll_is_sparse(&h))
	est := bloom.hll_estimate(&h)
	// Linear counting over 2^25 buckets: collisions are rare at this size.
	testing.expectf(t, rel_err(est, n) < 0.002, "estimate %v for %v", est, n)
}

@(test)
test_hll_converts_to_dense :: proc(t: ^testing.T) {
	h, _ := bloom.hll_make(10)
	defer bloom.hll_destroy(&h)
	for i in 0 ..< 10_000 {
		k := key(i)
		bloom.hll_add(&h, k[:])
	}
	testing.expect(t, !bloom.hll_is_sparse(&h))
	testing.expect_value(t, len(h.registers), 1024)
}

@(test)
test_hll_error_within_bound_across_range :: proc(t: ^testing.T) {
	// Average the squared relative error over independent seeds and check it
	// against the theoretical standard error 1.04/sqrt(m), with slack.
	cardinalities := [?]int{100, 1_000, 10_000, 100_000, 400_000}
	trials := 8
	for n in cardinalities {
		sum_sq := 0.0
		std := 0.0
		for trial in 0 ..< trials {
			h, _ := bloom.hll_make(12, seed = u64(trial) * 7919 + 1)
			defer bloom.hll_destroy(&h)
			std = bloom.hll_standard_error(&h)
			for i in 0 ..< n {
				bloom.hll_add_hash(&h, item_hash(i, h.seed))
			}
			e := rel_err(bloom.hll_estimate(&h), n)
			testing.expectf(t, e < 5 * std, "n=%v trial=%v error %v", n, trial, e)
			sum_sq += e * e
		}
		rmse := math.sqrt(sum_sq / f64(trials))
		testing.expectf(t, rmse < 2 * std, "n=%v rmse %v exceeds 2x standard error %v", n, rmse, std)
	}
}

@(test)
test_hll_insertion_order_does_not_matter :: proc(t: ^testing.T) {
	a, _ := bloom.hll_make(8)
	defer bloom.hll_destroy(&a)
	b, _ := bloom.hll_make(8)
	defer bloom.hll_destroy(&b)
	n := 5000
	for i in 0 ..< n {
		k := key(i)
		bloom.hll_add(&a, k[:])
		k = key(n - 1 - i)
		bloom.hll_add(&b, k[:])
	}
	testing.expect(t, slice.equal(a.registers, b.registers))
}

@(test)
test_hll_sparse_conversion_matches_dense_insertion :: proc(t: ^testing.T) {
	// A sketch that converted from sparse must hold the same registers as a
	// sketch that saw the same items only after it was dense.
	a, _ := bloom.hll_make(10)
	defer bloom.hll_destroy(&a)
	b, _ := bloom.hll_make(10)
	defer bloom.hll_destroy(&b)
	for i in 1_000_000 ..< 1_002_000 {
		k := key(i)
		bloom.hll_add(&b, k[:])
	}
	testing.expect(t, !bloom.hll_is_sparse(&b))
	for i in 0 ..< 200 {
		k := key(i)
		bloom.hll_add(&a, k[:])
		bloom.hll_add(&b, k[:])
	}
	testing.expect(t, bloom.hll_is_sparse(&a))
	for i in 1_000_000 ..< 1_002_000 {
		k := key(i)
		bloom.hll_add(&a, k[:])
	}
	testing.expect(t, slice.equal(a.registers, b.registers))
}

@(test)
test_hll_merge_estimates_union :: proc(t: ^testing.T) {
	a, _ := bloom.hll_make(12)
	defer bloom.hll_destroy(&a)
	b, _ := bloom.hll_make(12)
	defer bloom.hll_destroy(&b)
	for i in 0 ..< 60_000 {
		bloom.hll_add_hash(&a, item_hash(i))
	}
	for i in 30_000 ..< 90_000 {
		bloom.hll_add_hash(&b, item_hash(i))
	}
	testing.expect_value(t, bloom.hll_merge(&a, &b), nil)
	est := bloom.hll_estimate(&a)
	testing.expectf(t, rel_err(est, 90_000) < 5 * bloom.hll_standard_error(&a), "union estimate %v", est)
}

@(test)
test_hll_merge_sparse_into_sparse :: proc(t: ^testing.T) {
	a, _ := bloom.hll_make(14)
	defer bloom.hll_destroy(&a)
	b, _ := bloom.hll_make(14)
	defer bloom.hll_destroy(&b)
	for i in 0 ..< 100 {
		bloom.hll_add_hash(&a, item_hash(i))
		bloom.hll_add_hash(&b, item_hash(i + 50))
	}
	testing.expect_value(t, bloom.hll_merge(&a, &b), nil)
	testing.expect(t, bloom.hll_is_sparse(&a))
	testing.expect_value(t, bloom.hll_cardinality(&a), 150)
}

@(test)
test_hll_merge_dense_into_sparse :: proc(t: ^testing.T) {
	a, _ := bloom.hll_make(8)
	defer bloom.hll_destroy(&a)
	b, _ := bloom.hll_make(8)
	defer bloom.hll_destroy(&b)
	bloom.hll_add(&a, "only in a")
	for i in 0 ..< 5000 {
		bloom.hll_add_hash(&b, item_hash(i))
	}
	testing.expect_value(t, bloom.hll_merge(&a, &b), nil)
	testing.expect(t, !bloom.hll_is_sparse(&a))
	est := bloom.hll_estimate(&a)
	testing.expectf(t, rel_err(est, 5001) < 5 * bloom.hll_standard_error(&a), "estimate %v", est)
}

@(test)
test_hll_merge_rejects_incompatible :: proc(t: ^testing.T) {
	a, _ := bloom.hll_make(12)
	defer bloom.hll_destroy(&a)
	b, _ := bloom.hll_make(13)
	defer bloom.hll_destroy(&b)
	c, _ := bloom.hll_make(12, seed = 3)
	defer bloom.hll_destroy(&c)
	want := bloom.Error(bloom.Usage_Error.Incompatible)
	testing.expect_value(t, bloom.hll_merge(&a, &b), want)
	testing.expect_value(t, bloom.hll_merge(&a, &c), want)
}

@(test)
test_hll_clear_returns_to_sparse :: proc(t: ^testing.T) {
	h, _ := bloom.hll_make(6)
	defer bloom.hll_destroy(&h)
	for i in 0 ..< 1000 {
		bloom.hll_add_hash(&h, item_hash(i))
	}
	testing.expect(t, !bloom.hll_is_sparse(&h))
	bloom.hll_clear(&h)
	testing.expect(t, bloom.hll_is_sparse(&h))
	testing.expect_value(t, bloom.hll_cardinality(&h), 0)
}

@(test)
test_hll_clone_is_independent :: proc(t: ^testing.T) {
	h, _ := bloom.hll_make(6)
	defer bloom.hll_destroy(&h)
	for i in 0 ..< 1000 {
		bloom.hll_add_hash(&h, item_hash(i))
	}
	c, err := bloom.hll_clone(&h)
	testing.expect_value(t, err, nil)
	defer bloom.hll_destroy(&c)
	testing.expect_value(t, bloom.hll_estimate(&c), bloom.hll_estimate(&h))
	for i in 1000 ..< 5000 {
		bloom.hll_add_hash(&c, item_hash(i))
	}
	testing.expect(t, bloom.hll_estimate(&c) > bloom.hll_estimate(&h))
}

@(test)
test_hll_serialize_round_trip_sparse_and_dense :: proc(t: ^testing.T) {
	sizes := [?]int{10, 50_000}
	for n in sizes {
		h, _ := bloom.hll_make(12)
		defer bloom.hll_destroy(&h)
		for i in 0 ..< n {
			bloom.hll_add_hash(&h, item_hash(i))
		}
		data, err := bloom.hll_serialize(&h)
		testing.expect_value(t, err, nil)
		defer delete(data)
		g, derr := bloom.hll_deserialize(data)
		testing.expect_value(t, derr, nil)
		defer bloom.hll_destroy(&g)
		testing.expect_value(t, bloom.hll_is_sparse(&g), bloom.hll_is_sparse(&h))
		testing.expect_value(t, bloom.hll_estimate(&g), bloom.hll_estimate(&h))
	}
}

@(test)
test_hll_deserialize_rejects_unsorted_sparse :: proc(t: ^testing.T) {
	h, _ := bloom.hll_make(12)
	defer bloom.hll_destroy(&h)
	bloom.hll_add(&h, "a")
	bloom.hll_add(&h, "b")
	data, _ := bloom.hll_serialize(&h)
	defer delete(data)
	// Swap the two 4-byte entries that sit just before the checksum.
	n := len(data)
	for i in 0 ..< 4 {
		data[n - 12 + i], data[n - 8 + i] = data[n - 8 + i], data[n - 12 + i]
	}
	reseal(data)
	_, err := bloom.hll_deserialize(data)
	testing.expect_value(t, err, bloom.Error(bloom.Decode_Error.Corrupt))
}

@(test)
test_hll_deserialize_rejects_oversized_register :: proc(t: ^testing.T) {
	h, _ := bloom.hll_make(4)
	defer bloom.hll_destroy(&h)
	for i in 0 ..< 100 {
		bloom.hll_add_hash(&h, item_hash(i))
	}
	testing.expect(t, !bloom.hll_is_sparse(&h))
	data, _ := bloom.hll_serialize(&h)
	defer delete(data)
	data[len(data) - 5] = 200
	reseal(data)
	_, err := bloom.hll_deserialize(data)
	testing.expect_value(t, err, bloom.Error(bloom.Decode_Error.Corrupt))
}

@(test)
test_hll_sparse_conversion_matches_reference_registers :: proc(t: ^testing.T) {
	// Recompute every register from the hashes and compare, at every
	// precision, including hashes whose tails are all zeros.
	for p in bloom.MIN_PRECISION ..= bloom.MAX_PRECISION {
		h, _ := bloom.hll_make(p)
		defer bloom.hll_destroy(&h)
		pu := uint(p)
		want := make([]u8, 1 << pu)
		defer delete(want)
		edge := [?]u64{0, 1, max(u64), 1 << 38, 1 << 39, 1 << 40, u64(1) << (63 - pu)}
		for i in 0 ..< len(want) + len(edge) {
			x := i < len(edge) ? edge[i] : item_hash(i)
			testing.expect_value(t, bloom.hll_add_hash(&h, x), nil)
			index := x >> (64 - pu)
			rho := u8(min(uint(intrinsics.count_leading_zeros(x << pu)) + 1, 65 - pu))
			want[index] = max(want[index], rho)
		}
		testing.expect(t, !bloom.hll_is_sparse(&h))
		testing.expectf(t, slice.equal(h.registers, want), "precision %v registers differ", p)
	}
}
