package lokec

import "core:strings"
import "core:testing"

// `module` pruned is `module` without the lines of it that start with `-`; the
// others start with a space, which is not part of the module.
@(private = "file")
expect_pruned :: proc(t: ^testing.T, marked: string, loc := #caller_location) {
	context.allocator = context.temp_allocator
	module, expected: strings.Builder
	rest := marked
	for line in strings.split_lines_iterator(&rest) {
		text := len(line) > 0 ? line[1:] : line
		strings.write_string(&module, text)
		strings.write_byte(&module, '\n')
		if !strings.has_prefix(line, "-") {
			strings.write_string(&expected, text)
			strings.write_byte(&expected, '\n')
		}
	}
	pruned := prune_unreachable(strings.to_string(module))
	testing.expectf(t, pruned == strings.to_string(expected), "pruned to:\n%s", pruned, loc = loc)
}

@(test)
pruning_keeps_what_a_linker_visible_definition_reaches :: proc(t: ^testing.T) {
	expect_pruned(t, ` target triple = "x86_64-pc-windows-msvc"

 declare void @puts(ptr)
 @.str.0 = private unnamed_addr constant [3 x i8] c"hi\00"
-@.str.1 = private unnamed_addr constant [5 x i8] c"dead\00"
 @loke.g.count = global i64 0

 define internal void @loke.p.used() {
 entry:
   call void @puts(ptr @.str.0)
   ret void
 }

-define internal void @loke.p.unused() {
-entry:
-  call void @puts(ptr @.str.1)
-  call void @loke.p.recursive()
-  ret void
-}
-
-define internal void @loke.p.recursive() {
-entry:
-  call void @loke.p.recursive()
-  ret void
-}
-
 define i32 @main() {
 entry:
   call void @loke.p.used()
   ret i32 0
 }
`)
}

// A table's functions are reached through the table, and theirs through them.
@(test)
pruning_follows_a_global_to_the_functions_it_names :: proc(t: ^testing.T) {
	expect_pruned(t, ` define private void @loke.w.Shape.Circle.thunk.0(ptr %arg0) {
 entry:
   call void @loke.p.Circle.draw(ptr %arg0)
   ret void
 }

-define private void @loke.w.Shape.Square.thunk.0(ptr %arg0) {
-entry:
-  call void @loke.p.Square.draw(ptr %arg0)
-  ret void
-}
-
 define internal void @loke.p.Circle.draw(ptr %arg0) {
 entry:
   ret void
 }

-define internal void @loke.p.Square.draw(ptr %arg0) {
-entry:
-  ret void
-}
-
 @loke.w.Shape.Circle = private unnamed_addr constant [1 x ptr] [ ptr @loke.w.Shape.Circle.thunk.0 ]
-@loke.w.Shape.Square = private unnamed_addr constant [1 x ptr] [ ptr @loke.w.Shape.Square.thunk.0 ]
 @llvm.global_ctors = appending global [1 x { i32, ptr, ptr }] [{ i32, ptr, ptr } { i32 65535, ptr @loke.init, ptr null }]

 define internal void @loke.init() {
 entry:
   %table = getelementptr ptr, ptr @loke.w.Shape.Circle, i32 0
   ret void
 }
`)
}

// LLVM reads `@"f"` and `@f` as one name. A string's bytes name nothing, and
// one that ends in `@` does not open a quoted name.
@(test)
pruning_reads_names_as_llvm_does :: proc(t: ^testing.T) {
	expect_pruned(t, ` @pair = global { [1 x i8], ptr, [1 x i8] } { [1 x i8] c"@", ptr @"kept one", [1 x i8] c"y" }
 @text = global [14 x i8] c"@loke.p.named"

 define internal void @"kept one"() {
 entry:
   call void @"loke.p.plain"()
   ret void
 }

 define internal void @loke.p.plain() {
 entry:
   ret void
 }

-define internal void @loke.p.named() {
-entry:
-  ret void
-}
`)
}

// The debug markers above a global are comments, which go with it.
@(test)
pruning_drops_the_comments_above_a_definition_with_it :: proc(t: ^testing.T) {
	expect_pruned(t, ` ; a comment on its own

-;dbg.witness 0
-@loke.w.First = private unnamed_addr constant [0 x ptr] [ ]
 ;dbg.witness 1
 @loke.w.Second = private unnamed_addr constant [0 x ptr] [ ]
 @root = global ptr @loke.w.Second
`)
}

@(test)
pruning_returns_a_module_with_nothing_to_drop_as_it_is :: proc(t: ^testing.T) {
	module := "define void @main() {\nentry:\n  ret void\n}\n"
	context.allocator = context.temp_allocator
	testing.expect(t, raw_data(prune_unreachable(module)) == raw_data(module))
}
