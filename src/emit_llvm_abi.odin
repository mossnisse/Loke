// LLVM type representation and foreign procedure ABI lowering.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

// Preserve an external symbol byte-for-byte; LLVM quotes names with punctuation.
// One that starts `loke.` is quoted too, to read apart from a generated name
// (`llvm_linkage`).
@(private)
llvm_external_name :: proc(name: string) -> string {
	plain := llvm_plain_name(name) && !(name[0] >= '0' && name[0] <= '9') && !strings.has_prefix(name, "loke.")
	return plain ? fmt.aprintf("@%s", name) : fmt.aprintf("@\"%s\"", llvm_escape(name))
}

@(private)
foreign_llvm_name :: proc(sym: ^Symbol) -> string {
	return llvm_external_name(sym.link_name)
}

// Emit each foreign symbol once, unless this module already declares the name
// or goes on to declare or define it: the binding then refers to that one.
@(private)
emit_foreign_declarations :: proc(e: ^Emitter) {
	seen := make(map[string]bool, context.temp_allocator)
	for symbol_id, name in e.names {
		if sym := symbol_of(e.c, symbol_id);
		   sym != nil && !sym.is_foreign && (sym.kind == .Proc || sym.kind == .Var) {
			seen[name] = true
		}
	}
	// Only `emit_preamble`'s declarations have been written so far.
	written := strings.to_string(e.b)
	for line in strings.split_lines_iterator(&written) {
		if strings.has_prefix(line, "declare ") {
			name := line[strings.index_byte(line, '@'):strings.index_byte(line, '(')]
			seen[strings.clone(name, context.temp_allocator)] = true
		}
	}
	seen["@loke_rt_v1_program_tls_cleanup"] = true
	seen["@loke_rt_v1_sink_write"] = true
	seen["@loke_rt_v1_write_std"] = true
	if any_provider_selected(e.c) {
		seen["@loke_rt_v1_program_init"] = true
	}
	if e.c.build_mode != .Obj {
		seen["@wmain"] = true
	}
	for id in e.foreign_symbols {
		sym := symbol_of(e.c, id)
		if name := foreign_llvm_name(sym); !seen[name] {
			seen[name] = true
			emit_foreign_declare(e, sym)
		}
	}
}

@(private = "file")
emit_foreign_declare :: proc(e: ^Emitter, sym: ^Symbol) {
	name := foreign_llvm_name(sym)
	if sym.kind != .Proc {
		fmt.sbprintfln(&e.b, "%s = external global %s", name, llvm_type(e, sym.type))
		return
	}
	proc_info := type_of(e.c, sym.proc_type)
	ret, indirect := foreign_result_llvm(e, sym.result, proc_info)
	params := make([dynamic]string, 0, len(sym.params) + 2)
	if indirect {
		append(&params, fmt.aprintf("ptr sret(%s) align %d", llvm_type(e, sym.result), type_align(e.c, sym.result)))
	}
	for parameter, index in sym.params {
		append(&params, foreign_param_llvm(e, proc_info, parameter, index, attributes = true))
	}
	if proc_info.c_vararg {
		append(&params, "...")
	}
	fmt.sbprintfln(&e.b, "declare %s %s(%s)", ret, name, strings.join(params[:], ", "))
}

// ------------------------------------------------------------ LLVM types --

// One named definition per record. LLVM reads a by-value member's name ahead of
// its definition, so the order is the type table's.
@(private)
emit_struct_definitions :: proc(e: ^Emitter) {
	for index in 0 ..< len(e.c.types) {
		define_struct(e, Type_Id(index))
	}
	fmt.sbprintln(&e.b, "")
}

