// The checker mutation fuzzer. Every tests/run program is valid, so a small
// edit that stays lexically plausible (another name from the same file, another
// number or operator, a duplicated or deleted line) mostly gets past the parser
// and into the checker. For each mutant, `lokec -emit-ll` must finish within
// FUZZ_TIMEOUT, exit 0 or 1 (anything else is a crash or a backend failure),
// report no internal contract violation, never repeat one diagnostic at one
// location, and report no more errors than the mutant has lines.
//
// A failing mutant is reduced line by line and kept in tests/tmp/fuzz/; the
// failure message prints it, so a CI failure can be turned into a regression
// test without rerunning. LOKE_FUZZ_SEED and LOKE_FUZZ_MUTANTS (per program)
// explore beyond the fixed run.
//
// It costs a compile per mutant, over a minute in all, so it runs only when
// LOKE_TEST_FULL is set, as `test-all.ps1 -Full` and CI do.
package tests

import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
FUZZ_DIR :: TMP + "/fuzz"
@(private = "file")
FUZZ_TIMEOUT :: 30 * time.Second
// A reduction attempt costs a compile; a hang costs FUZZ_TIMEOUT per attempt.
@(private = "file")
REDUCE_BUDGET :: 300
@(private = "file")
REDUCE_BUDGET_HANG :: 4

@(private = "file")
Fuzz_Failure :: enum {
	None,
	Crash,
	Hang,
	Internal,
	Repeated,
	Cascade,
}

@(test)
checker_mutation_fuzzing :: proc(t: ^testing.T) {
	if os.get_env("LOKE_TEST_FULL", context.temp_allocator) == "" {
		log.info("LOKE_TEST_FULL is not set; skipping the mutation fuzzer")
		return
	}
	os.make_directory(TMP)
	os.make_directory(FUZZ_DIR)
	base := env_u64("LOKE_FUZZ_SEED", 0x2545f4914f6cdd1d)
	mutants := int(env_u64("LOKE_FUZZ_MUTANTS", 3))
	cases, _ := filepath.glob("tests/run/*.loke")
	testing.expect(t, len(cases) > 0, "no run cases to mutate")

	total, reached, clean := 0, 0, 0
	for path in cases {
		defer free_all(context.temp_allocator)
		data, data_err := os.read_entire_file(path, context.temp_allocator)
		if !testing.expectf(t, data_err == nil, "%s: cannot read", path) {
			continue
		}
		flags := extra_flags(path)
		// Seeded per program, so a new run case changes only its own mutants.
		state := base ~ hash.fnv64a(transmute([]byte)filepath.base(path))
		for _ in 0 ..< mutants {
			seed := state
			mutant := mutate_source(string(data), &state)
			failure, detail, checked, exit_code := fuzz_compile(mutant, flags)
			total += 1
			reached += checked ? 1 : 0
			clean += exit_code == 0 ? 1 : 0
			if failure == .None {
				continue
			}
			reduced := reduce_source(mutant, flags, failure)
			kept := fmt.tprintf("%s/%s-%d.loke", FUZZ_DIR, filepath.stem(path), seed)
			_ = os.write_entire_file(kept, transmute([]byte)reduced)
			testing.expectf(t, false, "%s, mutant seed %d: %v (%s); reduced to %s:\n%s",
			                path, seed, failure, detail, kept, reduced)
		}
	}
	// Mutants the parser rejects never test the checker; a drop here means the
	// mutations need retuning, not that the checker got better.
	log.infof("%d mutants: %d reached the checker, %d checked clean", total, reached, clean)
	testing.expectf(t, reached * 2 > total, "only %d of %d mutants reached the checker", reached, total)
}

// One `lokec -emit-ll` run of `source`, judged. `checked` is whether it got
// past the parser: it compiled, or reported something other than a lexer or
// parser diagnostic (L00xx-L02xx).
@(private = "file")
fuzz_compile :: proc(source: string, flags: []string) -> (failure: Fuzz_Failure, detail: string, checked: bool, exit_code: int) {
	input := FUZZ_DIR + "/mutant.loke"
	_ = os.write_entire_file(input, transmute([]byte)source)
	command := make([dynamic]string, context.temp_allocator)
	append(&command, compiler_path(), input, "-emit-ll", "-o", FUZZ_DIR + "/mutant.exe")
	append(&command, ..flags)

	// A pipe rather than a file: Windows hands the child only inheritable
	// handles, and `os.pipe` is the one that makes them. It is drained while
	// the compiler runs, so a long report cannot fill it and stall the child.
	errors_r, errors_w, pipe_err := os.pipe()
	if pipe_err != nil {
		return .Crash, "cannot create a pipe", false, -1
	}
	defer _ = os.close(errors_r)
	process, start_err := os.process_start({command = command[:], stderr = errors_w})
	_ = os.close(errors_w)
	if start_err != nil {
		return .Crash, "cannot start lokec", false, -1
	}

	stderr := make([dynamic]byte, context.temp_allocator)
	buf: [4096]byte
	started := time.tick_now()
	for {
		exited_state, wait_err := os.process_wait(process, 0)
		for {
			has_data, _ := os.pipe_has_data(errors_r)
			if !has_data { break }
			n, read_err := os.read(errors_r, buf[:])
			append(&stderr, ..buf[:n])
			if read_err != nil { break }
		}
		if wait_err == nil {
			failure, detail, checked = judge(string(stderr[:]), exited_state.exit_code, source)
			return failure, detail, checked, exited_state.exit_code
		}
		// Any failure but a timeout has already released the process.
		if wait_err != os.General_Error.Timeout {
			return .Crash, fmt.tprintf("cannot wait for lokec: %v", wait_err), false, -1
		}
		if time.tick_since(started) > FUZZ_TIMEOUT {
			_ = os.process_kill(process)
			_, _ = os.process_wait(process)
			return .Hang, fmt.tprintf("no exit within %v", FUZZ_TIMEOUT), false, -1
		}
		time.sleep(time.Millisecond)
	}
}

