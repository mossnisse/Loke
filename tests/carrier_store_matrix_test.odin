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
	names := make([dynamic]string, context.temp_allocator)
	sources := make([dynamic]string, context.temp_allocator)
	first_lines := make([dynamic]int, context.temp_allocator)
	for place in STORE_PLACES {
		source := strings.builder_make(context.temp_allocator)
		strings.write_string(&source, STORE_MATRIX_PRELUDE)
		append(&first_lines, strings.count(STORE_MATRIX_PRELUDE, "\n") + 1)
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
		}
		strings.write_string(&source, "main :: proc() {}\n")
		append(&names, place.name)
		append(&sources, strings.to_string(source))
	}
	errors, compiled := store_matrix_compile(t, names[:], sources[:])
	if !compiled {
		return
	}
	for place, index in STORE_PLACES {
		for entry, at in STORE_CASES {
			first := first_lines[index] + 4 * at
			expected := entry.rejected || store_case_over_rejected(place, entry)
			store_matrix_expect(t, place.name, entry.name, first, errors[index], expected)
		}
	}
}

// What a call may leave of a `stored` argument (design.md "Retaining a borrow"): the
// callee may keep it in any mutable destination it is given, so that destination then
// holds a copy of it, as a store by hand leaves one, and a call uses each mutable
// carrier it can reach. Each verdict is worked out by hand as above.
@(private = "file")
STORED_PRELUDE :: `package main;
Link :: struct { to: ^mut int }
Two :: struct { a: ^mut int, b: ^mut int }
flip :: proc() -> bool { return true; }
keep :: proc(dst: ^mut Link, @(escape=stored) c: ^mut int) { dst^.to = c; }
keep_view :: proc(dst: []mut Link, @(escape=stored) c: ^mut int) { dst[0].to = c; }
keep_inout :: proc(dst: inout Link, @(escape=stored) c: ^mut int) { dst.to = c; }
keep_pointer :: proc(dst: ^mut ^mut int, @(escape=stored) c: ^mut int) { dst^ = c; }
keep_two :: proc(dst: ^mut Two, @(escape=stored) c: ^mut int) { dst^.a = c; }
`

// Where the call may leave the carrier: `call` with `$C` for it, and `read` for the
// place a copy is read back from.
@(private = "file")
Stored_Place :: struct {
	name, params, setup, call, read: string,
}

@(private = "file")
STORED_LOCAL :: "v0 := 1; l := Link{&mut v0};"
@(private = "file")
STORED_VIEW :: "v0 := 1; v1 := 2; ls := [2]Link{Link{&mut v0}, Link{&mut v1}}; view := &mut ls[:];"

@(private = "file")
STORED_PLACES := [?]Stored_Place {
	{"stored_parameter_pointer", "l: ^mut Link", "", "keep(l, $C)", "l^.to"},
	{"stored_local_record", "", STORED_LOCAL, "keep(&mut l, $C)", "l.to"},
	{"stored_inout_local", "", STORED_LOCAL, "keep_inout(inout l, $C)", "l.to"},
	{"stored_inout_parameter", "l: inout Link", "", "keep_inout(inout l, $C)", "l.to"},
	{"stored_pointer_to_local", "", STORED_LOCAL + " p := &mut l;", "keep(p, $C)", "p^.to"},
	{"stored_field_of_local_read_by_name", "", STORED_LOCAL + " p := &mut l;", "keep(p, $C)", "l.to"},
	{"stored_view_parameter_first", "s: []mut Link", "", "keep_view(s, $C)", "s[0].to"},
	{"stored_view_parameter_second", "s: []mut Link", "", "keep_view(s, $C)", "s[1].to"},
	{"stored_view_parameter_any", "s: []mut Link, k: int", "", "keep_view(s, $C)", "s[k].to"},
	{"stored_local_view", "", STORED_VIEW, "keep_view(view, $C)", "view[1].to"},
	{"stored_array_read_by_name", "", STORED_VIEW, "keep_view(view, $C)", "ls[1].to"},
	{"stored_pointer_to_pointer_parameter", "p: ^mut ^mut int", "", "keep_pointer(p, $C)", "p^"},
	{"stored_pointer_to_pointer_local", "", "v0 := 1; r := &mut v0; p := &mut r;", "keep_pointer(p, $C)", "p^"},
	{"stored_pointer_to_pointer_read_by_name", "", "v0 := 1; r := &mut v0; p := &mut r;", "keep_pointer(p, $C)", "r"},
	{"stored_record_first_field", "t: ^mut Two", "", "keep_two(t, $C)", "t^.a"},
	{"stored_record_second_field", "t: ^mut Two", "", "keep_two(t, $C)", "t^.b"},
}

// `$CALL` passes `other`, `$HELD` passes `held`, and `$R` is the place read back.
@(private = "file")
STORED_CASES := [?]Store_Case {
	{"kept_then_both_used", "$CALL; x := $R; other^ = 1; x^ = 2;", true},
	{"kept_copy_done_first", "$CALL; x := $R; x^ = 2; other^ = 1;", false},
	{"kept_source_only", "$CALL; other^ = 1;", false},
	{"kept_dest_read_after_source", "$CALL; other^ = 1; x := $R; x^ = 2;", true},
	{"read_done_before_call", "x := $R; x^ = 1; other^ = 2; $CALL;", false},
	{"source_used_before_call", "other^ = 2; $CALL; x := $R; x^ = 1;", false},
	{"copy_live_across_call", "x := $R; $CALL; x^ = 1;", true},
	{"called_twice_then_read", "$CALL; $CALL; x := $R; x^ = 1;", true},
	{"kept_in_branch", "if (flip()) { $CALL; } x := $R; other^ = 1; x^ = 2;", true},
	{"called_in_loop_then_read", "for (i := 0; i < 2; i += 1) { $CALL; } x := $R; x^ = 1;", true},
	{"source_local_copy_stored", "held := other; $HELD; x := $R; held^ = 1; x^ = 2;", true},
	{"source_local_copy_after_done", "held := other; $HELD; x := $R; x^ = 1; held^ = 2;", false},
	{"kept_then_replaced", "$CALL; $R = fresh; x := $R; other^ = 1; x^ = 2;", false},
}

// What the place form changes: `s[k]` is no one place, so storing there replaces
// nothing, and a read by name uses what a pointer the later call uses is still lent from.
@(private = "file")
stored_case_rejected :: proc(place: Stored_Place, entry: Store_Case) -> bool {
	switch {
	case place.name == "stored_view_parameter_any" && entry.name == "kept_then_replaced":
		return true
	case entry.name == "read_done_before_call" && strings.has_suffix(place.name, "read_by_name"):
		return true
	}
	return entry.rejected
}

// Where the compiler rejects what the rules accept: known-gaps.md "A carrier a call may
// have left stays after its place is replaced". Listed so that closing it shows up here.
@(private = "file")
stored_case_over_rejected :: proc(place: Stored_Place, entry: Store_Case) -> bool {
	if entry.name != "kept_then_replaced" {
		return false
	}
	switch place.name {
	case "stored_parameter_pointer", "stored_view_parameter_first", "stored_view_parameter_second", "stored_pointer_to_pointer_parameter":
		return true
	}
	return false
}

@(test)
stored_argument_matrix :: proc(t: ^testing.T) {
	names := make([dynamic]string, context.temp_allocator)
	sources := make([dynamic]string, context.temp_allocator)
	first := strings.count(STORED_PRELUDE, "\n") + 1
	for place in STORED_PLACES {
		source := strings.builder_make(context.temp_allocator)
		strings.write_string(&source, STORED_PRELUDE)
		with_other, _ := strings.replace_all(place.call, "$C", "other", context.temp_allocator)
		with_held, _ := strings.replace_all(place.call, "$C", "held", context.temp_allocator)
		for entry in STORED_CASES {
			text, _ := strings.replace_all(entry.body, "$CALL", with_other, context.temp_allocator)
			text, _ = strings.replace_all(text, "$HELD", with_held, context.temp_allocator)
			text, _ = strings.replace_all(text, "$R", place.read, context.temp_allocator)
			params := fmt.tprintf("%s%s@(escape=stored) other: ^mut int", place.params, place.params == "" ? "" : ", ")
			if strings.contains(text, "fresh") {
				params = fmt.tprintf("%s, @(escape=stored) fresh: ^mut int", params)
			}
			// Every case takes up four lines, which the check below counts on.
			fmt.sbprintf(&source, "%s :: proc(%s) {{\n\t%s\n\t%s\n}}\n", entry.name, params, place.setup, text)
		}
		strings.write_string(&source, "main :: proc() {}\n")
		append(&names, place.name)
		append(&sources, strings.to_string(source))
	}
	errors, compiled := store_matrix_compile(t, names[:], sources[:])
	if !compiled {
		return
	}
	for place, index in STORED_PLACES {
		for entry, at in STORED_CASES {
			expected := stored_case_rejected(place, entry) || stored_case_over_rejected(place, entry)
			store_matrix_expect(t, place.name, entry.name, first + 4 * at, errors[index], expected)
		}
	}
}

// Destinations and sources a `stored` argument reaches other than as a plain place. A
// link to too few slots accepts a rejected case here, so these are what a landing
// that misses one would break.
@(private = "file")
STORED_REACH_PRELUDE :: `package main;
Link :: struct { to: ^mut int }
Holder :: struct { l: ^mut Link }
Node :: struct { next: ^mut Node, v: int }
RoLink :: struct { to: ^int }
SLink :: struct { s: []mut int }
flip :: proc() -> bool { return true; }
get :: proc(l: ^mut Link) -> ^mut Link { return l; }
get_int :: proc(c: ^mut int) -> ^mut int { return c; }
keep :: proc(dst: ^mut Link, @(escape=stored) c: ^mut int) { dst^.to = c; }
keep_both :: proc(x: ^mut Link, y: ^mut Link, @(escape=stored) c: ^mut int) { x^.to = c; }
keep_deep :: proc(dst: ^mut ^mut Link, @(escape=stored) c: ^mut int) { dst^^.to = c; }
keep_outer :: proc(o: ^mut Holder, @(escape=stored) c: ^mut int) { o^.l^.to = c; }
keep_ro :: proc(dst: ^mut RoLink, @(escape=stored) c: ^int) { dst^.to = c; }
keep_s :: proc(dst: ^mut SLink, @(escape=stored) s: []mut int) { dst^.s = s; }
keep_record :: proc(dst: ^mut Link, @(escape=stored) c: Link) { dst^ = c; }
keep_reached :: proc(dst: ^mut Link, @(escape=stored) h: ^mut Holder) { dst^.to = h^.l^.to; }
keep_self :: proc(@(escape=stored) n: ^mut Node) { n^.next = n; }
keep_cross :: proc(@(escape=stored) a: ^mut Node, @(escape=stored) b: ^mut Node) { a^.next = b; }
`

