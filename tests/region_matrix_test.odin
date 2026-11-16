// A generated matrix of owners built in an allocator region and what is done
// with them (design.md "Allocators", "Allocator regions and region provenance",
// "Region tracking", "Allocators and tasks"). Each program builds one kind of
// owner with an allocator of one kind of region, through one of several routes
// (inline, a generic call, a generic operator, a method, a delegated operator,
// a conversion, a moved or written argument), and then resets the region,
// lets the owner leave it, or hands the owner to a task. Whether that is legal
// comes from `region_expected`, a model of the rules written apart from the
// compiler, never from its output, so a route the compiler handles differently
// from the others shows up as a disagreement. Every case is one procedure, and
// a compile checks every route and flow of one shape and region at once.
package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
REGION_DIR :: TMP + "/region_matrix"

// Which region backs what a case builds: one of an arena the case creates, one
// it received and may reset, or the default provider's, which nothing resets
// and no task reserves.
@(private = "file")
Region_Backing :: enum { Local, Received, Default }

// `allocator` is the region's handle and `other` that of a second region of the
// same kind: another arena of the case's own, which is a region apart, or
// another parameter, which a caller may make the same region.
@(private = "file")
Region_Place :: struct {
	name:                            string,
	backing:                         Region_Backing,
	params, setup, allocator, other: string,
}

@(private = "file")
REGION_PLACES := [?]Region_Place {
	{"local", .Local, "", "arena := mem.Arena.init(); spare := mem.Arena.init();", "arena.allocator()", "spare.allocator()"},
	{"received", .Received, "@(allocator_reset) allocator: Allocator, @(allocator_reset) second: Allocator", "", "allocator", "second"},
	{"default", .Default, "", "", "mem.default_allocator()", "mem.default_allocator()"},
}

// The owner: its type, the expression building one, and a use of `held`. `$T`
// stands for the element type, `$S` for a value of it, and `$L` for the
// allocator.
@(private = "file")
Region_Shape :: struct {
	name, type, value, use: string,
}

@(private = "file")
REGION_SHAPES := [?]Region_Shape {
	{"array", "[dynamic]$T", "make([dynamic]$T, 1, $L)", "sink(held.len());"},
	{"box", "Box($T)", "box($S, $L)", "sink(held^);"},
	{"record", "Held($T)", "Held($T){make([dynamic]$T, 1, $L), 1}", "sink(held.count);"},
	{"option", "Option([dynamic]$T)", ".some(make([dynamic]$T, 1, $L))", "switch (held) { case .some(items): sink(items.len()); case .none: }"},
}

// How the owner `held` comes to be. `$A` and `$B` stand for the region's
// allocator and the other one, `$R` for the owner's type, and `$V` and `$D`
// for an owner built inline with `$A` and with the default provider.
// `default_backed` is a route whose body builds with the default provider
// whatever handle it is given.
@(private = "file")
Region_Route :: struct {
	name, take:     string,
	default_backed: bool,
}

@(private = "file")
REGION_ROUTES := [?]Region_Route {
	{"direct", "held: $R = $V;", false},
	{"named", "held := build(1, $A);", false},
	{"spare_argument", "held := build_beside(1, $A, $B);", false},
	{"forwarded", "held := forward(1, $A);", false},
	{"moved", "held := pass(build(1, $A));", false},
	{"written", "held: $R = $D; replace(inout held, build(1, $A));", false},
	{"operator", "maker := Maker(int){$A, 1}; held := maker[0];", false},
	{"other_overload", "maker := Maker(int){$A, 1}; held := maker[true];", true},
	{"method", "maker := Maker(int){$A, 1}; held := maker.made();", false},
	{"delegated", "wrapped := Wrapped{$A, 1}; held := wrapped[0];", false},
	{"converted", "maker := Maker(int){$A, 1}; wrapped := Wrapped(maker); held := wrapped[0];", false},
	{"converted_back", "wrapped := Wrapped{$A, 1}; held := get(Maker(int)(wrapped), 0);", false},
}

// The rule a flow tests, which decides its verdict from what backs the owner
// (`region_expected`).
@(private = "file")
Region_Rule :: enum {
	// Nothing ends the region or takes the owner out of it while the owner is live.
	Legal,
	// The owner's region is reset, or ends, while the owner is live.
	Reset,
	// Another region of the same kind is reset.
	Reset_Other,
	// The owner is returned.
	Return,
	// The owner is stored in file-scope storage.
	Store_Static,
	// The owner is stored in storage the caller owns.
	Store_Caller,
	// The owner is stored in a local declared before the region's provider.
	Outlive,
	// A task is given the owner, and the parent or another task then operates on
	// the region.
	Task,
}

