// Run from the repository root; this measures checking, including all summary
// revisits. It does not emit LLVM or execute benchmark programs.
package main

import lokec "../../src"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:time"

Record :: struct {
	program: string,
	repeat: int,
	check_ms: f64,
	body_builds, replay_passes: int,
	normalization_ms, replay_ms, materialization_ms: f64,
	peak_build_used_bytes: uint,
}

measure :: proc(input: string) -> (Record, bool) {
	session: lokec.Compilation_Session
	defer lokec.destroy_session(&session)
	config := lokec.DEFAULT_COMPILATION_CONFIG
	config.collections = []string{"base=base", "core=core"}
	if !lokec.init_session(&session, config) { return {}, false }
	started := time.tick_now()
	if !lokec.check_session(&session, input) { return {}, false }
	elapsed := time.tick_since(started)
	stats := session.compiler.provenance_stats
	return Record{
		program = input, repeat = 3, check_ms = f64(elapsed) / 1e6,
		body_builds = stats.body_builds, replay_passes = stats.replay_passes,
		normalization_ms = f64(stats.normalization_time) / 1e6,
		replay_ms = f64(stats.replay_time) / 1e6,
		materialization_ms = f64(stats.materialization_time) / 1e6,
		peak_build_used_bytes = stats.peak_build_bytes,
	}, true
}

main :: proc() {
	inputs := os.args[1:]
	if len(inputs) == 0 {
		inputs = []string{"bench/provenance.loke", "bench/workspace", "examples/corpus_runner.loke"}
	}
	results := make([dynamic]Record)
	defer delete(results)
	for input in inputs {
		best: Record
		for iteration in 0 ..< 3 {
			current, ok := measure(input)
			if !ok { fmt.eprintf("checking %s failed\n", input); os.exit(1) }
			if iteration == 0 || current.check_ms < best.check_ms { best = current }
		}
		append(&results, best)
	}
	encoded, err := json.marshal(results[:], {pretty = true, use_spaces = true, spaces = 2})
	if err != nil { fmt.eprintf("encoding measurements failed: %v\n", err); os.exit(1) }
	defer delete(encoded)
	fmt.println(string(encoded))
}
