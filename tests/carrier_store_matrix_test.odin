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
