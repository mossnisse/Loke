package lokec

import "core:fmt"
import "core:mem/virtual"
import os2 "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// `check_source`, plus the bootstrap's bodies and entry validation.
@(private = "file")
check_for_emission :: proc(p: ^Checked, source: string, key := "", mode := Build_Mode.Exe) {
	parse_source(p, source)
	p.c.build_mode = mode
	p.pkg = new_package(&p.c, p.f.package_name, key)
	p.c.root_package = p.pkg
	add_package_file(&p.c, p.pkg, &p.f)
	k := Checker{c = &p.c}
	ensure_runtime_bootstrap(&k)
	rebuild_active_items(&p.c, package_of(&p.c, p.pkg))
	prepare_package(&k, p.pkg)
	for id in package_order(&p.c) {
		if id == p.pkg { continue }
		check_package_bodies(&k, id)
		check_pending_impl_instances(&k)
	}
	check_package_bodies(&k, p.pkg)
	check_pending_impl_instances(&k)
	// The production pipeline's own tail, so emission sees what the driver's does.
	finish_program_analysis(&k)
	if p.c.build_mode == .Exe && p.c.error_count == 0 { validate_executable(&p.c, p.pkg) }
}

@(private = "file")
expect_rejection :: proc(t: ^testing.T, c: ^Compiler, message: string, loc := #caller_location) {
	last := len(c.diagnostics) > 0 ? c.diagnostics[len(c.diagnostics) - 1].message : ""
	testing.expectf(t, c.error_count == 1 && strings.contains(last, message),
	                "expected only %q, got %d errors ending in %q", message, c.error_count, last, loc = loc)
}

@(test)
debug_defer_copies_bind_each_local_address :: proc(t: ^testing.T) {
	p: Checked
	check_for_emission(&p, `package main;
stop :: proc() {}
work :: proc(early: bool) {
    seed := 42;
    defer {
        deferred := seed;
        stop();
        assert(deferred == 42);
    }
    if (early) { return; }
}
main :: proc() { work(false); }
`)
	defer destroy_checked(&p)
	c := &p.c
	if !testing.expect(t, c.error_count == 0) { report(c); return }
	c.debug_info = true
	finalize_semantics(c)
	module, emitted := emit_llvm_module(c)
	if !testing.expect(t, emitted && c.error_count == 0) { report(c); return }
	start := strings.index(module, "define internal void @loke.p.work(")
	if !testing.expect(t, start >= 0) { return }
	body := module[start:]
	end := strings.index(body, "\n}\n")
	if !testing.expect(t, end >= 0) { return }
	body = body[:end]
	copies := 0
	for raw in strings.split_lines(body, context.temp_allocator) {
		line := strings.trim_space(raw)
		if !strings.has_prefix(line, "%deferred.") || !strings.contains(line, " = alloca ") { continue }
		address := line[:strings.index(line, " = ")]
		copies += 1
		testing.expectf(t, strings.contains(body, fmt.tprintf("@llvm.dbg.declare(metadata ptr %s,", address)),
		                "cleanup storage %s has no debug binding", address)
	}
	testing.expect(t, copies == 2, "the regression must cover both cleanup exits")
}

@(test)
debug_exports_preserve_literal_link_names :: proc(t: ^testing.T) {
	p: Checked
	check_for_emission(&p, `package main;
@(export, link_name = "payment$41")
answer :: proc "c" () -> i32 { return 7; }
@(export, link_name = "loke.p.payment$41")
prefixed :: proc "c" () -> i32 { return 8; }
main :: proc() { _ = answer(); _ = prefixed(); }
`)
	defer destroy_checked(&p)
	c := &p.c
	check_exports(c)
	if !testing.expect(t, c.error_count == 0) { report(c); return }
	c.debug_info = true
	finalize_semantics(c)
	module, emitted := emit_llvm_module(c)
	if !testing.expect(t, emitted && c.error_count == 0) { report(c); return }
	for name in ([]string{"payment$41", "loke.p.payment$41"}) {
		testing.expectf(t, strings.contains(module, fmt.tprintf(`!DISubprogram(name: "%s",`, name)),
		                "literal export %q was changed in debug metadata", name)
	}
}

@(test)
debug_wide_enums_expose_exact_storage :: proc(t: ^testing.T) {
	p: Checked
	check_for_emission(&p, `package main;
Wide :: enum u128 { Small = 1, Huge = 18446744073709551617 }
Negative :: enum i128 { Huge = -(1 << 100) }
main :: proc() {
    unsigned := Wide.Huge;
    signed := Negative.Huge;
    integer: u128 = 1 << 100;
}
`)
	defer destroy_checked(&p)
	c := &p.c
	if !testing.expect(t, c.error_count == 0) { report(c); return }
	c.debug_info = true
	finalize_semantics(c)
	module, emitted := emit_llvm_module(c)
	if !testing.expect(t, emitted && c.error_count == 0) { report(c); return }
	for name in ([]string{"Wide", "Negative", "u128"}) {
		testing.expectf(t, strings.contains(module,
		                fmt.tprintf(`!DICompositeType(tag: DW_TAG_structure_type, name: "%s", size: 128,`, name)),
		                "wide type %q has no exact storage description", name)
	}
	testing.expect(t, !strings.contains(module, `!DIEnumerator(name: "Huge",`),
	               "a wide enumerator can be saturated by CodeView")
	testing.expect(t, strings.contains(module, `name: "low", baseType: !`) &&
	               strings.contains(module, `name: "high", baseType: !`) &&
	               strings.contains(module, "size: 64, offset: 64)"), "wide storage has no two-word layout")
}