// `outer` comes before the region's setup, `before` between that and the take,
// and `body` after the take, unless `body` holds `$TAKE` itself. `$USE` stands
// for the shape's use of `held`.
@(private = "file")
Region_Flow :: struct {
	name:                                string,
	rule:                                Region_Rule,
	body, before, outer, params, result: string,
}

@(private = "file")
REGION_FLOWS := [?]Region_Flow {
	{name = "used", rule = .Legal, body = "$USE"},
	{name = "reset_live", rule = .Reset, body = "free_all($A); $USE"},
	{name = "reset_unused", rule = .Reset, body = "free_all($A);"},
	{name = "reset_dropped", rule = .Legal, body = "drop(held); free_all($A);"},
	{name = "reset_moved", rule = .Legal, body = "eat(move(held)); free_all($A);"},
	{name = "reset_other", rule = .Reset_Other, body = "free_all($B); $USE"},
	{name = "reset_branch", rule = .Reset, body = "if (choose()) { free_all($A); } $USE"},
	{name = "reset_branch_dropped", rule = .Legal, body = "if (choose()) { drop(held); free_all($A); } else { $USE }"},
	{name = "reset_back_edge", rule = .Reset, body = "for (i := 0; i < 2; i += 1) { $USE free_all($A); }"},
	{name = "reset_loop_fresh", rule = .Legal, body = "for (i := 0; i < 2; i += 1) { $TAKE $USE drop(held); free_all($A); }"},
	{name = "reset_deferred_late", rule = .Reset, body = "defer free_all($A); $USE"},
	{name = "reset_deferred_early", rule = .Legal, before = "defer free_all($A);", body = "$USE"},
	{name = "returned", rule = .Return, result = " -> $R", body = "return held;"},
	{name = "stored_global", rule = .Store_Static, body = "kept = .some(move(held));"},
	{name = "stored_inout", rule = .Store_Caller, params = "out: inout $R", body = "out = move(held);"},
	{name = "stored_pointer", rule = .Store_Caller, params = "out: ^mut $R", body = "out^ = move(held);"},
	{name = "stored_outliving", rule = .Outlive, outer = "outer: [dynamic]$R = {};", body = "outer.append(move(held));"},
	{name = "stored_inside", rule = .Legal, body = "inner: [dynamic]$R = {}; inner.append(move(held));"},
	{name = "stored_inside_reset", rule = .Reset, body = "inner: [dynamic]$R = {}; inner.append(move(held)); free_all($A);"},
	{name = "task_parent", rule = .Task, body = "parallel { spawn eat(move(held)); again := build(1, $A); drop(again); }"},
	{name = "task_two", rule = .Task, body = "parallel { spawn eat(move(held)); spawn eat(build(1, $A)); }"},
	{name = "task_reset", rule = .Task, body = "parallel { spawn eat(move(held)); free_all($A); }"},
	{name = "task_joined", rule = .Legal, body = "parallel { spawn eat(move(held)); } again := build(1, $A); drop(again);"},
}

// The rules. An owner is backed by the region of the allocator it was built
// with, whatever call, operator, method, delegate, or conversion the handle
// went through on the way, and a moved or written owner keeps its region; a
// body that builds with the default provider is backed by that, whatever
// handle it was given, and an allocator argument a followed body never uses
// backs nothing (design.md "Allocator regions and region provenance"). A
// region may not be reset, nor its provider end, while an owner it backs is
// live: one that may be used later or still needs its cleanup, in a container
// too, but not one dropped or moved away, and a deferred reset runs in cleanup
// order (design.md "Allocators", "Region tracking"). Two arenas of the case's
// own are regions apart; a received allocator may be any region, so two may be
// one, and one may be the default provider's. An owner backed
// by a local region cannot leave by a return, into file-scope storage, into
// storage the caller owns, or into a local that outlives the provider; one
// backed by a received region may be returned or left in an argument, but
// not stored in file-scope storage, which outlives every region but the
// default provider's. A task reserves the regions it may operate on, other
// than the default provider's, until the join, so the parent and any other
// task may not operate on the region of an owner a task was given (design.md
// "Allocators and tasks").
// The code the rejection is reported with, or "" when the case is legal.
@(private = "file")
region_expected :: proc(place: Region_Place, route: Region_Route, flow: Region_Flow) -> string {
	backing := route.default_backed ? Region_Backing.Default : place.backing
	switch flow.rule {
	case .Legal:
	case .Reset:
		return backing != .Default || place.backing == .Received ? "L0537" : ""
	case .Reset_Other:
		return place.backing == .Received ? "L0537" : ""
	case .Return:
		return backing == .Local ? "L0592" : ""
	case .Store_Static:
		return backing != .Default ? "L0536" : ""
	case .Store_Caller:
		return backing == .Local ? "L0536" : ""
	case .Outlive:
		return backing == .Local ? "L0537" : ""
	case .Task:
		return backing != .Default ? "L0732" : ""
	}
	return ""
}

