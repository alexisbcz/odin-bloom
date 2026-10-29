// Example basic tours every bloom structure. Run it with `odin run examples/basic`.
package main

import bloom "../.."
import "core:fmt"
import "core:os"

main :: proc() {
	// A Bloom filter for 10k items at a 1% false positive rate.
	seen, err := bloom.filter_make(10_000, 0.01)
	if err != nil {
		fmt.eprintln("filter_make failed:", err)
		os.exit(1)
	}
	defer bloom.filter_destroy(&seen)

	bloom.filter_add(&seen, "alice@example.com")
	fmt.println("alice seen:", bloom.filter_contains(&seen, "alice@example.com"))
	fmt.println("bob seen:  ", bloom.filter_contains(&seen, "bob@example.com"))
	fmt.printfln("filter: %v bits, %v hashes", seen.bit_count, seen.hash_count)

	// Serialize, then load it back.
	data, serr := bloom.filter_serialize(&seen)
	if serr != nil {
		fmt.eprintln("filter_serialize failed:", serr)
		os.exit(1)
	}
	defer delete(data)
	loaded, lerr := bloom.filter_deserialize(data)
	if lerr != nil {
		fmt.eprintln("filter_deserialize failed:", lerr)
		os.exit(1)
	}
	defer bloom.filter_destroy(&loaded)
	fmt.println("loaded has alice:", bloom.filter_contains(&loaded, "alice@example.com"))

	// A cuckoo filter supports removal.
	sessions, _ := bloom.cuckoo_filter_make(1000)
	defer bloom.cuckoo_filter_destroy(&sessions)
	_ = bloom.cuckoo_filter_add(&sessions, "session-42")
	_ = bloom.cuckoo_filter_remove(&sessions, "session-42")
	fmt.println("session-42 active:", bloom.cuckoo_filter_contains(&sessions, "session-42"))

	// HyperLogLog++ counts distinct visitors in about 16 KiB.
	visitors, _ := bloom.hll_make(14)
	defer bloom.hll_destroy(&visitors)
	for i in 0 ..< 250_000 {
		id := transmute([8]u8)u64(i % 100_000)
		_ = bloom.hll_add(&visitors, id[:])
	}
	fmt.printfln("distinct visitors: about %v (true 100000)", bloom.hll_cardinality(&visitors))

	// Count-Min estimates frequencies within 0.1% of the total, 99% of the time.
	words, _ := bloom.count_min_make(0.001, 0.01)
	defer bloom.count_min_destroy(&words)
	for word in ([?]string{"odin", "go", "odin", "swift", "odin"}) {
		bloom.count_min_add(&words, word)
	}
	fmt.println("odin count:", bloom.count_min_estimate(&words, "odin"))
}