@(test)
checked_call_operations_are_cleared_by_syntax_cloning :: proc(t: ^testing.T) {
	p: Checked
	check_for_emission(&p, `package main;
Color :: enum { red, blue }
Value :: union { number: int }
identity :: proc(value: int) -> int { return value; }
main :: proc() {
    n := 7;
    text: string = "abc";
    ordinary := identity(value = n);
    converted := i32(n);
    wrapped: Value = .number(n);
    length := text.byte_len();
    color := Color.from_int(n);
    view: any_view = n;
    extracted := view.as(int);
}
`)
	defer destroy_checked(&p)
	c, f := &p.c, &p.f
	if !testing.expect(t, c.error_count == 0) { report(c); return }
	body := decl_proc(f.items[len(f.items) - 1].(^Decl)).body
	calls: [dynamic]^Expr_Call
	defer delete(calls)
	for statement in body.stmts {
		if declaration, ok := statement.(^Decl); ok {
			for value in declaration.values {
				if call, is_call := value.(^Expr_Call); is_call { append(&calls, call) }
			}
		}
	}
	if !testing.expect(t, len(calls) == 6) { return }
	_, ordinary := calls[0].operation.(Call_Procedure)
	_, conversion := calls[1].operation.(Call_Conversion)
	construction, wrapped := calls[2].operation.(Call_Union_Construct)
	text, text_call := calls[3].operation.(Call_Text)
	enum_conversion, enum_call := calls[4].operation.(Call_Enum_From_Int)
	extraction, extracted := calls[5].operation.(Call_Extract)
	testing.expect(t, ordinary && conversion && wrapped && text_call && enum_call && extracted)
	testing.expect(t, construction.index == 0 && !construction.clone)
	testing.expect(t, text.op == .Byte_Len && type_is_enum(c, enum_conversion.type))
	testing.expect(t, extraction.node != nil && extraction.node.type == calls[5].type)
	testing.expect(t, len(calls[0].bound_order) == 1 && calls[0].bound_order[0] == 0)
	for call in calls {
		clone := clone_expr(c, call).(^Expr_Call)
		testing.expect(t, clone.operation == nil && clone.bound == nil && clone.bound_order == nil,
		               "syntax cloning retained a checked call operation or argument binding")
		testing.expect(t, len(clone.args) == len(call.args))
	}
	finalize_semantics(c)
	_, emitted := emit_llvm_module(c)
	if !testing.expect(t, emitted && c.error_count == 0) { report(c); return }
	// Symbol resolution alone cannot stand in for an unchecked operation.
	calls[0].operation = nil
	module, unchecked := emit_llvm_module(c)
	testing.expect(t, !unchecked && module == "", "an unchecked call was emitted using its resolved symbol")
	expect_rejection(t, c, "an unchecked or compile-time call reached emission")
}

@(test)
composite_consumers_use_checked_field_indices :: proc(t: ^testing.T) {
	p: Checked
	check_for_emission(&p, `package main;
Pair :: struct { first, second: int }
value :: proc() -> int {
    number := 7;
    pair := Pair{second = number + 1, first = number};
    return pair.first * 10 + pair.second;
}
main :: proc() { assert(value() == 78); }
`)
	defer destroy_checked(&p)
	c, f := &p.c, &p.f
	if !testing.expect(t, c.error_count == 0) { report(c); return }
	value_decl := f.items[1].(^Decl)
	body := decl_proc(value_decl).body
	literal := body.stmts[1].(^Decl).values[0].(^Expr_Composite)
	if !testing.expect(t, len(literal.field_indices) == 2) { return }
	testing.expect(t, literal.field_indices[0] == 1 && literal.field_indices[1] == 0)
	cloned := clone_expr(c, literal).(^Expr_Composite)
	testing.expect(t, len(cloned.field_indices) == 0, "a syntax clone retained checked field indices")
	finalize_semantics(c)
	before, emitted := emit_llvm_module(c)
	if !testing.expect(t, emitted && c.error_count == 0) { report(c); return }

	// Swap the written keys; both consumers must keep the checked slots.
	literal.elements[0].key.(^Expr_Ident).name = "first"
	literal.elements[1].key.(^Expr_Ident).name = "second"
	call: Expr_Call
	call.type = TYPE_INT
	call.resolution = Resolution{kind = .Call, symbol = value_decl.symbols[0]}
	call.operation = Call_Procedure{}
	checker := Checker{c = c}
	value, evaluated := require_const(&checker, &call, "test result")
	testing.expect(t, evaluated && bi_eq_i64(c, value.integer, 78), "CTFE repeated field lookup")
	after, emitted_again := emit_llvm_module(c)
	if !testing.expect(t, emitted_again && c.error_count == 0 && before == after,
	                   "LLVM repeated field lookup") { report(c); return }
	literal.field_indices = nil
	module, missing := emit_llvm_module(c)
	testing.expect(t, !missing && module == "", "missing field indices did not reject the module")
	expect_rejection(t, c, "a struct literal element has no resolved field index")
}

