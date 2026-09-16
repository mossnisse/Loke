package lokec

import "core:strings"
import "core:testing"

// Emission consumes a fully checked program. The general front-end helper only
// checks the hand-built package's bodies because most semantic tests need the
// bootstrap's signatures, not its implementation. LLVM tests need both.
@(private = "file")
check_emission_package :: proc(c: ^Compiler, pkg_id: Package_Id) {
	k := Checker{c = c}
	ensure_runtime_bootstrap(&k)
	rebuild_active_items(c, package_of(c, pkg_id))
	prepare_package(&k, pkg_id)
	for id in package_order(c) {
		if id == pkg_id { continue }
		check_package_bodies(&k, id)
		check_pending_impl_instances(&k)
	}
	check_package_bodies(&k, pkg_id)
	check_pending_impl_instances(&k)
	if c.build_mode == .Exe && c.error_count == 0 { validate_executable(c, pkg_id) }
}

@(test)
checked_call_operations_are_cleared_by_syntax_cloning :: proc(t: ^testing.T) {
	c := test_compiler(`package main;
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
	defer destroy_compilation(&c)
	tokens := lex(&c, 0)
	defer delete(tokens)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)
	id := new_package(&c, f.package_name)
	c.root_package = id
	add_package_file(&c, id, &f)
	check_emission_package(&c, id)
	if !testing.expect(t, c.error_count == 0) { report(&c); return }
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
	testing.expect(t, text.op == .Byte_Len && type_is_enum(&c, enum_conversion.type))
	testing.expect(t, extraction.node != nil && extraction.node.type == calls[5].type)
	testing.expect(t, len(calls[0].bound_order) == 1 && calls[0].bound_order[0] == 0)
	for call in calls {
		clone := clone_expr(&c, call).(^Expr_Call)
		testing.expect(t, clone.operation == nil && clone.bound == nil && clone.bound_order == nil,
		               "syntax cloning retained a checked call operation or argument binding")
		testing.expect(t, len(clone.args) == len(call.args))
	}
	finalize_semantics(&c)
	_, emitted := emit_llvm_module(&c)
	if !testing.expect(t, emitted && c.error_count == 0) { report(&c); return }
	// Symbol resolution alone cannot stand in for an unchecked operation.
	calls[0].operation = nil
	module, unchecked := emit_llvm_module(&c)
	testing.expect(t, !unchecked && module == "" && c.error_count > 0,
	               "an unchecked call was emitted using its resolved symbol")
}

@(test)
composite_consumers_use_checked_field_indices :: proc(t: ^testing.T) {
	c := test_compiler(`package main;
Pair :: struct { first, second: int }
value :: proc() -> int {
    number := 7;
    pair := Pair{second = number + 1, first = number};
    return pair.first * 10 + pair.second;
}
main :: proc() { assert(value() == 78); }
`)
	defer destroy_compilation(&c)
	tokens := lex(&c, 0)
	defer delete(tokens)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)
	id := new_package(&c, f.package_name)
	c.root_package = id
	add_package_file(&c, id, &f)
	check_emission_package(&c, id)
	if !testing.expect(t, c.error_count == 0) { report(&c); return }
	value_decl := f.items[1].(^Decl)
	body := decl_proc(value_decl).body
	literal := body.stmts[1].(^Decl).values[0].(^Expr_Composite)
	if !testing.expect(t, len(literal.field_indices) == 2) { return }
	testing.expect(t, literal.field_indices[0] == 1 && literal.field_indices[1] == 0)
	cloned := clone_expr(&c, literal).(^Expr_Composite)
	testing.expect(t, len(cloned.field_indices) == 0, "a syntax clone retained checked field indices")
	finalize_semantics(&c)
	before, emitted := emit_llvm_module(&c)
	if !testing.expect(t, emitted && c.error_count == 0) { report(&c); return }

	// Change only the written keys after checking. Both consumers must still
	// use the original field slots, in the original evaluation order.
	literal.elements[0].key.(^Expr_Ident).name = "first"
	literal.elements[1].key.(^Expr_Ident).name = "second"
	call: Expr_Call
	call.type = TYPE_INT
	call.resolution = Resolution{kind = .Call, symbol = value_decl.symbols[0]}
	call.operation = Call_Procedure{}
	checker := Checker{c = &c}
	value, evaluated := require_const(&checker, &call, "test result")
	testing.expect(t, evaluated && bi_eq_i64(&c, value.integer, 78), "CTFE repeated field lookup")
	after, emitted_again := emit_llvm_module(&c)
	if !testing.expect(t, emitted_again && c.error_count == 0 && before == after,
	                   "LLVM repeated field lookup") { report(&c); return }
	literal.field_indices = nil
	module, missing := emit_llvm_module(&c)
	testing.expect(t, !missing && module == "" && c.error_count == 1,
	               "missing field indices did not reject the module")
}

@(test)
optional_extraction_uses_checked_variant_metadata :: proc(t: ^testing.T) {
	c := test_compiler(`package main;
main :: proc() {
    view: any_view = 42;
    extracted := view.as(int);
}
`)
	defer destroy_compilation(&c)
	tokens := lex(&c, 0)
	defer delete(tokens)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)
	id := new_package(&c, f.package_name)
	c.root_package = id
	add_package_file(&c, id, &f)
	check_emission_package(&c, id)
	if !testing.expect(t, c.error_count == 0) { report(&c); return }
	body := decl_proc(f.items[0].(^Decl)).body
	call := body.stmts[1].(^Decl).values[0].(^Expr_Call)
	extraction := call.operation.(Call_Extract).node
	if !testing.expect(t, extraction != nil) { return }
	finalize_semantics(&c)
	// Compare extraction instructions, since reflection tables legitimately
	// retain variant names even though this lowering no longer reads them.
	previous := ""
	for pass in 0 ..< 2 {
		// Emitter storage normally lives in the emission arena.
		context.allocator = context.temp_allocator
		e := make_emitter(&c)
		e.names[body.stmts[0].(^Decl).symbols[0]] = "%view"
		emit_expr(&e, call)
		ir := strings.to_string(e.b)
		if !testing.expect(t, !e.failed && c.error_count == 0) { report(&c); return }
		if pass > 0 {
			testing.expect(t, ir == previous, "LLVM repeated the optional success variant lookup")
		}
		previous = ir
		info := type_of(&c, extraction.type)
		info.variant_names[0], info.variant_names[1] = info.variant_names[1], info.variant_names[0]
	}
	type_of(&c, extraction.type).failure_designated = false
	module, missing := emit_llvm_module(&c)
	testing.expect(t, !missing && module == "" && c.error_count == 1,
	               "missing failure metadata did not reject the module")
}

@(test)
entry_emission_requires_validated_symbol :: proc(t: ^testing.T) {
	for scenario in ([]string{"lookup_removed", "missing_symbol", "missing_name", "object"}) {
		text := scenario == "object" ? "package utility; helper :: proc() { }" : "package main; main :: proc() { }"
		c := test_compiler(text)
		if scenario == "object" { c.build_mode = .Obj }
		tokens := lex(&c, 0)
		f := parse(&c, 0, tokens)
		// A nonempty package key makes a hardcoded entry-name fallback observable.
		id := new_package(&c, f.package_name, "entry_check")
		c.root_package = id
		add_package_file(&c, id, &f)
		check_emission_package(&c, id)
		finalize_semantics(&c)
		before, emitted := emit_llvm_module(&c)
		if !testing.expectf(t, emitted && c.error_count == 0, "%s setup failed", scenario) {
			report(&c)
		} else if scenario == "object" {
			testing.expect(t, c.entry_point == INVALID_SYMBOL && !strings.contains(before, "define i32 @wmain"),
			               "an object build required or emitted an entry point")
		} else {
			testing.expect(t, c.entry_point == f.items[0].(^Decl).symbols[0], "validation lost the entry symbol")
			switch scenario {
			case "lookup_removed":
				delete_key(&package_of(&c, id).scope.names, symbol_of(&c, c.entry_point).name)
			case "missing_symbol": c.entry_point = INVALID_SYMBOL
			case "missing_name": f.active_items = nil
			}
			after, emitted_again := emit_llvm_module(&c)
			if scenario == "lookup_removed" {
				testing.expect(t, emitted_again && c.error_count == 0 && before == after,
				               "LLVM repeated the entry lookup or used a hardcoded name")
			} else {
				testing.expectf(t, !emitted_again && after == "" && c.error_count == 1,
				                "%s did not reject the module", scenario)
			}
		}
		destroy_ast(&f)
		delete(tokens)
		destroy_compilation(&c)
	}
}

@(test)
coercion_emission_preserves_checked_annotations :: proc(t: ^testing.T) {
	c := test_compiler(`package main;
main :: proc() {
    number := 7;
    text: string = "hello";
    erased_place: any_view = number;
    erased_temporary: any_view = number + 1;
    view: string_view = text;
    vector: Simd(int, 4) = -number;
}
`)
	defer destroy_compilation(&c)
	tokens := lex(&c, 0)
	defer delete(tokens)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)
	id := new_package(&c, f.package_name)
	c.root_package = id
	add_package_file(&c, id, &f)
	check_emission_package(&c, id)
	if !testing.expect(t, c.error_count == 0) { report(&c); return }
	finalize_semantics(&c)

	body := decl_proc(f.items[0].(^Decl)).body
	number := body.stmts[0].(^Decl).symbols[0]
	text := body.stmts[1].(^Decl).symbols[0]
	sources := [4]Type_Id{TYPE_INT, TYPE_INT, TYPE_STRING, TYPE_INT}
	operations := [4]string{"load i64", "add i64", "load " + STRING_TYPE, "sub i64"}
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

	// A source-type request must skip this node's conversion without clearing
	// its annotations, while its children still use their checked types.
	for expr, index in expressions {
		// Emitter storage normally lives in the emission arena.
		context.allocator = context.temp_allocator
		e := make_emitter(&c)
		e.names[number] = "%number"
		e.names[text] = "%text"
		emit_expr_at(&e, expr, sources[index])
		ir := strings.to_string(e.b)
		testing.expectf(t, !e.failed && strings.contains(ir, operations[index]),
		                "source emission used the converted type:\n%s", ir)
		testing.expect(t, !strings.contains(ir, "insertvalue") &&
		               !strings.contains(ir, "extractvalue") && !strings.contains(ir, "shufflevector"),
		               "source emission reapplied the node's conversion")
	}

	// Independent emitters must see the same checked program and produce the
	// same module after both source-type and ordinary conversion emission.
	previous := ""
	for pass in 0 ..< 2 {
		module, emitted := emit_llvm_module(&c)
		if !testing.expect(t, emitted && c.error_count == 0) { report(&c); return }
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
	c := test_compiler(`package main;
unused :: proc(value: $T) -> T { return value; }
main :: proc() { }
`)
	defer destroy_compilation(&c)
	tokens := lex(&c, 0)
	defer delete(tokens)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)
	id := new_package(&c, f.package_name)
	c.root_package = id
	add_package_file(&c, id, &f)
	check_emission_package(&c, id)
	if !testing.expect(t, c.error_count == 0) { report(&c); return }
	// Model a declaration whose signature was never forced by package checking:
	// the emitter must still recognize the template from its syntax.
	for &symbol in c.symbols {
		if symbol.kind == .Proc && identifier_text(&c, symbol.name) == "unused" {
			symbol.generic = false
		}
	}
	finalize_semantics(&c)
	_, valid := emit_llvm_module(&c)
	if !testing.expect(t, valid && c.error_count == 0, "an unreferenced generic template reached LLVM emission") { report(&c) }
}

@(test)
maps_declared_only_in_fields_have_key_policies :: proc(t: ^testing.T) {
	c := test_compiler(`package main;
Key :: struct { id: int }
impl Key {
    hash :: proc(self, seed: uint) -> uint { return seed; }
    equal :: operator(==) proc(a, b: Key) -> bool { return a.id == b.id; }
}
Grid :: struct { entries: map[string]f32, nested: [1]map[Key]int, next: ^Grid }
main :: proc() {
    g: Grid = {};
    p := g.entries.find("a");
    value := g.entries.lookup_value("a");
    g.nested[0][{1}] = 7;
    n := g.nested[0].lookup_value(key = {1});
}
`)
	defer destroy_compilation(&c)
	tokens := lex(&c, 0)
	defer delete(tokens)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)
	id := new_package(&c, f.package_name)
	c.root_package = id
	add_package_file(&c, id, &f)
	check_emission_package(&c, id)
	if !testing.expect(t, c.error_count == 0) { report(&c); return }
	finalize_semantics(&c)
	_, valid := emit_llvm_module(&c)
	if !testing.expect(t, valid && c.error_count == 0, "field-only map types must reach emission with resolved key policies") { report(&c) }
}

@(test)
unregistered_typeid_is_a_backend_contract_error :: proc(t: ^testing.T) {
	c := test_compiler("package main; main :: proc() { zero: typeid; id := typeid_of(int); }")
	defer destroy_compilation(&c)
	tokens := lex(&c, 0)
	defer delete(tokens)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)
	id := new_package(&c, f.package_name)
	c.root_package = id
	add_package_file(&c, id, &f)
	check_emission_package(&c, id)
	finalize_semantics(&c)
	_, valid := emit_llvm_module(&c)
	testing.expect(t, valid && c.error_count == 0, "registered and nil typeids must both emit")
	delete_key(&c.typeid_values, TYPE_INT)
	module, missing := emit_llvm_module(&c)
	testing.expect(t, !missing && module == "" && c.error_count == 1, "a missing dependency silently became the nil typeid")
}

@(test)
emission_rejects_incomplete_registries :: proc(t: ^testing.T) {
	cases := []string{"unfrozen", "speculative", "typeid", "typeid_range", "map", "order", "formatter",
	                   "instance", "witness", "constant",
	                   "lifecycle_unready", "lifecycle_missing", "lifecycle_incomplete", "lifecycle_hook",
	                   "lifecycle_hook_owner"}
	for broken in cases {
		c: Compiler
		c.build_mode = .Obj
		init_semantic_stores(&c)
		request_typeid(&c, TYPE_INT)
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
			c.formatters[TYPE_INT] = Symbol_Id(len(c.symbols) + 1)
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
			// Emittable, but declared on another type: it would be called with the
			// bytes of this one.
			append(&c.symbols, Symbol{kind = .Proc, is_foreign = true, proc_type = TYPE_INT, owner_type = TYPE_BOOL})
			operations := c.lifecycle_operations[TYPE_INT]
			operations.custom_drop = Symbol_Id(len(c.symbols) - 1)
			c.lifecycle_operations[TYPE_INT] = operations
		}
		testing.expectf(t, !validate_emission_dependencies(&c) && c.error_count == 1,
		                "%s registry was accepted at the emission boundary", broken)
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
	c := test_compiler(`package main;
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
	defer destroy_compilation(&c)
	tokens := lex(&c, 0)
	defer delete(tokens)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)
	id := new_package(&c, f.package_name)
	c.root_package = id
	add_package_file(&c, id, &f)
	check_emission_package(&c, id)
	if !testing.expect(t, c.error_count == 0) { report(&c); return }
	for key, policy in c.map_key_policies {
		if !testing.expect(t, policy.kind == .Inherent) { return }
		// Remove the lookup input while retaining the checked declarations. CTFE
		// and LLVM must still use the exact IDs selected by the checker.
		members := make([dynamic]Symbol_Id, c.semantic_allocator)
		for member in type_of(&c, key).members {
			if member != policy.hash && member != policy.equal { append(&members, member) }
		}
		type_of(&c, key).members = members[:]
	}
	lookup: Symbol_Id
	for symbol, index in c.symbols {
		if symbol.kind == .Proc && identifier_text(&c, symbol.name) == "lookup" {
			lookup = Symbol_Id(index)
		}
	}
	call: Expr_Call
	call.type = TYPE_INT
	call.resolution = Resolution{kind = .Call, symbol = lookup}
	call.operation = Call_Procedure{}
	checker := Checker{c = &c}
	value, evaluated := require_const(&checker, &call, "test result")
	testing.expect(t, evaluated && bi_eq_i64(&c, value.integer, 7), "CTFE repeated member lookup")
	finalize_semantics(&c)
	_, emitted := emit_llvm_module(&c)
	if !testing.expect(t, emitted && c.error_count == 0, "LLVM repeated member lookup") { report(&c) }
}