@(private = "file")
Stored_Reach_Case :: struct {
	name, params, body: string,
	rejected:           bool,
}

@(private = "file")
STORED_OTHER :: "@(escape=stored) other: ^mut int"
@(private = "file")
STORED_L_OTHER :: "l: ^mut Link, " + STORED_OTHER
@(private = "file")
STORED_LM_OTHER :: "l: ^mut Link, m: ^mut Link, " + STORED_OTHER
@(private = "file")
STORED_USE :: " other^ = 1; x^ = 2;"
@(private = "file")
STORED_DONE :: " x^ = 2; other^ = 1;"
@(private = "file")
STORED_A :: "v0 := 1; a := Link{&mut v0}; "
@(private = "file")
STORED_RO :: "dst: ^mut RoLink, @(escape=stored) c: ^mut int"
@(private = "file")
STORED_SELF :: "@(escape=stored) n: ^mut Node"
@(private = "file")
STORED_CROSS :: "@(escape=stored) a: ^mut Node, @(escape=stored) b: ^mut Node"
@(private = "file")
STORED_LOADED :: "l: ^mut Link, @(escape=stored) m: ^mut Link"

@(private = "file")
STORED_REACH_CASES := [?]Stored_Reach_Case {
	// The destination reached through a result, a copy, or a holder.
	{"via_result", STORED_L_OTHER, "keep(get(l), other); x := l^.to;" + STORED_USE, true},
	{"via_result_done", STORED_L_OTHER, "keep(get(l), other); x := l^.to;" + STORED_DONE, false},
	{"via_copy", STORED_L_OTHER, "q := l; keep(q, other); x := q^.to;" + STORED_USE, true},
	{"via_copy_read_original", STORED_L_OTHER, "q := l; keep(q, other); x := l^.to;" + STORED_USE, true},
	{"via_copy_done", STORED_L_OTHER, "q := l; keep(q, other); x := l^.to;" + STORED_DONE, false},
	{"local_through_copy", STORED_OTHER, STORED_A + "p := &mut a; q := p; keep(q, other); x := a.to;" + STORED_USE, true},
	{"through_pointer_to_copy", STORED_L_OTHER, "q := l; pp := &mut q; keep(pp^, other); x := l^.to;" + STORED_USE, true},
	{"holder_field", STORED_L_OTHER, "h := Holder{l}; keep(h.l, other); x := h.l^.to;" + STORED_USE, true},
	{"holder_field_read_original", STORED_L_OTHER, "h := Holder{l}; keep(h.l, other); x := l^.to;" + STORED_USE, true},
	{"holder_written_whole", STORED_L_OTHER, "h := Holder{l}; keep_outer(&mut h, other); x := h.l^.to;" + STORED_USE, true},
	{"holder_written_read_original", STORED_L_OTHER, "h := Holder{l}; keep_outer(&mut h, other); x := l^.to;" + STORED_USE, true},
	{"holder_parameter", "h: ^mut Holder, " + STORED_OTHER, "keep_outer(h, other); x := h^.l^.to;" + STORED_USE, true},
	{"deep_local", STORED_L_OTHER, "q := l; keep_deep(&mut q, other); x := l^.to;" + STORED_USE, true},
	{"deep_parameter", "d: ^mut ^mut Link, " + STORED_OTHER, "keep_deep(d, other); x := d^^.to;" + STORED_USE, true},
	// Elements.
	{"element_same", "s: []mut Link, " + STORED_OTHER, "keep(&mut s[0], other); x := s[0].to;" + STORED_USE, true},
	{"element_any_read_one", "s: []mut Link, k: int, " + STORED_OTHER, "keep(&mut s[k], other); x := s[0].to;" + STORED_USE, true},
	{"element_same_done", "s: []mut Link, " + STORED_OTHER, "keep(&mut s[0], other); x := s[0].to;" + STORED_DONE, false},
	{"element_other", "s: []mut Link, " + STORED_OTHER, "keep(&mut s[0], other); x := s[1].to;" + STORED_USE, false},
	// What the source is.
	{"read_only_kept", "dst: ^mut RoLink, @(escape=stored) c: ^int", "keep_ro(dst, c); x := dst^.to; r := c^; y := x^;", false},
	{"mutable_kept_read_only_write", STORED_RO, "keep_ro(dst, c); x := dst^.to; c^ = 1; y := x^;", true},
	{"mutable_kept_read_only_done", STORED_RO, "keep_ro(dst, c); x := dst^.to; y := x^; c^ = 1;", false},
	{"mutable_kept_read_only_read", STORED_RO, "keep_ro(dst, c); x := dst^.to; y := c^; z := x^;", false},
	{"view_kept", "d: ^mut SLink, @(escape=stored) s: []mut int", "keep_s(d, s); x := d^.s; s[0] = 1; x[0] = 2;", true},
	{"view_kept_done", "d: ^mut SLink, @(escape=stored) s: []mut int", "keep_s(d, s); x := d^.s; x[0] = 2; s[0] = 1;", false},
	{"record_kept", "d: ^mut Link, @(escape=stored) c: Link", "keep_record(d, c); x := d^.to; c.to^ = 1; x^ = 2;", true},
	{"reached_kept", "d: ^mut Link, @(escape=stored) h: ^mut Holder", "keep_reached(d, h); x := d^.to; h^.l^.to^ = 1; x^ = 2;", true},
	{"loaded_source", STORED_LOADED, "keep(l, m^.to); x := l^.to; m^.to^ = 1; x^ = 2;", true},
	{"loaded_source_done", STORED_LOADED, "keep(l, m^.to); x := l^.to; x^ = 2; m^.to^ = 1;", false},
	{"result_source", STORED_L_OTHER, "keep(l, get_int(other)); x := l^.to;" + STORED_USE, true},
	{"fresh_borrow", "", STORED_A + "w := 2; keep(&mut a, &mut w); x := a.to; w = 1; x^ = 2;", true},
	{"fresh_borrow_done", "", STORED_A + "w := 2; keep(&mut a, &mut w); x := a.to; x^ = 2; w = 1;", false},
	// An argument that is its own destination, or each the other's. Reaching the copy
	// through the argument uses what it suspends, as after `n^.next = n;`.
	{"self_pointer", STORED_SELF, "keep_self(n); h := n^.next; n^.v = 1; h^.v = 2;", true},
	{"self_pointer_done", STORED_SELF, "keep_self(n); h := n^.next; h^.v = 2; n^.v = 1;", true},
	{"self_pointer_only_source", STORED_SELF, "keep_self(n); n^.v = 1;", false},
	{"self_local", "w: ^mut Node", "node := Node{w, 1}; keep_self(&mut node); h := node.next; node.v = 1; h^.v = 2;", true},
	{"self_local_done", "w: ^mut Node", "node := Node{w, 1}; keep_self(&mut node); h := node.next; h^.v = 2; node.v = 1;", true},
	{"cross_first", STORED_CROSS, "keep_cross(a, b); h := a^.next; b^.v = 1; h^.v = 2;", true},
	{"cross_second", STORED_CROSS, "keep_cross(a, b); h := b^.next; a^.v = 1; h^.v = 2;", true},
	{"cross_done", STORED_CROSS, "keep_cross(a, b); h := a^.next; h^.v = 2; b^.v = 1;", true},
	// A destination the call never received.
	{"other_parameter_untouched", STORED_LM_OTHER, "keep(l, other); x := m^.to;" + STORED_USE, false},
	{"other_local_untouched", STORED_OTHER, STORED_A + "v1 := 2; b := Link{&mut v1}; keep(&mut a, other); x := b.to;" + STORED_USE, false},
	{"second_destination", STORED_LM_OTHER, "keep_both(l, m, other); x := m^.to;" + STORED_USE, true},
	// One call's leavings passed on by another.
	{"chained_parameters", "l: ^mut Link, @(escape=stored) m: ^mut Link, " + STORED_OTHER, "keep(l, other); keep(m, l^.to); x := m^.to;" + STORED_USE, true},
	{"chained_through_local", STORED_L_OTHER, STORED_A + "keep(&mut a, other); keep(l, a.to); x := l^.to;" + STORED_USE, true},
	{"chained_in_a_loop", "l: ^mut Link, m: ^mut Link", "for (i := 0; i < 2; i += 1) { keep(l, m^.to); keep(m, l^.to); } x := m^.to; y := l^.to; x^ = 1; y^ = 2;", true},
	{"either_branch", STORED_LM_OTHER, "if (flip()) { keep(l, other); } else { keep(m, other); } x := l^.to;" + STORED_USE, true},
	{"loop_read_before_call", STORED_L_OTHER, "for (i := 0; i < 2; i += 1) { x := l^.to; x^ = 1; keep(l, other); other^ = 2; }", true},
	{"local_replaced", STORED_OTHER + ", @(escape=stored) fresh: ^mut int", STORED_A + "keep(&mut a, other); a = Link{fresh}; x := a.to;" + STORED_USE, false},
}

// known-gaps.md "What a call leaves through a pointer to one element counts for each".
@(private = "file")
stored_reach_over_rejected :: proc(entry: Stored_Reach_Case) -> bool {
	return entry.name == "element_other"
}

@(test)
stored_argument_reach_matrix :: proc(t: ^testing.T) {
	source := strings.builder_make(context.temp_allocator)
	strings.write_string(&source, STORED_REACH_PRELUDE)
	first := strings.count(STORED_REACH_PRELUDE, "\n") + 1
	for entry in STORED_REACH_CASES {
		// Every case takes up four lines, which the check below counts on.
		fmt.sbprintf(&source, "%s :: proc(%s) {{\n\t\n\t%s\n}}\n", entry.name, entry.params, entry.body)
	}
	strings.write_string(&source, "main :: proc() {}\n")
	names := []string{"stored_reach"}
	sources := []string{strings.to_string(source)}
	errors, compiled := store_matrix_compile(t, names, sources)
	if !compiled {
		return
	}
	for entry, at in STORED_REACH_CASES {
		expected := entry.rejected || stored_reach_over_rejected(entry)
		store_matrix_expect(t, names[0], entry.name, first + 4 * at, errors[0], expected)
	}
}

