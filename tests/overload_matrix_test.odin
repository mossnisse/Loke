// A generated matrix of calls through procedure groups (design.md "Operator
// lookup and overload resolution", "Explicit procedure overloading",
// "Specialization", "where clauses", "Inferred generic parameters"). Each group
// holds two or three members drawn from one list, in either order, and is called
// with each of a list of arguments. Which member the call selects, or that it is
// ambiguous, or that no member applies, comes from `overload_expected`, a model
// of the rules written apart from the compiler, never from its output. Every
// member returns a type of its own, and a case initialises a local of the
// expected member's result type, so a call that selects another member does not
// compile: a destination type never chooses the member.
package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
OVERLOAD_DIR :: TMP + "/overload_matrix"

@(private = "file")
Overload_Type :: enum { Int, I8, F64, Ptr, Ptr_Mut, Slice, Slice_Mut, Dynamic, Array, Pair }

@(private = "file")
OVERLOAD_TYPE_TEXT := [Overload_Type]string {
	.Int = "int", .I8 = "i8", .F64 = "f64", .Ptr = "^int", .Ptr_Mut = "^mut int", .Slice = "[]int", .Slice_Mut = "[]mut int",
	.Dynamic = "[dynamic]int", .Array = "[3]int", .Pair = "Pair(int, int)",
}

@(private = "file")
Overload_Constant :: enum { None, Integer, Floating }

// An argument: the locals it needs, how it is written, and its type, which for
// an unfixed constant is its default type. `owned` is a temporary or a
// `move(...)`, which a `move` parameter accepts.
@(private = "file")
Overload_Arg :: struct {
	name, setup, text: string,
	type:              Overload_Type,
	constant:          Overload_Constant,
	owned:             bool,
}

@(private = "file")
OVERLOAD_ARGS := [?]Overload_Arg {
	{"const_int", "", "7", .Int, .Integer, false},
	{"const_float", "", "7.5", .F64, .Floating, false},
	{"int", "n := 1;", "n", .Int, .None, false},
	{"i8", "small: i8 = 1;", "small", .I8, .None, false},
	{"f64", "real := 1.5;", "real", .F64, .None, false},
	{"pointer", "n := 1;", "&n", .Ptr, .None, false},
	{"pointer_mut", "n := 1;", "&mut n", .Ptr_Mut, .None, false},
	{"slice", "fixed := [3]int{1, 2, 3}; view := fixed[:];", "view", .Slice, .None, false},
	{"slice_mut", "fixed := [3]int{1, 2, 3}; view := fixed[mut :];", "view", .Slice_Mut, .None, false},
	{"dynamic", "items := make_items();", "items", .Dynamic, .None, false},
	{"dynamic_temporary", "", "make_items()", .Dynamic, .None, true},
	{"dynamic_moved", "items := make_items();", "move(items)", .Dynamic, .None, true},
	{"array", "fixed := [3]int{1, 2, 3};", "fixed", .Array, .None, false},
	{"pair", "pair := Pair(int, int){1, 2};", "pair", .Pair, .None, false},
}

// The calls with two arguments, as indices into `OVERLOAD_ARGS`: constants and
// scalars, whose locals have names of their own.
@(private = "file")
OVERLOAD_TWO_ARGS := [?][2]int{{0, 0}, {0, 1}, {1, 0}, {2, 0}, {0, 2}, {2, 2}, {2, 4}, {4, 2}, {3, 3}, {4, 0}, {1, 2}}

// A parameter: a concrete type, maybe taken by `move`, or a pattern binding `$`
// names, maybe under a bound on the type it binds.
@(private = "file")
Overload_Pattern :: enum { Concrete, Any, Slice_Of, Pointer_To, Pair_Of }

@(private = "file")
Overload_Bound :: enum { None, Integral, Numeric, Not_Integral }

@(private = "file")
Overload_Param :: struct {
	pattern: Overload_Pattern,
	type:    Overload_Type,
	move:    bool,
	bound:   Overload_Bound,
}

// A member of a group: `count` parameters, of which the last is an `..int` pack
// when `variadic`, and the last `defaults` have a default value.
@(private = "file")
Overload_Member :: struct {
	name:     string,
	params:   [2]Overload_Param,
	count:    int,
	variadic: bool,
	defaults: int,
}

