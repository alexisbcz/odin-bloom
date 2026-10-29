# Changelog

This file records all notable changes to this project.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-10-29

### Fixed

- `Count_Min` rows now hash independently. With double hashing, two items that collided in two rows collided in every row, so estimates broke the `epsilon * total` bound far more often than `delta` allows: about 1 query in 512 for a 32 by 14 sketch.
- `count_min_make` accepts a subnormal `delta` and rejects an `epsilon` too small to size, on every platform.
- `cuckoo_filter_make` rejects capacities above `MAX_CUCKOO_BUCKETS * BUCKET_SIZE`. Before, a capacity such as `1 << 62` overflowed and returned a filter with one bucket.
- `cuckoo_filter_merge` with the same filter as `dst` and `src` now stores exactly two copies of every item. Before, evictions moved fingerprints under the loop, so some items got three copies and others one.

### Changed

- `FORMAT_VERSION` is now 2. `count_min_deserialize` rejects version 1 input with `.Unsupported_Version`, because its counters use the old layout. The other structures still read version 1.

## [0.1.0] - 2026-10-29

### Added

- `Filter`, a Bloom filter sized with `optimal_bit_count` and `optimal_hash_count`, with union, intersection and a cardinality estimate.
- `Counting_Filter`, a Bloom filter with saturating 8-bit counters that supports removal and conversion to a `Filter`.
- `Cuckoo_Filter` with 4-slot buckets, 16-bit fingerprints, removal and a one-entry stash that keeps every added item.
- `Hll`, HyperLogLog++ with a sparse representation and Ertl's improved estimator.
- `Count_Min`, a Count-Min sketch sized from `epsilon` and `delta` with saturating counters.
- Merge procedures for every structure.
- A binary format with a CRC-32 checksum: `*_serialize` writes it and `*_deserialize` validates it, for every structure.
- `hash_bytes` and `hash_string`, plus `*_add_hash` procedures for precomputed hashes.

[Unreleased]: https://github.com/alexisbcz/odin-bloom/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/alexisbcz/odin-bloom/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alexisbcz/odin-bloom/releases/tag/v0.1.0