// A call that may leave a carrier in two places of what its argument reaches
// (design.md "Values that contain borrows"): each place may then hold a copy of the
// other, in a direction the caller cannot know, and a call uses each mutable carrier it
// can reach. Each verdict is worked out by hand as above.
@(private = "file")
CALL_COPY_PRELUDE :: `package main;
Link :: struct { to: ^mut int }
Pair :: struct { a: ^mut int, b: ^mut int }
Holder :: struct { links: []mut Link }
Slots :: struct { items: [2]Link }
Mixed :: struct { a: ^mut int, b: ^int }
RoLink :: struct { to: ^int }
RoS :: struct { s: []int }
flip :: proc() -> bool { return true; }
duplicate :: proc(links: []mut Link) { links[0] = links[1]; }
forward :: proc(links: []mut Link) { duplicate(links); }
one_field :: proc(links: []mut Link) { links[0].to = links[1].to; }
share :: proc(pair: ^mut Pair) { pair^.a = pair^.b; }
in_an_array :: proc(links: inout [2]Link) { links[0] = links[1]; }
behind_a_pointer :: proc(links: ^mut [2]Link) { links^[0] = links^[1]; }
in_a_holder :: proc(holder: ^mut Holder) { holder^.links[0] = holder^.links[1]; }
by_value_holder :: proc(holder: Holder) { holder.links[0] = holder.links[1]; }
weakened :: proc(mixed: ^mut Mixed) { mixed^.b = mixed^.a; }
weakened_view :: proc(mixed: []mut Mixed) { mixed[0].b = mixed[0].a; }
keep_ro :: proc(dst: ^mut RoLink, @(escape=stored) c: ^mut int) { dst^.to = c; }
keep_ro_copy :: proc(dst: ^mut RoLink, @(escape=stored) c: ^int) { dst^.to = c; }
keep_pointer_ro :: proc(dst: ^mut ^int, @(escape=stored) c: ^mut int) { dst^ = c; }
keep_rs :: proc(dst: ^mut RoS, @(escape=stored) s: []mut int) { dst^.s = s; }
impl Slots {
	shuffle :: proc(self: inout Slots) { self.items[0] = self.items[1]; }
}
`

@(private = "file")
Call_Copy_Place :: struct {
	name, params, setup, call, first, second: string,
}

@(private = "file")
COPY_ARRAY :: "v0 := 1; v1 := 2; ls := [2]Link{Link{&mut v0}, Link{&mut v1}};"
@(private = "file")
COPY_PAIR :: "v0 := 1; v1 := 2; pr := Pair{&mut v0, &mut v1};"
@(private = "file")
COPY_SLOTS :: "v0 := 1; v1 := 2; sl := Slots{[2]Link{Link{&mut v0}, Link{&mut v1}}};"

@(private = "file")
CALL_COPY_PLACES := [?]Call_Copy_Place {
	{"copy_view_parameter", "s: []mut Link", "", "duplicate(s)", "s[0].to", "s[1].to"},
	{"copy_view_parameter_any", "s: []mut Link, j: int, k: int", "", "duplicate(s)", "s[j].to", "s[k].to"},
	{"copy_forwarded_parameter", "s: []mut Link", "", "forward(s)", "s[0].to", "s[1].to"},
	{"copy_one_field_parameter", "s: []mut Link", "", "one_field(s)", "s[0].to", "s[1].to"},
	{"copy_local_array", "", COPY_ARRAY, "duplicate(&mut ls[:])", "ls[0].to", "ls[1].to"},
	{"copy_local_view", "", COPY_ARRAY + " view := &mut ls[:];", "duplicate(view)", "view[0].to", "view[1].to"},
	{"copy_local_array_inout", "", COPY_ARRAY, "in_an_array(inout ls)", "ls[0].to", "ls[1].to"},
	{"copy_inout_parameter", "ls: inout [2]Link", "", "in_an_array(inout ls)", "ls[0].to", "ls[1].to"},
	{"copy_pointer_parameter", "a: ^mut [2]Link", "", "behind_a_pointer(a)", "a^[0].to", "a^[1].to"},
	{"copy_pointer_to_local", "", COPY_ARRAY + " p := &mut ls;", "behind_a_pointer(p)", "p^[0].to", "p^[1].to"},
	{"copy_pair_parameter", "t: ^mut Pair", "", "share(t)", "t^.a", "t^.b"},
	{"copy_pair_local", "", COPY_PAIR, "share(&mut pr)", "pr.a", "pr.b"},
	{"copy_pair_through_pointer", "", COPY_PAIR + " p := &mut pr;", "share(p)", "p^.a", "p^.b"},
	{"copy_holder_parameter", "h: ^mut Holder", "", "in_a_holder(h)", "h^.links[0].to", "h^.links[1].to"},
	{"copy_holder_by_value", "h: Holder", "", "by_value_holder(h)", "h.links[0].to", "h.links[1].to"},
	{"copy_method_on_local", "", COPY_SLOTS, "sl.shuffle()", "sl.items[0].to", "sl.items[1].to"},
	{"copy_method_on_inout", "sl: inout Slots", "", "sl.shuffle()", "sl.items[0].to", "sl.items[1].to"},
}

// `$CALL` is the call, and `$A` and `$B` the two places. Reading one may use what the
// other was copied from, so copies done in turn still conflict.
@(private = "file")
CALL_COPY_CASES := [?]Store_Case {
	{"both_copies_used", "$CALL; x := $A; y := $B; x^ = 1; y^ = 2;", true},
	{"both_copies_other_order", "$CALL; x := $B; y := $A; x^ = 1; y^ = 2;", true},
	{"copies_done_in_turn", "$CALL; x := $A; x^ = 1; y := $B; y^ = 2;", true},
	{"one_copy", "$CALL; x := $A; x^ = 1;", false},
	{"copies_before_call", "x := $A; y := $B; x^ = 1; y^ = 2; $CALL;", false},
	{"copy_live_across_call", "x := $A; $CALL; x^ = 1;", true},
	{"called_twice", "$CALL; $CALL; x := $A; y := $B; x^ = 1; y^ = 2;", true},
	{"called_in_branch", "if (flip()) { $CALL; } x := $A; y := $B; x^ = 1; y^ = 2;", true},
	{"called_in_loop", "for (i := 0; i < 2; i += 1) { $CALL; } x := $A; y := $B; x^ = 1; y^ = 2;", true},
	{"read_before_call_in_loop", "for (i := 0; i < 2; i += 1) { x := $A; y := $B; x^ = 1; y^ = 2; $CALL; }", true},
	{"other_storage_untouched", "$CALL; x := $A; y := o^.to; x^ = 1; y^ = 2;", false},
	{"replaced_after_call", "$CALL; $A = fresh; x := $A; y := $B; x^ = 1; y^ = 2;", false},
	{"other_replaced_after_call", "$CALL; $B = fresh; x := $A; y := $B; x^ = 1; y^ = 2;", false},
}

// What the place form changes: `s[j]`, or an element of a view a record holds, names
// no one place. So nothing replaces it, its copies may be of one element, and one slot
// stands for both places, which reading in turn does not make a conflict.
@(private = "file")
call_copy_rejected :: proc(place: Call_Copy_Place, entry: Store_Case) -> bool {
	switch place.name {
	case "copy_view_parameter_any", "copy_holder_parameter", "copy_holder_by_value":
		switch entry.name {
		case "copies_before_call", "replaced_after_call", "other_replaced_after_call":
			return true
		case "copies_done_in_turn":
			return false
		}
	}
	return entry.rejected
}

@(test)
call_copy_matrix :: proc(t: ^testing.T) {
	names := make([dynamic]string, context.temp_allocator)
	sources := make([dynamic]string, context.temp_allocator)
	first := strings.count(CALL_COPY_PRELUDE, "\n") + 1
	for place in CALL_COPY_PLACES {
		source := strings.builder_make(context.temp_allocator)
		strings.write_string(&source, CALL_COPY_PRELUDE)
		for entry in CALL_COPY_CASES {
			text, _ := strings.replace_all(entry.body, "$CALL", place.call, context.temp_allocator)
			text, _ = strings.replace_all(text, "$A", place.first, context.temp_allocator)
			text, _ = strings.replace_all(text, "$B", place.second, context.temp_allocator)
			params := place.params
			if strings.contains(text, "o^") {
				params = fmt.tprintf("%s%so: ^mut Link", params, params == "" ? "" : ", ")
			}
			if strings.contains(text, "fresh") {
				params = fmt.tprintf("%s%s@(escape=stored) fresh: ^mut int", params, params == "" ? "" : ", ")
			}
			// Every case takes up four lines, which the check below counts on.
			fmt.sbprintf(&source, "%s :: proc(%s) {{\n\t%s\n\t%s\n}}\n", entry.name, params, place.setup, text)
		}
		strings.write_string(&source, "main :: proc() {}\n")
		append(&names, place.name)
		append(&sources, strings.to_string(source))
	}
	errors, compiled := store_matrix_compile(t, names[:], sources[:])
	if !compiled {
		return
	}
	for place, index in CALL_COPY_PLACES {
		for entry, at in CALL_COPY_CASES {
			store_matrix_expect(t, place.name, entry.name, first + 4 * at, errors[index], call_copy_rejected(place, entry))
		}
	}
}

@(private = "file")
COPY_LOCALS :: "v := 1; w := 2; "
@(private = "file")
COPY_MIXED :: COPY_LOCALS + "mx := Mixed{&mut v, &w}; "
@(private = "file")
COPY_RO :: COPY_LOCALS + "ro := RoLink{&v}; "
@(private = "file")
COPY_RO_TWO :: COPY_RO + "ro2 := RoLink{&w}; "
@(private = "file")
COPY_KEPT :: "@(escape=stored) c: ^mut int"
@(private = "file")
COPY_VIEW_KEPT :: "@(escape=stored) s: []mut int"
@(private = "file")
COPY_RS :: "arr := [2]int{1, 2}; rs := RoS{arr[:]}; keep_rs(&mut rs, s); q := rs.s; "

