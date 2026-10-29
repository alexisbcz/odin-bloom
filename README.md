# odin-bloom

[![CI](https://github.com/alexisbcz/odin-bloom/actions/workflows/ci.yml/badge.svg)](https://github.com/alexisbcz/odin-bloom/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--09-1e5a99.svg)](https://odin-lang.org)

Probabilistic data structures for Odin: Bloom, counting Bloom and cuckoo filters for membership, HyperLogLog++ for distinct counts, and Count-Min for frequencies, all mergeable and serializable.

## Install

The repository root is the package, so you can vendor it in two ways.

As a Git submodule inside your project:

```sh
git submodule add https://github.com/alexisbcz/odin-bloom libs/bloom
```

```odin
import "libs/bloom"
```

As a copy in a shared collection that all your projects use:

```sh
git clone https://github.com/alexisbcz/odin-bloom ~/odin-shared/bloom
odin build . -collection:shared=$HOME/odin-shared
```

```odin
import "shared:bloom"
```

## Quick start

```odin
package main

import "core:fmt"
import "shared:bloom"

main :: proc() {
	seen, err := bloom.filter_make(10_000, 0.01)
	if err != nil {
		fmt.eprintln("filter_make failed:", err)
		return
	}
	defer bloom.filter_destroy(&seen)

	bloom.filter_add(&seen, "alice@example.com")
	fmt.println(bloom.filter_contains(&seen, "alice@example.com")) // true
	fmt.println(bloom.filter_contains(&seen, "bob@example.com"))   // false, 99% of the time

	visitors, _ := bloom.hll_make(14)
	defer bloom.hll_destroy(&visitors)
	for i in 0 ..< 250_000 {
		id := transmute([8]u8)u64(i % 100_000)
		_ = bloom.hll_add(&visitors, id[:])
	}
	fmt.println(bloom.hll_cardinality(&visitors)) // about 100000
}
```

## Choosing a structure

| Question | Structure | Error | Memory |
| --- | --- | --- | --- |
| Have I seen this item? | `Filter` | False positives at the rate you pick | About 9.6 bits per item at 1% |
| Same, but items can leave | `Counting_Filter` | Same as `Filter` | 8 times a `Filter` |
| Same, with removal and a low false positive rate | `Cuckoo_Filter` | About 0.012% false positives | 16 bits per slot, 95% load |
| How many distinct items? | `Hll` | About `1.04 / sqrt(2^precision)` relative error | `2^precision` bytes, less while sparse |
| How often did this item occur? | `Count_Min` | Over-counts by at most `epsilon * total` with probability `1 - delta` | `e / epsilon * ln(1 / delta)` 64-bit counters |

## API overview

Every structure follows the same shape. The table uses `Filter`; swap the prefix for `counting_filter_`, `cuckoo_filter_`, `hll_` or `count_min_`.

| Declaration | Purpose | Allocates | Free with |
| --- | --- | --- | --- |
| `filter_make(n, p, seed, allocator)` | Size from expected items and a false positive rate | Yes | `filter_destroy` |
| `filter_make_exact(bits, hashes, seed, allocator)` | Pick the dimensions yourself | Yes | `filter_destroy` |
| `filter_add(f, item)` | Add a `string` or `[]byte` | No | Not needed |
| `filter_contains(f, item)` | Test membership | No | Not needed |
| `filter_add_hash(f, h)` | Add an item hashed with `hash_bytes` | No | Not needed |
| `filter_merge(dst, src)` | Union of two compatible filters | No | Not needed |
| `filter_serialize(f, allocator)` | Encode to bytes | Yes | `delete` |
| `filter_deserialize(data, allocator)` | Decode and verify bytes | Yes | `filter_destroy` |
| `optimal_bit_count(n, p)`, `optimal_hash_count(n, m)` | Sizing formulas | No | Not needed |
| `Error` | Union of `Usage_Error`, `Decode_Error` and `runtime.Allocator_Error` | No | Not needed |

Other procedures:

- `filter_intersect`, `filter_estimate_count`, `filter_fill_ratio`, `filter_current_fp_rate`, `filter_clone` and `filter_clear`.
- `counting_filter_remove`, `counting_filter_count` and `counting_filter_to_filter`.
- `cuckoo_filter_remove`, `cuckoo_filter_count` and `cuckoo_filter_load_factor`.
- `hll_estimate`, `hll_cardinality`, `hll_is_sparse`, `hll_standard_error` and `hll_clone`.
- `count_min_estimate`, `count_min_total` and `count_min_error_bound`.

## Examples

Each directory under `examples/` is a runnable program:

```sh
odin run examples/basic
```

## Design notes

- Items hash once with XXH64, so the `*_add_hash` procedures let you hash an item once and feed several structures that share a seed. Bloom filters derive their positions from that hash by Kirsch and Mitzenmacher double hashing. `Count_Min` gives each row its own SplitMix64 output instead, because its `delta` bound needs rows that act as independent hash functions.
- `Hll` follows HyperLogLog++: 64-bit hashes, a sorted sparse list with 25-bit indices for small sets, and dense 8-bit registers once the list would outgrow them. Dense estimates use Ertl's improved estimator, which needs no empirical bias tables and stays unbiased across the whole range.
- `Cuckoo_Filter` keeps the last homeless fingerprint in a one-entry stash, so a failed insert never drops an item that the filter already held. The next insert reports `.Full`.
- Counters saturate instead of wrapping: at 255 in `Counting_Filter`, at the largest `u64` in `Count_Min`.
- The binary format starts with the `OBLM` magic, a version byte and a kind byte, stores integers in little-endian order and ends with a CRC-32. Decoding checks every field and reports a `Decode_Error` instead of trusting the input.
- Every allocating procedure takes `allocator := context.allocator` and says who owns the result. Fallible procedures return `(T, Error)`, and the library never panics on bad input.
- The package keeps no global mutable state, so it's safe to use from several threads as long as each value stays on one thread.

## Testing

```sh
odin check . -vet -strict-style -disallow-do -no-entry-point
odin test tests -vet -strict-style -disallow-do
vale sync && vale *.md
```

The tests include statistical checks that compare observed false positive rates, HyperLogLog++ error across five cardinalities and Count-Min bound violations against their theoretical limits.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Commits follow Conventional Commits, and every change that users can see gets a line in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