@(private = "file")
define_struct :: proc(e: ^Emitter, type: Type_Id) {
	info := type_of(e.c, type)
	// A labelled record is spelled by its unlabelled counterpart's definition.
	if info == nil || record_abi_type(e.c, type) != type {
		return
	}
	// A generic record's own shell is a placeholder for its instances and has no
	// layout of its own.
	if sym := symbol_of(e.c, info.symbol); sym != nil && sym.generic {
		return
	}
	#partial switch info.kind {
	case .Union:
		if type_is_supported(e.c, type) {
			fmt.sbprintfln(&e.b, "%s = type %s", struct_name(e, type), union_storage_definition(e, type))
		}
		return
	case .Slice:
		// Only the read-only variant is defined; `[]mut T` shares its name.
		if !type_is_supported(e.c, type) || carrier_abi_type(e.c, type) != type {
			return
		}
	case .Dyn:
		// The same for a dyn view: one struct per interface application, named by
		// the read-only variant, whatever capabilities the program spells.
		if carrier_abi_type(e.c, type) != type {
			return
		}
	case .Struct:
	case:
		return
	}
	fmt.sbprintfln(&e.b, "%s = type %s", struct_name(e, type), struct_body(e, type, info))
}

// A `@(packed)`/`@(align=N)` record is spelled so LLVM's layout matches the
// checker's; GEP indices equal field indices in every form.
@(private = "file")
struct_body :: proc(e: ^Emitter, type: Type_Id, info: ^Type_Info) -> string {
	byte_members := record_uses_byte_members(e, type, info)
	angled := info.packed && !byte_members
	b := strings.builder_make()
	strings.write_string(&b, angled ? "<{" : "{")
	for field, index in info.fields {
		symbol := symbol_of(e.c, field)
		if index > 0 {
			strings.write_string(&b, ",")
		}
		if byte_members {
			fmt.sbprintf(&b, " [%d x i8]", type_size(e.c, symbol.type))
		} else {
			fmt.sbprintf(&b, " %s", llvm_type(e, symbol.type))
		}
	}
	// The zero-length tail raises alignment.
	if info.align > info.natural_align {
		if len(info.fields) > 0 {
			strings.write_string(&b, ",")
		}
		fmt.sbprintf(&b, " [0 x i%d]", info.align * 8)
	}
	strings.write_string(&b, angled ? " }>" : " }")
	return strings.to_string(b)
}

// Whether this record is the combined `@(packed, align=N)` body, whose LLVM
// members are byte arrays that keep packed offsets. It computes the layout, so
// the record's cached alignment and size may be read after it.
@(private)
record_uses_byte_members :: proc(e: ^Emitter, type: Type_Id, info: ^Type_Info) -> bool {
	type_size(e.c, type)
	return info.packed && info.align > info.natural_align
}

@(private)
struct_name :: proc(e: ^Emitter, raw: Type_Id) -> string {
	// Both capabilities of a carrier share one backend type, so `[]mut T` and
	// `dyn mut I` weakening is the no-op the design says it is, and so do a
	// labelled record and its unlabelled counterpart.
	type := record_abi_type(e.c, carrier_abi_type(e.c, raw))
	if name, ok := e.struct_names[type]; ok {
		return name
	}
	info := type_of(e.c, type)
	// An instantiation or a compiler-made type has its own backend spelling; a
	// written name may still mention punctuation LLVM would need quoting for.
	text := type_spelling(e, type)
	if text == "" && info != nil && info.name != INVALID_IDENTIFIER {
		text = llvm_safe(identifier_text(e.c, info.name))
	}
	prefix := info != nil && info.kind == .Union ? "union" : "struct"
	name := fmt.aprintf("%%%s.%s.%d", prefix, text == "" ? "anon" : text, int(type))
	e.struct_names[type] = name
	return name
}