// A read-only carrier read back by name holds what a store, a call that keeps its
// argument, or a call that copies may have left there, which only the solve knows, so
// a copy of it is a read-only reborrow. A write of what it reborrows conflicts while it
// is live; a read does not, and neither does anything done with what it held before.
@(private = "file")
READ_ONLY_COPY_CASES := [?]Stored_Reach_Case {
	{"weakened_parameter", "m: ^mut Mixed", "weakened(m); x := m^.b; m^.a^ = 1; y := x^;", true},
	{"weakened_parameter_named_copy", "m: ^mut Mixed", "weakened(m); x := m^.b; q := x; m^.a^ = 1; y := q^;", true},
	{"weakened_parameter_done", "m: ^mut Mixed", "weakened(m); x := m^.b; y := x^; m^.a^ = 1;", false},
	{"weakened_parameter_read", "m: ^mut Mixed", "weakened(m); x := m^.b; y := m^.a^; z := x^;", false},
	{"weakened_local", "", COPY_MIXED + "weakened(&mut mx); x := mx.b; mx.a^ = 1; y := x^;", true},
	{"weakened_local_named_copy", "", COPY_MIXED + "weakened(&mut mx); x := mx.b; q := x; mx.a^ = 1; y := q^;", true},
	{"weakened_local_done", "", COPY_MIXED + "weakened(&mut mx); x := mx.b; y := x^; mx.a^ = 1;", false},
	{"weakened_local_read", "", COPY_MIXED + "weakened(&mut mx); x := mx.b; y := mx.a^; z := x^;", false},
	{"weakened_view_local", "", COPY_LOCALS + "ms := [1]Mixed{Mixed{&mut v, &w}}; weakened_view(&mut ms[:]); x := ms[0].b; ms[0].a^ = 1; y := x^;", true},
	{"weakened_through_pointer", "", COPY_MIXED + "p := &mut mx; weakened(p); x := p^.b; p^.a^ = 1; y := x^;", true},
	{"weakened_through_pointer_read_by_name", "", COPY_MIXED + "p := &mut mx; weakened(p); x := mx.b; mx.a^ = 1; y := x^;", true},
	{"weakened_in_loop_copy_first", "", COPY_MIXED + "for (i := 0; i < 2; i += 1) { x := mx.b; q := x; mx.a^ = 1; y := q^; weakened(&mut mx); }", true},
	{"kept_local", COPY_KEPT, COPY_RO + "keep_ro(&mut ro, c); q := ro.to; c^ = 1; y := q^;", true},
	{"kept_local_named_copy", COPY_KEPT, COPY_RO + "keep_ro(&mut ro, c); q := ro.to; r := q; c^ = 1; y := r^;", true},
	{"kept_local_done", COPY_KEPT, COPY_RO + "keep_ro(&mut ro, c); q := ro.to; y := q^; c^ = 1;", false},
	{"kept_by_pointer", COPY_KEPT, COPY_RO + "p := &mut ro; keep_ro(p, c); q := ro.to; c^ = 1; y := q^;", true},
	{"kept_whole_record_copy", COPY_KEPT, COPY_RO + "keep_ro(&mut ro, c); h := ro; c^ = 1; y := h.to^;", true},
	{"kept_whole_record_copy_done", COPY_KEPT, COPY_RO + "keep_ro(&mut ro, c); h := ro; y := h.to^; c^ = 1;", false},
	{"kept_in_named_pointer", COPY_KEPT, COPY_LOCALS + "r: ^int = &v; keep_pointer_ro(&mut r, c); q := r; c^ = 1; y := q^;", true},
	{"kept_in_named_pointer_done", COPY_KEPT, COPY_LOCALS + "r: ^int = &v; keep_pointer_ro(&mut r, c); q := r; y := q^; c^ = 1;", false},
	{"kept_read_only_view", COPY_VIEW_KEPT, COPY_RS + "s[0] = 1; y := q[0];", true},
	{"kept_read_only_view_done", COPY_VIEW_KEPT, COPY_RS + "y := q[0]; s[0] = 1;", false},
	{"stored_by_hand", COPY_KEPT, COPY_RO + "p := &mut ro; p^.to = c; q := ro.to; c^ = 1; y := q^;", true},
	{"stored_by_hand_named_copy", COPY_KEPT, COPY_RO + "p := &mut ro; p^.to = c; q := ro.to; r := q; c^ = 1; y := r^;", true},
	{"stored_by_hand_done", COPY_KEPT, COPY_RO + "p := &mut ro; p^.to = c; q := ro.to; y := q^; c^ = 1;", false},
	{"stored_by_hand_read", COPY_KEPT, COPY_RO + "p := &mut ro; p^.to = c; q := ro.to; y := c^; z := q^;", false},
	{"stored_through_local_view", COPY_KEPT, COPY_LOCALS + "ros := [1]RoLink{RoLink{&v}}; view := &mut ros[:]; view[0].to = c; q := ros[0].to; c^ = 1; y := q^;", true},
	{"copy_before_the_store", COPY_KEPT, COPY_RO + "q := ro.to; p := &mut ro; p^.to = c; c^ = 1; y := q^;", false},
	{"copy_before_the_call", COPY_KEPT, COPY_RO + "q := ro.to; keep_ro(&mut ro, c); c^ = 1; y := q^;", false},
	{"passed_on_by_call", COPY_KEPT, COPY_RO_TWO + "keep_ro(&mut ro, c); keep_ro_copy(&mut ro2, ro.to); q := ro2.to; c^ = 1; y := q^;", true},
	{"passed_on_in_loop", COPY_KEPT, COPY_RO_TWO + "for (i := 0; i < 2; i += 1) { keep_ro_copy(&mut ro2, ro.to); keep_ro(&mut ro, c); } q := ro2.to; c^ = 1; y := q^;", true},
	{"stored_on_by_hand", COPY_KEPT, COPY_RO_TWO + "p := &mut ro; pp := &mut ro2; p^.to = c; q := ro.to; pp^.to = q; r := ro2.to; c^ = 1; y := r^;", true},
	{"plain_read_only_never_conflicts", COPY_KEPT, COPY_RO + "q := ro.to; r := q; c^ = 1; y := r^;", false},
}

// known-gaps.md "A read of a carrier a call may have weakened conflicts with the copy".
@(private = "file")
read_only_copy_over_rejected :: proc(entry: Stored_Reach_Case) -> bool {
	return entry.name == "weakened_parameter_read" || entry.name == "weakened_local_read"
}

@(test)
read_only_copy_matrix :: proc(t: ^testing.T) {
	source := strings.builder_make(context.temp_allocator)
	strings.write_string(&source, CALL_COPY_PRELUDE)
	first := strings.count(CALL_COPY_PRELUDE, "\n") + 1
	for entry in READ_ONLY_COPY_CASES {
		// Every case takes up four lines, which the check below counts on.
		fmt.sbprintf(&source, "%s :: proc(%s) {{\n\t\n\t%s\n}}\n", entry.name, entry.params, entry.body)
	}
	strings.write_string(&source, "main :: proc() {}\n")
	names := []string{"read_only_copy"}
	sources := []string{strings.to_string(source)}
	errors, compiled := store_matrix_compile(t, names, sources)
	if !compiled {
		return
	}
	for entry, at in READ_ONLY_COPY_CASES {
		expected := entry.rejected || read_only_copy_over_rejected(entry)
		store_matrix_expect(t, names[0], entry.name, first + 4 * at, errors[0], expected)
	}
}

// What reads a link while the walk runs: a traversal, an argument evaluated before
// another, and a spawn. A link the solve makes is not there yet, so each of these must
// still see what a store, or a call that keeps its argument, leaves in a place. Each
// verdict is worked out by hand as above.
@(private = "file")
WALK_READER_PRELUDE :: `package main;
Link :: struct { to: ^mut int }
RoS :: struct { s: []int }
MuS :: struct { s: []mut int }
RoLink :: struct { to: ^int }
keep_rs :: proc(dst: ^mut RoS, @(escape=stored) s: []mut int) { dst^.s = s; }
keep_ms :: proc(dst: ^mut MuS, @(escape=stored) s: []mut int) { dst^.s = s; }
keep_ro :: proc(dst: ^mut RoLink, @(escape=stored) c: ^mut int) { dst^.to = c; }
keep :: proc(dst: ^mut Link, @(escape=stored) c: ^mut int) { dst^.to = c; }
keep_pointer :: proc(dst: ^mut ^mut int, @(escape=stored) c: ^mut int) { dst^ = c; }
write_first :: proc(s: []mut int) -> int { s[0] = 1; return 0; }
write_it :: proc(c: ^mut int) -> int { c^ = 1; return 0; }
both_ro :: proc(a: []int, b: int) {}
both_mu :: proc(a: []mut int, b: int) {}
both_ptr :: proc(a: ^int, b: int) {}
both_mptr :: proc(a: ^mut int, b: int) {}
take_two :: proc(a: ^mut int, b: ^mut int) {}
take_one_view :: proc(a: []mut int, b: []mut int) {}
entry :: proc(p: ^mut int) { p^ = 1; }
read_entry :: proc(p: ^int) { y := p^; }
Pair_Ptr :: struct { a: ^mut int, b: int }
`