@(test)
lifecycle_consumers_use_finalized_operations :: proc(t: ^testing.T) {
	c := test_compiler(`package main;
Resource :: struct { value: int }
impl Resource {
    copy_owned :: hook(copy) proc(self, allocator: Allocator) -> Result(Resource, Allocator_Error) {
        return .ok(Resource{self.value + 1});
    }
    release :: hook(drop) proc(self: inout Resource) { self.value = 0; }
}
Nested :: struct { parts: [2]Resource, empty: [0]Resource, text: string }
Empty :: struct { parts: [0]Resource }
// A union and a managed map key: the tag-aware clone and the map write are the
// lowering paths that used to ask the checker's cache instead of the snapshot.
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
	defer destroy_compilation(&c)
	tokens := lex(&c, 0)
	defer delete(tokens)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)
	id := new_package(&c, f.package_name)
	c.root_package = id
	add_package_file(&c, id, &f)
	check_emission_package(&c, id)
	freeze_typeids(&c)
	types_before, symbols_before, procs_before := len(c.types), len(c.symbols), len(c.synth_procs)
	if !testing.expect(t, finalize_lifecycle_operations(&c)) { report(&c); return }
	testing.expect(t, len(c.types) == types_before && len(c.symbols) == symbols_before && len(c.synth_procs) == procs_before,
	               "finalizing lifecycle facts created semantic dependencies")
	for index in 1 ..< len(c.types) {
		type := Type_Id(index)
		operations, resolved := resolved_lifecycle_operations(&c, type)
		testing.expect(t, resolved && operations.managed == type_is_managed(&c, type) &&
		               operations.clone_fallible == type_clone_is_fallible(&c, type) &&
		               operations.clone_disabled == type_clone_disabled(&c, type),
		               "the snapshot changed lifecycle semantics")
	}
	before, emitted := emit_llvm_module(&c)
	if !testing.expect(t, emitted && c.error_count == 0) { report(&c); return }
	// Discard both sources of lazy lifecycle decisions. Checked symbols and the
	// final value records survive, so lowering must produce exactly the same IR.
	for &info in c.types {
		members := make([dynamic]Symbol_Id, c.semantic_allocator)
		for member in info.members {
			symbol := symbol_of(&c, member)
			if symbol.synth != .Clone && symbol.synth != .Try_Clone && symbol.hook != .Copy && symbol.hook != .Drop {
				append(&members, member)
			}
		}
		info.members = members[:]
	}
	clear(&c.lifecycles)
	after, emitted_again := emit_llvm_module(&c)
	testing.expect(t, emitted_again && c.error_count == 0 && before == after,
	               "LLVM repeated lifecycle member lookup or classification")
	testing.expect(t, len(c.lifecycles) == 0, "LLVM repopulated the checker's lifecycle cache")
}

@(test)
lifecycle_copy_dependencies_are_closed :: proc(t: ^testing.T) {
	for broken in ([]string{"missing_operation", "wrong_operation", "missing_body", "late_contribution"}) {
		c := test_compiler("package main; Record :: struct { value: int } main :: proc() { x: Record = {}; y := x.clone(); }")
		tokens := lex(&c, 0)
		f := parse(&c, 0, tokens)
		id := new_package(&c, f.package_name)
		c.root_package = id
		add_package_file(&c, id, &f)
		check_emission_package(&c, id)
		finalize_semantics(&c)
		testing.expect(t, validate_emission_dependencies(&c), "invalid lifecycle test setup")
		target: Type_Id
		for type, operations in c.lifecycle_operations {
			if operations.clone != INVALID_SYMBOL && underlying_info(&c, type).kind == .Struct {
				target = type
				break
			}
		}
		testing.expect(t, target != INVALID_TYPE)
		switch broken {
		case "missing_operation", "wrong_operation":
			operations := c.lifecycle_operations[target]
			operations.try_clone = broken == "missing_operation" ? INVALID_SYMBOL : operations.clone
			c.lifecycle_operations[target] = operations
		case "missing_body": clear(&c.synth_procs)
		case "late_contribution":
			// Removing the contribution marker models a late request, not a new
			// compilation. The closed phase must reject it without changing state.
			info := type_of(&c, target)
			info.contributed -= {.Lifecycle}
			symbols_before, procs_before, members_before := len(c.symbols), len(c.synth_procs), len(info.members)
			checker := Checker{c = &c}
			contribute_lifecycle_members(&checker, target)
			testing.expect(t, .Lifecycle not_in info.contributed && len(c.symbols) == symbols_before &&
			               len(c.synth_procs) == procs_before && len(info.members) == members_before,
			               "a late lifecycle request mutated semantic state")
		}
		module, emitted := emit_llvm_module(&c)
		testing.expectf(t, !emitted && module == "" && c.error_count == 1,
		                "%s lifecycle dependency was accepted", broken)
		destroy_ast(&f)
		delete(tokens)
		destroy_compilation(&c)
	}
}

@(test)
converted_string_temporary_is_cleaned_up :: proc(t: ^testing.T) {
	c := test_compiler(`package main;
make_key :: proc() -> string { return "x" + ""; }
main :: proc() {
    m: map[string]int = {};
    m["x"] = 1;
    _ = m.find_ref(make_key());
}
`)
	defer destroy_compilation(&c)
	tokens := lex(&c, 0)
	defer delete(tokens)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)
	id := new_package(&c, f.package_name)
	c.root_package = id
	add_package_file(&c, id, &f)
	check_emission_package(&c, id)
	if !testing.expect(t, c.error_count == 0) { report(&c); return }
	finalize_semantics(&c)
	module, emitted := emit_llvm_module(&c)
	if !testing.expect(t, emitted && c.error_count == 0) { report(&c); return }
	main_at := strings.index(module, "define internal void @loke.p.main()")
	if !testing.expect(t, main_at >= 0) { return }
	main_tail := module[main_at:]
	main_end := strings.index(main_tail, "\n}\n")
	if !testing.expect(t, main_end >= 0) { return }
	main_ir := main_tail[:main_end]
	made := strings.index(main_ir, "call %loke.string @loke.p.make_key()")
	if !testing.expect(t, made >= 0) { return }
	after_make := main_ir[made:]
	lookup := strings.index(after_make, ".find_ref(")
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

// A fixed-size `alloca` reaches the entry block however deep in the body it was
// asked for; a runtime-sized pack stays where its element count exists.
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

	// Nothing to place, and nowhere to place it, both leave the text alone.
	testing.expect(t, splice_prologue(&e, body, nil) == body)
	testing.expect(t, !e.failed && c.error_count == 0, "an ordinary splice reported a failure")

	// Storage with no entry block to hold it leaves the text for LLVM to describe,
	// but the module must not be handed back as though it were whole.
	orphan := "declare void @outside()\n"
	testing.expect(t, splice_prologue(&e, orphan, {"  %x = alloca i8"}) == orphan)
	testing.expect(t, e.failed && c.error_count == 1, "a dropped prologue was not reported")
}