@(private = "file")
judge :: proc(stderr: string, exit_code: int, source: string) -> (failure: Fuzz_Failure, detail: string, checked: bool) {
	checked = true
	lines := strings.split_lines(stderr, context.temp_allocator)
	seen := make(map[string]bool, allocator = context.temp_allocator)
	errors := 0
	for line, i in lines {
		if !strings.has_prefix(line, "error[") || len(line) < len("error[L0000]") {
			continue
		}
		errors += 1
		code := line[len("error["):][:5]
		if code < "L0300" {
			checked = false
		}
		if code == "L0405" {
			return .Internal, line, checked
		}
		// The whole report, notes included: an error inside a static `foreach`
		// is reported once per expansion, and its note names which one.
		end := i + 1
		for end < len(lines) && !strings.has_prefix(lines[end], "error[") && !strings.has_prefix(lines[end], "warning[") {
			end += 1
		}
		key := strings.join(lines[i:end], "\n", context.temp_allocator)
		if seen[key] {
			location := i + 1 < len(lines) ? strings.trim_space(lines[i + 1]) : ""
			return .Repeated, fmt.tprintf("%s %s", line, location), checked
		}
		seen[key] = true
	}
	if exit_code != 0 && exit_code != 1 {
		return .Crash, fmt.tprintf("exit code %d: %s", exit_code, strings.trim_space(stderr)), checked
	}
	if limit := strings.count(source, "\n") + 1; errors > limit {
		return .Cascade, fmt.tprintf("%d errors for %d lines", errors, limit), checked
	}
	return .None, "", checked
}

// Greedy line deletion: drop the largest chunks that keep the same failure,
// then smaller ones.
@(private = "file")
reduce_source :: proc(source: string, flags: []string, failure: Fuzz_Failure) -> string {
	current := strings.split_lines(source, context.temp_allocator)
	budget := failure == .Hang ? REDUCE_BUDGET_HANG : REDUCE_BUDGET
	chunk := max(len(current) / 2, 1)
	for budget > 0 {
		removed := false
		for start := 0; start < len(current) && budget > 0; {
			end := min(start + chunk, len(current))
			candidate := make([dynamic]string, 0, len(current), context.temp_allocator)
			append(&candidate, ..current[:start])
			append(&candidate, ..current[end:])
			budget -= 1
			if again, _, _, _ := fuzz_compile(strings.join(candidate[:], "\n", context.temp_allocator), flags); again == failure {
				current = candidate[:]
				removed = true
			} else {
				start = end
			}
		}
		if !removed {
			if chunk == 1 {
				break
			}
			chunk /= 2
		}
	}
	return strings.join(current, "\n", context.temp_allocator)
}

// ---------------------------------------------------------------- mutation --

@(private = "file")
Fuzz_Token_Kind :: enum {
	Name,
	Number,
	Operator,
}

@(private = "file")
Fuzz_Edit :: struct {
	lo, hi: int,
	text:   string,
}

@(private = "file")
KEYWORDS :: [?]string {
	"break", "case", "continue", "default", "defer", "distinct", "dyn", "dynamic", "else", "enum",
	"for", "foreach", "foreign", "hook", "if", "impl", "import", "in", "inout",
	"interface", "map", "move", "move_only", "mut", "operator", "or_else", "or_return",
	"package", "proc", "return", "struct", "switch", "type", "union", "via", "when", "where",
}

@(private = "file")
NUMBERS :: [?]string{"0", "1", "-1", "255", "256", "65536", "9223372036854775807", "18446744073709551616", "0.5"}

@(private = "file")
OPERATORS :: "+-*/%<>"

