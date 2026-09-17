// Carrier shapes: the structural queries on the type graph, and the provenance
// precision they promise to programs.
package lokec

import "core:strings"
import "core:testing"

@(private = "file")
named_type :: proc(t: ^testing.T, p: ^Checked, name: string) -> Type_Id {
	for item in p.f.items {
		d, ok := item.(^Decl)
		if !ok || len(d.symbols) == 0 {
			continue
		}
		sym := symbol_of(&p.c, d.symbols[0])
		if sym != nil && sym.kind == .Type && identifier_text(&p.c, sym.name) == name {
			return sym.type
		}
	}
	testing.expectf(t, false, "test type `%s` was not found", name)
	return INVALID_TYPE
}

@(test)
a_bare_carrier_is_one_empty_path :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, `package main;
Alias :: distinct []int
main :: proc() { }`)

	shape := carrier_shape(&p.c, named_type(t, &p, "Alias"))
	if !testing.expectf(t, len(shape) == 1, "expected one path, got %d", len(shape)) { return }
	testing.expect(t, len(shape[0].steps) == 0, "a bare carrier's path is the value itself")
	testing.expect(t, !shape[0].truncated, "a bare carrier is not truncated")
}

@(test)
a_scalar_record_has_no_paths :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, `package main;
Plain :: struct { a: int, b: f64, c: bool }
main :: proc() { }`)

	plain := named_type(t, &p, "Plain")
	testing.expect(t, len(carrier_shape(&p.c, plain)) == 0, "a scalar record carries nothing")
	testing.expect(t, !type_carries_borrow(&p.c, plain).any, "reachability disagrees with the shape")
}

@(test)
record_fields_are_distinct_paths :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, `package main;
Pair :: struct { left: []int, count: int, right: ^mut int }
main :: proc() { }`)

	shape := carrier_shape(&p.c, named_type(t, &p, "Pair"))
	if !testing.expectf(t, len(shape) == 2, "expected two carrier fields, got %d", len(shape)) { return }
	has_left, has_right := false, false
	for path in shape {
		if !testing.expect(t, len(path.steps) == 1, "a field path should be one step") { continue }
		switch path.steps[0].lo {
		case 0:
			has_left = true
			testing.expect(t, !path.mutable, "a read-only slice field reported a mutable capability")
		case 2:
			has_right = true
			testing.expect(t, path.mutable, "a `^mut` field reported an immutable capability")
		}
	}
	testing.expect(t, has_left && has_right, "the carrier fields are not at their own field indices")
}

@(test)
a_scalar_cycle_terminates_without_paths :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, `package main;
Chain :: struct { rest: [dynamic]Chain, value: int }
main :: proc() { }`)

	chain := named_type(t, &p, "Chain")
	testing.expect(t, !type_carries_borrow(&p.c, chain).any, "a cycle of scalars invented a carrier")
	testing.expect(t, len(carrier_shape(&p.c, chain)) == 0, "a cycle of scalars invented a path")
}

// Neither field order nor querying the recursive edge first may change the answer.
@(test)
a_recursive_shape_is_finite_and_order_independent :: proc(t: ^testing.T) {
	forward := `package main;
Node :: struct { children: [dynamic]Node, labels: []int }
main :: proc() { }`
	reversed := `package main;
Node :: struct { labels: []int, children: [dynamic]Node }
main :: proc() { }`

	shape_of_node :: proc(t: ^testing.T, text: string, inner_first: bool) -> (paths: int, reaches: bool) {
		p: Checked
		defer destroy_checked(&p)
		check_source(&p, text)
		node := named_type(t, &p, "Node")
		if inner_first {
			for field in type_of(&p.c, node).fields {
				if sym := symbol_of(&p.c, field); sym != nil {
					_ = carrier_shape(&p.c, sym.type)
					_ = type_carries_borrow(&p.c, sym.type)
				}
			}
		}
		return len(carrier_shape(&p.c, node)), type_carries_borrow(&p.c, node).any
	}

	a, a_reaches := shape_of_node(t, forward, false)
	b, b_reaches := shape_of_node(t, reversed, false)
	inner, inner_reaches := shape_of_node(t, forward, true)

	testing.expectf(t, a == b, "field order changed the shape: %d versus %d", a, b)
	testing.expectf(t, a == inner, "query order changed the shape: %d versus %d", a, inner)
	testing.expect(t, a_reaches && b_reaches && inner_reaches, "a recursive carrier was not reachable")
	testing.expectf(t, a == 3, "the recursive shape changed: %d paths", a)
}