llvm_type :: proc(e: ^Emitter, type: Type_Id) -> string {
	// Nothing untyped should reach the backend, but taking its default type here
	// keeps a leak from silently becoming a zero of the wrong width.
	under := type_underlying(e.c, default_type(e.c, type))
	info := type_of(e.c, under)
	if info == nil {
		return "i64"
	}
	// Exhaustive on purpose: `i64` is a plausible-looking wrong width, so a new
	// `Type_Kind` has to choose a spelling here rather than inherit one.
	switch info.kind {
	case .Void:
		return "void"
	case .Bool:
		// `i1` everywhere; LLVM stores it in one byte.
		return "i1"
	case .Int, .Enum, .Allocator_Error:
		return fmt.aprintf("i%d", type_bits(e.c, under))
	case .Typeid, .Type:
		// design.md: an ordinary runtime scalar holding one concrete type's unique
		// identifier; zero is nil. A compile-time `type` borrows the spelling,
		// reaching the backend only as the `type` member of a `meta.Field`
		// descriptor, whose values are folded before anything is emitted.
		return "i64"
	case .Rune:
		return "i32"
	case .Float:
		switch info.bits {
		case 16:
			return "half"
		case 32:
			return "float"
		}
		return "double"
	case .Pointer, .C_Pointer, .Raw_Pointer, .Proc, .Allocator, .CString_View, .Box:
		return "ptr"
	case .String:
		return STRING_TYPE
	case .String_View:
		return STRING_VIEW_TYPE
	case .Dynamic_Array, .Map:
		// Both headers are the same four words, so they share one backend type
		// exactly as the two slice capabilities do.
		return CONTAINER_TYPE
	case .Array:
		return fmt.aprintf("[%d x %s]", info.count, llvm_type(e, info.element))
	case .Simd:
		// design.md "SIMD vectors": `Simd(T, N)` lowers to LLVM's own `<N x T>`,
		// which is where the lane-wise operators and the vector alignment rule
		// both come from.
		return fmt.aprintf("<%d x %s>", info.count, simd_lane_llvm_type(e, info))
	case .Struct, .Union, .Dyn, .Slice:
		// A two-word erased view or slice is an ordinary aggregate to the backend.
		return struct_name(e, under)
	case .Invalid, .Distinct, .Interface,
	     .Untyped_Int, .Untyped_Float, .Untyped_Bool, .Untyped_Rune, .Untyped_Nil,
	     .Untyped_String:
		// `type_underlying` has already resolved a `distinct` and `default_type`
		// every untyped constant, so arriving here means a compile-time-only type
		// escaped the checker. Say which one instead of picking a width for it.
		backend_fail(e, fmt.aprintf("`%s` has no backend representation", type_name(e.c, type)))
	}
	return "i64"
}

// A vector lane's backend type. It is the element's own spelling except for a
// lane mask: design.md gives `Simd(bool, N)` one byte per lane, while a scalar
// `bool` is `i1`.
simd_lane_llvm_type :: proc(e: ^Emitter, info: ^Type_Info) -> string {
	if info.kind == .Simd && type_kind(e.c, type_underlying(e.c, info.element)) == .Bool {
		return "i8"
	}
	return llvm_type(e, info.element)
}

// ----------------------------------------------------------- foreign calls --

// The `define` signature of a foreign-convention procedure's body under the
// Windows x64 classification, which no caller may inline
// (`emit_entry_guard`). A result larger than one register becomes a hidden
// leading `sret` pointer and a `void` return; `e.abi_sret` records it.
@(private)
emit_foreign_signature :: proc(e: ^Emitter, symbol: ^Symbol, llvm_name: string) {
	ret, params, sret := foreign_signature(e, symbol)
	e.abi_sret = sret
	fmt.sbprintf(&e.b, "define %s%s %s(%s) noinline", llvm_linkage(llvm_name), ret, llvm_name, strings.join(params, ", "))
	// design.md "@(cold)": the body is `noinline` already.
	fmt.sbprintln(&e.b, cold_attributes(symbol) != "" ? " cold {" : " {")
}

// The return type and the parameters, each with its attributes and name, as
// a `define` writes them and a call that forwards them writes them again, and
// the name of the hidden `sret` pointer among them, or "".
@(private = "file")
foreign_signature :: proc(e: ^Emitter, symbol: ^Symbol) -> (ret: string, params: []string, sret: string) {
	out := make([dynamic]string, 0, len(symbol.params) + 1)
	proc_info := type_of(e.c, symbol.proc_type)
	indirect: bool
	ret, indirect = foreign_result_llvm(e, symbol.result, proc_info)
	if indirect {
		sret = "%arg.sret"
		append(&out, fmt.aprintf(
			"ptr sret(%s) align %d %s", llvm_type(e, symbol.result), type_align(e.c, symbol.result), sret,
		))
	}
	for parameter, index in symbol.params {
		append(&out, fmt.aprintf("%s %%arg%d", foreign_param_llvm(e, proc_info, parameter, index, attributes = true), index))
	}
	return ret, out[:], sret
}