@(private = "file")
WALK_READER_CASES := [?]Stored_Reach_Case {
	// A traversal.
	{"foreach_ro_by_hand", "@(escape=stored) s: []mut int", "arr := [2]int{1, 2}; rs := RoS{arr[:]}; p := &mut rs; p^.s = s; foreach (x in rs.s) { s[0] = x; }", true},
	{"foreach_ro_by_call", "@(escape=stored) s: []mut int", "arr := [2]int{1, 2}; rs := RoS{arr[:]}; keep_rs(&mut rs, s); foreach (x in rs.s) { s[0] = x; }", true},
	{"foreach_ro_by_hand_done", "@(escape=stored) s: []mut int", "arr := [2]int{1, 2}; rs := RoS{arr[:]}; p := &mut rs; p^.s = s; foreach (x in rs.s) { y := x; } s[0] = 1;", false},
	{"foreach_ro_by_call_done", "@(escape=stored) s: []mut int", "arr := [2]int{1, 2}; rs := RoS{arr[:]}; keep_rs(&mut rs, s); foreach (x in rs.s) { y := x; } s[0] = 1;", false},
	{"foreach_ro_named_by_hand", "@(escape=stored) s: []mut int", "arr := [2]int{1, 2}; rs := RoS{arr[:]}; p := &mut rs; p^.s = s; t := rs.s; foreach (x in t) { s[0] = x; }", true},
	{"foreach_ro_named_by_call", "@(escape=stored) s: []mut int", "arr := [2]int{1, 2}; rs := RoS{arr[:]}; keep_rs(&mut rs, s); t := rs.s; foreach (x in t) { s[0] = x; }", true},
	{"foreach_mu_by_hand", "@(escape=stored) s: []mut int", "arr := [2]int{1, 2}; ms := MuS{&mut arr[:]}; p := &mut ms; p^.s = s; foreach (x in ms.s) { s[0] = x; }", true},
	{"foreach_mu_by_call", "@(escape=stored) s: []mut int", "arr := [2]int{1, 2}; ms := MuS{&mut arr[:]}; keep_ms(&mut ms, s); foreach (x in ms.s) { s[0] = x; }", true},
	{"foreach_mu_named_by_hand", "@(escape=stored) s: []mut int", "arr := [2]int{1, 2}; ms := MuS{&mut arr[:]}; p := &mut ms; p^.s = s; t := ms.s; foreach (x in t) { s[0] = x; }", true},
	{"foreach_mu_named_by_call", "@(escape=stored) s: []mut int", "arr := [2]int{1, 2}; ms := MuS{&mut arr[:]}; keep_ms(&mut ms, s); t := ms.s; foreach (x in t) { s[0] = x; }", true},
	{"foreach_mu_by_call_done", "@(escape=stored) s: []mut int", "arr := [2]int{1, 2}; ms := MuS{&mut arr[:]}; keep_ms(&mut ms, s); foreach (x in ms.s) { y := x; } s[0] = 1;", false},
	// An argument evaluated before another that writes.
	{"argument_ro_by_hand", "@(escape=stored) s: []mut int", "arr := [2]int{1, 2}; rs := RoS{arr[:]}; p := &mut rs; p^.s = s; both_ro(rs.s, write_first(s));", true},
	{"argument_ro_by_call", "@(escape=stored) s: []mut int", "arr := [2]int{1, 2}; rs := RoS{arr[:]}; keep_rs(&mut rs, s); both_ro(rs.s, write_first(s));", true},
	{"argument_ro_named_by_call", "@(escape=stored) s: []mut int", "arr := [2]int{1, 2}; rs := RoS{arr[:]}; keep_rs(&mut rs, s); t := rs.s; both_ro(t, write_first(s));", true},
	{"argument_ro_after_by_call", "@(escape=stored) s: []mut int", "arr := [2]int{1, 2}; rs := RoS{arr[:]}; keep_rs(&mut rs, s); n := write_first(s); both_ro(arr[:], n);", false},
	{"argument_ptr_by_hand", "@(escape=stored) c: ^mut int", "v := 1; ro := RoLink{&v}; p := &mut ro; p^.to = c; both_ptr(ro.to, write_it(c));", true},
	{"argument_ptr_by_call", "@(escape=stored) c: ^mut int", "v := 1; ro := RoLink{&v}; keep_ro(&mut ro, c); both_ptr(ro.to, write_it(c));", true},
	{"argument_mu_by_hand", "@(escape=stored) s: []mut int", "arr := [2]int{1, 2}; ms := MuS{&mut arr[:]}; p := &mut ms; p^.s = s; both_mu(ms.s, write_first(s));", true},
	{"argument_mu_by_call", "@(escape=stored) s: []mut int", "arr := [2]int{1, 2}; ms := MuS{&mut arr[:]}; keep_ms(&mut ms, s); both_mu(ms.s, write_first(s));", true},
	{"argument_mptr_by_hand", "@(escape=stored) c: ^mut int", "v := 1; l := Link{&mut v}; p := &mut l; p^.to = c; both_mptr(l.to, write_it(c));", true},
	{"argument_mptr_by_call", "@(escape=stored) c: ^mut int", "v := 1; l := Link{&mut v}; keep(&mut l, c); both_mptr(l.to, write_it(c));", true},
	{"argument_mptr_pointer_by_call", "@(escape=stored) c: ^mut int", "v := 1; r := &mut v; pp := &mut r; keep_pointer(pp, c); both_mptr(r, write_it(c));", true},
	{"two_arguments_by_call", "@(escape=stored) c: ^mut int", "v := 1; l := Link{&mut v}; keep(&mut l, c); take_two(l.to, c);", true},
	{"two_arguments_by_hand", "@(escape=stored) c: ^mut int", "v := 1; l := Link{&mut v}; p := &mut l; p^.to = c; take_two(l.to, c);", true},
	{"two_arguments_pointer_by_call", "@(escape=stored) c: ^mut int", "v := 1; r := &mut v; pp := &mut r; keep_pointer(pp, c); take_two(r, c);", true},
	{"two_arguments_view_by_call", "@(escape=stored) s: []mut int", "arr := [2]int{1, 2}; ms := MuS{&mut arr[:]}; keep_ms(&mut ms, s); take_one_view(ms.s, s);", true},
	{"record_literal_by_call", "@(escape=stored) c: ^mut int", "v := 1; l := Link{&mut v}; keep(&mut l, c); t := Pair_Ptr{l.to, write_it(c)}; t.a^ = 1;", true},
	// A spawn.
	{"spawn_copy_by_hand", "@(escape=stored) c: ^mut int", "v := 1; r := &mut v; pp := &mut r; pp^ = c; parallel { spawn entry(r); c^ = 1; }", true},
	{"spawn_copy_by_call", "@(escape=stored) c: ^mut int", "v := 1; r := &mut v; pp := &mut r; keep_pointer(pp, c); parallel { spawn entry(r); c^ = 1; }", true},
	{"spawn_field_by_call", "@(escape=stored) c: ^mut int", "v := 1; l := Link{&mut v}; keep(&mut l, c); parallel { spawn entry(l.to); c^ = 1; }", true},
	{"spawn_field_by_hand", "@(escape=stored) c: ^mut int", "v := 1; l := Link{&mut v}; p := &mut l; p^.to = c; parallel { spawn entry(l.to); c^ = 1; }", true},
	{"spawn_named_copy_by_call", "@(escape=stored) c: ^mut int", "v := 1; l := Link{&mut v}; keep(&mut l, c); x := l.to; parallel { spawn entry(x); c^ = 1; }", true},
	{"spawn_named_copy_by_hand", "@(escape=stored) c: ^mut int", "v := 1; l := Link{&mut v}; p := &mut l; p^.to = c; x := l.to; parallel { spawn entry(x); c^ = 1; }", true},
	{"spawn_read_only_by_call", "@(escape=stored) c: ^mut int", "v := 1; ro := RoLink{&v}; keep_ro(&mut ro, c); parallel { spawn read_entry(ro.to); c^ = 1; }", true},
	{"spawn_read_only_named_by_call", "@(escape=stored) c: ^mut int", "v := 1; ro := RoLink{&v}; keep_ro(&mut ro, c); x := ro.to; parallel { spawn read_entry(x); c^ = 1; }", true},
	{"spawn_read_only_by_hand", "@(escape=stored) c: ^mut int", "v := 1; ro := RoLink{&v}; p := &mut ro; p^.to = c; parallel { spawn read_entry(ro.to); c^ = 1; }", true},
	{"spawn_done_by_call", "@(escape=stored) c: ^mut int", "v := 1; r := &mut v; pp := &mut r; keep_pointer(pp, c); parallel { spawn entry(r); } c^ = 1;", false},
	{"spawn_two_copies_by_call", "@(escape=stored) c: ^mut int", "v := 1; l := Link{&mut v}; keep(&mut l, c); parallel { spawn entry(l.to); spawn entry(c); }", true},
	{"spawn_two_copies_by_hand", "@(escape=stored) c: ^mut int", "v := 1; l := Link{&mut v}; p := &mut l; p^.to = c; parallel { spawn entry(l.to); spawn entry(c); }", true},
	{"spawn_two_named_by_call", "@(escape=stored) c: ^mut int", "v := 1; l := Link{&mut v}; keep(&mut l, c); x := l.to; parallel { spawn entry(x); spawn entry(c); }", true},
	{"spawn_two_read_only_named_by_call", "@(escape=stored) c: ^mut int", "v := 1; ro := RoLink{&v}; keep_ro(&mut ro, c); x := ro.to; parallel { spawn read_entry(x); spawn entry(c); }", true},
}

@(test)
walk_reader_matrix :: proc(t: ^testing.T) {
	source := strings.builder_make(context.temp_allocator)
	strings.write_string(&source, WALK_READER_PRELUDE)
	first := strings.count(WALK_READER_PRELUDE, "\n") + 1
	for entry in WALK_READER_CASES {
		// Every case takes up four lines, which the check below counts on.
		fmt.sbprintf(&source, "%s :: proc(%s) {{\n\t\n\t%s\n}}\n", entry.name, entry.params, entry.body)
	}
	strings.write_string(&source, "main :: proc() {}\n")
	names := []string{"walk_reader"}
	sources := []string{strings.to_string(source)}
	errors, compiled := store_matrix_compile(t, names, sources)
	if !compiled {
		return
	}
	for entry, at in WALK_READER_CASES {
		store_matrix_expect(t, names[0], entry.name, first + 4 * at, errors[0], entry.rejected)
	}
}

// What a task is lent of a mutable carrier (design.md "Task borrows and the join"): a
// read-only argument keeps what it borrows read-only borrowed until the join, so others may
// read it and nothing may write it, and a mutable carrier is the task's alone. Each
// verdict is worked out by hand as above.
@(private = "file")
TASK_LENDING_PRELUDE :: `package main;
Link :: struct { to: ^mut int }
RoLink :: struct { to: ^int }
Node :: struct { v: int, w: int }
Holder :: struct { l: ^mut Link }
Views :: struct { s: []mut int }
read_int :: proc(p: ^int) { y := p^; }
write_int :: proc(p: ^mut int) { p^ = 1; }
read_view :: proc(s: []int) { y := s[0]; }
write_view :: proc(s: []mut int) { s[0] = 1; }
read_ro :: proc(r: RoLink) { y := r.to^; }
read_node :: proc(n: ^Node) { y := n^.v; }
write_node :: proc(n: ^mut Node) { n^.v = 1; }
keep_ro :: proc(dst: ^mut RoLink, @(escape=stored) c: ^mut int) { dst^.to = c; }
flip :: proc() -> bool { return true; }
Shape :: interface($Self: type) { slot area: proc(self: ^Self) -> int; }
impl Node { area :: proc(self: ^Node) -> int { return self.v; } }
take_shape :: proc(s: dyn Shape) { y := s.area(); }
NodeRef :: struct { n: ^mut Node }
take_view_ptr :: proc(n: ^Node) { y := n^.v; }
`

