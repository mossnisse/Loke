package lokec

import "core:fmt"
import "core:strings"
import "core:testing"

// design.md "Operator declarations", "Weakening and reborrows",
// "Procedure result contracts": reading a
// carrier through a generic operator is an ordinary call. Its result keeps the
// borrow, including through a forwarding instance, method, or delegate. The
// unused overload and a scalar instance must not change the result summary.
@(test)
generic_operator_results_keep_their_borrows :: proc(t: ^testing.T) {
	Shape :: struct { name, type, setup, first, second, use, write: string }
	shapes := []Shape{
		{"pointer", "^mut int", "left := 1; right := 2;", "&mut left", "&mut right", "sink(held^);", "left = 3;"},
		{"slice", "[]int", "left := [2]int{1, 2}; right := [2]int{3, 4};", "left[:]", "right[:]", "sink(held[0]);", "left[0] = 3;"},
		{"payload", "Option(^mut int)", "left := 1; right := 2;", ".some(&mut left)", ".some(&mut right)", "switch (held) { case .some(p): sink(p^); case .none: }", "left = 3;"},
	}
	Route :: struct { name, take: string }
	routes := []Route{
		{"field", "held := box.first;"},
		{"named", "held := get(box, 0);"},
		{"operator", "held := box[0];"},
		{"forwarded", "held := forward(box);"},
		{"method", "held := box.read();"},
		{"delegated", "wrapped := Wrapped(box); held := wrapped[0];"},
	}
	Flow :: struct { name, body: string, rejected: bool, result: string }
	flows := []Flow{
		{"live", "$WRITE $USE", true, ""},
		{"finished", "$USE $WRITE", false, ""},
		{"other_root", "$OTHER $USE", false, ""},
		{"branch", "if (choose()) { $WRITE } $USE", true, ""},
		{"back_edge", "for (i := 0; i < 2; i += 1) { $USE $WRITE }", true, ""},
		{"defer", "defer { $USE } $WRITE", true, ""},
		{"escape", "return held;", true, " -> $TYPE"},
	}
	prelude := `package main;
Box :: struct($T: type) { first, second: T }
get :: operator([]) proc(box: Box($T), index: int) -> T { return box.first; }
other :: operator([]) proc(box: Box($T), index: bool) -> T { return box.second; }
forward :: proc(box: Box($T)) -> T { return box[0]; }
impl Box($T) { read :: proc(self: Box(T)) -> T { return self[0]; } }
Wrapped :: distinct Box($TYPE);
impl Wrapped { delegate([]); }
sink :: proc(value: int) {}
choose :: proc() -> bool { return true; }
probe :: proc()$RESULT {
$BEFORE
$SETUP
box := Box($TYPE){$FIRST, $SECOND};
$TAKE
$BODY
$AFTER
}
main :: proc() { probe(); }
`
	// Exercise both orders of scalar and carrier instantiation in one program.
	warm := "scalar := Box(int){7, 8}; sink(scalar[0]); sink(scalar[true]); sink(forward(scalar)); sink(scalar.read());"
	for shape in shapes {
		for route in routes {
			for flow in flows {
				for scalar_first in ([2]bool{false, true}) {
					body := flow.body
					other, _ := strings.replace_all(shape.write, "left", "right", context.temp_allocator)
					for replacement in ([][2]string{{"$WRITE", shape.write}, {"$OTHER", other}, {"$USE", shape.use}}) {
						body, _ = strings.replace_all(body, replacement[0], replacement[1], context.temp_allocator)
					}
					source := prelude
					for replacement in ([][2]string{
						{"$RESULT", flow.result}, {"$TYPE", shape.type}, {"$SETUP", shape.setup}, {"$FIRST", shape.first}, {"$SECOND", shape.second},
						{"$TAKE", route.take}, {"$BODY", body}, {"$BEFORE", scalar_first ? warm : ""}, {"$AFTER", scalar_first ? "" : warm},
					}) {
						source, _ = strings.replace_all(source, replacement[0], replacement[1], context.temp_allocator)
					}
					p: Checked
					check_source(&p, source)
					if p.c.error_count == 0 {
						k := Checker{c = &p.c}
						check_pending_impl_instances(&k)
						analyze_program_provenance(&k)
					}
					label := fmt.tprintf("%s/%s/%s/scalar_first=%v", shape.name, route.name, flow.name, scalar_first)
					count := flow.rejected ? 1 : 0
					if !testing.expectf(t, p.c.error_count == count, "%s: expected %d errors, got %d", label, count, p.c.error_count) {
						report(&p.c)
					} else if flow.rejected {
						diagnostic := p.c.diagnostics[0]
						code := shape.name == "slice" ? "L0511" : "L0512"
						if flow.name == "escape" { code = "L0526" }
						testing.expectf(t, diagnostic.code == code && strings.contains(diagnostic.message, "`left`"),
						                "%s: expected %s naming left's borrow, got %s: %s", label, code, diagnostic.code, diagnostic.message)
					}
					destroy_checked(&p)
					free_all(context.temp_allocator)
				}
			}
		}
	}
}
