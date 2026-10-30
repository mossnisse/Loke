// A generated matrix of mutable copies out of a place, borrows, slices and
// traversals of one, and the uses beside them (design.md "Weakening and
// reborrows", "Switch ownership", "Slices", "foreach statement"). Each
// program takes a mutable carrier out of `head` or `first` of a `List`,
// borrows its `count`, or slices or traverses its `cells`, reached through
// one of several place forms, does one thing beside it, and maybe uses what
// it took again, in straight-line code, a branch, or a loop. Whether that is
// legal comes from `matrix_expected`, a model of the rules written apart from
// the compiler, never from its output, so a form the compiler handles
// differently from the others shows up as a disagreement. Every case is one
// procedure, and a compile checks a whole place form at once.
package tests

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

@(private = "file")
MATRIX_DIR :: TMP + "/borrow_matrix"

// Where the `List` lives, and how the place is written: `base` is the `List`
// itself, `pointer` a `^mut List` to it, which `local_chosen` chooses between
// two elements of an array, so it may point at either. A `read_only` place is
// reached through a read-only pointer, so nothing writes the place itself,
// but the mutable carriers stored in it keep their capability (design.md
// "Values that contain borrows").
@(private = "file")
Matrix_Place :: struct {
	name, params, setup, base, pointer: string,
	read_only:                          bool,
}

@(private = "file")
MATRIX_NODES :: "a := Node{1, .none}; b := Node{2, .none}; c := Node{3, .none};"
@(private = "file")
MATRIX_LIST :: "List{&mut a, &mut b, 2, .some(&mut c), [2]int{4, 5}}"

@(private = "file")
MATRIX_PLACES := [?]Matrix_Place {
	{"local", "", MATRIX_NODES + " l := " + MATRIX_LIST + ";", "l", "&mut l", false},
	{"local_pointer", "", MATRIX_NODES + " l := " + MATRIX_LIST + "; list := &mut l;", "list^", "list", false},
	{"param", "list: ^mut List", "", "list^", "list", false},
	{"local_two_pointers", "", MATRIX_NODES + " l := " + MATRIX_LIST + "; held := &mut l; p := &mut held;", "p^^", "p^", false},
	{"param_two_pointers", "p: ^mut ^mut List", "", "p^^", "p^", false},
	{"local_indexed", "", MATRIX_NODES + " lists := [1]List{" + MATRIX_LIST + "}; p := &mut lists;", "p[0]", "&mut p[0]", false},
	{"param_indexed", "p: ^mut [1]List", "", "p[0]", "&mut p[0]", false},
	{"param_slice", "s: []mut List", "", "s[0]", "&mut s[0]", false},
	{
		"local_slice", "",
		MATRIX_NODES + " d := Node{4, .none}; e := Node{5, .none}; f := Node{6, .none}; lists := [2]List{" + MATRIX_LIST +
		", List{&mut d, &mut e, 2, .some(&mut f), [2]int{4, 5}}}; s := &mut lists[:];",
		"s[0]", "&mut s[0]", false,
	},
	{
		"local_resliced", "",
		MATRIX_NODES + " d := Node{4, .none}; e := Node{5, .none}; f := Node{6, .none}; lists := [2]List{List{&mut d, &mut e, 2, .some(&mut f), [2]int{4, 5}}, " +
		MATRIX_LIST + "}; s := &mut lists[:]; t := &mut s[1:];",
		"t[0]", "&mut t[0]", false,
	},
	{
		"local_chosen", "",
		MATRIX_NODES + " d := Node{4, .none}; e := Node{5, .none}; f := Node{6, .none}; lists := [2]List{" + MATRIX_LIST +
		", List{&mut d, &mut e, 2, .some(&mut f), [2]int{4, 5}}}; chosen := &mut lists[0] if cond() else &mut lists[1];",
		"chosen^", "chosen", false,
	},
	{"param_read_only", "list: ^List", "", "list^", "list", true},
	{"param_read_only_two_pointers", "p: ^^List", "", "p^^", "p^", true},
}

