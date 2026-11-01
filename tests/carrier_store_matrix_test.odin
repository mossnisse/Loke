// A matrix of carriers stored through carriers and what is done with them after
// (design.md "Weakening and reborrows"): copies and reorderings of two carrier fields
// or two records holding one, written in a statement or with a temporary, in
// straight-line code, a branch, or a loop, through each place form. Each verdict is
// worked out by hand from the rules, never from the compiler's output: each carrier
// is in one place, a copy suspends what it was copied from until its last use, and a
// store to one place replaces what it held. Every case is one procedure, and a
// compile checks a whole place form at once.
package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
STORE_MATRIX_DIR :: TMP + "/carrier_store_matrix"

@(private = "file")
STORE_MATRIX_PRELUDE :: `package main;
Link :: struct { to: ^mut int }
Pair :: struct { x: Link, y: Link }
flip :: proc() -> bool { return true; }
`

// Where the two records holding a carrier are, as `first` and `second`.
@(private = "file")
Store_Place :: struct {
	name, params, setup, first, second: string,
}

@(private = "file")
STORE_NAMED_ARRAY :: "v0 := 1; v1 := 2; ls := [2]Link{Link{&mut v0}, Link{&mut v1}};"
@(private = "file")
STORE_NAMED_RECORD :: "v0 := 1; v1 := 2; pr := Pair{Link{&mut v0}, Link{&mut v1}};"

@(private = "file")
STORE_PLACES := [?]Store_Place {
	{"view_parameter", "s: []mut Link", "", "s[0]", "s[1]"},
	{"pointer_to_array", "a: ^mut [2]Link", "", "a^[0]", "a^[1]"},
	{"pointer_to_record", "t: ^mut Pair", "", "t^.x", "t^.y"},
	{"view_of_record_fields", "s: []mut Pair", "", "s[0].x", "s[0].y"},
	{"local_view", "", STORE_NAMED_ARRAY + " view := &mut ls[:];", "view[0]", "view[1]"},
	{"named_array", "", STORE_NAMED_ARRAY, "ls[0]", "ls[1]"},
	{"named_record", "", STORE_NAMED_RECORD, "pr.x", "pr.y"},
	{"pointer_to_named", "", STORE_NAMED_RECORD + " p := &mut pr;", "p^.x", "p^.y"},
}

// `$A` and `$B` are the two records, `$a` and `$b` their carriers, and `other` a
// carrier of the procedure's own. `rejected` is what the rules say.
@(private = "file")
Store_Case :: struct {
	name, body: string,
	rejected:   bool,
}

@(private = "file")
STORE_CASES := [?]Store_Case {
	{"swap_temp", "h := $A; $A = $B; $B = h;", false},
	{"swap_temp_then_both_named", "h := $A; $A = $B; $B = h; h.to^ = 3; $B.to^ = 4;", true},
	{"swap_temp_then_each_place", "h := $A; $A = $B; $B = h; $A.to^ = 3; $B.to^ = 4;", false},
	{"swap_temp_copies_of_each", "h := $A; $A = $B; $B = h; x := $a; y := $b; x^ = 1; y^ = 2;", false},
	{"swap_in_a_statement_copies", "$A, $B = $B, $A; x := $a; y := $b; x^ = 1; y^ = 2;", false},
	{"swap_twice_copies", "$A, $B = $B, $A; $A, $B = $B, $A; x := $a; y := $b; x^ = 1; y^ = 2;", false},
	{"swap_fields_temp", "x := $a; $a = $b; $b = x; $a^ = 1; $b^ = 2;", false},
	{"swap_fields_then_both_named", "x := $a; $a = $b; $b = x; x^ = 1; $b^ = 2;", true},
	{"swap_fields_statement", "$a, $b = $b, $a; x := $a; y := $b; x^ = 1; y^ = 2;", false},
	{"copy_whole_copies", "$A = $B; x := $a; y := $b; x^ = 1; y^ = 2;", true},
	{"copy_field_copies", "$a = $b; x := $a; y := $b; x^ = 1; y^ = 2;", true},
	{"copy_whole_in_branch", "if (flip()) { $A = $B; } x := $a; y := $b; x^ = 1; y^ = 2;", true},
	{"copy_field_in_branch", "if (flip()) { $a = $b; } x := $a; y := $b; x^ = 1; y^ = 2;", true},
	{"local_then_store_used_after", "h := $A; $B = h; x := $b; h.to^ = 1; x^ = 2;", true},
	{"local_then_store_copy_done", "h := $A; $B = h; x := $b; x^ = 2; h.to^ = 1;", false},
	{"copy_then_store_then_both", "x := $a; $b = $a; x^ = 1; $b^ = 2;", true},
	{"old_value_kept_past_replacing", "x := $a; $a = $b; x^ = 1;", false},
	{"old_value_and_other_place", "x := $a; $a = $b; x^ = 1; $a^ = 2;", false},
	{"first_reader_then_copy_of_it", "y := $b; $a = $b; y^ = 1; $a^ = 2;", true},
	{"reader_done_before_store", "y := $b; y^ = 1; $A = $B; $a^ = 2;", false},
	{"two_places_one_carrier", "$a, $b = $b, $b; x := $a; y := $b; x^ = 1; y^ = 2;", true},
	{"store_back_and_forth", "$a = $b; $b = $a; x := $a; y := $b; x^ = 1; y^ = 2;", true},
	{"copy_of_a_copy_held", "h := $A; g := h; $A = $B; $B = g; h.to^ = 1; $B.to^ = 2;", true},
	{"copied_then_replaced", "$a = $b; $a = other; x := $a; y := $b; x^ = 1; y^ = 2;", false},
	{"copied_whole_then_replaced", "$A = $B; $A = Link{other}; x := $a; y := $b; x^ = 1; y^ = 2;", false},
	{"carrier_stored_then_used", "$a = other; x := $a; other^ = 1; x^ = 2;", true},
	{"carrier_stored_whole_then_used", "$A = Link{other}; x := $a; other^ = 1; x^ = 2;", true},
	{"carrier_stored_copy_done", "$a = other; x := $a; x^ = 2; other^ = 1;", false},
	{"carrier_stored_replaced", "$a = other; $a = $b; other^ = 1; $a^ = 2;", false},
	{"loop_store_replaces", "for (i := 0; i < 2; i += 1) { $a = other; } x := $a; x^ = 1;", false},
	{"loop_store_then_conflict", "for (i := 0; i < 2; i += 1) { $a = other; } x := $a; other^ = 1; x^ = 2;", true},
	{"loop_swap_temp", "for (i := 0; i < 2; i += 1) { h := $A; $A = $B; $B = h; }", false},
	{"loop_copy_then_copies", "for (i := 0; i < 2; i += 1) { $A = $B; } x := $a; y := $b; x^ = 1; y^ = 2;", true},
	{"loop_store_reaches_read_before_it", "for (i := 0; i < 2; i += 1) { x := $a; x^ = 1; $a = other; other^ = 2; }", true},
	{"branch_swap_temp", "if (flip()) { h := $A; $A = $B; $B = h; } x := $a; y := $b; x^ = 1; y^ = 2;", false},
}