@(private = "file")
OVERLOAD_MEMBERS := [?]Overload_Member {
	{name = "int", params = {{type = .Int}, {}}, count = 1},
	{name = "i8", params = {{type = .I8}, {}}, count = 1},
	{name = "f64", params = {{type = .F64}, {}}, count = 1},
	{name = "pointer", params = {{type = .Ptr}, {}}, count = 1},
	{name = "pointer_mut", params = {{type = .Ptr_Mut}, {}}, count = 1},
	{name = "slice", params = {{type = .Slice}, {}}, count = 1},
	{name = "slice_mut", params = {{type = .Slice_Mut}, {}}, count = 1},
	{name = "dynamic", params = {{type = .Dynamic}, {}}, count = 1},
	{name = "dynamic_move", params = {{type = .Dynamic, move = true}, {}}, count = 1},
	{name = "array", params = {{type = .Array}, {}}, count = 1},
	{name = "pair", params = {{type = .Pair}, {}}, count = 1},
	{name = "any", params = {{pattern = .Any}, {}}, count = 1},
	{name = "any_integral", params = {{pattern = .Any, bound = .Integral}, {}}, count = 1},
	{name = "any_numeric", params = {{pattern = .Any, bound = .Numeric}, {}}, count = 1},
	{name = "any_not_integral", params = {{pattern = .Any, bound = .Not_Integral}, {}}, count = 1},
	{name = "slice_of", params = {{pattern = .Slice_Of}, {}}, count = 1},
	{name = "pointer_to", params = {{pattern = .Pointer_To}, {}}, count = 1},
	{name = "pair_of", params = {{pattern = .Pair_Of}, {}}, count = 1},
	{name = "variadic", params = {{type = .Int}, {}}, count = 1, variadic = true},
	{name = "defaulted", params = {{type = .Int}, {type = .Int}}, count = 2, defaults = 1},
	{name = "int_f64", params = {{type = .Int}, {type = .F64}}, count = 2},
	{name = "f64_int", params = {{type = .F64}, {type = .Int}}, count = 2},
	{name = "int_int", params = {{type = .Int}, {type = .Int}}, count = 2},
	{name = "i8_i8", params = {{type = .I8}, {type = .I8}}, count = 2},
	{name = "any_int", params = {{pattern = .Any}, {type = .Int}}, count = 2},
	{name = "int_any", params = {{type = .Int}, {pattern = .Any}}, count = 2},
	{name = "any_any", params = {{pattern = .Any}, {pattern = .Any}}, count = 2},
}

// The groups of three, as indices into `OVERLOAD_MEMBERS`: every three of these.
@(private = "file")
OVERLOAD_TRIPLE_POOL := [?]int{0, 2, 5, 11, 12, 15, 18, 19, 22, 26}

// How one argument fits one parameter (design.md "Operator lookup and overload
// resolution"): rank 0 for its own type, 1 for a mutable pointer or slice
// weakened to a read-only one, 2 for an unfixed constant converting within its
// kind, and 3 for any other implicit conversion (design.md "Implicit type
// conversions"): an unfixed integer to a floating type, or a dynamic or fixed
// array viewed as a slice. A `move` parameter takes a temporary or a
// `move(...)`, never a place. A `$T` parameter binds any argument's type, a
// constant's default type included (design.md "Inferred generic parameters"),
// which is that constant's conversion, and its bound then filters on the type
// bound; a pattern binds from an argument that converts to the type the pattern
// produces, at that conversion's rank (design.md "Specialization").
@(private = "file")
overload_rank :: proc(arg: Overload_Arg, param: Overload_Param) -> (rank: int, ok: bool) {
	integer := arg.type == .Int || arg.type == .I8
	switch param.pattern {
	case .Concrete:
		switch arg.constant {
		case .Integer:
			#partial switch param.type {
			case .Int, .I8: return 2, true
			case .F64:      return 3, true
			}
			return 0, false
		case .Floating:
			return 2, param.type == .F64
		case .None:
		}
		if param.move && !arg.owned {
			return 0, false
		}
		if arg.type == param.type {
			return 0, true
		}
		#partial switch param.type {
		case .Ptr:
			return 1, arg.type == .Ptr_Mut
		case .Slice:
			if arg.type == .Slice_Mut {
				return 1, true
			}
			return 3, arg.type == .Dynamic || arg.type == .Array
		}
		return 0, false
	case .Any:
		switch param.bound {
		case .None:
		case .Integral:
			if !integer { return 0, false }
		case .Numeric:
			if !integer && arg.type != .F64 { return 0, false }
		case .Not_Integral:
			if integer { return 0, false }
		}
		return arg.constant == .None ? 0 : 2, true
	case .Slice_Of:
		if arg.constant != .None {
			return 0, false
		}
		#partial switch arg.type {
		case .Slice:           return 0, true
		case .Slice_Mut:       return 1, true
		case .Dynamic, .Array: return 3, true
		}
	case .Pointer_To:
		if arg.constant != .None {
			return 0, false
		}
		#partial switch arg.type {
		case .Ptr:     return 0, true
		case .Ptr_Mut: return 1, true
		}
	case .Pair_Of:
		return 0, arg.constant == .None && arg.type == .Pair
	}
	return 0, false
}