// One or two edits, applied back to front so earlier offsets stay valid.
@(private = "file")
mutate_source :: proc(text: string, state: ^u64) -> string {
	spans: [Fuzz_Token_Kind][dynamic][2]int
	for kind in Fuzz_Token_Kind {
		spans[kind] = make([dynamic][2]int, context.temp_allocator)
	}
	scan_tokens(text, &spans)

	edits := make([dynamic]Fuzz_Edit, context.temp_allocator)
	for _ in 0 ..< 1 + int(next_random(state) % 2) {
		switch next_random(state) % 5 {
		case 0, 1:
			names := spans[.Name][:]
			if len(names) < 2 { continue }
			target := names[next_random(state) % u64(len(names))]
			source := names[next_random(state) % u64(len(names))]
			append(&edits, Fuzz_Edit{target[0], target[1], text[source[0]:source[1]]})
		case 2:
			numbers := spans[.Number][:]
			if len(numbers) == 0 { continue }
			target := numbers[next_random(state) % u64(len(numbers))]
			choices := NUMBERS
			append(&edits, Fuzz_Edit{target[0], target[1], choices[next_random(state) % len(choices)]})
		case 3:
			operators := spans[.Operator][:]
			if len(operators) == 0 { continue }
			target := operators[next_random(state) % u64(len(operators))]
			operator_text := OPERATORS
			at := next_random(state) % len(OPERATORS)
			append(&edits, Fuzz_Edit{target[0], target[1], operator_text[at:at + 1]})
		case:
			// Duplicate or delete the line holding a random offset.
			at := int(next_random(state) % u64(max(len(text), 1)))
			lo := strings.last_index_byte(text[:at], '\n') + 1
			hi := strings.index_byte(text[at:], '\n')
			hi = hi < 0 ? len(text) : at + hi + 1
			line := text[lo:hi]
			append(&edits, Fuzz_Edit{lo, hi, next_random(state) % 2 == 0 ? "" : strings.concatenate({line, line}, context.temp_allocator)})
		}
	}

	out := strings.builder_make(context.temp_allocator)
	written := 0
	for len(edits) > 0 {
		// The earliest remaining edit; an overlapping later one is dropped.
		first := 0
		for edit, i in edits {
			if edit.lo < edits[first].lo { first = i }
		}
		edit := edits[first]
		unordered_remove(&edits, first)
		if edit.lo < written { continue }
		strings.write_string(&out, text[written:edit.lo])
		strings.write_string(&out, edit.text)
		written = edit.hi
	}
	strings.write_string(&out, text[written:])
	return strings.to_string(out)
}

// Names, numbers, and lone single-character operators, skipping comments and
// string, rune, and raw literals so an edit never lands inside one.
@(private = "file")
scan_tokens :: proc(text: string, spans: ^[Fuzz_Token_Kind][dynamic][2]int) {
	is_name :: proc(c: u8) -> bool { return c == '_' || (c | 0x20 >= 'a' && c | 0x20 <= 'z') || (c >= '0' && c <= '9') }
	is_operator :: proc(c: u8) -> bool { return strings.index_byte("+-*/%<>=!&|^~.", c) >= 0 }
	keywords := KEYWORDS
	i := 0
	for i < len(text) {
		c := text[i]
		switch {
		case strings.has_prefix(text[i:], "//"):
			end := strings.index_byte(text[i:], '\n')
			i = end < 0 ? len(text) : i + end
		case strings.has_prefix(text[i:], "/*"):
			end := strings.index(text[i + 2:], "*/")
			i = end < 0 ? len(text) : i + 2 + end + 2
		case c == '"' || c == '\'' || c == '`':
			j := i + 1
			for j < len(text) && text[j] != c {
				j += c != '`' && text[j] == '\\' ? 2 : 1
			}
			i = j + 1
		case c >= '0' && c <= '9':
			j := i
			for j < len(text) && (is_name(text[j]) || (text[j] == '.' && j + 1 < len(text) && text[j + 1] != '.')) {
				j += 1
			}
			append(&spans[.Number], [2]int{i, j})
			i = j
		case is_name(c):
			j := i
			for j < len(text) && is_name(text[j]) {
				j += 1
			}
			keyword := false
			for word in keywords {
				keyword ||= text[i:j] == word
			}
			if !keyword {
				append(&spans[.Name], [2]int{i, j})
			}
			i = j
		case strings.index_byte(OPERATORS, c) >= 0:
			alone := (i == 0 || !is_operator(text[i - 1])) && (i + 1 >= len(text) || !is_operator(text[i + 1]))
			if alone {
				append(&spans[.Operator], [2]int{i, i + 1})
			}
			i += 1
		case:
			i += 1
		}
	}
}

@(private = "file")
next_random :: proc(state: ^u64) -> u64 {
	x := state^
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	state^ = x
	return x
}

@(private = "file")
env_u64 :: proc(name: string, fallback: u64) -> u64 {
	text := os.get_env(name, context.temp_allocator)
	if text == "" {
		return fallback
	}
	value, ok := strconv.parse_u64(text)
	return ok ? value : fallback
}