@(private = "file")
TASK_LENDING_CASES := [?]Stored_Reach_Case {
	// The carrier itself.
	{"carrier_written", "c: ^mut int", "parallel { spawn read_int(c); c^ = 1; }", true},
	{"carrier_written_first", "c: ^mut int", "c^ = 1; parallel { spawn read_int(c); }", false},
	{"carrier_written_after_join", "c: ^mut int", "parallel { spawn read_int(c); } c^ = 1;", false},
	{"carrier_read", "c: ^mut int", "parallel { spawn read_int(c); y := c^; }", false},
	{"carrier_read_twice", "c: ^mut int", "parallel { spawn read_int(c); spawn read_int(c); }", false},
	{"carrier_then_writer", "c: ^mut int", "parallel { spawn read_int(c); spawn write_int(c); }", true},
	{"writer_then_carrier", "c: ^mut int", "parallel { spawn write_int(c); spawn read_int(c); }", true},
	{"writer_twice", "c: ^mut int", "parallel { spawn write_int(c); spawn write_int(c); }", true},
	{"writer_then_read", "c: ^mut int", "parallel { spawn write_int(c); y := c^; }", true},
	{"carrier_written_in_branch", "c: ^mut int", "parallel { spawn read_int(c); if (flip()) { c^ = 1; } }", true},
	{"spawned_in_branch_written", "c: ^mut int", "parallel { if (flip()) { spawn read_int(c); } c^ = 1; }", true},
	{"written_in_nested_block", "c: ^mut int", "parallel { spawn read_int(c); parallel { spawn write_int(c); } }", true},
	{"two_blocks_in_turn", "c: ^mut int", "parallel { spawn read_int(c); } parallel { spawn write_int(c); } parallel { spawn read_int(c); }", false},
	{"loop_of_blocks", "c: ^mut int", "for (i := 0; i < 2; i += 1) { parallel { spawn read_int(c); } c^ = 1; }", false},
	{"spawned_in_loop_written_after", "c: ^mut int", "parallel { for (i := 0; i < 2; i += 1) { spawn read_int(c); } c^ = 1; }", true},
	{"spawned_in_loop_read_after", "c: ^mut int", "parallel { for (i := 0; i < 2; i += 1) { spawn read_int(c); } y := c^; }", false},
	// A read-only copy.
	{"copy_written", "c: ^mut int", "x: ^int = c; parallel { spawn read_int(x); c^ = 1; }", true},
	{"copy_written_after_join", "c: ^mut int", "x: ^int = c; parallel { spawn read_int(x); } c^ = 1;", false},
	{"copy_of_copy_written", "c: ^mut int", "x: ^int = c; q := x; parallel { spawn read_int(q); c^ = 1; }", true},
	{"copy_read_by_parent", "c: ^mut int", "x: ^int = c; parallel { spawn read_int(x); y := x^; }", false},
	{"copy_read_through_carrier", "c: ^mut int", "x: ^int = c; parallel { spawn read_int(x); y := c^; }", false},
	{"copy_read_twice", "c: ^mut int", "x: ^int = c; parallel { spawn read_int(x); spawn read_int(x); }", false},
	{"copy_and_carrier_read", "c: ^mut int", "x: ^int = c; parallel { spawn read_int(x); spawn read_int(c); }", false},
	{"copy_then_writer", "c: ^mut int", "x: ^int = c; parallel { spawn read_int(x); spawn write_int(c); }", true},
	{"copy_replaced_while_lent", "c: ^mut int, d: ^int", "x: ^int = c; parallel { spawn read_int(x); x = d; y := x^; }", false},
	{"copy_replaced_then_written", "c: ^mut int, d: ^int", "x: ^int = c; parallel { spawn read_int(x); x = d; c^ = 1; }", true},
	{"plain_read_only_shared", "r: ^int", "parallel { spawn read_int(r); y := r^; spawn read_int(r); }", false},
	{"unrelated_carrier_written", "c: ^mut int, d: ^mut int", "parallel { spawn read_int(c); d^ = 1; }", false},
	// A mutable copy weakened at the call.
	{"mutable_copy_written", "c: ^mut int", "x := c; parallel { spawn read_int(x); c^ = 1; }", true},
	{"mutable_copy_done_read", "c: ^mut int", "x := c; parallel { spawn read_int(x); y := x^; }", false},
	{"mutable_copy_written_through_it", "c: ^mut int", "x := c; parallel { spawn read_int(x); x^ = 1; }", true},
	// Views.
	{"view_written", "s: []mut int", "parallel { spawn read_view(s); s[0] = 1; }", true},
	{"view_read", "s: []mut int", "parallel { spawn read_view(s); y := s[0]; }", false},
	{"view_written_after_join", "s: []mut int", "parallel { spawn read_view(s); } s[0] = 1;", false},
	{"view_then_writer", "s: []mut int", "parallel { spawn read_view(s); spawn write_view(s); }", true},
	{"view_read_twice", "s: []mut int", "parallel { spawn read_view(s); spawn read_view(s); }", false},
	{"view_copy_written", "s: []mut int", "x: []int = s; parallel { spawn read_view(x); s[0] = 1; }", true},
	{"slice_written_same", "s: []mut int", "parallel { spawn read_view(s[:2]); s[0] = 1; }", true},
	{"slice_read", "s: []mut int", "parallel { spawn read_view(s[:2]); y := s[0]; }", false},
	{"slice_named_written", "s: []mut int", "x := s[:2]; parallel { spawn read_view(x); s[0] = 1; }", true},
	{"element_written", "s: []mut int", "parallel { spawn read_int(&s[0]); s[0] = 1; }", true},
	{"element_read", "s: []mut int", "parallel { spawn read_int(&s[0]); y := s[0]; }", false},
	// Through a pointer.
	{"pointee_field_written", "n: ^mut Node", "parallel { spawn read_int(&n^.v); n^.v = 1; }", true},
	{"pointee_field_read", "n: ^mut Node", "parallel { spawn read_int(&n^.v); y := n^.v; }", false},
	{"pointee_other_field_written", "n: ^mut Node", "parallel { spawn read_int(&n^.v); n^.w = 1; }", false},
	{"pointee_whole_written", "n: ^mut Node", "parallel { spawn read_node(n); n^.v = 1; }", true},
	{"pointee_whole_writer", "n: ^mut Node", "parallel { spawn read_node(n); spawn write_node(n); }", true},
	{"pointee_whole_read", "n: ^mut Node", "parallel { spawn read_node(n); y := n^.v; }", false},
	{"carrier_in_a_field_written", "l: ^mut Link", "parallel { spawn read_int(l^.to); l^.to^ = 1; }", true},
	{"carrier_in_a_field_read", "l: ^mut Link", "parallel { spawn read_int(l^.to); y := l^.to^; }", false},
	{"carrier_in_a_field_copy_written", "l: ^mut Link", "x: ^int = l^.to; parallel { spawn read_int(x); l^.to^ = 1; }", true},
	// Loaded out of a field: no link exists during the walk.
	{"field_writer_then_written", "l: ^mut Link", "parallel { spawn write_int(l^.to); l^.to^ = 1; }", true},
	{"field_writer_then_read", "l: ^mut Link", "parallel { spawn write_int(l^.to); y := l^.to^; }", true},
	{"field_writer_twice", "l: ^mut Link", "parallel { spawn write_int(l^.to); spawn write_int(l^.to); }", true},
	{"field_reader_then_writer", "l: ^mut Link", "parallel { spawn read_int(l^.to); spawn write_int(l^.to); }", true},
	{"field_writer_then_reader", "l: ^mut Link", "parallel { spawn write_int(l^.to); spawn read_int(l^.to); }", true},
	{"field_reader_twice", "l: ^mut Link", "parallel { spawn read_int(l^.to); spawn read_int(l^.to); }", false},
	{"field_writer_after_join", "l: ^mut Link", "parallel { spawn write_int(l^.to); } l^.to^ = 1; y := l^.to^;", false},
	{"field_replaced_while_read", "l: ^mut Link, @(escape=stored) d: ^mut int", "parallel { spawn read_int(l^.to); l^.to = d; }", false},
	{"field_of_view_written", "s: []mut Link", "parallel { spawn read_int(s[0].to); s[0].to^ = 1; }", true},
	{"field_of_view_writer_twice", "s: []mut Link", "parallel { spawn write_int(s[0].to); spawn write_int(s[0].to); }", true},
	{"field_of_view_other_element", "s: []mut Link", "parallel { spawn write_int(s[0].to); spawn write_int(s[1].to); }", false},
	{"field_of_local_written", "", "v := 1; a := Link{&mut v}; parallel { spawn read_int(a.to); a.to^ = 1; }", true},
	{"field_of_local_writer_twice", "", "v := 1; a := Link{&mut v}; parallel { spawn write_int(a.to); spawn write_int(a.to); }", true},
	{"deep_field_writer_twice", "h: ^mut Holder", "parallel { spawn write_int(h^.l^.to); spawn write_int(h^.l^.to); }", true},
	{"deep_field_reader_written", "h: ^mut Holder", "parallel { spawn read_int(h^.l^.to); h^.l^.to^ = 1; }", true},
	{"deep_view_writer_twice", "v: ^mut Views", "parallel { spawn write_view(v^.s); spawn write_view(v^.s); }", true},
	{"deep_view_reader_written", "v: ^mut Views", "parallel { spawn read_view(v^.s); v^.s[0] = 1; }", true},
	{"deep_view_reader_read", "v: ^mut Views", "parallel { spawn read_view(v^.s); y := v^.s[0]; }", false},
	{"loaded_read_only_never_conflicts", "r: ^mut RoLink", "parallel { spawn read_int(r^.to); y := r^.to^; spawn read_int(r^.to); }", false},
	// In a value.
	{"record_written", "c: ^mut int", "r := RoLink{c}; parallel { spawn read_ro(r); c^ = 1; }", true},
	{"record_read", "c: ^mut int", "r := RoLink{c}; parallel { spawn read_ro(r); y := c^; }", false},
	{"record_literal_written", "c: ^mut int", "parallel { spawn read_ro(RoLink{c}); c^ = 1; }", true},
	// A view converted at the spawn.
	{"dyn_view_twice", "n: ^mut Node", "parallel { spawn take_shape((dyn Shape)(n)); spawn take_shape((dyn Shape)(n)); }", false},
	{"dyn_view_read_by_parent", "n: ^mut Node", "parallel { spawn take_shape((dyn Shape)(n)); y := n^.v; }", false},
	{"dyn_view_written", "n: ^mut Node", "parallel { spawn take_shape((dyn Shape)(n)); n^.v = 1; }", true},
	{"dyn_view_then_writer", "n: ^mut Node", "parallel { spawn take_shape((dyn Shape)(n)); spawn write_node(n); }", true},
	{"writer_then_dyn_view", "n: ^mut Node", "parallel { spawn write_node(n); spawn take_shape((dyn Shape)(n)); }", true},
	{"dyn_view_after_join", "n: ^mut Node", "parallel { spawn take_shape((dyn Shape)(n)); } n^.v = 1;", false},
	{"view_of_local_carrier_twice", "", "v := Node{1, 2}; n := &mut v; parallel { spawn take_shape((dyn Shape)(n)); spawn take_shape((dyn Shape)(n)); }", false},
	{"view_named_twice", "n: ^mut Node", "s := (dyn Shape)(n); parallel { spawn take_shape(s); spawn take_shape(s); }", false},
	{"view_named_written", "n: ^mut Node", "s := (dyn Shape)(n); parallel { spawn take_shape(s); n^.v = 1; }", true},
	{"view_of_loaded_twice", "r: ^mut NodeRef", "parallel { spawn take_shape((dyn Shape)(r^.n)); spawn take_shape((dyn Shape)(r^.n)); }", false},
	{"view_of_loaded_written", "r: ^mut NodeRef", "parallel { spawn take_shape((dyn Shape)(r^.n)); r^.n^.v = 1; }", true},
	{"view_of_local_field_twice", "n: ^mut Node", "h := NodeRef{n}; parallel { spawn take_shape((dyn Shape)(h.n)); spawn take_shape((dyn Shape)(h.n)); }", false},
	{"pointer_converted_twice", "n: ^mut Node", "parallel { spawn take_view_ptr((^Node)(n)); spawn take_view_ptr((^Node)(n)); }", false},
	{"pointer_converted_written", "n: ^mut Node", "parallel { spawn take_view_ptr((^Node)(n)); n^.v = 1; }", true},
	{"slice_converted_twice", "s: []mut int", "parallel { spawn read_view(([]int)(s)); spawn read_view(([]int)(s)); }", false},
	{"slice_converted_written", "s: []mut int", "parallel { spawn read_view(([]int)(s)); s[0] = 1; }", true},
	// A conversion outside a task reads as a read-only parameter does.
	{"converted_outside_a_task_twice", "c: ^mut int", "x := (^int)(c); y := (^int)(c); a := x^; b := y^;", false},
	{"converted_outside_a_task_written", "c: ^mut int", "x := (^int)(c); c^ = 1; a := x^;", true},
	{"converted_outside_a_task_done", "c: ^mut int", "x := (^int)(c); a := x^; c^ = 1;", false},
	{"view_outside_a_task_written", "n: ^mut Node", "s := (dyn Shape)(n); n^.v = 1; take_shape(s);", true},
	{"view_outside_a_task_done", "n: ^mut Node", "s := (dyn Shape)(n); take_shape(s); n^.v = 1;", false},
	{"view_outside_a_task_twice", "n: ^mut Node", "s := (dyn Shape)(n); t := (dyn Shape)(n); take_shape(s); take_shape(t);", false},
	{"mutable_copy_live_across_conversion", "c: ^mut int", "x := c; y := (^int)(c); x^ = 1; a := y^;", true},
	// What a store or a call left.
	{"kept_field", "@(escape=stored) c: ^mut int", "v := 1; ro := RoLink{&v}; keep_ro(&mut ro, c); parallel { spawn read_int(ro.to); c^ = 1; }", true},
	{"kept_named", "@(escape=stored) c: ^mut int", "v := 1; ro := RoLink{&v}; keep_ro(&mut ro, c); x := ro.to; parallel { spawn read_int(x); c^ = 1; }", true},
	{"kept_named_then_writer", "@(escape=stored) c: ^mut int", "v := 1; ro := RoLink{&v}; keep_ro(&mut ro, c); x := ro.to; parallel { spawn read_int(x); spawn write_int(c); }", true},
	{"kept_read", "@(escape=stored) c: ^mut int", "v := 1; ro := RoLink{&v}; keep_ro(&mut ro, c); x := ro.to; parallel { spawn read_int(x); y := c^; }", false},
	{"kept_after_join", "@(escape=stored) c: ^mut int", "v := 1; ro := RoLink{&v}; keep_ro(&mut ro, c); x := ro.to; parallel { spawn read_int(x); } c^ = 1;", false},
	{"stored_by_hand_field", "@(escape=stored) c: ^mut int", "v := 1; ro := RoLink{&v}; p := &mut ro; p^.to = c; parallel { spawn read_int(ro.to); c^ = 1; }", true},
	{"stored_by_hand_named", "@(escape=stored) c: ^mut int", "v := 1; ro := RoLink{&v}; p := &mut ro; p^.to = c; x := ro.to; parallel { spawn read_int(x); c^ = 1; }", true},
	{"stored_directly_field", "@(escape=stored) c: ^mut int", "v := 1; ro := RoLink{&v}; ro.to = c; parallel { spawn read_int(ro.to); c^ = 1; }", true},
	{"stored_directly_named", "@(escape=stored) c: ^mut int", "v := 1; ro := RoLink{&v}; ro.to = c; x := ro.to; parallel { spawn read_int(x); c^ = 1; }", true},
	{"copied_before_the_store", "@(escape=stored) c: ^mut int", "v := 1; ro := RoLink{&v}; x := ro.to; keep_ro(&mut ro, c); parallel { spawn read_int(x); c^ = 1; }", false},
	// A local, which the loan already covered.
	{"local_written", "", "v := 1; parallel { spawn read_int(&v); v = 1; }", true},
	{"local_named_written", "", "v := 1; x := &v; parallel { spawn read_int(x); v = 1; }", true},
	{"local_read", "", "v := 1; parallel { spawn read_int(&v); y := v; }", false},
	{"local_view_written", "", "a := [2]int{1, 2}; parallel { spawn read_view(a[:]); a[0] = 1; }", true},
	{"local_mutable_carrier_read_only", "", "v := 1; m := &mut v; parallel { spawn read_int(m); m^ = 1; }", true},
}