@(test)
optional_extraction_uses_checked_variant_metadata :: proc(t: ^testing.T) {
	p: Checked
	check_for_emission(&p, `package main;
main :: proc() {
    view: any_view = 42;
    extracted := view.as(int);
}
`)
	defer destroy_checked(&p)
	c, f := &p.c, &p.f
	if !testing.expect(t, c.error_count == 0) { report(c); return }
	body := decl_proc(f.items[0].(^Decl)).body
	call := body.stmts[1].(^Decl).values[0].(^Expr_Call)
	extraction := call.operation.(Call_Extract).node
	if !testing.expect(t, extraction != nil) { return }
	finalize_semantics(c)
	// Only the extraction, since reflection tables do read variant names.
	previous := ""
	for pass in 0 ..< 2 {
		context.allocator = virtual.arena_allocator(&c.emission_arena)
		e := make_emitter(c)
		e.names[body.stmts[0].(^Decl).symbols[0]] = "%view"
		emit_expr(&e, call)
		ir := strings.to_string(e.b)
		if !testing.expect(t, !e.failed && c.error_count == 0) { report(c); return }
		if pass > 0 {
			testing.expect(t, ir == previous, "LLVM repeated the optional success variant lookup")
		}
		previous = ir
		info := type_of(c, extraction.type)
		info.variant_names[0], info.variant_names[1] = info.variant_names[1], info.variant_names[0]
	}
	type_of(c, extraction.type).failure_designated = false
	module, missing := emit_llvm_module(c)
	testing.expect(t, !missing && module == "", "missing failure metadata did not reject the module")
	expect_rejection(t, c, "an optional extraction has no checked failure variant")
}

@(test)
entry_emission_requires_validated_symbol :: proc(t: ^testing.T) {
	for scenario in ([]string{"lookup_removed", "missing_symbol", "missing_name", "object"}) {
		object := scenario == "object"
		p: Checked
		// A nonempty package key makes a hardcoded entry-name fallback observable.
		check_for_emission(&p, object ? "package utility; helper :: proc() { }" : "package main; main :: proc() { }",
		                   "entry_check", object ? .Obj : .Exe)
		defer destroy_checked(&p)
		c := &p.c
		finalize_semantics(c)
		before, emitted := emit_llvm_module(c)
		if !testing.expectf(t, emitted && c.error_count == 0, "%s setup failed", scenario) {
			report(c)
			continue
		}
		if object {
			testing.expect(t, c.entry_point == INVALID_SYMBOL && !strings.contains(before, "define i32 @wmain"),
			               "an object build required or emitted an entry point")
			continue
		}
		testing.expect(t, c.entry_point == p.f.items[0].(^Decl).symbols[0], "validation lost the entry symbol")
		switch scenario {
		case "lookup_removed":
			delete_key(&package_of(c, p.pkg).scope.names, symbol_of(c, c.entry_point).name)
		case "missing_symbol": c.entry_point = INVALID_SYMBOL
		case "missing_name": p.f.active_items = nil
		}
		after, emitted_again := emit_llvm_module(c)
		if scenario == "lookup_removed" {
			testing.expect(t, emitted_again && c.error_count == 0 && before == after,
			               "LLVM repeated the entry lookup or used a hardcoded name")
		} else {
			testing.expect(t, !emitted_again && after == "")
			expect_rejection(t, c, scenario == "missing_name" ? "entry procedure has no emitted name" : "no validated entry procedure")
		}
	}
}

