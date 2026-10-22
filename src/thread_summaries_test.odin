package lokec

import "core:strings"
import "core:testing"

// concurrency-proposal.md "The summaries the checks read": the reach effect,
// the allocator-use effect, and the drops every thread runs at exit, over
// direct calls, recursion, procedure values, `dyn` witnesses, hooks, and
// cleanup.

@(private = "file")
summarized :: proc(t: ^testing.T, p: ^Checked, body: string) -> bool {
	source := strings.concatenate({"package main;\n", body, "\nmain :: proc() {}\n"}, context.temp_allocator)
	check_source(p, source)
	if !testing.expectf(t, p.c.error_count == 0, "the program did not check: %v", p.c.diagnostics[:]) {
		return false
	}
	k := Checker{c = &p.c}
	p.c.thread_summaries_wanted = true
	analyze_program_provenance(&k)
	return testing.expectf(t, p.c.error_count == 0, "provenance rejected the program: %v", p.c.diagnostics[:])
}

@(private = "file")
symbol_named :: proc(t: ^testing.T, p: ^Checked, name: string, kind: Symbol_Kind) -> Symbol_Id {
	for sym, index in p.c.symbols {
		if sym != nil && sym.kind == kind && identifier_text(&p.c, sym.name) == name {
			return Symbol_Id(index)
		}
	}
	testing.expectf(t, false, "`%s` was not found", name)
	return INVALID_SYMBOL
}

// Where `procedure`'s reach effect has `global`, if it does.
@(private = "file")
reach_of :: proc(t: ^testing.T, p: ^Checked, procedure, global: string) -> (Effect_Source, bool) {
	wanted := symbol_named(t, p, global, .Var)
	for reached in p.c.reach_effects[symbol_named(t, p, procedure, .Proc)] {
		if reached.global == wanted {
			return reached.source, true
		}
	}
	return {}, false
}

@(private = "file")
expect_reach :: proc(t: ^testing.T, p: ^Checked, procedure, global: string, via := "", loc := #caller_location) {
	source, found := reach_of(t, p, procedure, global)
	if !testing.expectf(t, found, "`%s` should reach through `%s`", procedure, global, loc = loc) {
		return
	}
	expected := via == "" ? INVALID_SYMBOL : symbol_named(t, p, via, .Proc)
	testing.expectf(
		t, source.via == expected, "`%s` should reach `%s` through `%s`, found %v", procedure, global, via, source.via, loc = loc,
	)
}

@(private = "file")
expect_no_reach :: proc(t: ^testing.T, p: ^Checked, procedure, global: string, loc := #caller_location) {
	_, found := reach_of(t, p, procedure, global)
	testing.expectf(t, !found, "`%s` should not reach through `%s`", procedure, global, loc = loc)
}

@(private = "file")
use_of :: proc(t: ^testing.T, p: ^Checked, procedure: string) -> Allocator_Use {
	return p.c.allocator_uses[symbol_named(t, p, procedure, .Proc)]
}

@(private = "file")
uses_param :: proc(use: Allocator_Use, index: int) -> bool {
	return index < len(use.regions.params) && use.regions.params[index]
}

@(test)
reach_follows_copies_helpers_and_results :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !summarized(t, &p, `
shared: []mut int;
other: []int;
Holder :: struct { view: []mut int, count: int }
holder: Holder;
write_through :: proc() { shared[0] = 1; }
copy_then_write :: proc() { local := shared; local[0] = 2; }
read_other :: proc() -> int { return other[0]; }
header_only :: proc() -> int { return shared.len(); }
poke :: proc(xs: []mut int) { xs[0] = 3; }
hand_off :: proc() { poke(shared); }
get :: proc() -> []mut int { return shared; }
through_result :: proc() { get()[0] = 4; }
caller :: proc() { write_through(); }
field_through :: proc() { holder.view[0] = 5; }
pointer_through :: proc() { p := &holder; p.view[0] = 6; }
plain_field :: proc() -> int { return holder.count; }
store :: proc(@(escape=static) xs: []mut int) { shared = xs; }
`) {
		return
	}
	expect_reach(t, &p, "write_through", "shared")
	expect_reach(t, &p, "copy_then_write", "shared")
	expect_reach(t, &p, "read_other", "other")
	expect_no_reach(t, &p, "header_only", "shared")
	expect_no_reach(t, &p, "poke", "shared")
	expect_reach(t, &p, "hand_off", "shared")
	expect_reach(t, &p, "get", "shared")
	expect_reach(t, &p, "through_result", "shared", via = "get")
	expect_reach(t, &p, "caller", "shared", via = "write_through")
	expect_reach(t, &p, "field_through", "holder")
	expect_reach(t, &p, "pointer_through", "holder")
	expect_no_reach(t, &p, "plain_field", "holder")
	// Storing a parameter's view writes the global, which the write effect
	// records; nothing it held before is reached.
	expect_no_reach(t, &p, "store", "shared")
}

