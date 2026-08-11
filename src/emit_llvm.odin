// Backend (compiler-plan B16/B17, minimal): typed AST straight to textual LLVM
// IR (decision A5), then `clang` to object-and-link in one step.
//
// There is no MIR here on purpose — B13 arrives at M6, and keeping codegen to
// this one file is what makes it replaceable then.
//
// Every local is an alloca plus load/store: LLVM's mem2reg builds the SSA form,
// so this file never constructs a phi node.
package lokec

import "core:fmt"
import "core:os"
import "core:path/filepath"
import os2 "core:os/os2"
import "core:strings"

@(private = "file")
Emitter :: struct {
	c:    ^Compiler,
	b:    strings.Builder,
	next: int, // temporary and unique-name counter
	// Backend names are an emitter concern. Semantic symbols remain reusable by
	// MIR, interpreters, and multiple backend invocations.
	names: map[Symbol_Id]string,
}

emit_package :: proc(c: ^Compiler, package_id: Package_Id, opts: Options) -> int {
	pkg := package_of(c, package_id)
	if pkg == nil {
		errorf(c, no_span(), "L0404", "cannot emit an unknown package")
		return 2
	}
	e := Emitter {
		c     = c,
		names = make(map[Symbol_Id]string),
	}
	strings.builder_init(&e.b)

	emit_preamble(&e)
	for file in pkg.files {
		for item in file.items {
			if d, ok := item.(^Decl); ok && decl_proc(d) == nil {
				emit_global(&e, d)
			}
		}
	}
	for file in pkg.files {
		for item in file.items {
			if d, ok := item.(^Decl); ok && decl_proc(d) != nil {
				emit_proc(&e, d)
			}
		}
	}
	emit_entry(&e)

	ll_path := replace_ext(opts.output, ".ll")
	if !os.write_entire_file(ll_path, transmute([]u8)strings.to_string(e.b)) {
		errorf(c, no_span(), "L0401", "cannot write `%s`", ll_path)
		return 2
	}
	if opts.emit_ll {
		fmt.printfln("wrote %s", ll_path)
		return 0
	}
	defer if !opts.keep_temps {
		os.remove(ll_path)
	}

	return link(c, ll_path, opts.output)
}

@(private = "file")
emit_preamble :: proc(e: ^Emitter) {
	fmt.sbprintln(&e.b, `target triple = "x86_64-pc-windows-msvc"`)
	fmt.sbprintln(&e.b, "")
	// ponytail: printf stands in for core:fmt until the seed runtime lands (M6).
	fmt.sbprintln(&e.b, `@.fmt_int = private unnamed_addr constant [6 x i8] c"%lld\0A\00"`)
	fmt.sbprintln(&e.b, "declare i32 @printf(ptr, ...)")
	// M0 has no runtime yet. Exceptional integer operations still take an
	// explicit, deterministic failure path instead of inheriting LLVM poison or
	// a target-specific hardware exception.
	fmt.sbprintln(&e.b, "declare void @llvm.trap()")
	fmt.sbprintln(&e.b, "")
}

// File-scope variables need constant initialisers (design.md "Values that
// outlive every scope"), so folding has already produced the value.
@(private = "file")
emit_global :: proc(e: ^Emitter, d: ^Decl) {
	for symbol_id, i in d.symbols {
		sym := symbol_of(e.c, symbol_id)
		if sym == nil || sym.kind != .Var {
			continue
		}
		name := llvm_global_name(identifier_text(e.c, sym.name))
		e.names[symbol_id] = name
		value := i64(0)
		if i < len(d.values) && d.values[i] != nil && is_const_expr(d.values[i]) {
			value = const_value_of(d.values[i])
		}
		fmt.sbprintfln(&e.b, "%s = global i64 %d", name, value)
	}
	fmt.sbprintln(&e.b, "")
}

@(private = "file")
emit_proc :: proc(e: ^Emitter, d: ^Decl) {
	// `{` is a format directive to core:fmt, so the brace is printed separately.
	name := llvm_proc_name(d.names[0].text)
	if len(d.symbols) > 0 && d.symbols[0] != INVALID_SYMBOL {
		e.names[d.symbols[0]] = name
	}
	fmt.sbprintf(&e.b, "define void %s()", name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	emit_block(e, decl_proc(d).body)
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
}

// The C entry point. `@(init)`/`@(fini)` and runtime startup hang here later,
// which is why loke's `main` is not the C `main`.
@(private = "file")
emit_entry :: proc(e: ^Emitter) {
	fmt.sbprintln(&e.b, "define i32 @main() {")
	fmt.sbprintln(&e.b, "entry:")
	fmt.sbprintfln(&e.b, "  call void %s()", llvm_proc_name("main"))
	fmt.sbprintln(&e.b, "  ret i32 0")
	fmt.sbprintln(&e.b, "}")
}

@(private = "file")
emit_block :: proc(e: ^Emitter, b: ^Block) {
	if b == nil {
		return
	}
	for stmt in b.stmts {
		#partial switch s in stmt {
		case ^Stmt_Error:
		case ^Decl:
			emit_local_decl(e, s)
		case ^Stmt_Expr:
			for expr in s.exprs {
				emit_expr(e, expr)
			}
		case ^Stmt_Return:
			fmt.sbprintln(&e.b, "  ret void")
			// Anything after a terminator needs a fresh label to stay valid IR.
			fmt.sbprintfln(&e.b, "unreachable.%d:", next_id(e))
		case ^Block:
			emit_block(e, s)
		case:
			// The checker's L0350 arm gates every statement missing here, so this
			// is a hole in that gate — and skipping it would emit a program that
			// silently does less than the source says.
			panic("a statement the checker did not gate reached the backend")
		}
	}
}