@(test)
depth_beyond_the_limit_becomes_one_truncated_path :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, `package main;
Five :: struct { view: ^mut int }
Four :: struct { inner: Five }
Three :: struct { inner: Four }
Two :: struct { inner: Three }
One :: struct { inner: Two }
main :: proc() { }`)

	// `Two` reaches its leaf exactly at the limit; `One` is one level deeper.
	deep := carrier_shape(&p.c, named_type(t, &p, "Two"))
	testing.expect(t, len(deep) == 1 && !deep[0].truncated, "a path at the limit was cut")

	over := carrier_shape(&p.c, named_type(t, &p, "One"))
	if !testing.expectf(t, len(over) == 1, "expected one path past the limit, got %d", len(over)) { return }
	testing.expect(t, over[0].truncated, "a path past the depth limit was not marked truncated")
	testing.expect(t, over[0].mutable, "a truncated path hid a mutable carrier below it")
	testing.expect(t, .Depth in over[0].precision, "depth cutoff lost its diagnostic reason")
	testing.expectf(
		t,
		len(over[0].steps) == CARRIER_DEPTH,
		"a truncated path should stop at the limit, got %d steps",
		len(over[0].steps),
	)
}

@(test)
map_keys_and_values_are_separate_paths :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, `package main;
Held :: struct { view: []int }
Table :: struct { entries: map[^int]Held }
main :: proc() { }`)
	if !testing.expect(t, p.c.error_count == 0, "map fixture should check") { report(&p.c); return }

	// One key and one value path per constant-key entry.
	shape := carrier_shape(&p.c, named_type(t, &p, "Table"))
	if !testing.expectf(t, len(shape) == 2 * MAP_KEY_SLOTS, "expected a key and a value path per entry, got %d", len(shape)) {
		return
	}
	seen := make(map[[2]i64]bool, 2 * MAP_KEY_SLOTS, context.temp_allocator)
	for path in shape {
		steps := path.steps
		// `entries`, then the entry, then the key or value side.
		if !testing.expectf(t, len(steps) >= 3, "a map path is missing its entry steps: %d", len(steps)) { continue }
		entry, side := steps[1], steps[2]
		testing.expect(t, side.kind == .Field, "a map path does not separate key from value")
		testing.expect(t, entry.kind == .Range, "a keyed map entry is not a constant range")
		slot := [2]i64{entry.lo, side.lo}
		testing.expect(t, !seen[slot], "two paths share one entry side")
		seen[slot] = true
	}
}

@(test)
a_wide_map_value_keeps_one_entry :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, `package main;
Wide :: struct { a: []int, b: []int, c: []int }
Table :: struct { entries: map[string]Wide }
main :: proc() { }`)

	// Wider than MAP_KEY_PATH_LIMIT, so one wildcard entry instead of per-key copies.
	shape := carrier_shape(&p.c, named_type(t, &p, "Table"))
	if !testing.expectf(t, len(shape) == 3, "expected one path per field, got %d", len(shape)) { return }
	for path in shape {
		if !testing.expect(t, len(path.steps) >= 3, "a map path is missing its entry steps") { continue }
		testing.expect(t, path.steps[len(path.steps) - 3].kind == .Wild, "a wide map value was given keyed entries")
		testing.expect(t, .Map_Width in path.precision, "map width cutoff lost its diagnostic reason")
	}
}

@(test)
minimum_carrier_precision_boundaries :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, `package main;
Eight :: struct { values: [8][]int }
Nine :: struct { values: [9][]int }
SixtyFour :: struct { values: [8][8][]int }
SixtyFive :: struct { first: SixtyFour, last: []int }
Pair :: struct { first, second: []int }
MapPairs :: struct { entries: map[int]Pair }
Leaf :: struct { value: []int }
Two :: struct { value: Leaf }
Three :: struct { value: Two }
Four :: struct { value: Three }
main :: proc() {}`)
	testing.expect(t, p.c.error_count == 0, "boundary types should check")
	eight := carrier_shape(&p.c, named_type(t, &p, "Eight"))
	testing.expect(t, len(eight) == 8, "eight elements must remain independent")
	for path in eight { testing.expect(t, path.precision == {}, "exact array reported precision loss") }
	nine := carrier_shape(&p.c, named_type(t, &p, "Nine"))
	testing.expect(t, len(nine) == 1 && .Array_Elements in nine[0].precision, "nine elements must explain their merge")
	full := carrier_shape(&p.c, named_type(t, &p, "SixtyFour"))
	testing.expect(t, len(full) == 64, "64 paths must remain independent")
	for path in full { testing.expect(t, path.precision == {}, "exact width reported precision loss") }
	over := carrier_shape(&p.c, named_type(t, &p, "SixtyFive"))
	testing.expect(t, len(over) == 1 && .Width in over[0].precision, "65 paths must explain their merge")
	pairs := carrier_shape(&p.c, named_type(t, &p, "MapPairs"))
	testing.expect(t, len(pairs) == 8, "two-path map entries must distinguish four keys")
	for path in pairs { testing.expect(t, path.precision == {}, "two-path map entry reported precision loss") }
	deep := carrier_shape(&p.c, named_type(t, &p, "Four"))
	testing.expect(t, len(deep) == 1 && len(deep[0].steps) == 4 && deep[0].precision == {}, "four projection steps must stay precise")
}