// design.md "Floating-point operators": MXCSR's control bits, the rounding
// mode, flush-to-zero, denormals-are-zero, and the exception masks, and their
// value in Loke's environment, which is also the Windows x64 default. The six
// bits below are the exception flags, which the environment leaves free.
@(private = "file")
MXCSR_CONTROL :: 0xffc0
@(private = "file")
MXCSR_LOKE :: 0x1f80
@(private = "file")
MXCSR_FLAGS :: 0x3f

@(private)
emit_foreign_entry_guard :: proc(e: ^Emitter, symbol: ^Symbol, llvm_name, body: string) {
	ret, params, _ := foreign_signature(e, symbol)
	emit_entry_guard(e, llvm_name, ret, params, body)
}

// The externally callable half of a function foreign code enters, a Loke
// procedure with a foreign calling convention or a generated entry such as
// `loke_rt_v1_program_init`, under its own name: foreign code may enter it in
// any environment, so it sets Loke's when the caller's differs, calls `body`
// with the same arguments, and restores the caller's control bits on return,
// keeping the flags raised meanwhile. `body` is `noinline`, so none of its
// arithmetic can be moved into this function and run before the switch; this
// one does no floating-point arithmetic of its own.
@(private)
emit_entry_guard :: proc(e: ^Emitter, llvm_name, ret: string, params: []string, body: string) {
	// Calls `body`, binding what it returns to `result`, and gives the `ret` that
	// returns the same. A `ret` names the type without the return attribute a
	// `define` carries.
	call_body :: proc(e: ^Emitter, ret, body, arguments, result: string) -> (ret_line: string) {
		if ret == "void" {
			fmt.sbprintfln(&e.b, "  call void %s(%s)", body, arguments)
			return "  ret void"
		}
		fmt.sbprintfln(&e.b, "  %s = call %s %s(%s)", result, ret, body, arguments)
		return fmt.aprintf("  ret %s %s", strings.trim_prefix(ret, "zeroext "), result)
	}

	arguments := strings.join(params, ", ")
	open_function(e, "define %s%s %s(%s)", llvm_linkage(llvm_name), ret, llvm_name, arguments)
	fmt.sbprintln(&e.b, "  %mxcsr = alloca i32, align 4")
	fmt.sbprintln(&e.b, "  call void @llvm.x86.sse.stmxcsr(ptr %mxcsr)")
	fmt.sbprintln(&e.b, "  %mxcsr.caller = load i32, ptr %mxcsr, align 4")
	fmt.sbprintfln(&e.b, "  %%mxcsr.control = and i32 %%mxcsr.caller, %d", MXCSR_CONTROL)
	fmt.sbprintfln(&e.b, "  %%mxcsr.ours = icmp eq i32 %%mxcsr.control, %d", MXCSR_LOKE)
	fmt.sbprintln(&e.b, "  br i1 %mxcsr.ours, label %same, label %switched")

	fmt.sbprintln(&e.b, "same:")
	fmt.sbprintln(&e.b, call_body(e, ret, body, arguments, "%result"))

	fmt.sbprintln(&e.b, "switched:")
	fmt.sbprintfln(&e.b, "  %%mxcsr.held = and i32 %%mxcsr.caller, %d", MXCSR_FLAGS)
	fmt.sbprintfln(&e.b, "  %%mxcsr.loke = or i32 %%mxcsr.held, %d", MXCSR_LOKE)
	fmt.sbprintln(&e.b, "  store i32 %mxcsr.loke, ptr %mxcsr, align 4")
	fmt.sbprintln(&e.b, "  call void @llvm.x86.sse.ldmxcsr(ptr %mxcsr)")
	ret_line := call_body(e, ret, body, arguments, "%switched.result")
	fmt.sbprintln(&e.b, "  call void @llvm.x86.sse.stmxcsr(ptr %mxcsr)")
	fmt.sbprintln(&e.b, "  %mxcsr.after = load i32, ptr %mxcsr, align 4")
	fmt.sbprintfln(&e.b, "  %%mxcsr.raised = and i32 %%mxcsr.after, %d", MXCSR_FLAGS)
	fmt.sbprintln(&e.b, "  %mxcsr.back = or i32 %mxcsr.control, %mxcsr.raised")
	fmt.sbprintln(&e.b, "  store i32 %mxcsr.back, ptr %mxcsr, align 4")
	fmt.sbprintln(&e.b, "  call void @llvm.x86.sse.ldmxcsr(ptr %mxcsr)")
	fmt.sbprintln(&e.b, ret_line)
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
}