// A member that applies to a call, with what the tie-breakers read.
@(private = "file")
Overload_Candidate :: struct {
	member:     int,
	ranks:      [2]int,
	consumed:   int,
	omitted:    int,
	variadic:   bool,
	parametric: bool,
	// How specific each parameter is: 0 an unconstrained `$T`, 1 a pattern, 2 a
	// concrete type.
	specific:   [2]int,
}

@(private = "file")
overload_candidate :: proc(index: int, args: []Overload_Arg) -> (out: Overload_Candidate, ok: bool) {
	member := OVERLOAD_MEMBERS[index]
	out.member, out.variadic = index, member.variadic
	if member.variadic {
		if len(args) < member.count - 1 {
			return out, false
		}
	} else if len(args) > member.count || len(args) < member.count - member.defaults {
		return out, false
	} else {
		out.omitted = member.count - len(args)
	}
	for param, at in member.params[:member.count] {
		out.parametric ||= param.pattern != .Concrete
		out.specific[at] = param.pattern == .Concrete ? 2 : param.pattern == .Any ? 0 : 1
	}
	for arg, at in args {
		param := member.params[min(at, member.count - 1)]
		out.ranks[at] = overload_rank(arg, param) or_return
		if param.move && arg.owned {
			out.consumed += 1
		}
	}
	return out, true
}

// Whether `a` is at least as good as `b` at each of the first `count` positions,
// and better at one.
@(private = "file")
overload_dominates :: proc(a, b: [2]int, count: int, lower_is_better: bool) -> bool {
	better := false
	for at in 0 ..< count {
		x, y := a[at], b[at]
		if !lower_is_better {
			x, y = y, x
		}
		if x > y {
			return false
		}
		better ||= x < y
	}
	return better
}

// The rules (design.md "Operator lookup and overload resolution"). A member is
// a candidate when the argument count fits and every argument converts. A
// candidate is better than another when its conversion ranks are no worse for
// every argument and better for one, and the candidates no other is better than
// remain; with ranks that differ, as crossed ones do, the call is ambiguous.
// Tied ranks go through the tie-breakers in order, each keeping the candidates
// it prefers: the one consuming more owned arguments, a fixed-arity one over a
// variadic one, the one needing fewer omitted defaults, a non-parametric one
// over a parametric one, and a more specialized parametric one, parameter by
// parameter. A bound only filters, so two members alike but for their bounds
// stay ambiguous, and the order the group lists its members in decides nothing.
// The member selected, or -1 with the code the call is rejected with.
@(private = "file")
overload_expected :: proc(group: []int, args: []Overload_Arg) -> (member: int, code: string) {
	candidates := make([dynamic]Overload_Candidate, context.temp_allocator)
	for index in group {
		if candidate, ok := overload_candidate(index, args); ok {
			append(&candidates, candidate)
		}
	}
	if len(candidates) == 0 {
		return -1, "L0392"
	}
	kept := make([dynamic]Overload_Candidate, context.temp_allocator)
	for candidate in candidates {
		beaten := false
		for other in candidates {
			beaten ||= overload_dominates(other.ranks, candidate.ranks, len(args), true)
		}
		if !beaten {
			append(&kept, candidate)
		}
	}
	for candidate in kept[1:] {
		if candidate.ranks != kept[0].ranks {
			return -1, "L0391"
		}
	}
	// Each tie-breaker keeps the candidates with the best key.
	narrow :: proc(kept: ^[dynamic]Overload_Candidate, key: proc(candidate: Overload_Candidate) -> int) {
		best := max(int)
		for candidate in kept {
			best = min(best, key(candidate))
		}
		#reverse for candidate, at in kept {
			if key(candidate) != best {
				ordered_remove(kept, at)
			}
		}
	}
	narrow(&kept, proc(candidate: Overload_Candidate) -> int { return -candidate.consumed })
	narrow(&kept, proc(candidate: Overload_Candidate) -> int { return int(candidate.variadic) })
	narrow(&kept, proc(candidate: Overload_Candidate) -> int { return candidate.omitted })
	narrow(&kept, proc(candidate: Overload_Candidate) -> int { return int(candidate.parametric) })
	if len(kept) > 1 {
		specialized := make([dynamic]Overload_Candidate, context.temp_allocator)
		for candidate in kept {
			beaten := false
			for other in kept {
				beaten ||= overload_dominates(other.specific, candidate.specific, OVERLOAD_MEMBERS[candidate.member].count, false)
			}
			if !beaten {
				append(&specialized, candidate)
			}
		}
		kept = specialized
	}
	if len(kept) != 1 {
		return -1, "L0391"
	}
	return kept[0].member, ""
}

