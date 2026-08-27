package lokec

import "core:testing"

@(test)
unregistered_typeid_is_a_backend_contract_error :: proc(t: ^testing.T) {
	c := test_compiler("package main; main :: proc() { zero: typeid; id := typeid_of(int); }")
	defer destroy_compilation(&c)
	tokens := lex(&c, 0)
	defer delete(tokens)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)
	id := new_package(&c, f.package_name, "<typeid-contract-test>")
	c.root_package = id
	add_package_file(&c, id, &f)
	check_one_package(&c, id)
	freeze_typeids(&c)
	_, valid := emit_llvm_module(&c, id)
	testing.expect(t, valid && c.error_count == 0, "registered and nil typeids must both emit")
	delete_key(&c.typeid_values, TYPE_INT)
	module, missing := emit_llvm_module(&c, id)
	testing.expect(t, !missing && module == "" && c.error_count == 1, "a missing dependency silently became the nil typeid")
}

@(test)
emission_rejects_incomplete_registries :: proc(t: ^testing.T) {
	cases := []string{"unfrozen", "speculative", "typeid", "typeid_range", "map", "instance", "witness", "constant"}
	for broken in cases {
		c: Compiler
		init_semantic_stores(&c)
		request_typeid(&c, TYPE_INT)
		freeze_typeids(&c)
		switch broken {
		case "unfrozen": c.typeid_frozen = false
		case "speculative": c.speculation_depth = 1
		case "typeid": delete_key(&c.typeid_values, TYPE_INT)
		case "typeid_range": c.typeid_values[TYPE_INT] = 2
		case "map":
			map_type := map_of(&c, TYPE_INT, TYPE_INT)
			type_of(&c, map_type).contributed += {.Container}
		case "instance":
			instance := new(Instance, c.semantic_allocator)
			instance.body_checked = true
			c.procedure_instances[Symbol_Id(1)] = instance
		case "witness": append(&c.witness_order, new(Witness, c.semantic_allocator))
		case "constant": append(&c.materialized_order, new(Materialized, c.semantic_allocator))
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
	id := new_package(&c, f.package_name, "<resolved-map-test>")
	c.root_package = id
	add_package_file(&c, id, &f)
	check_one_package(&c, id)
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
	checker := Checker{c = &c}
	value, evaluated := require_const(&checker, &call, "test result")
	testing.expect(t, evaluated && bi_eq_i64(&c, value.integer, 7), "CTFE repeated member lookup")
	freeze_typeids(&c)
	_, emitted := emit_llvm_module(&c, id)
	if !testing.expect(t, emitted && c.error_count == 0, "LLVM repeated member lookup") { report(&c) }
}

@(test)
artifact_extension_ignores_dotted_parent_directories :: proc(t: ^testing.T) {
	actual := replace_ext(`C:\release.v2\program`, ".ll")
	testing.expectf(t, actual == `C:\release.v2\program.ll`, "unexpected artifact path %q", actual)
}

@(test)
assembly_temporaries_include_the_source_identity :: proc(t: ^testing.T) {
	first := assembly_object_path(`C:\one\helper.asm`, `C:\out\program.exe`)
	second := assembly_object_path(`C:\two\helper.asm`, `C:\out\program.exe`)
	again := assembly_object_path(`c:\ONE\helper.asm`, `C:\out\program.exe`)
	testing.expectf(t, first != second, "different assembly sources collide at %q", first)
	testing.expectf(t, first == again, "one Windows source path produced %q and %q", first, again)
}

@(test)
fixed_allocas_are_hoisted_per_function :: proc(t: ^testing.T) {
	module :=
		"define void @first(i64 %n, i32 %m) {\n" +
		"entry:\n" +
		"  br label %loop\n" +
		"loop:\n" +
		"  %pair = alloca { i64, i64 }\n" +
		"  %named = alloca %Thing, align 8\n" +
		"  %pack = alloca i8, i64 %n\n" +
		"  %pack32 = alloca i8, i32 %m\n" +
		"  br label %loop\n" +
		"}\n" +
		"define void @empty() { ret void }\n" +
		"define void @second() {\n" +
		"entry:\n" +
		"  %byte = alloca i8\n" +
		"  ret void\n" +
		"}\n"
	expected :=
		"define void @first(i64 %n, i32 %m) {\n" +
		"entry:\n" +
		"  %pair = alloca { i64, i64 }\n" +
		"  %named = alloca %Thing, align 8\n" +
		"  br label %loop\n" +
		"loop:\n" +
		"  %pack = alloca i8, i64 %n\n" +
		"  %pack32 = alloca i8, i32 %m\n" +
		"  br label %loop\n" +
		"}\n" +
		"define void @empty() { ret void }\n" +
		"define void @second() {\n" +
		"entry:\n" +
		"  %byte = alloca i8\n" +
		"  ret void\n" +
		"}\n"
	actual := hoist_fixed_allocas(module)
	testing.expectf(t, actual == expected, "unexpected alloca hoist:\n%s", actual)
}