@(test)
task_lending_matrix :: proc(t: ^testing.T) {
	source := strings.builder_make(context.temp_allocator)
	strings.write_string(&source, TASK_LENDING_PRELUDE)
	first := strings.count(TASK_LENDING_PRELUDE, "\n") + 1
	for entry in TASK_LENDING_CASES {
		// Every case takes up four lines, which the check below counts on.
		fmt.sbprintf(&source, "%s :: proc(%s) {{\n\t\n\t%s\n}}\n", entry.name, entry.params, entry.body)
	}
	strings.write_string(&source, "main :: proc() {}\n")
	names := []string{"task_lending"}
	sources := []string{strings.to_string(source)}
	errors, compiled := store_matrix_compile(t, names, sources)
	if !compiled {
		return
	}
	for entry, at in TASK_LENDING_CASES {
		store_matrix_expect(t, names[0], entry.name, first + 4 * at, errors[0], entry.rejected)
	}
}

// A call given a record by value holding a carrier (design.md "Weakening and reborrows"):
// handing it over uses what its carriers point to, as handing over the carrier does.
// Each verdict is worked out by hand as above.
@(private = "file")
RECORD_BY_VALUE_PRELUDE :: `package main;
Link :: struct { to: ^mut int }
Holder :: struct { links: []mut Link }
Ro_Holder :: struct { links: []Link }
Ptr_Holder :: struct { l: ^mut Link }
Ro_Ptr_Holder :: struct { l: ^Link }
Deep :: struct { h: Holder }
Plain :: struct { p: ^mut int, n: int }
Mixed :: struct { links: []mut Link, n: ^mut int }
Either :: union { holder: Holder, number: int }
Some :: struct { n: int }
take_holder :: proc(holder: Holder) {}
duplicate :: proc(holder: Holder) { holder.links[0] = holder.links[1]; }
take_ro :: proc(holder: Ro_Holder) {}
take_ptr :: proc(holder: Ptr_Holder) {}
take_ro_ptr :: proc(holder: Ro_Ptr_Holder) {}
take_deep :: proc(deep: Deep) {}
take_plain :: proc(plain: Plain) {}
take_mixed :: proc(mixed: Mixed) {}
take_two :: proc(a: Holder, b: Holder) {}
take_array :: proc(holders: [2]Holder) {}
take_either :: proc(either: Either) {}
take_view :: proc(links: []mut Link) {}
Two_Holders :: struct { a: Holder, b: Holder }
Two_Views :: struct { a: []mut Link, b: []mut Link }
take_two_views :: proc(a: []mut Link, b: []mut Link) {}
take_moved :: proc(holder: move Holder) {}
Ptr_Pair :: struct { a: ^mut int, b: ^mut int, n: int }
dup_view :: proc(links: []mut Link) { links[0] = links[1]; }
take_ro_view :: proc(links: []Link) {}
take_value :: proc(value: int) {}
take_any :: proc(@(escape=stored) holder: Holder, dst: ^mut Holder) { dst^ = holder; }
flip :: proc() -> bool { return true; }
impl Holder {
	by_value :: proc(self: Holder) {}
}
Call :: struct { p: ^mut int, n: int }
impl Call { size :: proc(self) -> int { return self.n; } }
impl Ptr_Pair {
	size :: proc(self: ^) -> int { return self.n; }
}
`

