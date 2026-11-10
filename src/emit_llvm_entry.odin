// Program entry: `wmain` for an executable and a test build, an object's CPU
// check, and the provider initializer.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"

// The attributes that make a function baseline x86-64 whatever `-march` says.
@(private = "file")
BASELINE_ATTRIBUTES :: `"target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87"`

// compiler-guide.md "C runtime": `wmain` initializes the arguments, the
// thread, and the providers, in that order, then calls `main`.
//
// compiler-guide.md "CPU levels": above baseline, `wmain` itself is baseline
// code and first asks the runtime whether the processor runs the build's level.
// The explicit feature list is what makes it baseline: a `target-cpu` alone
// keeps the command line's features. A callee compiled for the level is then
// never inlined into it, so nothing of the level's runs before the check.
@(private = "file")
open_program_entry :: proc(e: ^Emitter) {
	if e.c.target.cpu == .X86_64 {
		open_function(e, "define i32 @wmain(i32 %%argc, ptr %%argv)")
	} else {
		open_function(e, "define i32 @wmain(i32 %%argc, ptr %%argv) " + BASELINE_ATTRIBUTES)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_require_cpu(i32 %d)", int(e.c.target.cpu))
	}
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_args_init(i32 %argc, ptr %argv)")
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_thread_attach()")
	if e.c.debug_info {
		fmt.sbprintln(&e.b, "  call void @loke_rt_v1_enable_panic_trace()")
	}
	if any_provider_selected(e.c) {
		fmt.sbprintln(&e.b, "  call void @loke_rt_v1_program_init()")
	}
}

// `wmain` has no debug information, and LLVM drops the locations of code
// inlined into it, so a `-g` build keeps what it calls a frame of its own.
@(private = "file")
entry_call_attributes :: proc(e: ^Emitter) -> string {
	return e.c.debug_info ? " noinline" : ""
}

// compiler-guide.md "CPU levels": an object build has no entry to check from,
// so above baseline it carries a baseline static constructor that does, which
// the host's C runtime runs before the host's `main`.
@(private)
emit_object_cpu_check :: proc(e: ^Emitter) {
	name := claim_name(e, "@loke.require_cpu")
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	open_function(e, "define internal void %s() %s", name, BASELINE_ATTRIBUTES)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_require_cpu(i32 %d)", int(e.c.target.cpu))
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
	append(
		&e.globals,
		fmt.aprintf(
			"@llvm.global_ctors = appending global [1 x {{ i32, ptr, ptr }}] [{{ i32, ptr, ptr }} {{ i32 65535, ptr %s, ptr null }}]\n",
			name,
		),
	)
}

// `wmain` for an executable: startup, then `main`.
@(private)
emit_entry :: proc(e: ^Emitter) {
	entry, found := e.names[e.c.entry_point]
	if !found {
		backend_fail(e, "the validated entry procedure has no emitted name")
		return
	}
	symbol := symbol_of(e.c, e.c.entry_point)
	callee := entry
	failure, fallible := entry_failure_type(e.c, symbol.result)
	if fallible {
		callee = emit_failure_reporter(e, "@loke.main.report", entry, symbol.result, failure)
	}
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	open_program_entry(e)
	// design.md "Program entry and exit": an `i32` result is the exit status.
	status := "0"
	if symbol.result == TYPE_I32 || fallible {
		status = temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i32 %s()%s", status, callee, entry_call_attributes(e))
	} else {
		fmt.sbprintfln(&e.b, "  call void %s()%s", entry, entry_call_attributes(e))
	}
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_thread_detach()")
	fmt.sbprintfln(&e.b, "  ret i32 %s", status)
	fmt.sbprintln(&e.b, "}")
}