@(private = "file")
overload_member_text :: proc(index: int) -> string {
	member := OVERLOAD_MEMBERS[index]
	b := strings.builder_make(context.temp_allocator)
	bounds := make([dynamic]string, context.temp_allocator)
	fmt.sbprintf(&b, "m%d :: proc(", index)
	for param, at in member.params[:member.count] {
		if at > 0 {
			strings.write_string(&b, ", ")
		}
		if member.variadic && at == member.count - 1 {
			fmt.sbprintf(&b, "x%d: ..int", at)
			continue
		}
		fmt.sbprintf(&b, "x%d: ", at)
		switch param.pattern {
		case .Concrete:   fmt.sbprintf(&b, "%s%s", param.move ? "move " : "", OVERLOAD_TYPE_TEXT[param.type])
		case .Any:        fmt.sbprintf(&b, "$T%d", at)
		case .Slice_Of:   fmt.sbprintf(&b, "[]$T%d", at)
		case .Pointer_To: fmt.sbprintf(&b, "^$T%d", at)
		case .Pair_Of:    fmt.sbprintf(&b, "Pair($T%d, $U%d)", at, at)
		}
		if at >= member.count - member.defaults {
			strings.write_string(&b, " = 0")
		}
		switch param.bound {
		case .None:
		case .Integral:     append(&bounds, fmt.tprintf("Integral(T%d)", at))
		case .Numeric:      append(&bounds, fmt.tprintf("Numeric(T%d)", at))
		case .Not_Integral: append(&bounds, fmt.tprintf("!Integral(T%d)", at))
		}
	}
	fmt.sbprintf(&b, ") -> R%d", index)
	if len(bounds) > 0 {
		fmt.sbprintf(&b, " where %s", strings.join(bounds[:], ", ", context.temp_allocator))
	}
	fmt.sbprintf(&b, " {{ return R%d{{}}; }}", index)
	return strings.to_string(b)
}

@(private = "file")
Overload_Case :: struct {
	group:  []int,
	args:   []Overload_Arg,
	member: int,
	code:   string,
	line:   int,
}

// One program holding the given groups, each called with every list of
// arguments one of its members could take the count of.
@(private = "file")
overload_program :: proc(groups: [][]int, cases: ^[dynamic]Overload_Case) -> string {
	b := strings.builder_make(context.temp_allocator)
	lines := 0
	line :: proc(b: ^strings.Builder, lines: ^int, text: string) {
		strings.write_string(b, text)
		strings.write_byte(b, '\n')
		lines^ += 1
	}
	line(&b, &lines, "package main;")
	line(&b, &lines, "Pair :: struct($A: type, $B: type) { a: A, b: B }")
	line(&b, &lines, "make_items :: proc() -> [dynamic]int { return {}; }")
	line(&b, &lines, "main :: proc() {}")
	for _, index in OVERLOAD_MEMBERS {
		line(&b, &lines, fmt.tprintf("R%d :: struct {{}}", index))
		line(&b, &lines, overload_member_text(index))
	}
	calls := make([dynamic][]Overload_Arg, context.temp_allocator)
	for _, index in OVERLOAD_ARGS {
		append(&calls, overload_call(index))
	}
	for pair in OVERLOAD_TWO_ARGS {
		append(&calls, overload_call(pair[0], pair[1]))
	}
	for group, at in groups {
		names := make([dynamic]string, context.temp_allocator)
		most := 0
		for index in group {
			append(&names, fmt.tprintf("m%d", index))
			most = max(most, OVERLOAD_MEMBERS[index].variadic ? 2 : OVERLOAD_MEMBERS[index].count)
		}
		line(&b, &lines, fmt.tprintf("g%d :: proc{{%s}}", at, strings.join(names[:], ", ", context.temp_allocator)))
		for args in calls {
			if len(args) > most {
				continue
			}
			member, code := overload_expected(group, args)
			setup, written := "", ""
			for arg, position in args {
				if arg.setup != "" && !strings.contains(setup, arg.setup) {
					setup = fmt.tprintf("%s%s ", setup, arg.setup)
				}
				written = fmt.tprintf("%s%s%s", written, position > 0 ? ", " : "", arg.text)
			}
			destination := member >= 0 ? fmt.tprintf("r: R%d", member) : "_"
			line(&b, &lines, fmt.tprintf("case_%d :: proc() {{ %s%s = g%d(%s); }}", len(cases), setup, destination, at, written))
			append(cases, Overload_Case{group = group, args = args, member = member, code = code, line = lines})
		}
	}
	return strings.to_string(b)
}

