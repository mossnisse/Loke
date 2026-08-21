package lokec

import "core:testing"

@(test)
fixed_allocas_are_hoisted_per_function :: proc(t: ^testing.T) {
	module :=
		"define void @first(i64 %n) {\n" +
		"entry:\n" +
		"  br label %loop\n" +
		"loop:\n" +
		"  %pair = alloca { i64, i64 }\n" +
		"  %pack = alloca i8, i64 %n\n" +
		"  br label %loop\n" +
		"}\n" +
		"define void @empty() { ret void }\n" +
		"define void @second() {\n" +
		"entry:\n" +
		"  %byte = alloca i8\n" +
		"  ret void\n" +
		"}\n"
	expected :=
		"define void @first(i64 %n) {\n" +
		"entry:\n" +
		"  %pair = alloca { i64, i64 }\n" +
		"  br label %loop\n" +
		"loop:\n" +
		"  %pack = alloca i8, i64 %n\n" +
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
