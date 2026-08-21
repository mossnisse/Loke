package lokec

import "core:testing"

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