// The arguments of one call, by their indices in `OVERLOAD_ARGS`.
@(private = "file")
overload_call :: proc(indices: ..int) -> []Overload_Arg {
	out := make([]Overload_Arg, len(indices), context.temp_allocator)
	for index, at in indices {
		out[at] = OVERLOAD_ARGS[index]
	}
	return out
}

@(private = "file")
overload_describe :: proc(entry: Overload_Case) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "group {")
	for index, at in entry.group {
		fmt.sbprintf(&b, "%s%s", at > 0 ? ", " : "", OVERLOAD_MEMBERS[index].name)
	}
	strings.write_string(&b, "} called with (")
	for arg, at in entry.args {
		fmt.sbprintf(&b, "%s%s", at > 0 ? ", " : "", arg.name)
	}
	strings.write_string(&b, ")")
	return strings.to_string(b)
}

@(test)
overload_matrix :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	os.make_directory(OVERLOAD_DIR)
	// Every pair of members in both orders, a program for each first member, and
	// every three of a smaller list, forwards and backwards.
	Program :: struct {
		cases: [dynamic]Overload_Case,
	}
	batches := make([dynamic][][]int, context.temp_allocator)
	for _, first in OVERLOAD_MEMBERS {
		groups := make([dynamic][]int, context.temp_allocator)
		for second in first + 1 ..< len(OVERLOAD_MEMBERS) {
			forward, backward := make([]int, 2, context.temp_allocator), make([]int, 2, context.temp_allocator)
			forward[0], forward[1] = first, second
			backward[0], backward[1] = second, first
			append(&groups, forward, backward)
		}
		if len(groups) > 0 {
			append(&batches, groups[:])
		}
	}
	triples := make([dynamic][]int, context.temp_allocator)
	pool := OVERLOAD_TRIPLE_POOL
	for a in 0 ..< len(pool) {
		for b in a + 1 ..< len(pool) {
			for c in b + 1 ..< len(pool) {
				forward, backward := make([]int, 3, context.temp_allocator), make([]int, 3, context.temp_allocator)
				forward[0], forward[1], forward[2] = pool[a], pool[b], pool[c]
				backward[0], backward[1], backward[2] = pool[c], pool[b], pool[a]
				append(&triples, forward, backward)
			}
		}
	}
	append(&batches, triples[:])

	programs := make([dynamic]Program, context.temp_allocator)
	jobs := make([dynamic]Exec, context.temp_allocator)
	for groups, at in batches {
		program := Program{cases = make([dynamic]Overload_Case, context.temp_allocator)}
		source := overload_program(groups, &program.cases)
		path := fmt.tprintf("%s/batch_%d.loke", OVERLOAD_DIR, at)
		if !testing.expectf(t, os.write_entire_file(path, transmute([]byte)source) == nil, "%s: cannot write", path) {
			continue
		}
		append(&programs, program)
		command := make([]string, 5, context.temp_allocator)
		command[0], command[1], command[2] = compiler_path(), path, "-emit-ll"
		command[3], command[4] = "-o", fmt.tprintf("%s/batch_%d.exe", OVERLOAD_DIR, at)
		append(&jobs, Exec{command = command})
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
		// A case is one line, and takes every diagnostic reported on it.
		codes := make(map[int]string, context.temp_allocator)
		for e in errors {
			if _, seen := codes[e.line]; !seen {
				codes[e.line] = e.code
			}
		}
		for entry in program.cases {
			code := codes[entry.line]
			delete_key(&codes, entry.line)
			expected := entry.member >= 0 ? fmt.tprintf("member `%s`", OVERLOAD_MEMBERS[entry.member].name) : entry.code
			testing.expectf(
				t, code == entry.code, "%s:%d: %s: expected %s, got %s", path, entry.line, overload_describe(entry), expected,
				code if code != "" else "a member selected",
			)
		}
		for at, code in codes {
			testing.expectf(t, false, "%s:%d: unexpected %s:\n%s", path, at, code, string(job.stderr))
		}
	}
}