// What is taken: a mutable carrier copied out of `head`, or bound as the
// payload of `first` by a switch over the place, a read-only or mutable
// borrow of `count`, a read-only or mutable slice of `cells`, or a borrowing
// or mutable traversal of `cells`.
@(private = "file")
Matrix_Take :: enum { Copy, Binding, Borrow, Borrow_Mut, Slice, Slice_Mut, Foreach, Foreach_Mut }

// What happens beside the carrier taken. `before` runs between its first use
// and the later one; `after` runs after the later one, keeping anything
// `before` made in use. `$H`, `$T`, `$F`, `$B` and `$P` stand for `head`,
// `tail`, `first`, the `List` and a pointer to it.
@(private = "file")
Matrix_Use :: struct {
	name, before, after: string,
}

@(private = "file")
MATRIX_USES := [?]Matrix_Use {
	{"nothing", "", ""},
	{"store_through_same", "$H^.value = 2;", ""},
	{"read_through_same", "sink($H^.value);", ""},
	{"copy_same", "other := $H;", "other^.value = 3;"},
	{"copy_same_option", "other := $F;", "switch (other) { case .some(o): o^.value = 3; case .none: }"},
	{"second_view", "switch ($F) { case .some(o): sink(o^.value); case .none: }", ""},
	{"store_through_sibling", "$T^.value = 2;", ""},
	{"write_count", "$B.count += 1;", ""},
	{"write_cells", "$B.cells[1] = 2;", ""},
	{"read_cells", "sink($B.cells[1]);", ""},
	{"replace_head", "$H = $T;", ""},
	{"replace_first", "$F = .none;", ""},
	{"pass_whole", "touch($P);", ""},
	{"pass_sibling", "bump(&mut $B.count);", ""},
	{"pass_cells", "bump(&mut $B.cells[1]);", ""},
	{"pass_read", "sink(look($P));", ""},
	{"copy_pointer", "q := $P;", ""},
	{"copy_pointer_read", "q: ^List = $P;", ""},
}

// Where the use and the later use stand. `Branch` makes the use one arm of an
// `if`, and `Branch_Later` makes the later use conditional. `Loop_Carried`
// repeats the later use and then the use in a loop, so the later use of one
// iteration follows the use of the one before, and `Loop_Whole` repeats the
// whole case, taking afresh in each iteration. Only what the place holds when
// a later iteration takes from it changes what is legal (`matrix_expected`);
// a use that needs `after` is not put where it would leave its own block
// before `after`.
@(private = "file")
Matrix_Shape :: enum { Straight, Branch, Branch_Later, Loop_Carried, Loop_Whole }

// The rules, for what is taken out of a place and used again later
// (design.md "Weakening and reborrows"): a copy is a mutable reborrow of the
// stored carrier, which suspends every other use of it, a read or a copy
// included, and handing a pointer to the place to a call, or copying one,
// even read-only, lets the callee or the copy use it. Storage beside it, and storing a new carrier into the place, are not
// uses of it. A switch payload binding is no copy but names the stored
// carrier, so it is suspended in turn by a copy of that carrier still in use,
// and the switch borrows the place, which a call given a mutable pointer to
// it, or a mutable copy of one, may write, as storing into the place does
// (design.md "Switch ownership"). A borrow of `count`, or a slice of `cells` (design.md
// "Slices"), reborrows the carriers it goes through for that field only:
// writing it, handing it on mutably, or handing the `List` to a call that may
// write it, conflicts with the borrow, and a mutable borrow excludes reading
// it, or a call that may, too; the other fields stay free. A traversal of
// `cells` is a borrow of it for the whole loop, as the next step uses the
// traversal again, so it conflicts with a use in the body whether or not the
// element is used after it (design.md "foreach statement"). A loop that takes
// afresh finds in `head` the copy of `tail` an earlier iteration's
// `replace_head` stored there, so its copy out of `head` reborrows `tail`,
// which copying `tail` again then uses. A store through a pointer that may
// name either of two places replaces neither (design.md "Values that contain
// borrows"), so there `head` keeps every earlier iteration's copy of `tail`,
// which the next copy out of `head` uses even without a later use.
// The code the rejection is reported with, or "" when the case is legal.
@(private = "file")
matrix_expected :: proc(place: Matrix_Place, take: Matrix_Take, use: Matrix_Use, shape: Matrix_Shape, later: bool) -> string {
	if place.name == "local_chosen" && take == .Copy && use.name == "replace_head" && shape == .Loop_Whole {
		return "L0641"
	}
	if !later && take != .Foreach && take != .Foreach_Mut {
		return ""
	}
	// A local's own loan conflicts with an access to it; through a pointer, a
	// reborrow of the pointer is what conflicts.
	conflict := place.name == "local" ? "L0511" : "L0641"
	switch take {
	case .Copy:
		switch use.name {
		case "store_through_same", "read_through_same", "copy_same", "pass_whole", "copy_pointer", "pass_read", "copy_pointer_read":
			return "L0641"
		case "replace_head":
			if shape == .Loop_Whole {
				return "L0641"
			}
		}
	case .Binding:
		switch use.name {
		case "copy_same_option":
			return "L0641"
		case "pass_whole", "replace_first", "copy_pointer":
			return "L0511"
		}
	case .Borrow:
		switch use.name {
		case "write_count", "pass_whole", "copy_pointer", "pass_sibling":
			return conflict
		}
	case .Borrow_Mut:
		switch use.name {
		case "write_count", "pass_whole", "copy_pointer", "pass_sibling", "pass_read", "copy_pointer_read":
			return conflict
		}
	case .Slice, .Foreach:
		switch use.name {
		case "write_cells", "pass_whole", "copy_pointer", "pass_cells":
			return conflict
		}
	case .Slice_Mut, .Foreach_Mut:
		switch use.name {
		case "write_cells", "read_cells", "pass_whole", "copy_pointer", "pass_cells", "pass_read", "copy_pointer_read":
			return conflict
		}
	}
	return ""
}