// design.md "Floating-point operators": with `-debug`, a call into foreign code
// that returns with Loke's environment changed panics, naming the callee, after
// putting the environment back so the report and the unwind run in it. A
// procedure Loke defines guards its own entry, so a call to one is not checked.
@(private = "file")
emit_foreign_environment_check :: proc(e: ^Emitter, symbol: ^Symbol) {
	if !e.c.debug || (symbol != nil && !symbol.is_foreign) {
		return
	}
	slot := alloca(e, "i32")
	fmt.sbprintfln(&e.b, "  call void @llvm.x86.sse.stmxcsr(ptr %s)", slot)
	value, control, kept := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = load i32, ptr %s, align 4", value, slot)
	fmt.sbprintfln(&e.b, "  %s = and i32 %s, %d", control, value, MXCSR_CONTROL)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, %d", kept, control, MXCSR_LOKE)
	changed, after := new_label(e, "fenv.changed"), new_label(e, "fenv.kept")
	branch_if(e, kept, after, changed)
	place_label(e, changed)
	flags, restored := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = and i32 %s, %d", flags, value, MXCSR_FLAGS)
	fmt.sbprintfln(&e.b, "  %s = or i32 %s, %d", restored, flags, MXCSR_LOKE)
	fmt.sbprintfln(&e.b, "  store i32 %s, ptr %s, align 4", restored, slot)
	fmt.sbprintfln(&e.b, "  call void @llvm.x86.sse.ldmxcsr(ptr %s)", slot)
	call := "a foreign call through a procedure value"
	if symbol != nil {
		call = fmt.aprintf("the foreign call to `%s`", identifier_text(e.c, symbol.name))
	}
	emit_panic(e, fmt.aprintf("%s returned with the floating-point environment changed", call))
	place_label(e, after)
}

// A foreign procedure's LLVM return type, or `void` and `indirect` for a result
// through an `sret` pointer the signature adds.
@(private = "file")
foreign_result_llvm :: proc(e: ^Emitter, result: Type_Id, info: ^Type_Info) -> (ret: string, indirect: bool) {
	if result == INVALID_TYPE {
		return "void", false
	}
	if info != nil && info.result_inout {
		return "ptr", false
	}
	switch abi_pass(e.c, result) {
	case .Indirect:
		return "void", true
	case .Reg_Int:
		return fmt.aprintf("i%d", abi_reg_bits(e.c, result)), false
	case .Bool_I1:
		return "zeroext i1", false
	case .Direct:
		return llvm_type(e, result), false
	}
	unreachable()
}

@(private = "file")
foreign_param_llvm :: proc(e: ^Emitter, info: ^Type_Info, parameter: Type_Id, index: int, attributes: bool) -> string {
	// design.md: a `self: ^` receiver, `inout T`, and `@(by_ptr) T` cross as a pointer.
	if foreign_param_is_pointer(info.param_modes, info.param_by_ptr, index) {
		return "ptr"
	}
	switch abi_pass(e.c, parameter) {
	case .Bool_I1:
		// A parameter attribute follows the type, unlike the return attribute.
		return attributes ? "i1 zeroext" : "i1"
	case .Reg_Int:
		return fmt.aprintf("i%d", abi_reg_bits(e.c, parameter))
	case .Indirect:
		return "ptr"
	case .Direct:
		return llvm_type(e, parameter)
	}
	unreachable()
}

// Materializes a foreign value parameter's addressable storage from its incoming
// register, and returns the slot the body binds to. A register-sized aggregate is
// stored byte-exact through an integer; a larger one is already a caller-owned
// pointer the immutable value parameter uses directly.
@(private)
emit_foreign_param_slot :: proc(e: ^Emitter, parameter: Type_Id, index: int) -> string {
	arg := fmt.aprintf("%%arg%d", index)
	pass := abi_pass(e.c, parameter)
	if pass == .Indirect {
		return arg
	}
	slot := fmt.aprintf("%%p%d.%d", index, next_id(e))
	alloca_named(e, slot, llvm_type(e, parameter))
	if pass == .Reg_Int {
		fmt.sbprintfln(
			&e.b, "  store i%d %s, ptr %s, align %d",
			abi_reg_bits(e.c, parameter), arg, slot, type_align(e.c, parameter),
		)
	} else {
		store(e, parameter, arg, slot)
	}
	return slot
}

