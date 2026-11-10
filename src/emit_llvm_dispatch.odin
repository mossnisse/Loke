// compiler-architecture.md "CPU dispatch": a procedure marked for a level above the
// build's is written twice, once as usual and once for that level, together
// with every procedure the level's copy calls directly. Its own name becomes a
// dispatcher at the build's level, which asks the runtime once whether the
// processor has the level and calls one copy or the other.
//
// A copy calls copies, and LLVM never inlines a function into one whose features
// lack the callee's, so the level's code stays behind the check
// (comments.md "A dispatched procedure is copied with its callees").
package lokec

import "core:fmt"
import "core:strings"

@(private)
Cpu_Copy :: struct {
	symbol: Symbol_Id,
	cpu:    Cpu_Level,
}

// What follows a copy's signature, or "" for a function at the build's level:
// clang's attributes for `-march` at the copy's level, so that a copy is the code
// the whole build would be.
@(private)
copy_attributes :: proc(e: ^Emitter) -> string {
	if !e.copying { return "" }
	#partial switch e.copy_cpu {
	case .X86_64_V2:
		return ` "target-cpu"="x86-64-v2" "target-features"="+cmov,+crc32,+cx16,+cx8,+fxsr,+mmx,+popcnt,+sahf,+sse,+sse2,+sse3,+sse4.1,+sse4.2,+ssse3,+x87"`
	case .X86_64_V3:
		return ` "target-cpu"="x86-64-v3" "target-features"="+avx,+avx2,+bmi,+bmi2,+cmov,+crc32,+cx16,+cx8,+f16c,+fma,+fxsr,+lzcnt,+mmx,+movbe,+popcnt,+sahf,+sse,+sse2,+sse3,+sse4.1,+sse4.2,+ssse3,+x87,+xsave"`
	}
	return ""
}

@(private)
emitted_has_fma :: proc(e: ^Emitter) -> bool {
	return cpu_has_fma(e.copying ? e.copy_cpu : e.c.target.cpu)
}

// A copy's name for a level, and its check's.
@(private = "file")
cpu_suffix :: proc(cpu: Cpu_Level) -> string {
	return cpu == .X86_64_V3 ? "v3" : "v2"
}

// In a copy, the callee's copy for the level, made on first use; a procedure with
// no body has none. A helper shared between levels is written as its own function,
// which is not a copy, so it names the callee itself.
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
	name := claim_name(e, fmt.aprintf("%s.%s", symbol_name(e, symbol_id), cpu_suffix(cpu)))
	e.cpu_copies[key] = name
	append(&e.unwritten_copies, key)
	return name
}

// Whether the procedure's own name is a dispatcher: it asks for a level the
// build does not already have.
@(private)
dispatched :: proc(e: ^Emitter, symbol: ^Symbol) -> bool {
	return symbol.dispatch_cpu > e.c.target.cpu
}

// The procedure as usual under an internal name, its copy for the level, and,
// under its own name, the dispatcher between them.
@(private)
emit_dispatched_proc :: proc(e: ^Emitter, symbol_id: Symbol_Id, literal: ^Expr_Proc, llvm_name: string) {
	symbol := symbol_of(e.c, symbol_id)
	plain := claim_name(e, strings.concatenate({llvm_name, ".plain"}))
	emit_proc_definition(e, symbol_id, literal, plain)
	copy := cpu_copy_name(e, symbol_id, symbol.dispatch_cpu)
	check := dispatch_check(e, symbol.dispatch_cpu)

	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	inout := result_inout_of(e, symbol.proc_type)
	result := llvm_result_type(e, symbol.result, inout)
	// The parameter list, attributes such as `nonnull` included, doubles as the
	// forwarded call's arguments: a call site accepts parameter attributes.
	arguments := loke_param_list(e, symbol, inout)
	// compiler-architecture.md "CPU dispatch": a call to a cold procedure is a call to its dispatcher.
	open_function(e, "define %s%s %s(%s)%s", llvm_linkage(llvm_name), result, llvm_name, arguments, cold_attributes(symbol))
	fmt.sbprintfln(&e.b, "  %%has = call i1 %s()", check)
	fmt.sbprintln(&e.b, "  br i1 %has, label %copy, label %plain")
	for target in ([2]string{copy, plain}) {
		fmt.sbprintfln(&e.b, "%s:", target == copy ? "copy" : "plain")
		emit_forward_ret(e, "tail call", result, target, arguments)
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
	if name := e.dispatch_checks[cpu]; name != "" {
		return name
	}
	name := claim_name(e, fmt.aprintf("@loke.cpu_dispatch.%s", cpu_suffix(cpu)))
	e.dispatch_checks[cpu] = name
	state := claim_name(e, strings.concatenate({name, ".state"}))
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