@(private = "file")
emit_local_decl :: proc(e: ^Emitter, d: ^Decl) {
	for symbol_id, i in d.symbols {
		sym := symbol_of(e.c, symbol_id)
		// Constants are folded at every use, so they need no storage.
		if sym == nil || sym.kind != .Var {
			continue
		}
		name := fmt.aprintf("%%%s.%d", identifier_text(e.c, sym.name), next_id(e))
		e.names[symbol_id] = name
		fmt.sbprintfln(&e.b, "  %s = alloca i64", name)

		value := "0"
		if i < len(d.values) && d.values[i] != nil {
			value = emit_expr(e, d.values[i])
		}
		fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", value, name)
	}
}

@(private = "file")
next_id :: proc(e: ^Emitter) -> int {
	e.next += 1
	return e.next
}

@(private = "file")
temp :: proc(e: ^Emitter) -> string {
	return fmt.aprintf("%%t%d", next_id(e))
}

// Returns an operand: either a literal or a `%name`.
@(private = "file")
emit_expr :: proc(e: ^Emitter, expr: Expr) -> string {
	if expr == nil {
		return "0"
	}
	if is_const_expr(expr) {
		return fmt.aprintf("%d", const_value_of(expr))
	}

	#partial switch v in expr {
	case ^Expr_Error:
		return "0"
	case ^Expr_Literal:
		return fmt.aprintf("%d", v.const_value.integer)

	case ^Expr_Ident:
		out := temp(e)
		name, ok := e.names[v.symbol]
		if !ok {
			panic("resolved value has no backend storage")
		}
		fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", out, name)
		return out

	case ^Expr_Unary:
		operand := emit_expr(e, v.operand)
		if v.op != .Minus {
			return operand
		}
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = sub i64 0, %s", out, operand)
		return out

	case ^Expr_Binary:
		lhs := emit_expr(e, v.lhs)
		rhs := emit_expr(e, v.rhs)
		if v.op == .Amp_Tilde {
			complement := temp(e)
			fmt.sbprintfln(&e.b, "  %s = xor i64 %s, -1", complement, rhs)
			out := temp(e)
			fmt.sbprintfln(&e.b, "  %s = and i64 %s, %s", out, lhs, complement)
			return out
		}
		if v.op == .Slash || v.op == .Percent {
			return emit_divrem(e, v.op, lhs, rhs)
		}
		if (v.op == .Shl || v.op == .Shr) && is_const_expr(v.rhs) {
			count := const_value_of(v.rhs)
			if count >= 64 {
				if v.op == .Shl {
					return "0"
				}
				out := temp(e)
				fmt.sbprintfln(&e.b, "  %s = ashr i64 %s, 63", out, lhs)
				return out
			}
		}
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = %s i64 %s, %s", out, llvm_op(v.op), lhs, rhs)
		return out

	case ^Expr_Call:
		callee := v.callee.(^Expr_Ident)
		symbol := symbol_of(e.c, callee.symbol)
		if symbol != nil && symbol.kind == .Builtin {
			arg := emit_expr(e, v.args[0].value)
			out := temp(e)
			fmt.sbprintfln(
				&e.b,
				"  %s = call i32 (ptr, ...) @printf(ptr @.fmt_int, i64 %s)",
				out,
				arg,
			)
			return "0"
		}
		fmt.sbprintfln(&e.b, "  call void %s()", llvm_proc_name(callee.name))
		return "0"
	}
	// Same gate as `emit_block`: returning `0` here would compile silently and
	// produce the wrong answer.
	panic("an expression the checker did not gate reached the backend")
}

