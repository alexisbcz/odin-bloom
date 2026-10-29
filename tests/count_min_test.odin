package bloom_tests

import bloom ".."
import "core:math"
import "core:testing"

@(test)
test_count_min_dimensions_from_epsilon_delta :: proc(t: ^testing.T) {
	c, err := bloom.count_min_make(0.01, 0.01)
	testing.expect_value(t, err, nil)
	defer bloom.count_min_destroy(&c)
	// ceil(e / 0.01) = 272 and ceil(ln(100)) = 5.
	testing.expect_value(t, c.width, 272)
	testing.expect_value(t, c.depth, 5)
}

@(test)
test_count_min_rejects_invalid_parameters :: proc(t: ^testing.T) {
	want := bloom.Error(bloom.Usage_Error.Invalid_Parameter)
	_, err := bloom.count_min_make(0, 0.1)
	testing.expect_value(t, err, want)
	_, err = bloom.count_min_make(0.1, 1)
	testing.expect_value(t, err, want)
	_, err = bloom.count_min_make(math.nan_f64(), 0.1)
	testing.expect_value(t, err, want)
	_, err = bloom.count_min_make_exact(0, 3)
	testing.expect_value(t, err, want)
	_, err = bloom.count_min_make_exact(1 << 31, 4)
	testing.expect_value(t, err, want)
}

@(test)
test_count_min_counts_exactly_without_collisions :: proc(t: ^testing.T) {
	c, _ := bloom.count_min_make(0.001, 0.001)
	defer bloom.count_min_destroy(&c)
	bloom.count_min_add(&c, "a", 3)
	bloom.count_min_add(&c, "b")
	bloom.count_min_add(&c, "a")
	testing.expect_value(t, bloom.count_min_estimate(&c, "a"), 4)
	testing.expect_value(t, bloom.count_min_estimate(&c, "b"), 1)
	testing.expect_value(t, bloom.count_min_estimate(&c, "c"), 0)
	testing.expect_value(t, bloom.count_min_total(&c), 5)
}

@(test)
test_count_min_never_underestimates :: proc(t: ^testing.T) {
	c, _ := bloom.count_min_make_exact(64, 3)
	defer bloom.count_min_destroy(&c)
	for i in 0 ..< 2000 {
		k := key(i)
		bloom.count_min_add(&c, k[:], u64(i % 7 + 1))
	}
	for i in 0 ..< 2000 {
		k := key(i)
		testing.expect(t, bloom.count_min_estimate(&c, k[:]) >= u64(i % 7 + 1))
	}
}

@(test)
test_count_min_error_bound_holds_with_probability :: proc(t: ^testing.T) {
	epsilon, delta := 0.001, 0.01
	c, _ := bloom.count_min_make(epsilon, delta)
	defer bloom.count_min_destroy(&c)
	// A skewed stream: item i appears (i % 50) + 1 times.
	n_items := 20_000
	for i in 0 ..< n_items {
		bloom.count_min_add_hash(&c, item_hash(i), u64(i % 50 + 1))
	}
	bound := epsilon * f64(bloom.count_min_total(&c))
	testing.expect(t, bloom.count_min_error_bound(&c) <= bound)
	violations := 0
	for i in 0 ..< n_items {
		over := f64(bloom.count_min_estimate_hash(&c, item_hash(i)) - u64(i % 50 + 1))
		if over > bound {
			violations += 1
		}
	}
	// Each query fails with probability at most delta; allow sampling noise.
	testing.expectf(t, f64(violations) / f64(n_items) <= delta * 1.5, "%v violations", violations)
}

@(test)
test_count_min_saturates_instead_of_wrapping :: proc(t: ^testing.T) {
	c, _ := bloom.count_min_make_exact(8, 2)
	defer bloom.count_min_destroy(&c)
	bloom.count_min_add(&c, "x", max(u64) - 1)
	bloom.count_min_add(&c, "x", 10)
	testing.expect_value(t, bloom.count_min_estimate(&c, "x"), max(u64))
	testing.expect_value(t, bloom.count_min_total(&c), max(u64))
}

@(test)
test_count_min_merge_adds_streams :: proc(t: ^testing.T) {
	a, _ := bloom.count_min_make(0.01, 0.01)
	defer bloom.count_min_destroy(&a)
	b, _ := bloom.count_min_make(0.01, 0.01)
	defer bloom.count_min_destroy(&b)
	bloom.count_min_add(&a, "k", 2)
	bloom.count_min_add(&b, "k", 5)
	testing.expect_value(t, bloom.count_min_merge(&a, &b), nil)
	testing.expect_value(t, bloom.count_min_estimate(&a, "k"), 7)
	testing.expect_value(t, bloom.count_min_total(&a), 7)

	c, _ := bloom.count_min_make(0.02, 0.01)
	defer bloom.count_min_destroy(&c)
	testing.expect_value(t, bloom.count_min_merge(&a, &c), bloom.Error(bloom.Usage_Error.Incompatible))
}

@(test)
test_count_min_clear_resets :: proc(t: ^testing.T) {
	c, _ := bloom.count_min_make(0.01, 0.01)
	defer bloom.count_min_destroy(&c)
	bloom.count_min_add(&c, "k", 9)
	bloom.count_min_clear(&c)
	testing.expect_value(t, bloom.count_min_estimate(&c, "k"), 0)
	testing.expect_value(t, bloom.count_min_total(&c), 0)
}

@(test)
test_count_min_serialize_round_trip :: proc(t: ^testing.T) {
	c, _ := bloom.count_min_make(0.01, 0.05, seed = 11)
	defer bloom.count_min_destroy(&c)
	for i in 0 ..< 1000 {
		bloom.count_min_add_hash(&c, item_hash(i, c.seed), u64(i))
	}
	data, err := bloom.count_min_serialize(&c)
	testing.expect_value(t, err, nil)
	defer delete(data)
	g, derr := bloom.count_min_deserialize(data)
	testing.expect_value(t, derr, nil)
	defer bloom.count_min_destroy(&g)
	testing.expect_value(t, bloom.count_min_total(&g), bloom.count_min_total(&c))
	for i in 0 ..< 1000 {
		h := item_hash(i, c.seed)
		testing.expect_value(t, bloom.count_min_estimate_hash(&g, h), bloom.count_min_estimate_hash(&c, h))
	}
}