// Where the compiler rejects what the rules accept: known-gaps.md "A swap with a
// temporary is rejected in a branch or a loop", and "Copies out of elements swapped
// with a temporary through a view parameter are rejected". Listed so that closing
// either shows up here.
@(private = "file")
store_case_over_rejected :: proc(place: Store_Place, entry: Store_Case) -> bool {
	if entry.name == "loop_swap_temp" || entry.name == "branch_swap_temp" {
		return true
	}
	return place.name == "view_parameter" && entry.name == "swap_temp_copies_of_each"
}

@(test)
carrier_store_matrix :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	os.make_directory(STORE_MATRIX_DIR)
	jobs := make([dynamic]Exec, context.temp_allocator)
	first_lines := make([dynamic]int, context.temp_allocator)
	for place in STORE_PLACES {
		source := strings.builder_make(context.temp_allocator)
		strings.write_string(&source, STORE_MATRIX_PRELUDE)
		line := strings.count(STORE_MATRIX_PRELUDE, "\n") + 1
		append(&first_lines, line)
		for entry in STORE_CASES {
			text, _ := strings.replace_all(entry.body, "$A", place.first, context.temp_allocator)
			text, _ = strings.replace_all(text, "$B", place.second, context.temp_allocator)
			text, _ = strings.replace_all(text, "$a", fmt.tprintf("%s.to", place.first), context.temp_allocator)
			text, _ = strings.replace_all(text, "$b", fmt.tprintf("%s.to", place.second), context.temp_allocator)
			params := place.params
			if strings.contains(text, "other") {
				params = fmt.tprintf("%s%s@(escape=stored) other: ^mut int", params, params == "" ? "" : ", ")
			}
			// Every case takes up four lines, which the check below counts on.
			fmt.sbprintf(&source, "%s :: proc(%s) {{\n\t%s\n\t%s\n}}\n", entry.name, params, place.setup, text)
			line += 4
		}
		strings.write_string(&source, "main :: proc() {}\n")
		path := fmt.tprintf("%s/%s.loke", STORE_MATRIX_DIR, place.name)
		if !testing.expectf(t, os.write_entire_file(path, transmute([]byte)strings.to_string(source)) == nil, "%s: cannot write", path) {
			return
		}
		command := make([]string, 5, context.temp_allocator)
		command[0], command[1], command[2] = compiler_path(), path, "-emit-ll"
		command[3], command[4] = "-o", fmt.tprintf("%s/%s.exe", STORE_MATRIX_DIR, place.name)
		append(&jobs, Exec{command = command})
	}
	exec_all(jobs[:])
	for place, index in STORE_PLACES {
		job := jobs[index]
		if !testing.expectf(t, job.err == nil, "%s: cannot run lokec: %v", place.name, job.err) {
			continue
		}
		errors := store_matrix_error_lines(string(job.stderr))
		for entry, at in STORE_CASES {
			first := first_lines[index] + 4 * at
			rejected := false
			for line in errors {
				rejected ||= line >= first && line < first + 4
			}
			expected := entry.rejected || store_case_over_rejected(place, entry)
			testing.expectf(
				t, rejected == expected, "%s, %s (line %d): expected %s, got %s",
				place.name, entry.name, first, expected ? "a rejection" : "no error", rejected ? "a rejection" : "no error",
			)
		}
	}
}

// The lines `stderr` reports an error at.
@(private = "file")
store_matrix_error_lines :: proc(stderr: string) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	pending := false
	for text in strings.split_lines(stderr, context.temp_allocator) {
		trimmed := strings.trim_space(text)
		if strings.has_prefix(trimmed, "error[") {
			pending = true
		} else if pending && strings.has_prefix(trimmed, "-->") {
			pending = false
			parts := strings.split(trimmed, ":", context.temp_allocator)
			if len(parts) >= 3 {
				append(&out, parse_int_or_zero(parts[len(parts) - 2]))
			}
		}
	}
	return out[:]
}

@(private = "file")
parse_int_or_zero :: proc(text: string) -> int {
	value := 0
	for digit in text {
		if digit < '0' || digit > '9' {
			return 0
		}
		value = value * 10 + int(digit - '0')
	}
	return value
}