@(private = "file")
RECORD_BY_VALUE_CASES := [?]Stored_Reach_Case {
	// The record's view.
	{"copy_live_across", "h: Holder", "x := h.links[0].to; duplicate(h); x^ = 1;", true},
	{"copy_live_across_no_write", "h: Holder", "x := h.links[0].to; take_holder(h); x^ = 1;", true},
	{"copy_done_first", "h: Holder", "x := h.links[0].to; x^ = 1; duplicate(h);", false},
	{"copy_after_call", "h: Holder", "duplicate(h); x := h.links[0].to; x^ = 1;", false},
	{"copy_read_across", "h: Holder", "x := h.links[0].to; take_holder(h); y := x^;", true},
	{"no_copy_no_body", "h: Holder", "take_holder(h); take_holder(h);", false},
	{"after_a_copy", "h: Holder", "duplicate(h); take_holder(h);", true},
	{"after_a_copy_view_form", "s: []mut Link", "dup_view(s); take_view(s);", true},
	{"copy_of_copy_across", "h: Holder", "x := h.links[0].to; q := x; take_holder(h); q^ = 1;", true},
	{"copy_replaced_before_call", "h: Holder, @(escape=stored) d: ^mut int", "x := h.links[0].to; x = d; take_holder(h); x^ = 1;", false},
	{"whole_element_copy_across", "h: Holder", "e := h.links[0]; take_holder(h); e.to^ = 1;", true},
	{"view_copy_across", "h: Holder", "q := h.links; take_holder(h); q[0].to^ = 1;", true},
	{"in_a_branch", "h: Holder", "x := h.links[0].to; if (flip()) { take_holder(h); } x^ = 1;", true},
	{"in_a_loop", "h: Holder", "x := h.links[0].to; for (i := 0; i < 2; i += 1) { take_holder(h); } x^ = 1;", true},
	{"read_before_call_in_loop", "h: Holder", "for (i := 0; i < 2; i += 1) { x := h.links[0].to; take_holder(h); x^ = 1; }", true},
	{"read_done_in_loop", "h: Holder", "for (i := 0; i < 2; i += 1) { x := h.links[0].to; x^ = 1; take_holder(h); }", false},
	// By name and in a literal.
	{"view_by_name_literal", "s: []mut Link", "x := s[0].to; take_holder(Holder{s}); x^ = 1;", true},
	{"view_by_name_literal_done", "s: []mut Link", "x := s[0].to; x^ = 1; take_holder(Holder{s});", false},
	{"view_by_name_local", "s: []mut Link", "h := Holder{s}; x := h.links[0].to; take_holder(h); x^ = 1;", true},
	{"view_by_name_local_read_through_original", "s: []mut Link", "h := Holder{s}; x := s[0].to; take_holder(h); x^ = 1;", true},
	{"local_array", "", "v0 := 1; v1 := 2; ls := [2]Link{Link{&mut v0}, Link{&mut v1}}; h := Holder{&mut ls[:]}; x := h.links[0].to; take_holder(h); x^ = 1;", true},
	{"local_array_done", "", "v0 := 1; v1 := 2; ls := [2]Link{Link{&mut v0}, Link{&mut v1}}; h := Holder{&mut ls[:]}; x := h.links[0].to; x^ = 1; take_holder(h);", false},
	// The carrier itself, as the rule's baseline.
	{"view_passed", "s: []mut Link", "x := s[0].to; take_view(s); x^ = 1;", true},
	{"view_passed_read_only", "s: []mut Link", "x := s[0].to; take_ro_view(s); x^ = 1;", true},
	{"field_view_passed", "h: Holder", "x := h.links[0].to; take_view(h.links); x^ = 1;", true},
	// Other shapes.
	{"pointer_in_record", "h: Ptr_Holder", "x := h.l^.to; take_ptr(h); x^ = 1;", true},
	{"pointer_in_record_done", "h: Ptr_Holder", "x := h.l^.to; x^ = 1; take_ptr(h);", false},
	{"read_only_pointer_in_record", "h: Ro_Ptr_Holder, l: ^mut Link", "x := l^.to; take_ro_ptr(Ro_Ptr_Holder{l}); x^ = 1;", true},
	{"read_only_pointer_done", "l: ^mut Link", "x := l^.to; x^ = 1; take_ro_ptr(Ro_Ptr_Holder{l});", false},
	{"read_only_view_in_record", "s: []mut Link", "x := s[0].to; take_ro(Ro_Holder{s}); x^ = 1;", true},
	{"read_only_view_read_only_copy", "s: []mut Link", "x: ^int = s[0].to; take_ro(Ro_Holder{s}); y := x^;", false},
	{"read_only_view_read_only_copy_mutable_call", "s: []mut Link", "x: ^int = s[0].to; take_holder(Holder{s}); y := x^;", true},
	{"read_only_view_kept_reading", "h: Ro_Holder", "take_ro(h); y := h.links[0].to^;", false},
	{"nested_record", "d: Deep", "x := d.h.links[0].to; take_deep(d); x^ = 1;", true},
	{"nested_record_done", "d: Deep", "x := d.h.links[0].to; x^ = 1; take_deep(d);", false},
	{"field_record_passed", "d: Deep", "x := d.h.links[0].to; take_holder(d.h); x^ = 1;", true},
	{"array_of_records", "hs: [2]Holder", "x := hs[0].links[0].to; take_array(hs); x^ = 1;", true},
	{"element_of_records_passed", "hs: [2]Holder", "x := hs[0].links[0].to; take_holder(hs[0]); x^ = 1;", true},
	{"other_element_of_records_passed", "hs: [2]Holder", "x := hs[0].links[0].to; take_holder(hs[1]); x^ = 1;", false},
	{"two_records_either", "h: Holder, g: Holder", "x := h.links[0].to; take_two(g, h); x^ = 1;", true},
	{"unrelated_record", "h: Holder, g: Holder", "x := h.links[0].to; take_holder(g); x^ = 1;", false},
	{"mixed_record_view", "m: Mixed", "x := m.links[0].to; take_mixed(m); x^ = 1;", true},
	{"mixed_record_done", "m: Mixed", "x := m.links[0].to; x^ = 1; take_mixed(m);", false},
	{"union_value", "h: Holder", "x := h.links[0].to; take_either(Either.holder(h)); x^ = 1;", true},
	{"method_by_value", "h: Holder", "x := h.links[0].to; h.by_value(); x^ = 1;", true},
	{"method_by_value_done", "h: Holder", "x := h.links[0].to; x^ = 1; h.by_value();", false},
	{"indirect_call", "h: Holder, f: proc(holder: Holder)", "x := h.links[0].to; f(h); x^ = 1;", true},
	{"indirect_call_done", "h: Holder, f: proc(holder: Holder)", "x := h.links[0].to; x^ = 1; f(h);", false},
	// What reaches no carrier stays free.
	{"plain_pointer_in_record", "p: Plain", "q := p.n; take_plain(p); r := q;", false},
	{"plain_pointer_copy_across", "p: Plain", "q := p.p; take_plain(p); q^ = 1;", true},
	{"plain_pointer_read_across", "p: Plain", "y: ^int = p.p; take_plain(p); z := y^;", true},
	{"value_of_a_field", "l: Link", "x := l.to^; take_value(x); y := l.to^;", false},
	{"number_in_record", "s: Some", "n := s.n; take_value(n); m := s.n;", false},
	// What a call may leave.
	{"kept_then_copy", "@(escape=stored) h: Holder, d: ^mut Holder", "take_any(h, d); x := d^.links[0].to; take_holder(h); x^ = 1;", true},
	// A spawn, which shares nothing mutable.
	{"spawn_by_value_across", "h: Holder", "x := h.links[0].to; parallel { spawn take_holder(h); x^ = 1; }", true},
	{"spawn_shares_mutable", "h: Holder", "x := h.links[0].to; x^ = 1; parallel { spawn take_holder(h); }", true},
	// The compiler's own operations run nothing that uses it.
	{"stored_by_compiler_operation", "h: Holder", "list := [dynamic]Holder{}; x := h.links[0].to; list.append(h); x^ = 1;", false},
	{"printed_field_number", "s: Some", "n := s.n; take_value(n);", false},
	// Moved in: what the record reaches is still reached.
	{"moved_across", "h: move Holder", "x := h.links[0].to; take_moved(move(h)); x^ = 1;", true},
	{"moved_done", "h: move Holder", "x := h.links[0].to; x^ = 1; take_moved(move(h));", false},
	// Behind a pointer: only that record.
	{"record_behind_pointer", "p: ^mut Holder", "x := p^.links[0].to; take_holder(p^); x^ = 1;", true},
	{"record_behind_pointer_done", "p: ^mut Holder", "x := p^.links[0].to; x^ = 1; take_holder(p^);", false},
	{"record_behind_read_only_pointer", "p: ^Holder, s: []mut Link", "x := s[0].to; h := Holder{s}; q := &h; take_holder(q^); x^ = 1;", true},
	{"two_fields_behind_pointer", "p: ^mut Two_Holders", "take_two(p^.a, p^.b);", false},
	{"two_fields_of_pointer_copy_across", "p: ^mut Two_Holders", "x := p^.a.links[0].to; take_two(p^.a, p^.b); x^ = 1;", true},
	{"sibling_field_copy_across", "p: ^mut Two_Holders", "x := p^.a.links[0].to; take_holder(p^.b); x^ = 1;", false},
	{"same_field_twice", "p: ^mut Two_Holders", "take_two(p^.a, p^.a);", true},
	{"two_views_behind_pointer", "p: ^mut Two_Views", "take_two_views(p^.a, p^.b);", false},
	{"record_behind_pointer_twice", "p: ^mut Holder", "take_holder(p^); take_holder(p^);", false},
	{"record_in_view_element", "hs: []mut Holder", "x := hs[0].links[0].to; take_holder(hs[0]); x^ = 1;", true},
	{"record_in_view_element_done", "hs: []mut Holder", "x := hs[0].links[0].to; x^ = 1; take_holder(hs[0]);", false},
	{"record_method_behind_pointer", "p: ^mut Holder", "x := p^.links[0].to; p^.by_value(); x^ = 1;", true},
	// A receiver written `self: ^` is lent.
	{"borrowed_receiver_field", "l: ^mut Ptr_Pair", "n := l^.size(); y := l^.a; l^.b^ = 1; y^ = n;", false},
	{"borrowed_receiver_across", "l: ^mut Ptr_Pair", "y := l^.a; n := l^.size(); y^ = n;", true},
	{"borrowed_receiver_read_only_across", "l: ^mut Ptr_Pair", "y: ^int = l^.a; n := l^.size(); z := y^;", false},
	{"callable_called_through_pointer", "f: ^Call", "g := f; a := g^.size(); b := g^.size();", false},
}

// known-gaps.md "A receiver written `self: ^` behind a carrier conflicts with a read-only copy".
@(private = "file")
record_by_value_over_rejected :: proc(entry: Stored_Reach_Case) -> bool {
	return entry.name == "borrowed_receiver_read_only_across"
}

@(test)
record_by_value_matrix :: proc(t: ^testing.T) {
	source := strings.builder_make(context.temp_allocator)
	strings.write_string(&source, RECORD_BY_VALUE_PRELUDE)
	first := strings.count(RECORD_BY_VALUE_PRELUDE, "\n") + 1
	for entry in RECORD_BY_VALUE_CASES {
		// Every case takes up four lines, which the check below counts on.
		fmt.sbprintf(&source, "%s :: proc(%s) {{\n\t\n\t%s\n}}\n", entry.name, entry.params, entry.body)
	}
	strings.write_string(&source, "main :: proc() {}\n")
	names := []string{"record_by_value"}
	sources := []string{strings.to_string(source)}
	errors, compiled := store_matrix_compile(t, names, sources)
	if !compiled {
		return
	}
	for entry, at in RECORD_BY_VALUE_CASES {
		expected := entry.rejected || record_by_value_over_rejected(entry)
		store_matrix_expect(t, names[0], entry.name, first + 4 * at, errors[0], expected)
	}
}

// Compiles each source, and returns the lines each one reports an error at.
@(private = "file")
store_matrix_compile :: proc(t: ^testing.T, names, sources: []string) -> (errors: [][]int, compiled: bool) {
	os.make_directory(TMP)
	os.make_directory(STORE_MATRIX_DIR)
	jobs := make([]Exec, len(names), context.temp_allocator)
	for name, index in names {
		path := fmt.tprintf("%s/%s.loke", STORE_MATRIX_DIR, name)
		if !testing.expectf(t, os.write_entire_file(path, transmute([]byte)sources[index]) == nil, "%s: cannot write", path) {
			return nil, false
		}
		command := make([]string, 5, context.temp_allocator)
		command[0], command[1], command[2] = compiler_path(), path, "-emit-ll"
		command[3], command[4] = "-o", fmt.tprintf("%s/%s.exe", STORE_MATRIX_DIR, name)
		jobs[index] = Exec{command = command}
	}
	exec_all(jobs)
	errors = make([][]int, len(names), context.temp_allocator)
	for job, index in jobs {
		if !testing.expectf(t, job.err == nil, "%s: cannot run lokec: %v", names[index], job.err) {
			return nil, false
		}
		errors[index] = store_matrix_error_lines(string(job.stderr))
	}
	return errors, true
}

// Whether the four lines of the case at `first` got an error, as `expected` says.
@(private = "file")
store_matrix_expect :: proc(t: ^testing.T, place, name: string, first: int, errors: []int, expected: bool) {
	rejected := false
	for line in errors {
		rejected ||= line >= first && line < first + 4
	}
	testing.expectf(
		t, rejected == expected, "%s, %s (line %d): expected %s, got %s",
		place, name, first, expected ? "a rejection" : "no error", rejected ? "a rejection" : "no error",
	)
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