// The code the compiler reports instead of `matrix_expected`'s for a case
// known-gaps.md records, or false when it agrees. Fixing a gap fails these
// cases until they are removed here. None is recorded now.
@(private = "file")
matrix_known_gap :: proc(place: Matrix_Place, take: Matrix_Take, use: Matrix_Use, shape: Matrix_Shape, later: bool) -> (string, bool) {
	return "", false
}

// `replace_head` and the uses of `head` say nothing about a binding of
// `first`, and the option copy and view say nothing about a copy of `head`;
// beside a borrow of `count` or a slice of `cells`, both are other fields. A
// read-only place cannot be written, borrowed mutably, or handed on as a
// mutable pointer.
@(private = "file")
matrix_applies :: proc(place: Matrix_Place, take: Matrix_Take, use: Matrix_Use, shape: Matrix_Shape) -> bool {
	switch take {
	case .Borrow_Mut, .Slice_Mut, .Foreach_Mut:
		if place.read_only {
			return false
		}
	case .Copy, .Binding, .Borrow, .Slice, .Foreach:
	}
	if (shape == .Branch || shape == .Loop_Carried) && use.after != "" {
		return false
	}
	switch use.name {
	case "write_count", "write_cells", "replace_first", "pass_whole", "pass_sibling", "pass_cells", "copy_pointer":
		return !place.read_only
	case "copy_same_option", "second_view":
		return take != .Copy
	case "store_through_same", "read_through_same", "copy_same":
		return take != .Binding
	case "replace_head":
		return take != .Binding && !place.read_only
	}
	return true
}

@(private = "file")
Matrix_Case :: struct {
	use:        Matrix_Use,
	shape:      Matrix_Shape,
	later:      bool,
	first_line: int,
	last_line:  int,
}

@(private = "file")
matrix_expand :: proc(text: string, place: Matrix_Place) -> string {
	out := text
	out, _ = strings.replace_all(out, "$H", fmt.tprintf("%s.head", place.base), context.temp_allocator)
	out, _ = strings.replace_all(out, "$T", fmt.tprintf("%s.tail", place.base), context.temp_allocator)
	out, _ = strings.replace_all(out, "$F", fmt.tprintf("%s.first", place.base), context.temp_allocator)
	out, _ = strings.replace_all(out, "$B", place.base, context.temp_allocator)
	out, _ = strings.replace_all(out, "$P", place.pointer, context.temp_allocator)
	return out
}