// design.md "Test procedures": with no argument, run every test in order and
// stop at the first failure; with a test's name, run that one alone. The
// runtime matches the name and exits 2 on one no test has.
@(private)
emit_test_entry :: proc(e: ^Emitter) {
	runners := make([]string, len(e.c.tests))
	reported := make([]bool, len(e.c.tests))
	for test, index in e.c.tests {
		name := symbol_name(e, test)
		runners[index] = name
		symbol := symbol_of(e.c, test)
		if failure, fallible := entry_failure_type(e.c, symbol.result); fallible {
			runners[index] = emit_failure_reporter(e, fmt.aprintf("@loke.test.%d", index), name, symbol.result, failure)
			reported[index] = true
		}
	}
	names := "null"
	if len(e.c.tests) > 0 {
		entries := make([]string, len(e.c.tests))
		for test, index in e.c.tests {
			entries[index] = text_literal_global(e, identifier_text(e.c, symbol_of(e.c, test).name))
		}
		names = claim_name(e, "@loke.tests")
		append_constant_array(e, names, "ptr", entries)
	}

	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	open_program_entry(e)
	selected, every := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = call i64 @loke_rt_v1_test_select(ptr %s, i64 %d)", selected, names, len(e.c.tests))
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, -1", every, selected)
	failed := new_label(e, "test.failed")
	for runner, index in runners {
		picked := emit_value(e, "icmp eq i64 %s, %d", selected, index)
		run := combine_or(e, every, picked)
		body, next := new_label(e, "test.run"), new_label(e, "test.next")
		branch_if(e, run, body, next)
		place_label(e, body)
		if !reported[index] {
			fmt.sbprintfln(&e.b, "  call void %s()%s", runner, entry_call_attributes(e))
			branch(e, next)
		} else {
			status := emit_value(e, "call i32 %s()", runner)
			branch_if(e, icmp_zero(e, "i32", status, equal = false), failed, next)
		}
		place_label(e, next)
	}
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_thread_detach()")
	fmt.sbprintln(&e.b, "  ret i32 0")
	e.terminated = true
	place_label(e, failed)
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_thread_detach()")
	fmt.sbprintln(&e.b, "  ret i32 1")
	fmt.sbprintln(&e.b, "}")
}

// design.md "What the unwind runs, and what it does not": a fallible `main` or
// test is called, reported, and dropped in a function of its own, whose frame
// registers the failure it hands back while that is printed. The function's name;
// it returns the exit status.
@(private = "file")
emit_failure_reporter :: proc(e: ^Emitter, base, callee: string, result, failure: Type_Id) -> string {
	name := claim_name(e, base)
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	open_function(e, "define private i32 %s()", name)
	header := begin_generated_frame(e, name)
	status := emit_entry_failure_report(e, callee, result, failure, entry_call_attributes(e))
	emit_unwind_pop(e)
	fmt.sbprintfln(&e.b, "  ret i32 %s", status)
	fmt.sbprintln(&e.b, "}")
	end_generated_frame(e, header)
	return name
}

// design.md "Build-selected providers": run once, allocator first so the logger
// factory already allocates through it. The runtime keeps the once-only state.
// The host calls it, so it is guarded as a foreign entry is (design.md
// "Floating-point operators").
@(private)
emit_program_init :: proc(e: ^Emitter) {
	body := entry_body_name(e, "@loke_rt_v1_program_init")
	emit_program_init_body(e, body)
	emit_entry_guard(e, "@loke_rt_v1_program_init", "void", nil, body)
}

@(private = "file")
emit_program_init_body :: proc(e: ^Emitter, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	open_function(e, "define internal void %s() noinline", name)
	go := emit_value(e, "call i32 @loke_rt_v1_provider_init_begin()")
	run := icmp_zero(e, "i32", go, equal = false)
	body, done := new_label(e, "init.run"), new_label(e, "init.done")
	branch_if(e, run, body, done)
	place_label(e, body)

	if allocator := e.c.providers[.Allocator].factory; allocator != INVALID_SYMBOL {
		handle := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call ptr %s()", handle, symbol_name(e, allocator))
		// The runtime rejects a zero or foreign handle.
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_publish_allocator(ptr %s)", handle)
	}
	if logger := e.c.providers[.Logger].factory; logger != INVALID_SYMBOL {
		factory := symbol_of(e.c, logger)
		global, found := e.names[e.c.providers[.Logger].destination]
		if factory == nil || !found {
			backend_fail(e, "the selected logger has no factory or nowhere to be published")
		} else {
			// A large handle comes back through storage, as any call's would.
			handle := emit_call_result(e, factory.result, symbol_name(e, logger), "")
			destination := symbol_of(e.c, e.c.providers[.Logger].destination).type
			store(e, destination, emit_option_some(e, destination, handle), global)
		}
	}
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_provider_init_end()")
	place_label(e, done)
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
}
