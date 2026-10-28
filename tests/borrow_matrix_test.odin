// A generated matrix of mutable copies out of a place and the uses beside
// them (design.md "Weakening and reborrows", "Switch ownership"). Each program
// takes a mutable carrier out of `head` or `first` of a `List`, reached through
// one of several place forms, does one thing beside it, and maybe uses the copy
// again. Whether that is legal comes from `matrix_rejects`, a model of the
// rules written apart from the compiler, never from its output, so a form the
// compiler handles differently from the others shows up as a disagreement.
// Every case is one procedure, and a compile checks a whole place form at once.
package tests

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

@(private = "file")
MATRIX_DIR :: TMP + "/borrow_matrix"

// Where the `List` lives, and how the place is written: `base` is the `List`
// itself, `pointer` a `^mut List` to it.
@(private = "file")
Matrix_Place :: struct {
	name, params, setup, base, pointer: string,
}

@(private = "file")
MATRIX_NODES :: "a := Node{1, .none}; b := Node{2, .none}; c := Node{3, .none};"
@(private = "file")
MATRIX_LIST :: "List{&mut a, &mut b, 2, .some(&mut c)}"

@(private = "file")
MATRIX_PLACES := [?]Matrix_Place {
	{"local", "", MATRIX_NODES + " l := " + MATRIX_LIST + ";", "l", "&mut l"},
	{"local_pointer", "", MATRIX_NODES + " l := " + MATRIX_LIST + "; list := &mut l;", "list^", "list"},
	{"param", "list: ^mut List", "", "list^", "list"},
	{"local_two_pointers", "", MATRIX_NODES + " l := " + MATRIX_LIST + "; held := &mut l; p := &mut held;", "p^^", "p^"},
	{"param_two_pointers", "p: ^mut ^mut List", "", "p^^", "p^"},
	{"local_indexed", "", MATRIX_NODES + " lists := [1]List{" + MATRIX_LIST + "}; p := &mut lists;", "p[0]", "&mut p[0]"},
	{"param_indexed", "p: ^mut [1]List", "", "p[0]", "&mut p[0]"},
	{"param_slice", "s: []mut List", "", "s[0]", "&mut s[0]"},
}

// How the mutable carrier is taken: copied out of `head`, or bound as the
// payload of `first` by a switch over the place.
@(private = "file")
Matrix_Take :: enum { Copy, Binding }

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
	{"replace_head", "$H = $T;", ""},
	{"pass_whole", "touch($P);", ""},
}

// The rules, for a mutable carrier taken out of a place and used again later
// (design.md "Weakening and reborrows"): a copy is a mutable reborrow of the
// stored carrier, which suspends every other use of it, a read or a copy
// included, and handing a pointer to the place to a call lets the callee use
// it. Storage beside it, and storing a new carrier into the place, are not
// uses of it. A switch payload binding is no copy but names the stored
// carrier, so it is suspended in turn by a copy of that carrier still in use,
// and the switch borrows the place, which a call given a mutable pointer to
// it may write (design.md "Switch ownership"). The code the rejection is
// reported with, or "" when the case is legal.
@(private = "file")
matrix_expected :: proc(take: Matrix_Take, use: Matrix_Use, later: bool) -> string {
	if !later {
		return ""
	}
	switch take {
	case .Copy:
		switch use.name {
		case "store_through_same", "read_through_same", "copy_same", "pass_whole":
			return "L0641"
		}
	case .Binding:
		switch use.name {
		case "copy_same_option":
			return "L0641"
		case "pass_whole":
			return "L0511"
		}
	}
	return ""
}

// Cases the compiler is known to get wrong, each with the known-gaps.md entry
// that records it. A case listed here is expected to compile, and fails once
// the gap is fixed, so the entry is removed with the gap.
@(private = "file")
matrix_known_gap :: proc(place: Matrix_Place, take: Matrix_Take, use: Matrix_Use, later: bool) -> string {
	if take == .Binding && use.name == "pass_whole" && later && place.name != "local" {
		return "A switch over a place reached through a pointer does not borrow the place"
	}
	return ""
}

// `replace_head` and the uses of `head` say nothing about a binding of
// `first`, and the option copy and view say nothing about a copy of `head`.
@(private = "file")
matrix_applies :: proc(take: Matrix_Take, use: Matrix_Use) -> bool {
	switch use.name {
	case "copy_same_option", "second_view":
		return take == .Binding
	case "store_through_same", "read_through_same", "copy_same", "replace_head":
		return take == .Copy
	}
	return true
}

@(private = "file")
Matrix_Case :: struct {
	use:        Matrix_Use,
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
		lines^ += 1
	}
	line(&b, &lines, "package main;")
	line(&b, &lines, "Node :: struct { value: int, next: Option(^mut Node) }")
	line(&b, &lines, "List :: struct { head: ^mut Node, tail: ^mut Node, count: int, first: Option(^mut Node) }")
	line(&b, &lines, "sink :: proc(value: int) {}")
	line(&b, &lines, "touch :: proc(list: ^mut List) { list^.head^.value += 1; }")
	line(&b, &lines, "main :: proc() {}")
	for use in MATRIX_USES {
		if !matrix_applies(take, use) {
			continue
		}
		for later in ([2]bool{false, true}) {
			entry := Matrix_Case{use = use, later = later, first_line = lines + 1}
			line(&b, &lines, fmt.tprintf("case_%d :: proc(%s) {{", len(cases), place.params))
			if place.setup != "" {
				line(&b, &lines, fmt.tprintf("\t%s", place.setup))
			}
			uses := fmt.tprintf("\tnode^.value = 0;\n\t%s\n\t%s\n\t%s",
				matrix_expand(use.before, place), later ? "node^.value = 1;" : "", matrix_expand(use.after, place))
			switch take {
			case .Copy:
				line(&b, &lines, fmt.tprintf("\tnode := %s.head;", place.base))
				line(&b, &lines, uses)
				lines += 3
			case .Binding:
				line(&b, &lines, fmt.tprintf("\tswitch (%s.first) {{", place.base))
				line(&b, &lines, "\tcase .some(node):")
				line(&b, &lines, uses)
				lines += 3
				line(&b, &lines, "\tcase .none:")
				line(&b, &lines, "\t}")
			}
			line(&b, &lines, "}")
			entry.last_line = lines
			append(cases, entry)
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
			expected := matrix_expected(program.take, entry.use, entry.later)
			gap := matrix_known_gap(program.place, program.take, entry.use, entry.later)
			if gap != "" {
				expected = ""
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
				"%s (lines %d-%d): %v of a carrier from %s, then %s%s: expected %s, got %s%s",
				path, entry.first_line, entry.last_line, program.take, program.place.name, entry.use.name,
				entry.later ? " and a later use" : "", expected if expected != "" else "no error",
				code if code != "" else "no error",
				gap != "" ? fmt.tprintf(" (known gap \"%s\": remove it from matrix_known_gap once fixed)", gap) : "",
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