@(test)
coercion_emission_preserves_checked_annotations :: proc(t: ^testing.T) {
	p: Checked
	check_for_emission(&p, `package main;
main :: proc() {
    number := 7;
    text: string = "hello";
    erased_place: any_view = number;
    erased_temporary: any_view = number + 1;
    view: string_view = text;
    vector: Simd(int, 4) = -number;
}
`)
	defer destroy_checked(&p)
	c, f := &p.c, &p.f
	if !testing.expect(t, c.error_count == 0) { report(c); return }
	finalize_semantics(c)

	body := decl_proc(f.items[0].(^Decl)).body
	number := body.stmts[0].(^Decl).symbols[0]
	text := body.stmts[1].(^Decl).symbols[0]
	sources := [4]Type_Id{TYPE_INT, TYPE_INT, TYPE_STRING, TYPE_INT}
	// design.md "Integer overflow": signed arithmetic is the checked intrinsic.
	operations := [4]string{"load i64", "sadd.with.overflow.i64", "load " + STRING_TYPE, "ssub.with.overflow.i64"}
	expressions: [4]Expr
	saved: [4]Expr_Base
	for index in 0 ..< len(expressions) {
		expr := body.stmts[index + 2].(^Decl).values[0]
		expressions[index] = expr
		saved[index] = expr_base(expr)^
	}
	testing.expect(t, saved[0].erased_from == TYPE_INT && saved[0].addressable)
	testing.expect(t, saved[1].erased_from == TYPE_INT && !saved[1].addressable)
	testing.expect(t, saved[2].view_from == TYPE_STRING && saved[3].splat_from == TYPE_INT)

	// A source-type request skips only this node's conversion.
	for expr, index in expressions {
		context.allocator = virtual.arena_allocator(&c.emission_arena)
		e := make_emitter(c)
		e.names[number] = "%number"
		e.names[text] = "%text"
		emit_expr_at(&e, expr, sources[index])
		ir := strings.to_string(e.b)
		testing.expectf(t, !e.failed && strings.contains(ir, operations[index]),
		                "source emission used the converted type:\n%s", ir)
		// The overflow check reads its `{ i64, i1 }` pair; no converted view is read.
		testing.expect(t, !strings.contains(ir, "insertvalue") &&
		               !strings.contains(ir, "extractvalue %") && !strings.contains(ir, "shufflevector"),
		               "source emission reapplied the node's conversion")
	}

	previous := ""
	for pass in 0 ..< 2 {
		module, emitted := emit_llvm_module(c)
		if !testing.expect(t, emitted && c.error_count == 0) { report(c); return }
		if pass > 0 { testing.expect(t, module == previous, "repeated emission changed the LLVM module") }
		previous = module
		for expr, index in expressions {
			base := expr_base(expr)
			before := saved[index]
			testing.expect(t, base.type == before.type && base.erased_from == before.erased_from &&
			               base.view_from == before.view_from && base.splat_from == before.splat_from,
			               "emission changed checker annotations")
		}
	}
}

@(test)
unreferenced_generic_templates_are_not_emitted :: proc(t: ^testing.T) {
	p: Checked
	check_for_emission(&p, `package main;
unused :: proc(value: $T) -> T { return value; }
main :: proc() { }
`)
	defer destroy_checked(&p)
	c := &p.c
	if !testing.expect(t, c.error_count == 0) { report(c); return }
	// A template whose signature was never forced is still recognized by syntax.
	for symbol in c.symbols {
		if symbol.kind == .Proc && identifier_text(c, symbol.name) == "unused" {
			symbol.generic = false
		}
	}
	finalize_semantics(c)
	_, valid := emit_llvm_module(c)
	if !testing.expect(t, valid && c.error_count == 0, "an unreferenced generic template reached LLVM emission") { report(c) }
}

@(test)
maps_declared_only_in_fields_have_key_policies :: proc(t: ^testing.T) {
	p: Checked
	check_for_emission(&p, `package main;
Key :: struct { id: int }
impl Key {
    hash :: proc(self, seed: uint) -> uint { return seed; }
    equal :: operator(==) proc(a, b: Key) -> bool { return a.id == b.id; }
}
Grid :: struct { entries: map[string]f32, nested: [1]map[Key]int, next: Option(^Grid) }
main :: proc() {
    g: Grid = {};
    p := g.entries.find("a");
    value := g.entries.lookup_value("a");
    g.nested[0][{1}] = 7;
    n := g.nested[0].lookup_value(key = {1});
}
`)
	defer destroy_checked(&p)
	c := &p.c
	if !testing.expect(t, c.error_count == 0) { report(c); return }
	finalize_semantics(c)
	_, valid := emit_llvm_module(c)
	if !testing.expect(t, valid && c.error_count == 0, "field-only map types must reach emission with resolved key policies") { report(c) }
}

@(test)
unregistered_typeid_is_a_backend_contract_error :: proc(t: ^testing.T) {
	p: Checked
	check_for_emission(&p, "package main; main :: proc() { zero: typeid; id := typeid_of(int); }")
	defer destroy_checked(&p)
	c := &p.c
	finalize_semantics(c)
	_, valid := emit_llvm_module(c)
	testing.expect(t, valid && c.error_count == 0, "registered and nil typeids must both emit")
	delete_key(&c.typeid_values, TYPE_INT)
	module, missing := emit_llvm_module(c)
	testing.expect(t, !missing && module == "", "a missing dependency silently became the nil typeid")
	expect_rejection(t, c, "typeid registry is incomplete")
}