// Nothing resets the default provider.
@(private = "file")
region_applies :: proc(place: Region_Place, flow: Region_Flow) -> bool {
	return place.backing != .Default || !(strings.contains(flow.body, "free_all") || strings.contains(flow.before, "free_all"))
}

@(private = "file")
Region_Case :: struct {
	route:      Region_Route,
	flow:       Region_Flow,
	first_line: int,
	last_line:  int,
}

@(private = "file")
region_replace :: proc(text: string, replacements: [][2]string) -> string {
	out := text
	for replacement in replacements {
		out, _ = strings.replace_all(out, replacement[0], replacement[1], context.temp_allocator)
	}
	return out
}

// One program holding every route and flow of one shape and kind of region,
// each in its own procedure. The generic procedures are instantiated at another
// element type, with the default provider, by a procedure before the cases or
// after them, so neither order of instances may change a result's region.
@(private = "file")
region_program :: proc(shape: Region_Shape, place: Region_Place, warm_first: bool, cases: ^[dynamic]Region_Case) -> string {
	b := strings.builder_make(context.temp_allocator)
	lines := 0
	line :: proc(b: ^strings.Builder, lines: ^int, text: string) {
		strings.write_string(b, text)
		strings.write_byte(b, '\n')
		lines^ += strings.count(text, "\n") + 1
	}
	generic := region_replace(shape.type, {{"$T", "T"}})
	built := region_replace(shape.value, {{"$T", "T"}, {"$S", "seed"}, {"$L", "allocator"}})
	owner := region_replace(shape.type, {{"$T", "int"}})
	line(&b, &lines, "package main;")
	line(&b, &lines, "import \"core:mem\";")
	line(&b, &lines, "Held :: struct($T: type) { items: [dynamic]T, count: int }")
	line(&b, &lines, "Maker :: struct($T: type) { allocator: Allocator, seed: T }")
	line(&b, &lines, fmt.tprintf("build :: proc(seed: $T, allocator: Allocator) -> %s {{ return %s; }}", generic, built))
	line(&b, &lines, fmt.tprintf("build_beside :: proc(seed: $T, allocator: Allocator, beside: Allocator) -> %s {{ return build(seed, allocator); }}", generic))
	line(&b, &lines, fmt.tprintf("forward :: proc(seed: $T, allocator: Allocator) -> %s {{ return build(seed, allocator); }}", generic))
	line(&b, &lines, "pass :: proc(owner: move $O) -> O { return owner; }")
	line(&b, &lines, "replace :: proc(slot: inout $O, @(escape=stored) owner: move O) { slot = move(owner); }")
	line(&b, &lines, fmt.tprintf("get :: operator([]) proc(maker: Maker($T), index: int) -> %s {{ return build(maker.seed, maker.allocator); }}", generic))
	line(&b, &lines, fmt.tprintf("other :: operator([]) proc(maker: Maker($T), index: bool) -> %s {{ return build(maker.seed, mem.default_allocator()); }}", generic))
	line(&b, &lines, fmt.tprintf("impl Maker($T) {{ made :: proc(self: Maker(T)) -> %s {{ return self[0]; }} }}", generic))
	line(&b, &lines, "Wrapped :: distinct Maker(int);")
	line(&b, &lines, "impl Wrapped { delegate([]); }")
	line(&b, &lines, "sink :: proc(value: int) {}")
	line(&b, &lines, "choose :: proc() -> bool { return true; }")
	line(&b, &lines, fmt.tprintf("eat :: proc(owner: move %s) {{}}", owner))
	line(&b, &lines, fmt.tprintf("kept: Option(%s);", owner))
	line(&b, &lines, "main :: proc() {}")
	warm :=
		"warm :: proc() { maker := Maker(bool){mem.default_allocator(), true};" +
		" a := build(true, mem.default_allocator()); drop(a); b := maker[0]; drop(b); c := maker[true]; drop(c);" +
		" d := maker.made(); drop(d); e := forward(true, mem.default_allocator()); drop(e);" +
		" f := pass(build_beside(true, mem.default_allocator(), mem.default_allocator())); drop(f); }"
	if warm_first {
		line(&b, &lines, warm)
	}

	for route in REGION_ROUTES {
		for flow in REGION_FLOWS {
			if !region_applies(place, flow) {
				continue
			}
			replacements := [][2]string {
				{"$TAKE", route.take}, {"$USE", shape.use},
				{"$V", region_replace(shape.value, {{"$T", "int"}, {"$S", "1"}, {"$L", "$A"}})},
				{"$D", region_replace(shape.value, {{"$T", "int"}, {"$S", "1"}, {"$L", "mem.default_allocator()"}})},
				{"$A", place.allocator}, {"$B", place.other}, {"$R", owner},
			}
			params := place.params
			if flow.params != "" {
				params = strings.join({params, flow.params}, params != "" ? ", " : "", context.temp_allocator)
			}
			entry := Region_Case{route = route, flow = flow, first_line = lines + 1}
			line(&b, &lines, region_replace(fmt.tprintf("case_%d :: proc(%s)%s {{", len(cases), params, flow.result), replacements))
			for text in ([]string{flow.outer, place.setup, flow.before, strings.contains(flow.body, "$TAKE") ? "" : route.take, flow.body}) {
				if text != "" {
					line(&b, &lines, region_replace(fmt.tprintf("\t%s", text), replacements))
				}
			}
			line(&b, &lines, "}")
			entry.last_line = lines
			append(cases, entry)
		}
	}
	if !warm_first {
		line(&b, &lines, warm)
	}
	return strings.to_string(b)
}

