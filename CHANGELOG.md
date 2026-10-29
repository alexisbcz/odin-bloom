# Changelog

This file records all notable changes to this project.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/alexisbcz/odin-bloom/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/alexisbcz/odin-bloom/releases/tag/v0.1.0