// The classified `ret` of a foreign-convention procedure: a
// register-sized aggregate result is read back byte-exact as an integer, a
// larger one has already been written through `sret`.
@(private)
emit_foreign_return :: proc(e: ^Emitter) {
	if e.result_type == INVALID_TYPE {
		fmt.sbprintln(&e.b, "  ret void")
		return
	}
	result := e.result_type
	slot := e.result_slot
	if e.result_inout {
		v := load(e, "ptr", slot)
		fmt.sbprintfln(&e.b, "  ret ptr %s", v)
		return
	}
	switch abi_pass(e.c, result) {
	case .Indirect:
		fmt.sbprintln(&e.b, "  ret void")
	case .Reg_Int:
		bits := abi_reg_bits(e.c, result)
		v := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load i%d, ptr %s, align %d", v, bits, slot, type_align(e.c, result))
		fmt.sbprintfln(&e.b, "  ret i%d %s", bits, v)
	case .Bool_I1, .Direct:
		v := load_place(e, result, slot)
		fmt.sbprintfln(&e.b, "  ret %s %s", llvm_type(e, result), v)
	}
}

// A value spilled to a slot, as the `ptr <slot>` operand that crosses for it.
@(private = "file")
foreign_spill_operand :: proc(e: ^Emitter, type: Type_Id, operand: string) -> string {
	slot := alloca(e, llvm_type(e, type))
	store(e, type, operand, slot)
	return fmt.aprintf("ptr %s", slot)
}

// A by-value argument under the ordinary classification, as a `<type> <value>`
// operand.
@(private = "file")
foreign_value_operand :: proc(e: ^Emitter, type: Type_Id, operand: string) -> string {
	switch abi_pass(e.c, type) {
	case .Bool_I1:
		return fmt.aprintf("i1 zeroext %s", operand)
	case .Reg_Int:
		slot, loaded := temp(e), temp(e)
		bits, align := abi_reg_bits(e.c, type), type_align(e.c, type)
		alloca_named(e, slot, llvm_type(e, type))
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s, align %d", llvm_type(e, type), operand, slot, align)
		fmt.sbprintfln(&e.b, "  %s = load i%d, ptr %s, align %d", loaded, bits, slot, align)
		return fmt.aprintf("i%d %s", bits, loaded)
	case .Indirect:
		return foreign_spill_operand(e, type, operand)
	case .Direct:
		return fmt.aprintf("%s %s", llvm_type(e, type), operand)
	}
	unreachable()
}

// design.md "`@(c_vararg)`": the C default argument promotions. Returns the
// promoted `<type> <value>` operand.
@(private = "file")
emit_c_vararg_promote :: proc(e: ^Emitter, type: Type_Id, operand: string) -> string {
	under := type_underlying(e.c, type)
	info := type_of(e.c, under)
	if info == nil {
		return fmt.aprintf("%s %s", llvm_type(e, type), operand)
	}
	#partial switch info.kind {
	case .Float:
		if info.bits == 32 {
			out := temp(e)
			fmt.sbprintfln(&e.b, "  %s = fpext float %s to double", out, operand)
			return fmt.aprintf("double %s", out)
		}
	case .Bool:
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i32", out, operand)
		return fmt.aprintf("i32 %s", out)
	case .Int, .Enum:
		if bits := type_bits(e.c, under); bits < 32 {
			out := temp(e)
			op := type_signed(e.c, under) ? "sext" : "zext"
			fmt.sbprintfln(&e.b, "  %s = %s i%d %s to i32", out, op, bits, operand)
			return fmt.aprintf("i32 %s", out)
		}
	case .Struct, .Array, .Union:
		return foreign_value_operand(e, under, operand)
	}
	return fmt.aprintf("%s %s", llvm_type(e, type), operand)
}