@(test)
reach_settles_over_recursion :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !summarized(t, &p, `
shared: []mut int;
ping :: proc(n: int) { if (n > 0) { pong(n - 1); } }
pong :: proc(n: int) { if (n > 0) { ping(n - 1); } else { shared[0] = n; } }
`) {
		return
	}
	expect_reach(t, &p, "pong", "shared")
	expect_reach(t, &p, "ping", "shared", via = "pong")
}

@(test)
reach_unions_procedure_values_and_witnesses :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !summarized(t, &p, `
shared: []mut int;
touch :: proc() { shared[0] = 1; }
quiet :: proc() {}
run :: proc(action: proc()) { action(); }
choose :: proc() { run(touch); run(quiet); }
Poker :: interface($Self: type) { slot poke: proc(self); }
Real :: struct { id: int }
impl Real { poke :: proc(self) { shared[0] = self.id; } }
use_view :: proc(view: dyn Poker) { view.poke(); }
build :: proc() { r := Real{1}; use_view((dyn Poker)(&r)); }
`) {
		return
	}
	// One compatible procedure used as a value puts its effect in every call
	// through a value of its type.
	expect_reach(t, &p, "run", "shared", via = "touch")
	expect_reach(t, &p, "use_view", "shared", via = "poke")
	expect_reach(t, &p, "build", "shared", via = "use_view")
}

@(test)
reach_includes_hooks_and_cleanup :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !summarized(t, &p, `
shared: []mut int;
Guard :: struct { id: int }
impl Guard { release :: hook(drop) proc(self: inout Guard) { shared[0] = self.id; } }
scoped :: proc() { g := Guard{1}; }
deferred :: proc() { defer shared[0] = 2; }
@(synchronized) vouched: []mut int;
mine: thread_local []mut int;
vouched_write :: proc() { vouched[0] = 3; }
own_thread :: proc() { mine[0] = 4; }
`) {
		return
	}
	expect_reach(t, &p, "scoped", "shared", via = "release")
	expect_reach(t, &p, "deferred", "shared")
	// A `@(synchronized)` variable's package vouches for what it holds; a
	// `thread_local` one is held to the same rule as any global.
	expect_no_reach(t, &p, "vouched_write", "vouched")
	expect_reach(t, &p, "own_thread", "mine")
}

@(test)
allocator_use_names_parameters_and_the_default :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !summarized(t, &p, `
grow :: proc(list: inout [dynamic]int) { list.append(1); }
build :: proc(a: Allocator) -> [dynamic]int { return make([dynamic]int, 0, 4, a); }
forward :: proc(unused: int, a: Allocator) { xs := build(a); grow(inout xs); }
fresh :: proc() { xs: [dynamic]int = {}; xs.append(1); }
idle :: proc(a: Allocator) -> int { return 1; }
peek :: proc(list: ^[dynamic]int) -> int { return list[0]; }
`) {
		return
	}
	testing.expect(t, uses_param(use_of(t, &p, "grow"), 0), "`grow` appends to its parameter")
	testing.expect(t, uses_param(use_of(t, &p, "build"), 0), "`build` makes from its allocator")
	forward := use_of(t, &p, "forward")
	testing.expect(t, uses_param(forward, 1) && !uses_param(forward, 0), "`forward` uses its allocator parameter only")
	testing.expect(t, !forward.regions.unknown, "`forward` uses no unknown region")
	testing.expect(t, use_of(t, &p, "fresh").regions.default, "`fresh` grows a default-bound array")
	testing.expect(t, allocator_use_is_empty(use_of(t, &p, "idle")), "`idle` uses no allocator")
	testing.expect(t, allocator_use_is_empty(use_of(t, &p, "peek")), "`peek` only reads")
}

@(test)
allocator_use_settles_over_recursion_values_and_witnesses :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !summarized(t, &p, `
down :: proc(n: int, a: Allocator) { if (n > 0) { up(n - 1, a); } }
up :: proc(n: int, a: Allocator) { if (n > 0) { down(n - 1, a); } else { xs := make([dynamic]int, 0, 4, a); } }
fill :: proc(a: Allocator) { xs := make([dynamic]int, 0, 4, a); }
apply :: proc(f: proc(a: Allocator), a: Allocator) { f(a); }
pick :: proc(a: Allocator) { apply(fill, a); }
Filler :: interface($Self: type) { slot fill_into: proc(self, a: Allocator); }
Real :: struct { id: int }
impl Real { fill_into :: proc(self, a: Allocator) { xs := make([dynamic]int, 0, 4, a); } }
use_view :: proc(view: dyn Filler, a: Allocator) { view.fill_into(a); }
build :: proc(a: Allocator) { r := Real{1}; use_view((dyn Filler)(&r), a); }
`) {
		return
	}
	testing.expect(t, uses_param(use_of(t, &p, "down"), 1), "`down` reaches `up`'s allocation")
	apply := use_of(t, &p, "apply")
	testing.expect(t, uses_param(apply, 1), "a call through a value binds the allocator argument")
	testing.expectf(t, apply.param_sources[1].via == symbol_named(t, &p, "fill", .Proc), "`apply` names `fill`")
	use_view := use_of(t, &p, "use_view")
	testing.expect(t, uses_param(use_view, 1), "a `dyn` call reaches the witness's allocation")
	testing.expectf(t, use_view.param_sources[1].via == symbol_named(t, &p, "fill_into", .Proc), "`use_view` names the witness")
	testing.expect(t, uses_param(use_of(t, &p, "build"), 0), "`build` substitutes its own parameter")
}

