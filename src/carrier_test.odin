// The structural half of carrier shapes: they ask the shape of a type
// directly rather than compiling a program, because what has to hold is a
// property of the type graph — the same answer whichever type is queried
// first, whichever field order, and a finite answer for a self-containing type.
package lokec

import "core:fmt"
import "core:testing"

// Checks one package of source into the caller's compiler and hands back its
// file, so a test can look types up by written name. The compiler is filled in
// place — the checker stores `^Compiler` internally, so it must already live
// at its final address before anything takes its pointer.
@(private = "file")
shaped :: proc(c: ^Compiler, text: string) -> ^File {
	c^ = test_compiler(text)
	f := new(File)
	f^ = parse(c, 0, lex(c, 0))
	pkg_id := new_package(c, "main")
	add_package_file(c, pkg_id, f)
	check_one_package(c, pkg_id)
	return f
}

@(private = "file")
named_type :: proc(c: ^Compiler, f: ^File, name: string) -> Type_Id {
	for item in f.items {
		d, ok := item.(^Decl)
		if !ok || len(d.symbols) == 0 {
			continue
		}
		sym := symbol_of(c, d.symbols[0])
		if sym == nil || sym.kind != .Type {
			continue
		}
		if identifier_text(c, sym.name) == name {
			return sym.type
		}
	}
	return INVALID_TYPE
}

// One string per path, so a test can assert on the set of paths without
// depending on the order fields were written in.
@(private = "file")
path_key :: proc(path: Carrier_Path) -> string {
	key := ""
	for step in path.steps {
		switch step.kind {
		case .Field: key = fmt.tprintf("%s.%d", key, step.lo)
		case .Range: key = fmt.tprintf("%s:%d", key, step.lo)
		case .Deref: key = fmt.tprintf("%s^", key)
		case .Wild:  key = fmt.tprintf("%s*", key)
		}
	}
	if path.truncated {
		key = fmt.tprintf("%s!", key)
	}
	return key
}

@(private = "file")
path_keys :: proc(shape: []Carrier_Path) -> map[string]Carrier_Path {
	out := make(map[string]Carrier_Path, len(shape), context.temp_allocator)
	for path in shape {
		out[path_key(path)] = path
	}
	return out
}

@(test)
a_bare_carrier_is_one_empty_path :: proc(t: ^testing.T) {
	text := `package main;
Alias :: distinct []int
main :: proc() { }`
	c: Compiler
	defer destroy_compilation(&c)
	f := shaped(&c, text)

	shape := carrier_shape(&c, named_type(&c, f, "Alias"))
	testing.expectf(t, len(shape) == 1, "expected one path, got %d", len(shape))
	testing.expect(t, len(shape[0].steps) == 0, "a bare carrier's path is the value itself")
	testing.expect(t, !shape[0].truncated, "a bare carrier is not truncated")
}

@(test)
a_scalar_record_has_no_paths :: proc(t: ^testing.T) {
	text := `package main;
Plain :: struct { a: int, b: f64, c: bool }
main :: proc() { }`
	c: Compiler
	defer destroy_compilation(&c)
	f := shaped(&c, text)

	plain := named_type(&c, f, "Plain")
	testing.expect(t, plain != INVALID_TYPE, "the test type was not found, so the rest is vacuous")
	testing.expect(t, len(carrier_shape(&c, plain)) == 0, "a scalar record carries nothing")
	testing.expect(t, !type_carries_borrow(&c, plain).any, "reachability disagrees with the shape")
}

@(test)
record_fields_are_distinct_paths :: proc(t: ^testing.T) {
	text := `package main;
Pair :: struct { left: []int, count: int, right: ^mut int }
main :: proc() { }`
	c: Compiler
	defer destroy_compilation(&c)
	f := shaped(&c, text)

	shape := carrier_shape(&c, named_type(&c, f, "Pair"))
	testing.expectf(t, len(shape) == 2, "expected two carrier fields, got %d", len(shape))
	keys := path_keys(shape)
	left, has_left := keys[".0"]
	right, has_right := keys[".2"]
	testing.expect(t, has_left && has_right, "the carrier fields are not at their own field indices")
	testing.expect(t, has_left && !left.mutable, "a read-only slice field reported a mutable capability")
	testing.expect(t, has_right && right.mutable, "a `^mut` field reported an immutable capability")
}

@(test)
a_scalar_cycle_terminates_without_paths :: proc(t: ^testing.T) {
	text := `package main;
Chain :: struct { rest: [dynamic]Chain, value: int }
main :: proc() { }`
	c: Compiler
	defer destroy_compilation(&c)
	f := shaped(&c, text)

	chain := named_type(&c, f, "Chain")
	testing.expect(t, chain != INVALID_TYPE, "the test type was not found, so the rest is vacuous")
	testing.expect(t, !type_carries_borrow(&c, chain).any, "a cycle of scalars invented a carrier")
	testing.expect(t, len(carrier_shape(&c, chain)) == 0, "a cycle of scalars invented a path")
}