@(test)
precision_explanations_follow_values_and_overwrites :: proc(t: ^testing.T) {
	cases := []struct { body: string, note: string } {
		{`bad :: proc(input: []int) -> []int {
    local := [1]int{2};
    large: [9][]int = {}; large[8] = local[:];
    return local[:];
}`, ""},
		{`bad :: proc(input: []int) -> []int {
    local := [1]int{2};
    large: [9][]int = {}; large[0] = input; large[8] = local[:];
    view := large[0];
    view = local[:];
    return view;
}`, ""},
		{`head :: proc(values: [9][]int) -> []int { return values[0]; }
forward :: proc(values: [9][]int) -> []int { f := head; return f(values); }
bad :: proc(input: []int) -> []int {
    local := [1]int{2};
    large: [9][]int = {}; large[0] = input; large[8] = local[:];
    return forward(large);
}`, "fixed arrays longer than 8 elements"},
		{`Holder :: struct { view: []int }
bad :: proc(input: []int) -> []int {
    local := [1]int{2};
    large: [9][]int = {}; large[0] = input; large[8] = local[:];
    holder := Holder{input};
    pointer := &mut holder;
    pointer^.view = large[0];
    return pointer^.view;
}`, "fixed arrays longer than 8 elements"},
		{`bad :: proc(input: []int, choose: bool) -> []int {
    local := [1]int{2};
    large: [9][]int = {}; large[0] = input; large[8] = local[:];
    view := input;
    if (choose) { view = large[0]; }
    return view;
}`, "fixed arrays longer than 8 elements"},
		{`bad :: proc(input: []int) -> []int {
    local := [1]int{2};
    values: map[int][]int = {};
    values[0] = input; values[1] = input; values[2] = input; values[3] = input;
    values[4] = local[:];
    return values[0];
}`, "only 4 constant map keys per procedure"},
		{`Wide :: struct { matrix: [8][8][]int, other: []int }
bad :: proc(input: []int) -> []int {
    local := [1]int{2};
    value: Wide = {}; value.matrix[0][0] = input; value.other = local[:];
    return value.matrix[0][0];
}`, "more than 64 carrier paths"},
		{`Leaf :: struct { wanted, other: []int }
Two :: struct { value: Leaf }
Three :: struct { value: Two }
Four :: struct { value: Three }
Five :: struct { value: Four }
bad :: proc(input: []int) -> []int {
    local := [1]int{2};
    value: Five = {};
    value.value.value.value.value.wanted = input;
    value.value.value.value.value.other = local[:];
    return value.value.value.value.value.wanted;
}`, "below 4 aggregate projection steps"},
	}
	for item, index in cases {
		p: Checked
		source := strings.concatenate({"package main;\n", item.body, "\nmain :: proc() {}"})
		defer delete(source)
		check_source(&p, source)
		defer destroy_checked(&p)
		if !testing.expectf(t, p.c.error_count == 0, "case %d did not type check: %v", index, p.c.diagnostics[:]) { continue }
		k := Checker{c = &p.c}
		analyze_program_provenance(&k)
		if !testing.expectf(t, p.c.error_count == 1, "case %d: expected one lifetime rejection, got %d", index, p.c.error_count) {
			continue
		}
		found := false
		for diagnostic in p.c.diagnostics {
			for note in diagnostic.notes {
				if strings.contains(note.message, "provenance precision") {
					testing.expectf(t, item.note != "", "case %d: an unrelated or overwritten value added a precision note", index)
					found ||= item.note != "" && strings.contains(note.message, item.note)
				}
			}
		}
		testing.expectf(t, found == (item.note != ""), "case %d: the affected value lost its precision explanation", index)
	}
}

@(test)
four_constant_map_keys_preserve_independence :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, `package main;
read :: proc(input: []int) -> []int {
    local := [1]int{2};
    values: map[int][]int = {};
    values[0] = input; values[1] = input; values[2] = input; values[3] = local[:];
    return values[0];
}
main :: proc() {}`)
	k := Checker{c = &p.c}
	analyze_program_provenance(&k)
	testing.expectf(t, p.c.error_count == 0, "four constant keys lost independence: %v", p.c.diagnostics[:])
}

@(test)
union_alternatives_join_under_one_wildcard :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, `package main;
Held :: struct { view: []int }
Other :: struct { target: ^mut int }
Choice :: union { held: Held, other: Other, plain: int }
main :: proc() { }`)

	shape := carrier_shape(&p.c, named_type(t, &p, "Choice"))
	testing.expectf(t, len(shape) == 2, "expected one path per carrying alternative, got %d", len(shape))
	for path in shape {
		testing.expect(t, len(path.steps) > 0 && path.steps[0].kind == .Wild, "an alternative is not behind a wildcard")
	}
}