@(test)
emission_rejects_incomplete_registries :: proc(t: ^testing.T) {
	cases := [][2]string{
		{"unfrozen", "typeids must be frozen"},
		{"speculative", "during speculative checking"},
		{"typeid", "typeid registry is incomplete"},
		{"typeid_range", "no unique frozen typeid"},
		{"map", "map key operation was not resolved"},
		{"order", "ordering operation has no checked procedure"},
		{"formatter", "formatter has no checked procedure"},
		{"instance", "generic body is missing from its package"},
		{"witness", "witness has no concrete type"},
		{"constant", "materialized constant has no registered definition"},
		{"lifecycle_unready", "must be finalized before emission"},
		{"lifecycle_missing", "no finalized lifecycle operations"},
		{"lifecycle_incomplete", "no finalized lifecycle operations"},
		{"lifecycle_hook", "lifecycle hook has no checked procedure"},
		{"lifecycle_hook_owner", "lifecycle hook has no checked procedure"},
		{"held", "diagnostics are still held aside"},
		{"unanalyzed", "whole-program analyses have not completed"},
		{"formatters", "formatter discovery has not completed"},
		{"carrier", "carrier type has no installed fields"},
	}
	for entry in cases {
		broken, message := entry[0], entry[1]
		c: Compiler
		c.build_mode = .Obj
		init_semantic_stores(&c)
		request_typeid(&c, TYPE_INT)
		c.program_analyzed = true
		finalize_semantics(&c)
		switch broken {
		case "unfrozen": c.typeid_frozen = false
		case "speculative": c.speculation_depth = 1
		case "typeid": delete_key(&c.typeid_values, TYPE_INT)
		case "typeid_range": c.typeid_values[TYPE_INT] = 2
		case "map":
			map_type := map_of(&c, TYPE_INT, TYPE_INT)
			type_of(&c, map_type).contributed += {.Container}
		case "order":
			c.order_policies[TYPE_INT] = Order_Policy{kind = .Inherent, less = Symbol_Id(len(c.symbols) + 1)}
		case "formatter":
			c.formatters[TYPE_INT] = new(Witness, c.semantic_allocator)
		case "instance":
			instance := new(Instance, c.semantic_allocator)
			instance.body_checked = true
			c.procedure_instances[Symbol_Id(1)] = instance
		case "witness": append(&c.witness_order, new(Witness, c.semantic_allocator))
		case "constant": append(&c.materialized_order, new(Materialized, c.semantic_allocator))
		case "lifecycle_unready": c.lifecycle_operations_ready = false
		case "lifecycle_missing": delete_key(&c.lifecycle_operations, TYPE_INT)
		case "lifecycle_incomplete":
			operations := c.lifecycle_operations[TYPE_INT]
			operations.state = .Checking
			c.lifecycle_operations[TYPE_INT] = operations
		case "lifecycle_hook":
			operations := c.lifecycle_operations[TYPE_INT]
			operations.custom_drop = Symbol_Id(len(c.symbols) + 1)
			c.lifecycle_operations[TYPE_INT] = operations
		case "lifecycle_hook_owner":
			// Emittable, but owned by another type.
			operations := c.lifecycle_operations[TYPE_INT]
			operations.custom_drop = new_symbol(&c, Symbol{kind = .Proc, is_foreign = true, proc_type = TYPE_INT, owner_type = TYPE_BOOL})
			c.lifecycle_operations[TYPE_INT] = operations
		case "held":
			// Out of `error_count`, so only the held list shows it.
			append(&c.held_diagnostics, Diagnostic{severity = .Error, code = "L0000"})
		case "unanalyzed": c.program_analyzed = false
		case "formatters": c.formatters_ready = false
		case "carrier": type_of(&c, TYPE_ANY_VIEW).fields = nil
		}
		testing.expectf(t, !validate_emission_dependencies(&c), "%s registry was accepted at the emission boundary", broken)
		expect_rejection(t, &c, message)
		destroy_compilation(&c)
	}
}

@(test)
frozen_typeids_reject_new_dependencies :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)
	init_semantic_stores(&c)
	request_typeid(&c, TYPE_INT)
	freeze_typeids(&c)
	request_typeid(&c, TYPE_INT) // Reusing an existing dependency remains legal.
	testing.expect(t, c.error_count == 0)
	request_typeid(&c, TYPE_BOOL)
	testing.expect(t, c.error_count == 1 && !c.typeid_requested[TYPE_BOOL] && len(c.typeid_order) == 1,
	               "late registration mutated the frozen type set")
}