@(test)
region_matrix :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	os.make_directory(REGION_DIR)
	Program :: struct {
		shape:      Region_Shape,
		place:      Region_Place,
		warm_first: bool,
		cases:      [dynamic]Region_Case,
	}
	programs := make([dynamic]Program, context.temp_allocator)
	jobs := make([dynamic]Exec, context.temp_allocator)
	for shape in REGION_SHAPES {
		for place in REGION_PLACES {
			for warm_first in ([2]bool{false, true}) {
				program := Program{shape = shape, place = place, warm_first = warm_first, cases = make([dynamic]Region_Case, context.temp_allocator)}
				source := region_program(shape, place, warm_first, &program.cases)
				name := fmt.tprintf("%s_%s_%s", shape.name, place.name, warm_first ? "warm_first" : "warm_last")
				path := fmt.tprintf("%s/%s.loke", REGION_DIR, name)
				if !testing.expectf(t, os.write_entire_file(path, transmute([]byte)source) == nil, "%s: cannot write", path) {
					continue
				}
				append(&programs, program)
				command := make([]string, 5, context.temp_allocator)
				command[0], command[1], command[2] = compiler_path(), path, "-emit-ll"
				command[3], command[4] = "-o", fmt.tprintf("%s/%s.exe", REGION_DIR, name)
				append(&jobs, Exec{command = command})
			}
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
		testing.expectf(t, matrix_exit_matches_diagnostics(job.state, errors), "%s: unexpected compiler exit %d:\n%s", path, job.state.exit_code, string(job.stderr))
		// Every diagnostic of a case has the code its rule reports, and one outside
		// every case is a mistake in the generated program.
		claimed := make([]bool, len(errors), context.temp_allocator)
		for entry in program.cases {
			expected := region_expected(program.place, entry.route, entry.flow)
			code := ""
			for e, at in errors {
				if e.line >= entry.first_line && e.line <= entry.last_line {
					claimed[at] = true
					if code == "" || e.code != expected {
						code = e.code
					}
				}
			}
			testing.expectf(
				t, code == expected, "%s (lines %d-%d): %s owner by %s in a %s region, then %s: expected %s, got %s",
				path, entry.first_line, entry.last_line, program.shape.name, entry.route.name, program.place.name, entry.flow.name,
				expected if expected != "" else "no error", code if code != "" else "no error",
			)
		}
		for e, at in errors {
			testing.expectf(t, claimed[at], "%s:%d: unexpected %s:\n%s", path, e.line, e.code, string(job.stderr))
		}
	}
}
