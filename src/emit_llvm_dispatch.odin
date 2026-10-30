// design.md "@(cpu_dispatch=<string>)": a procedure marked for a level above the
// build's is written twice, once as usual and once for that level, together
// with every procedure the level's copy calls directly. Its own name becomes a
// dispatcher at the build's level, which asks the runtime once whether the
// processor has the level and calls one copy or the other.
//
// A copy calls copies, so nothing compiled for the level runs before the check
// says it may. The dispatcher is at the build's level, and LLVM never inlines a
// function into one whose features lack the callee's, so the level's code stays
// behind the check (deterministic-math-and-targets-plan.md "Code generation and
// startup").
package lokec

import "core:fmt"
import "core:strings"

// One procedure's copy for one level.
@(private)
Cpu_Copy :: struct {
	symbol: Symbol_Id,
	cpu:    Cpu_Level,
}

// The attributes of a function compiled for `cpu`, which are clang's for
// `-march` at that level, so that a copy is the code the whole build would be.
@(private)
cpu_level_attributes :: proc(cpu: Cpu_Level) -> string {
	switch cpu {
	case .X86_64:
		return `"target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87"`
	case .X86_64_V2:
		return `"target-cpu"="x86-64-v2" "target-features"="+cmov,+crc32,+cx16,+cx8,+fxsr,+mmx,+popcnt,+sahf,+sse,+sse2,+sse3,+sse4.1,+sse4.2,+ssse3,+x87"`
	case .X86_64_V3:
		return `"target-cpu"="x86-64-v3" "target-features"="+avx,+avx2,+bmi,+bmi2,+cmov,+crc32,+cx16,+cx8,+f16c,+fma,+fxsr,+lzcnt,+mmx,+movbe,+popcnt,+sahf,+sse,+sse2,+sse3,+sse4.1,+sse4.2,+ssse3,+x87,+xsave"`
	}
	return ""
}

// What follows a copy's signature, or "" for a function at the build's level.
@(private)
copy_attributes :: proc(e: ^Emitter) -> string {
	return e.copying ? strings.concatenate({" ", cpu_level_attributes(e.copy_cpu)}) : ""
}

// The features of the function being written, a copy's or the build's.
@(private)
emitted_features :: proc(e: ^Emitter) -> Cpu_Features {
	return e.copying ? windows_x64_target(e.copy_cpu).features : e.c.target.features
}

// The function a direct call names: in a copy, the callee's copy for the same
// level, made on first use, for any procedure with a body; otherwise, and for
// one without, the callee itself. A call through a procedure value reaches the
// procedure as written, which is correct at any level.
@(private)
callee_name :: proc(e: ^Emitter, symbol_id: Symbol_Id) -> string {
	if e.copying && symbol_id in e.bodies {
		return cpu_copy_name(e, symbol_id, e.copy_cpu)
	}
	return symbol_name(e, symbol_id)
}

// The copy's name, claimed and queued for `emit_cpu_copies` the first time.
@(private)
cpu_copy_name :: proc(e: ^Emitter, symbol_id: Symbol_Id, cpu: Cpu_Level) -> string {
	key := Cpu_Copy{symbol_id, cpu}
	if name, found := e.cpu_copies[key]; found {
		return name
	}
	base := symbol_name(e, symbol_id)[1:]
	suffix := cpu == .X86_64_V3 ? "v3" : "v2"
	name: string
	switch {
	case strings.has_prefix(base, "loke."):
		name = claim_name(e, fmt.aprintf("@%s.%s", base, suffix))
	case llvm_plain_name(base):
		name = claim_name(e, fmt.aprintf("@loke.%s.%s", base, suffix))
	case:
		name = claim_name(e, fmt.aprintf("@loke.copy.%s", suffix))
	}
	e.cpu_copies[key] = name
	append(&e.unwritten_copies, key)
	return name
}

// Whether the procedure's own name is a dispatcher: it asks for a level the
// build does not already have.
@(private)
dispatched :: proc(e: ^Emitter, symbol: ^Symbol) -> bool {
	return symbol.dispatches && symbol.dispatch_cpu > e.c.target.cpu
}