@(test)
map_consumers_use_the_checked_operation_ids :: proc(t: ^testing.T) {
	p: Checked
	check_for_emission(&p, `package main;
Key :: struct { id, annotation: int }
impl Key {
    hash :: proc(self, seed: uint) -> uint { return seed; }
    equal :: operator(==) proc(a, b: Key) -> bool { return a.id == b.id; }
}
lookup :: proc() -> int {
    m := map[Key]int{Key{1, 10} = 7};
    return m[Key{1, 20}];
}
main :: proc() { assert(lookup() == 7); }
`)
	defer destroy_checked(&p)
	c := &p.c
	if !testing.expect(t, c.error_count == 0) { report(c); return }
	for key, policy in c.map_key_policies {
		if !testing.expect(t, policy.kind == .Inherent) { return }
		// CTFE and LLVM must use the checked IDs, not a member lookup.
		members := make([dynamic]Symbol_Id, c.semantic_allocator)
		for member in type_of(c, key).members {
			if member != policy.hash && member != policy.equal { append(&members, member) }
		}
		type_of(c, key).members = members[:]
	}
	lookup: Symbol_Id
	for symbol, index in c.symbols {
		if symbol.kind == .Proc && identifier_text(c, symbol.name) == "lookup" {
			lookup = Symbol_Id(index)
		}
	}
	call: Expr_Call
	call.type = TYPE_INT
	call.resolution = Resolution{kind = .Call, symbol = lookup}
	call.operation = Call_Procedure{}
	checker := Checker{c = c}
	value, evaluated := require_const(&checker, &call, "test result")
	testing.expect(t, evaluated && bi_eq_i64(c, value.integer, 7), "CTFE repeated member lookup")
	finalize_semantics(c)
	_, emitted := emit_llvm_module(c)
	if !testing.expect(t, emitted && c.error_count == 0, "LLVM repeated member lookup") { report(c) }
}

// Failure cleanup must not emit a separate copy of every earlier array part.
@(test)
fixed_array_clone_ir_grows_linearly :: proc(t: ^testing.T) {
	sizes: [2]int
	counts := [2]int{128, 256}
	for count, index in counts {
		p: Checked
		source, _ := strings.replace_all(`package main;
Value :: struct { id: int }
impl Value {
    copy_owned :: hook(copy) proc(self, allocator: Allocator) -> Result(Value, Allocator_Error) {
        return .ok(Value{self.id});
    }
    release :: hook(drop) proc(self: inout Value) { self.id = 0; }
}
main :: proc() { items := [ARRAY_COUNT]Value{Value{1}}; }
`, "ARRAY_COUNT", fmt.aprintf("%d", count, allocator = context.temp_allocator), context.temp_allocator)
		check_for_emission(&p, source)
		defer destroy_checked(&p)
		if !testing.expect(t, p.c.error_count == 0) { report(&p.c); return }
		finalize_semantics(&p.c)
		module, emitted := emit_llvm_module(&p.c)
		if !testing.expect(t, emitted && p.c.error_count == 0) { report(&p.c); return }
		sizes[index] = len(module)
	}
	testing.expectf(t, sizes[1] < 3 * sizes[0], "doubling an array grew its IR from %d to %d bytes", sizes[0], sizes[1])
}

@(test)
lifecycle_consumers_use_finalized_operations :: proc(t: ^testing.T) {
	p: Checked
	check_for_emission(&p, `package main;
Resource :: struct { value: int }
impl Resource {
    copy_owned :: hook(copy) proc(self, allocator: Allocator) -> Result(Resource, Allocator_Error) {
        return .ok(Resource{self.value + 1});
    }
    release :: hook(drop) proc(self: inout Resource) { self.value = 0; }
}
Nested :: struct { parts: [2]Resource, empty: [0]Resource, text: string }
Empty :: struct { parts: [0]Resource }
Shape :: union { two: int, one: Resource }
main :: proc() {
    x: Nested = {};
    y := x.clone();
    z: Empty = {};
    w := z.clone();
    s: Shape = .one(Resource{5});
    u := s.clone();
    keys: map[string]int = {};
    keys["one"] = 1;
}
`)
	defer destroy_checked(&p)
	c := &p.c
	freeze_typeids(c)
	types_before, symbols_before, procs_before := len(c.types), len(c.symbols), len(c.synth_procs)
	if !testing.expect(t, finalize_lifecycle_operations(c)) { report(c); return }
	testing.expect(t, len(c.types) == types_before && len(c.symbols) == symbols_before && len(c.synth_procs) == procs_before,
	               "finalizing lifecycle facts created semantic dependencies")
	for index in 1 ..< len(c.types) {
		type := Type_Id(index)
		operations, resolved := resolved_lifecycle_operations(c, type)
		testing.expect(t, resolved && operations.managed == type_is_managed(c, type) &&
		               operations.clone_fallible == type_clone_is_fallible(c, type) &&
		               operations.clone_disabled == type_clone_disabled(c, type),
		               "the snapshot changed lifecycle semantics")
	}
	finalize_semantics(c)
	before, emitted := emit_llvm_module(c)
	if !testing.expect(t, emitted && c.error_count == 0) { report(c); return }
	// Without the lazy lifecycle sources the IR must not change.
	for info in c.types {
		members := make([dynamic]Symbol_Id, c.semantic_allocator)
		for member in info.members {
			symbol := symbol_of(c, member)
			if symbol.synth != .Clone && symbol.synth != .Try_Clone && symbol.hook != .Copy && symbol.hook != .Drop {
				append(&members, member)
			}
		}
		info.members = members[:]
	}
	clear(&c.lifecycles)
	after, emitted_again := emit_llvm_module(c)
	testing.expect(t, emitted_again && c.error_count == 0 && before == after,
	               "LLVM repeated lifecycle member lookup or classification")
	testing.expect(t, len(c.lifecycles) == 0, "LLVM repopulated the checker's lifecycle cache")
}