// One program holding every case of one place form and way of taking the
// carrier, each in its own procedure.
@(private = "file")
matrix_program :: proc(place: Matrix_Place, take: Matrix_Take, cases: ^[dynamic]Matrix_Case) -> string {
	b := strings.builder_make(context.temp_allocator)
	lines := 0
	line :: proc(b: ^strings.Builder, lines: ^int, text: string) {
		strings.write_string(b, text)
		strings.write_byte(b, '\n')
		lines^ += strings.count(text, "\n") + 1
	}
	line(&b, &lines, "package main;")
	line(&b, &lines, "Node :: struct { value: int, next: Option(^mut Node) }")
	line(&b, &lines, "List :: struct { head: ^mut Node, tail: ^mut Node, count: int, first: Option(^mut Node), cells: [2]int }")
	line(&b, &lines, "sink :: proc(value: int) {}")
	line(&b, &lines, "cond :: proc() -> bool { return true; }")
	line(&b, &lines, "touch :: proc(list: ^mut List) { list^.head^.value += 1; }")
	line(&b, &lines, "look :: proc(list: ^List) -> int { return list^.head^.value; }")
	line(&b, &lines, "bump :: proc(n: ^mut int) { n^ += 1; }")
	line(&b, &lines, "main :: proc() {}")

	// How the take opens and closes, and its first and later use.
	open, close, first, again: string
	switch take {
	case .Copy:
		open, first, again = fmt.tprintf("node := %s.head;", place.base), "node^.value = 0;", "node^.value = 1;"
	case .Binding:
		open, close = fmt.tprintf("switch (%s.first) {{\n\tcase .some(node):", place.base), "case .none:\n\t}"
		first, again = "node^.value = 0;", "node^.value = 1;"
	case .Borrow:
		open, first, again = fmt.tprintf("taken := &%s.count;", place.base), "sink(taken^);", "sink(taken^);"
	case .Borrow_Mut:
		open, first, again = fmt.tprintf("taken := &mut %s.count;", place.base), "taken^ = 0;", "taken^ = 1;"
	case .Slice:
		open, first, again = fmt.tprintf("taken := %s.cells[:];", place.base), "sink(taken[0]);", "sink(taken[0]);"
	case .Slice_Mut:
		open, first, again = fmt.tprintf("taken := &mut %s.cells[:];", place.base), "taken[0] = 0;", "taken[0] = 1;"
	case .Foreach:
		open, close = fmt.tprintf("foreach (item in %s.cells) {{", place.base), "}"
		first, again = "sink(item);", "sink(item);"
	case .Foreach_Mut:
		open, close = fmt.tprintf("foreach (&mut item in %s.cells) {{", place.base), "}"
		first, again = "item = 0;", "item = 1;"
	}

	for use in MATRIX_USES {
		for shape in Matrix_Shape {
			if !matrix_applies(place, take, use, shape) {
				continue
			}
			for later in ([2]bool{false, true}) {
				entry := Matrix_Case{use = use, shape = shape, later = later, first_line = lines + 1}
				before, after := matrix_expand(use.before, place), matrix_expand(use.after, place)
				later_use := later ? again : ""
				line(&b, &lines, fmt.tprintf("case_%d :: proc(%s) {{", len(cases), place.params))
				if place.setup != "" {
					line(&b, &lines, fmt.tprintf("\t%s", place.setup))
				}
				if shape == .Loop_Whole {
					line(&b, &lines, "\tfor (round := 0; round < 2; round += 1) {")
				}
				line(&b, &lines, fmt.tprintf("\t%s", open))
				line(&b, &lines, fmt.tprintf("\t%s", first))
				switch shape {
				case .Straight, .Loop_Whole:
					line(&b, &lines, fmt.tprintf("\t%s", before))
					line(&b, &lines, fmt.tprintf("\t%s", later_use))
					line(&b, &lines, fmt.tprintf("\t%s", after))
				case .Branch:
					line(&b, &lines, fmt.tprintf("\tif (cond()) {{ %s }} else {{ sink(0); }}", before))
					line(&b, &lines, fmt.tprintf("\t%s", later_use))
				case .Branch_Later:
					line(&b, &lines, fmt.tprintf("\t%s", before))
					line(&b, &lines, fmt.tprintf("\tif (cond()) {{ %s }}", later_use))
					line(&b, &lines, fmt.tprintf("\t%s", after))
				case .Loop_Carried:
					line(&b, &lines, "\tfor (step := 0; step < 2; step += 1) {")
					line(&b, &lines, fmt.tprintf("\t%s", later_use))
					line(&b, &lines, fmt.tprintf("\t%s", before))
					line(&b, &lines, "\t}")
				}
				if close != "" {
					line(&b, &lines, fmt.tprintf("\t%s", close))
				}
				if shape == .Loop_Whole {
					line(&b, &lines, "\t}")
				}
				line(&b, &lines, "}")
				entry.last_line = lines
				append(cases, entry)
			}
		}
	}
	return strings.to_string(b)
}