// The procedure as usual under an internal name, its copy for the level, and,
// under its own name, the dispatcher between them.
@(private)
emit_dispatched_proc :: proc(e: ^Emitter, symbol_id: Symbol_Id, literal: ^Expr_Proc, llvm_name: string) {
	symbol := symbol_of(e.c, symbol_id)
	plain := claim_name(e, fmt.aprintf("@loke.%s.plain", strings.trim_prefix(llvm_name[1:], "loke.")))
	emit_proc_definition(e, symbol_id, literal, plain)
	copy := cpu_copy_name(e, symbol_id, symbol.dispatch_cpu)
	check := dispatch_check(e, symbol.dispatch_cpu)

	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	inout := result_inout_of(e, symbol.proc_type)
	result := llvm_result_type(e, symbol.result, inout)
	params := make([dynamic]string)
	if returns_sret(e, symbol.result, inout) {
		append(&params, "ptr %sret")
	}
	for parameter, index in symbol.params {
		mode := symbol_param_mode(e.c, symbol, index)
		append(&params, fmt.aprintf("%s%s %%arg%d", param_llvm(e, parameter, mode), param_nonnull(e, parameter, mode), index))
	}
	arguments := strings.join(params[:], ", ")
	// design.md "@(cold)": a call to a cold procedure is a call to its dispatcher.
	open_function(e, "define %s%s %s(%s)%s", llvm_linkage(llvm_name), result, llvm_name, arguments, cold_attributes(symbol))
	fmt.sbprintfln(&e.b, "  %%has = call i1 %s()", check)
	fmt.sbprintln(&e.b, "  br i1 %has, label %copy, label %plain")
	for target in ([2]string{copy, plain}) {
		fmt.sbprintfln(&e.b, "%s:", target == copy ? "copy" : "plain")
		if result == "void" {
			fmt.sbprintfln(&e.b, "  tail call void %s(%s)", target, arguments)
			fmt.sbprintln(&e.b, "  ret void")
		} else {
			out := temp(e)
			fmt.sbprintfln(&e.b, "  %s = tail call %s %s(%s)", out, result, target, arguments)
			fmt.sbprintfln(&e.b, "  ret %s %s", result, out)
		}
	}
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
}

// Every copy a dispatcher or another copy named, each of whose bodies may name
// more.
@(private)
emit_cpu_copies :: proc(e: ^Emitter) {
	for len(e.unwritten_copies) > 0 {
		key := pop(&e.unwritten_copies)
		emit_proc_definition(e, key.symbol, e.bodies[key.symbol], e.cpu_copies[key], copy_cpu = key.cpu)
	}
}

// A function answering whether the processor runs `cpu`, which asks the
// runtime the first time and then reads its cached answer: 0 before it is
// known, then 1 for no and 2 for yes. Two threads asking at once store the
// same answer.
@(private = "file")
dispatch_check :: proc(e: ^Emitter, cpu: Cpu_Level) -> string {
	if name, found := e.dispatch_checks[cpu]; found {
		return name
	}
	name := claim_name(e, fmt.aprintf("@loke.cpu_dispatch.%s", cpu == .X86_64_V3 ? "v3" : "v2"))
	e.dispatch_checks[cpu] = name
	if len(e.dispatch_checks) == 1 {
		append(&e.globals, "declare i32 @loke_rt_v1_cpu_dispatch(i32)\n")
	}
	state := strings.concatenate({name, ".state"})
	append(&e.globals, fmt.aprintf("%s = internal global i8 0\n", state))
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	open_function(e, "define internal i1 %s()", name)
	fmt.sbprintfln(&e.b, "  %%known = load atomic i8, ptr %s monotonic, align 1", state)
	fmt.sbprintln(&e.b, "  %asked = icmp ne i8 %known, 0")
	fmt.sbprintln(&e.b, "  br i1 %asked, label %answer, label %ask")
	fmt.sbprintln(&e.b, "ask:")
	fmt.sbprintfln(&e.b, "  %%runs = call i32 @loke_rt_v1_cpu_dispatch(i32 %d)", int(cpu))
	fmt.sbprintln(&e.b, "  %yes = icmp ne i32 %runs, 0")
	fmt.sbprintln(&e.b, "  %found = select i1 %yes, i8 2, i8 1")
	fmt.sbprintfln(&e.b, "  store atomic i8 %%found, ptr %s monotonic, align 1", state)
	fmt.sbprintln(&e.b, "  br label %answer")
	fmt.sbprintln(&e.b, "answer:")
	fmt.sbprintln(&e.b, "  %state = phi i8 [ %known, %entry ], [ %found, %ask ]")
	fmt.sbprintln(&e.b, "  %has = icmp eq i8 %state, 2")
	fmt.sbprintln(&e.b, "  ret i1 %has")
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
	return name
}