@(test)
lifecycle_copy_dependencies_are_closed :: proc(t: ^testing.T) {
	cases := [][2]string{
		{"missing_operation", "no recorded operation"},
		{"wrong_operation", "copy operation has no registered procedure"},
		{"missing_body", "copy operation has no registered procedure"},
		{"late_contribution", "requested after finalization"},
	}
	for entry in cases {
		broken := entry[0]
		p: Checked
		check_for_emission(&p, "package main; Record :: struct { value: int } main :: proc() { x: Record = {}; y := x.clone(); }")
		defer destroy_checked(&p)
		c := &p.c
		finalize_semantics(c)
		if !testing.expect(t, validate_emission_dependencies(c) && c.error_count == 0) { report(c); return }
		target: Type_Id
		for type, operations in c.lifecycle_operations {
			if operations.clone != INVALID_SYMBOL && underlying_info(c, type).kind == .Struct {
				target = type
				break
			}
		}
		if !testing.expect(t, target != INVALID_TYPE, "Record has no clone operation") { return }
		switch broken {
		case "missing_operation", "wrong_operation":
			operations := c.lifecycle_operations[target]
			operations.try_clone = broken == "missing_operation" ? INVALID_SYMBOL : operations.clone
			c.lifecycle_operations[target] = operations
		case "missing_body": clear(&c.synth_procs)
		case "late_contribution":
			// Clearing the marker models a late request; it must not change state.
			info := type_of(c, target)
			info.contributed -= {.Lifecycle, .Lifecycle_Enrolled}
			symbols_before, procs_before, members_before := len(c.symbols), len(c.synth_procs), len(info.members)
			checker := Checker{c = c}
			contribute_lifecycle_members(&checker, target)
			testing.expect(t, .Lifecycle not_in info.contributed && len(c.symbols) == symbols_before &&
			               len(c.synth_procs) == procs_before && len(info.members) == members_before,
			               "a late lifecycle request mutated semantic state")
		}
		module, emitted := emit_llvm_module(c)
		testing.expectf(t, !emitted && module == "", "%s lifecycle dependency was accepted", broken)
		expect_rejection(t, c, entry[1])
	}
}

@(test)
converted_string_temporary_is_cleaned_up :: proc(t: ^testing.T) {
	p: Checked
	check_for_emission(&p, `package main;
make_key :: proc() -> string { return "x" + ""; }
main :: proc() {
    m: map[string]int = {};
    m["x"] = 1;
    _ = m.find(make_key());
}
`)
	defer destroy_checked(&p)
	c := &p.c
	if !testing.expect(t, c.error_count == 0) { report(c); return }
	finalize_semantics(c)
	module, emitted := emit_llvm_module(c)
	if !testing.expect(t, emitted && c.error_count == 0) { report(c); return }
	main_at := strings.index(module, "define internal void @loke.p.main()")
	if !testing.expect(t, main_at >= 0) { return }
	main_tail := module[main_at:]
	main_end := strings.index(main_tail, "\n}\n")
	if !testing.expect(t, main_end >= 0) { return }
	main_ir := main_tail[:main_end]
	made := strings.index(main_ir, "call %loke.string @loke.p.make_key()")
	if !testing.expect(t, made >= 0) { return }
	after_make := main_ir[made:]
	lookup := strings.index(after_make, ".find(")
	release := strings.index(after_make, "call void @loke_rt_v1_string_release")
	testing.expectf(t, lookup >= 0 && release > lookup, "converted query key was not released:\n%s", main_ir)
}

@(test)
artifact_extension_ignores_dotted_parent_directories :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	actual := replace_ext(`C:\release.v2\program`, ".ll")
	testing.expectf(t, actual == `C:\release.v2\program.ll`, "unexpected artifact path %q", actual)
}

@(test)
assembly_temporaries_include_the_source_identity :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	first := assembly_object_path(`C:\one\helper.asm`, `C:\out\program.exe`)
	second := assembly_object_path(`C:\two\helper.asm`, `C:\out\program.exe`)
	again := assembly_object_path(`c:\ONE\helper.asm`, `C:\out\program.exe`)
	testing.expectf(t, first != second, "different assembly sources collide at %q", first)
	testing.expectf(t, first == again, "one Windows source path produced %q and %q", first, again)
}