// The explicit LLVM function type a variadic call names: `<ret> (<fixed...>, ...)`,
// matching the `declare`'s parameter types without their call-site attributes.
@(private = "file")
foreign_call_type :: proc(e: ^Emitter, callee_type: ^Type_Info, has_sret: bool) -> string {
	ret, _ := foreign_result_llvm(e, callee_type.result, callee_type)
	parts := make([dynamic]string, 0, len(callee_type.parameters) + 2)
	if has_sret {
		append(&parts, "ptr")
	}
	for parameter, index in callee_type.parameters {
		append(&parts, foreign_param_llvm(e, callee_type, parameter, index, attributes = false))
	}
	append(&parts, "...")
	return fmt.aprintf("%s (%s)", ret, strings.join(parts[:], ", "))
}

// The operands of a foreign call, ahead of them the `sret` pointer it writes its
// result through, if any.
@(private = "file")
foreign_arguments :: proc(e: ^Emitter, callee_type: ^Type_Info, operands: []string, bound: []Expr, sret: string) -> []string {
	args := make([dynamic]string, 0, len(operands) + 1)
	if sret != "" {
		append(&args, fmt.aprintf(
			"ptr sret(%s) align %d %s", llvm_type(e, callee_type.result), type_align(e.c, callee_type.result), sret,
		))
	}
	for operand, index in operands {
		// design.md "`@(c_vararg)`": arguments past the fixed parameters are concrete
		// C variadics with the default promotions applied here.
		if callee_type.c_vararg && index >= len(callee_type.parameters) {
			append(&args, emit_c_vararg_promote(e, expr_base(bound[index]).type, operand))
			continue
		}
		parameter := callee_type.parameters[index]
		// An `inout` operand is already the address; a `@(by_ptr)` value gets one.
		switch {
		case foreign_param_is_pointer(callee_type.param_modes, nil, index):
			append(&args, fmt.aprintf("ptr %s", operand))
		case foreign_param_is_pointer(callee_type.param_modes, callee_type.param_by_ptr, index):
			append(&args, foreign_spill_operand(e, parameter, operand))
		case:
			append(&args, foreign_value_operand(e, parameter, operand))
		}
	}
	return args[:]
}

// What a foreign call's result is to its caller, from what the call returned or
// wrote through `sret`.
@(private = "file")
foreign_call_result :: proc(e: ^Emitter, callee_type: ^Type_Info, call, sret: string) -> string {
	result := callee_type.result
	if result == INVALID_TYPE {
		return "0"
	}
	if callee_type.result_inout {
		return call
	}
	#partial switch abi_pass(e.c, result) {
	case .Indirect:
		return load_place(e, result, sret)
	case .Reg_Int:
		slot, v := temp(e), temp(e)
		align := type_align(e.c, result)
		alloca_named(e, slot, llvm_type(e, result))
		fmt.sbprintfln(&e.b, "  store i%d %s, ptr %s, align %d", abi_reg_bits(e.c, result), call, slot, align)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s, align %d", v, llvm_type(e, result), slot, align)
		return v
	}
	return call
}

@(private)
emit_foreign_call :: proc(
	e: ^Emitter, callee: string, callee_type: ^Type_Info, operands: []string,
	symbol: ^Symbol, bound: []Expr,
) -> string {
	ret, indirect := foreign_result_llvm(e, callee_type.result, callee_type)
	sret := ""
	if indirect {
		sret = temp(e)
		alloca_named(e, sret, llvm_type(e, callee_type.result))
	}
	args := strings.join(foreign_arguments(e, callee_type, operands, bound, sret), ", ")

	// A variadic call names the explicit function type in place of the plain
	// return type; a fixed call names only the return type.
	head := callee_type.c_vararg ? foreign_call_type(e, callee_type, indirect) : ret
	call := ""
	if ret == "void" {
		fmt.sbprintfln(&e.b, "  call %s %s(%s)", head, callee, args)
	} else {
		call = temp(e)
		fmt.sbprintfln(&e.b, "  %s = call %s %s(%s)", call, head, callee, args)
	}
	emit_foreign_environment_check(e, symbol)
	return foreign_call_result(e, callee_type, call, sret)
}