// `Node` contains a container of itself and a bare borrow. The answer must not
// depend on field order, nor on whether the recursive edge or the whole type
// was asked about first.
@(test)
a_recursive_shape_is_finite_and_order_independent :: proc(t: ^testing.T) {
	forward := `package main;
Node :: struct { children: [dynamic]Node, labels: []int }
main :: proc() { }`
	reversed := `package main;
Node :: struct { labels: []int, children: [dynamic]Node }
main :: proc() { }`

	shape_of_node :: proc(text: string, inner_first: bool) -> (paths: int, reaches: bool) {
		c: Compiler
		defer destroy_compilation(&c)
		f := shaped(&c, text)
		node := named_type(&c, f, "Node")
		if inner_first {
			info := type_of(&c, node)
			for field in info.fields {
				if sym := symbol_of(&c, field); sym != nil {
					_ = carrier_shape(&c, sym.type)
					_ = type_carries_borrow(&c, sym.type)
				}
			}
		}
		return len(carrier_shape(&c, node)), type_carries_borrow(&c, node).any
	}

	a, a_reaches := shape_of_node(forward, false)
	b, b_reaches := shape_of_node(reversed, false)
	inner, inner_reaches := shape_of_node(forward, true)

	testing.expectf(t, a == b, "field order changed the shape: %d versus %d", a, b)
	testing.expectf(t, a == inner, "query order changed the shape: %d versus %d", a, inner)
	testing.expect(t, a_reaches && b_reaches && inner_reaches, "a recursive carrier was not reachable")
	testing.expectf(t, a > 0 && a <= CARRIER_DEPTH + 1, "a recursive shape did not stay finite: %d paths", a)
	testing.expectf(t, a == 3, "the recursive shape changed: %d paths", a)
}

@(test)
depth_beyond_the_limit_becomes_one_truncated_path :: proc(t: ^testing.T) {
	text := `package main;
Five :: struct { view: []int }
Four :: struct { inner: Five }
Three :: struct { inner: Four }
Two :: struct { inner: Three }
One :: struct { inner: Two }
main :: proc() { }`
	c: Compiler
	defer destroy_compilation(&c)
	f := shaped(&c, text)

	// `Four` reaches its leaf within the limit; `One` is one level deeper.
	deep := carrier_shape(&c, named_type(&c, f, "Four"))
	testing.expectf(t, len(deep) == 1 && !deep[0].truncated, "a path inside the limit was cut")

	over := carrier_shape(&c, named_type(&c, f, "One"))
	testing.expectf(t, len(over) == 1, "expected one path past the limit, got %d", len(over))
	testing.expect(t, over[0].truncated, "a path past the depth limit was not marked truncated")
	testing.expectf(
		t,
		len(over[0].steps) == CARRIER_DEPTH,
		"a truncated path should stop at the limit, got %d steps",
		len(over[0].steps),
	)
}

@(test)
a_truncated_path_keeps_the_strongest_capability :: proc(t: ^testing.T) {
	text := `package main;
Five :: struct { view: ^mut int }
Four :: struct { inner: Five }
Three :: struct { inner: Four }
Two :: struct { inner: Three }
One :: struct { inner: Two }
main :: proc() { }`
	c: Compiler
	defer destroy_compilation(&c)
	f := shaped(&c, text)

	over := carrier_shape(&c, named_type(&c, f, "One"))
	testing.expect(t, len(over) == 1 && over[0].truncated, "expected one truncated path")
	testing.expect(t, over[0].mutable, "a truncated path hid a mutable carrier below it")
}

@(test)
map_keys_and_values_are_separate_paths :: proc(t: ^testing.T) {
	text := `package main;
Held :: struct { view: []int }
Table :: struct { entries: map[string]Held }
main :: proc() { }`
	c: Compiler
	defer destroy_compilation(&c)
	f := shaped(&c, text)

	// A `string` key carries no borrow, so every path here is a value path — one
	// per entry, since a constant key gets an entry of its own.
	shape := carrier_shape(&c, named_type(&c, f, "Table"))
	testing.expectf(
		t,
		len(shape) == MAP_KEY_SLOTS,
		"expected one value path per entry, got %d",
		len(shape),
	)
	entries := make(map[i64]bool, MAP_KEY_SLOTS, context.temp_allocator)
	for path in shape {
		steps := path.steps
		testing.expectf(t, len(steps) >= 3, "a map value path is missing its entry steps: %d", len(steps))
		testing.expect(t, steps[len(steps) - 2].kind == .Field, "a map path does not separate key from value")
		testing.expectf(
			t,
			steps[len(steps) - 2].lo == PROJ_MAP_VALUE,
			"a value path was recorded under the key step",
		)
		entry := steps[len(steps) - 3]
		testing.expect(t, entry.kind == .Range, "a keyed map entry is not a constant range")
		testing.expect(t, !entries[entry.lo], "two entries share one key slot")
		entries[entry.lo] = true
	}
}

@(test)
a_wide_map_value_keeps_one_entry :: proc(t: ^testing.T) {
	// Replicating the entry costs a copy of the value's paths, so a value with
	// more than the limit keeps the single wildcard entry instead.
	text := `package main;
Wide :: struct { a: []int, b: []int, c: []int }
Table :: struct { entries: map[string]Wide }
main :: proc() { }`
	c: Compiler
	defer destroy_compilation(&c)
	f := shaped(&c, text)

	shape := carrier_shape(&c, named_type(&c, f, "Table"))
	testing.expectf(t, len(shape) == 3, "expected one path per field, got %d", len(shape))
	for path in shape {
		entry := path.steps[len(path.steps) - 3]
		testing.expect(t, entry.kind == .Wild, "a wide map value was given keyed entries")
	}
}

@(test)
union_alternatives_join_under_one_wildcard :: proc(t: ^testing.T) {
	text := `package main;
Held :: struct { view: []int }
Other :: struct { target: ^mut int }
Choice :: union { held: Held, other: Other, plain: int }
main :: proc() { }`
	c: Compiler
	defer destroy_compilation(&c)
	f := shaped(&c, text)

	shape := carrier_shape(&c, named_type(&c, f, "Choice"))
	testing.expectf(t, len(shape) == 2, "expected one path per carrying alternative, got %d", len(shape))
	for path in shape {
		testing.expect(t, len(path.steps) > 0 && path.steps[0].kind == .Wild, "an alternative is not behind a wildcard")
	}
}