// Fixed-size allocas move to the entry block; runtime-sized ones stay put.
@(test)
fixed_allocas_reach_the_entry_block :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body :=
		"define void @first(i64 %n) {\n" +
		"entry:\n" +
		"  br label %loop\n" +
		"loop:\n" +
		"  %pack = alloca i8, i64 %n\n" +
		"  br label %loop\n" +
		"}\n"
	expected :=
		"define void @first(i64 %n) {\n" +
		"entry:\n" +
		"  %pair = alloca { i64, i64 }\n" +
		"  %byte = alloca i8\n" +
		"  br label %loop\n" +
		"loop:\n" +
		"  %pack = alloca i8, i64 %n\n" +
		"  br label %loop\n" +
		"}\n"
	c := test_compiler("package main;")
	defer destroy_compilation(&c)
	e := make_emitter(&c)
	actual := splice_prologue(&e, body, {"  %pair = alloca { i64, i64 }", "  %byte = alloca i8"})
	testing.expectf(t, actual == expected, "unexpected prologue splice:\n%s", actual)

	testing.expect(t, splice_prologue(&e, body, nil) == body)
	testing.expect(t, !e.failed && c.error_count == 0, "an ordinary splice reported a failure")

	// No entry block leaves the text alone but fails the module.
	orphan := "declare void @outside()\n"
	testing.expect(t, splice_prologue(&e, orphan, {"  %x = alloca i8"}) == orphan)
	testing.expect(t, e.failed && c.error_count == 1, "a dropped prologue was not reported")
}

@(test)
toolchain_discovery_picks_the_newest_complete_version :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := fmt.tprintf("loke-sdk-test-%d", os2.get_pid())
	defer os2.remove_all(root)
	// Every version holds `ucrt` except the newest, which must be skipped.
	for version in ([]string{"10.0.19041.0", "10.0.22621.0", "10.0.26100.0"}) {
		dir := filepath.join({root, version})
		os2.make_directory_all(version == "10.0.26100.0" ? dir : filepath.join({dir, "ucrt"}))
	}
	found := newest_containing({filepath.join({root, "*"})}, "ucrt")
	testing.expectf(t, filepath.base(found) == "10.0.22621.0", "picked %q", found)
}

// Nesting just under the limit goes through checking and emission. The limit
// was once 128, so a 140-term `||` chain was rejected; a nested call costs two
// levels, one for the call and one for its argument.
@(test)
nesting_below_the_limit_is_compiled :: proc(t: ^testing.T) {
	text := strings.concatenate(
		{
			"package main;\nid :: proc(v: int) -> int { return v; }\nmain :: proc() {\n\tx := 3;\n\tb := x > 0",
			strings.repeat(" || x > 1", 2000, context.temp_allocator),
			";\n\ty := ",
			strings.repeat("id(", 1000, context.temp_allocator),
			"x",
			strings.repeat(")", 1000, context.temp_allocator),
			";\n}\n",
		},
		context.temp_allocator,
	)
	p: Checked
	check_for_emission(&p, text)
	defer destroy_checked(&p)
	if !testing.expectf(t, p.c.error_count == 0, "expected no diagnostics, got %d", p.c.error_count) {
		return
	}
	finalize_semantics(&p.c)
	_, emitted := emit_llvm_module(&p.c)
	testing.expect(t, emitted, "deep nesting did not emit")
}

@(test)
debug_else_if_conditions_keep_their_source_locations :: proc(t: ^testing.T) {
	p: Checked
	check_for_emission(&p, `package main;
choose :: proc(x: int) -> int {
    if (x == 1) {
        return 10;
    }
    else if (
        y := x;
        y == 2
    ) {
        return 20;
    }
    else {
        return 30;
    }
}
main :: proc() { assert(choose(2) == 20); }
`)
	defer destroy_checked(&p)
	c := &p.c
	if !testing.expect(t, c.error_count == 0) { report(c); return }
	c.debug_info = true
	finalize_semantics(c)
	module, emitted := emit_llvm_module(c)
	if !testing.expect(t, emitted && c.error_count == 0) { report(c); return }
	start := strings.index(module, "define internal i64 @loke.p.choose(")
	if !testing.expect(t, start >= 0) { return }
	tail := module[start:]
	end := strings.index(tail, "\n}\n")
	if !testing.expect(t, end >= 0) { return }
	expected := [2]int{3, 8}
	conditions := 0
	for line in strings.split_lines(tail[:end], context.temp_allocator) {
		if !strings.contains(line, " = icmp eq i64 ") { continue }
		if !testing.expect(t, conditions < len(expected)) { return }
		_, _, location := strings.partition(line, ", !dbg ")
		definition := fmt.tprintf("\n%s = !DILocation(line: %d,", location, expected[conditions])
		testing.expectf(t, location != "" && strings.contains(module, definition),
		                "condition %d has no location on source line %d:\n%s", conditions + 1, expected[conditions], line)
		conditions += 1
	}
	testing.expectf(t, conditions == len(expected), "expected two conditions, got %d", conditions)
}