@(test)
allocator_use_includes_hooks_and_cleanup :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !summarized(t, &p, `
chosen: Allocator;
Guard :: struct { id: int }
impl Guard {
	release :: hook(drop) proc(self: inout Guard) { log := make([dynamic]int, 0, 4, chosen); }
}
scoped :: proc() { g := Guard{1}; }
deferred :: proc(list: inout [dynamic]int) { defer list.append(1); }
dropped :: proc(a: Allocator) { xs := make([dynamic]int, 0, 4, a); drop(xs); }
`) {
		return
	}
	release := use_of(t, &p, "release")
	testing.expect(t, release.regions.unknown, "an allocator read from a global is an unknown region")
	scoped := use_of(t, &p, "scoped")
	testing.expect(t, scoped.regions.unknown, "dropping a `Guard` runs its hook")
	testing.expectf(t, scoped.unknown_source.via == symbol_named(t, &p, "release", .Proc), "`scoped` names the hook")
	testing.expect(t, uses_param(use_of(t, &p, "deferred"), 0), "a deferred append is the body's")
	testing.expect(t, uses_param(use_of(t, &p, "dropped"), 0), "`dropped` frees in its parameter's region")
}

@(test)
thread_exit_drops_cover_every_thread_local_owner :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !summarized(t, &p, `
total: int;
shared: []mut int;
Tracked :: struct { id: int }
impl Tracked { release :: hook(drop) proc(self: inout Tracked) { total += self.id; shared[0] = self.id; } }
resource: thread_local Tracked;
names: thread_local [dynamic]int;
plain: thread_local int;
remember :: proc() { local: thread_local Tracked; }
`) {
		return
	}
	resource := symbol_named(t, &p, "resource", .Var)
	names := symbol_named(t, &p, "names", .Var)
	local := symbol_named(t, &p, "local", .Var)
	release := symbol_named(t, &p, "release", .Proc)
	total := symbol_named(t, &p, "total", .Var)
	shared := symbol_named(t, &p, "shared", .Var)
	hooked, released, local_hooked := false, false, false
	for drop in p.c.thread_exit_drops {
		testing.expect(t, drop.variable != symbol_named(t, &p, "plain", .Var), "a plain `thread_local` drops nothing")
		switch {
		case drop.variable == resource && drop.hook == release:
			hooked = true
			testing.expect(t, len(drop.writes) == 1 && drop.writes[0] == total, "the hook's writes are the drop's")
			testing.expect(t, len(drop.reach) == 1 && drop.reach[0].global == shared, "so is its reach")
			testing.expect(t, len(drop.reach) == 1 && drop.reach[0].source.via == release, "naming the hook")
		case drop.variable == names && drop.hook == INVALID_SYMBOL:
			released = true
			testing.expect(t, drop.use.regions.default, "a default-bound owner frees in the default region")
		case drop.variable == local && drop.hook == release:
			local_hooked = true
		}
	}
	testing.expect(t, hooked, "the hooked owner's drop is listed")
	testing.expect(t, released, "the managed owner's release is listed")
	testing.expect(t, local_hooked, "a procedure's `thread_local` owner is listed too")
}

// Text operations return before the ordinary call path, so their reads and
// allocations are recorded on their own; reading only the header is no reach.
@(test)
text_calls_reach_and_allocate :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !summarized(t, &p, `
shared: string_view;
touch :: proc() -> int { return shared.rune_count(); }
header :: proc() -> int { return shared.byte_len(); }
handed :: proc() -> []u8 { return shared.bytes(); }
duplicate :: proc(s: string_view) -> string { return s.copy(); }
count :: proc(s: string_view) -> int { return s.rune_count(); }
`) {
		return
	}
	expect_reach(t, &p, "touch", "shared")
	// A header read touches no bytes; a derived view handed back may be read.
	expect_no_reach(t, &p, "header", "shared")
	expect_reach(t, &p, "handed", "shared")
	testing.expect(t, use_of(t, &p, "duplicate").regions.default, "`copy` allocates from the default provider")
	testing.expect(t, allocator_use_is_empty(use_of(t, &p, "count")), "counting runes allocates nothing")
}

// A `move_only` record of plain fields is managed for its lifecycle but frees
// no allocator storage.
@(test)
plain_move_only_drops_use_no_allocator :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !summarized(t, &p, `
Token :: move_only struct { id: int }
token: thread_local Token;
hold :: proc() { held := Token{1}; }
`) {
		return
	}
	testing.expect(t, allocator_use_is_empty(use_of(t, &p, "hold")), "dropping a plain `Token` frees nothing")
	token := symbol_named(t, &p, "token", .Var)
	for drop in p.c.thread_exit_drops {
		testing.expect(t, drop.variable != token, "a plain `Token` owner releases no storage at thread exit")
	}
}