// The lines of `stderr` that an `error[Lxxxx]` diagnostic is reported at,
// with its code.
@(private = "file")
Matrix_Error :: struct {
	code: string,
	line: int,
}

@(private = "file")
matrix_errors :: proc(stderr: string) -> []Matrix_Error {
	out := make([dynamic]Matrix_Error, context.temp_allocator)
	code := ""
	for text in strings.split_lines(stderr, context.temp_allocator) {
		trimmed := strings.trim_space(text)
		if strings.has_prefix(trimmed, "error[") {
			code = trimmed[len("error["):strings.index_byte(trimmed, ']')]
			continue
		}
		if code == "" || !strings.has_prefix(trimmed, "-->") {
			continue
		}
		parts := strings.split(trimmed, ":", context.temp_allocator)
		if len(parts) >= 3 {
			if at, ok := strconv.parse_int(parts[len(parts) - 2]); ok {
				append(&out, Matrix_Error{code, at})
			}
		}
		code = ""
	}
	return out[:]
}

@(test)
borrow_matrix :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	os.make_directory(MATRIX_DIR)
	Program :: struct {
		place: Matrix_Place,
		take:  Matrix_Take,
		cases: [dynamic]Matrix_Case,
	}
	programs := make([dynamic]Program, context.temp_allocator)
	jobs := make([dynamic]Exec, context.temp_allocator)
	for place in MATRIX_PLACES {
		for take in Matrix_Take {
			program := Program{place = place, take = take, cases = make([dynamic]Matrix_Case, context.temp_allocator)}
			source := matrix_program(place, take, &program.cases)
			path := fmt.tprintf("%s/%s_%v.loke", MATRIX_DIR, place.name, take)
			if !testing.expectf(t, os.write_entire_file(path, transmute([]byte)source) == nil, "%s: cannot write", path) {
				continue
			}
			append(&programs, program)
			command := make([]string, 5, context.temp_allocator)
			command[0], command[1], command[2] = compiler_path(), path, "-emit-ll"
			command[3], command[4] = "-o", fmt.tprintf("%s/%s_%v.exe", MATRIX_DIR, place.name, take)
			append(&jobs, Exec{command = command})
		}
	}
	exec_all(jobs[:])
	for program, index in programs {
		job := jobs[index]
		path := job.command[1]
		if !testing.expectf(t, job.err == nil, "%s: cannot run lokec: %v", path, job.err) {
			continue
		}
		errors := matrix_errors(string(job.stderr))
		for entry in program.cases {
			expected := matrix_expected(program.place, program.take, entry.use, entry.shape, entry.later)
			gap_code, gap := matrix_known_gap(program.place, program.take, entry.use, entry.shape, entry.later)
			if gap {
				expected = gap_code
			}
			code := ""
			for e in errors {
				if e.line >= entry.first_line && e.line <= entry.last_line {
					code = e.code
					break
				}
			}
			testing.expectf(
				t, code == expected,
				"%s (lines %d-%d): %v of a carrier from %s, then %s (%v)%s: expected %s%s, got %s",
				path, entry.first_line, entry.last_line, program.take, program.place.name, entry.use.name,
				entry.shape, entry.later ? " and a later use" : "", expected if expected != "" else "no error",
				gap ? " (a gap known-gaps.md records)" : "", code if code != "" else "no error",
			)
		}
		// An error outside every case is a mistake in the generated program.
		for e in errors {
			inside := false
			for entry in program.cases {
				inside ||= e.line >= entry.first_line && e.line <= entry.last_line
			}
			testing.expectf(t, inside, "%s:%d: %s outside every case:\n%s", path, e.line, e.code, string(job.stderr))
		}
	}
}
