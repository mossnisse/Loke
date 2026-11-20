package lokec

import "core:strings"
import "core:testing"

// The module `source` is emitted as, kept past its compilation.
@(private = "file")
emitted_module :: proc(t: ^testing.T, source: string, loc := #caller_location) -> (module: string, ok: bool) {
	p: Checked
	check_for_emission(&p, source)
	defer destroy_checked(&p)
	if !testing.expect(t, p.c.error_count == 0, loc = loc) { report(&p.c); return }
	finalize_semantics(&p.c)
	text, emitted := emit_llvm_module(&p.c)
	if !testing.expect(t, emitted && p.c.error_count == 0, loc = loc) { report(&p.c); return }
	return strings.clone(text, context.temp_allocator), true
}

// A procedure nothing calls is not written: with one or without it, the module
// is the same text, down to the number of every temporary and literal. Were its
// body written and then dropped, those numbers would have moved.
@(private = "file")
REACHED :: `
Pair :: struct { left: int, right: int }
swap :: proc(pair: Pair) -> Pair { return Pair{pair.right, pair.left}; }
main :: proc() {
    pair := swap(Pair{1, 2});
    assert(pair.left == 2, "swapped");
}
`

@(test)
an_uncalled_procedure_is_not_written :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	alone, alone_ok := emitted_module(t, "package main;" + REACHED)
	beside, beside_ok := emitted_module(t, `package main;
unused :: proc(pair: Pair) -> Pair {
    again := swap(swap(pair));
    assert(again.left == pair.left, "swapped twice");
    return also_unused(again);
}
also_unused :: proc(pair: Pair) -> Pair { return swap(pair); }` + REACHED)
	if !alone_ok || !beside_ok {
		return
	}
	testing.expect(t, strings.contains(alone, "define internal %struct.Pair"), "`swap` is not written")
	testing.expect(t, alone == beside, "an uncalled procedure changed the module")
}

// Bodies are in declaration order whatever order they were named in, each
// written once, and a body only a written body names is written too.
@(test)
called_procedures_are_written_in_declaration_order :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	module, ok := emitted_module(t, `package main;
first :: proc() -> int { return third() + 1; }
second :: proc() -> int { return 2; }
third :: proc() -> int { return 3; }
main :: proc() {
    assert(second() + first() + second() == 8);
}
`)
	if !ok {
		return
	}
	at := 0
	for name in ([]string{"first", "second", "third", "main"}) {
		define := strings.concatenate({"@loke.p.", name, "() {"})
		testing.expectf(t, strings.count(module, define) == 1, "`%s` is written %d times", name, strings.count(module, define))
		found := strings.index(module, define)
		testing.expectf(t, found > at, "`%s` is out of order", name)
		at = found
	}
}
