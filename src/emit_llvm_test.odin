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
	_, missing := emit_llvm_module(&c, id)
	testing.expect(t, !missing && c.error_count == 1, "a missing dependency silently became the nil typeid")
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