// Division and remainder need two guards. Zero takes M0's explicit failure
// seam; MIN/-1 has the wrapping result required by design.md and must not reach
// LLVM `sdiv`/`srem`, where it would be poison.
@(private = "file")
emit_divrem :: proc(e: ^Emitter, op: Token_Kind, lhs, rhs: string) -> string {
	id := next_id(e)
	zero_label := fmt.aprintf("div.zero.%d", id)
	checked_label := fmt.aprintf("div.checked.%d", id)
	special_label := fmt.aprintf("div.special.%d", id)
	normal_label := fmt.aprintf("div.normal.%d", id)
	done_label := fmt.aprintf("div.done.%d", id)

	is_zero := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", is_zero, rhs)
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", is_zero, zero_label, checked_label)
	fmt.sbprintfln(&e.b, "%s:", zero_label)
	fmt.sbprintln(&e.b, "  call void @llvm.trap()")
	fmt.sbprintln(&e.b, "  unreachable")

	fmt.sbprintfln(&e.b, "%s:", checked_label)
	is_min := temp(e)
	is_neg_one := temp(e)
	is_overflow := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, -9223372036854775808", is_min, lhs)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, -1", is_neg_one, rhs)
	fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", is_overflow, is_min, is_neg_one)
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", is_overflow, special_label, normal_label)

	fmt.sbprintfln(&e.b, "%s:", special_label)
	fmt.sbprintfln(&e.b, "  br label %%%s", done_label)

	fmt.sbprintfln(&e.b, "%s:", normal_label)
	normal_value := temp(e)
	op_name := op == .Slash ? "sdiv" : "srem"
	fmt.sbprintfln(&e.b, "  %s = %s i64 %s, %s", normal_value, op_name, lhs, rhs)
	fmt.sbprintfln(&e.b, "  br label %%%s", done_label)

	fmt.sbprintfln(&e.b, "%s:", done_label)
	out := temp(e)
	special_value := op == .Slash ? "-9223372036854775808" : "0"
	fmt.sbprintfln(
		&e.b,
		"  %s = phi i64 [ %s, %%%s ], [ %s, %%%s ]",
		out,
		special_value,
		special_label,
		normal_value,
		normal_label,
	)
	return out
}

@(private = "file")
llvm_op :: proc(op: Token_Kind) -> string {
	#partial switch op {
	case .Plus:
		return "add"
	case .Minus:
		return "sub"
	case .Star:
		return "mul"
	case .Slash:
		return "sdiv"
	case .Percent:
		return "srem"
	case .Amp:
		return "and"
	case .Pipe:
		return "or"
	case .Tilde:
		return "xor"
	case .Shl:
		return "shl"
	case .Shr:
		return "ashr"
	}
	return "add"
}

@(private = "file")
llvm_global_name :: proc(name: string) -> string {
	return fmt.aprintf("@loke.g.%s", name)
}

@(private = "file")
llvm_proc_name :: proc(name: string) -> string {
	return fmt.aprintf("@loke.p.%s", name)
}

@(private = "file")
replace_ext :: proc(path: string, ext: string) -> string {
	if i := strings.last_index_byte(path, '.'); i >= 0 {
		return strings.concatenate({path[:i], ext})
	}
	return strings.concatenate({path, ext})
}

// clang does llc + link + CRT startup in one process (decision A5, A7). It
// finds the Windows SDK itself, but computes a relative, unusable
// VCToolsInstallDir unless it is run from a developer prompt — so the CRT
// import libraries are located here.
@(private = "file")
link :: proc(c: ^Compiler, ll_path: string, exe_path: string) -> int {
	clang := find_clang()

	command := make([dynamic]string)
	append(&command, clang, ll_path, "-o", exe_path)
	// The module states its triple; clang's default carries an MSVC version
	// suffix, and the mismatch is not interesting.
	append(&command, "-Wno-override-module")
	if lib := msvc_lib_dir(); lib != "" {
		append(&command, "-L", lib)
	}

	state, _, stderr, err := os2.process_exec(
		os2.Process_Desc{command = command[:]},
		context.allocator,
	)
	if err != nil {
		errorf(
			c,
			no_span(),
			"L0402",
			"cannot run `%s`: install LLVM (`winget install LLVM.LLVM`) or set LOKE_CLANG",
			clang,
		)
		return 2
	}
	if state.exit_code != 0 {
		errorf(c, no_span(), "L0403", "`%s` failed:\n%s", clang, string(stderr))
		return 2
	}
	return 0
}

@(private = "file")
find_clang :: proc() -> string {
	if configured := os2.get_env("LOKE_CLANG", context.allocator); configured != "" {
		return configured
	}
	candidates := []string {
		`C:\Program Files\LLVM\bin\clang.exe`,
		`C:\Program Files (x86)\LLVM\bin\clang.exe`,
	}
	for candidate in candidates {
		if os.is_file(candidate) {
			return candidate
		}
	}
	return "clang"
}

// The MSVC toolset's `lib\x64`, or "" when there is nothing to add: a developer
// prompt has already put it in LIB, which lld-link honours.
//
// ponytail: a glob and a string compare instead of vswhere.exe. Picks the
// lexically greatest toolset, which orders real MSVC version numbers correctly
// today. Switch to vswhere if that ever stops holding, or if a build needs a
// specific toolset.
@(private = "file")
msvc_lib_dir :: proc() -> string {
	if os2.get_env("LIB", context.allocator) != "" {
		return ""
	}

	best := ""
	patterns := []string {
		`C:\Program Files\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\lib\x64`,
		`C:\Program Files (x86)\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\lib\x64`,
	}
	for pattern in patterns {
		matches, err := filepath.glob(pattern)
		if err != nil {
			continue
		}
		for match in matches {
			if match > best {
				best = match
			}
		}
	}
	return best
}
