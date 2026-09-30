package lokec

// Foreign ABI validation and Win64 argument classification.
// design.md "Foreign-ABI-safe types" and "Calling conventions".

import "core:fmt"

convention_is_foreign :: proc(convention: string) -> bool {
	return convention == "c" || convention == "stdcall"
}

// design.md "Receiver forms": inout and borrowed receivers cross as pointers.
param_mode_is_pointer :: proc(mode: Param_Mode) -> bool {
	return mode == .Inout || mode == .Borrow
}

symbol_param_mode :: proc(c: ^Compiler, symbol: ^Symbol, index: int) -> Param_Mode {
	info := type_of(c, symbol.proc_type)
	if info == nil || index >= len(info.param_modes) {
		return .Value
	}
	return info.param_modes[index]
}

// design.md "Parameter semantics and ABI lowering": managed value parameters
// borrow caller allocations for the call, independently of machine classification.
param_borrows_caller_storage :: proc(c: ^Compiler, mode: Param_Mode, type: Type_Id) -> bool {
	return param_mode_is_pointer(mode) || (mode == .Value && type_is_managed(c, type))
}

// design.md "Calling conventions": the default is spelled as an empty string.
validate_convention :: proc(k: ^Checker, convention: string, span: Span) -> bool {
	switch convention {
	case "", "c", "stdcall":
		return true
	}
	errorf(
		k.c,
		span,
		"L0618",
		"unknown calling convention `%s`; the accepted conventions are `c` and `stdcall`",
		convention,
	)
	return false
}

// design.md "Foreign-ABI-safe types": a pointer's pointee need not be ABI-safe.
foreign_param_is_pointer :: proc(modes: []Param_Mode, by_ptr: []bool, index: int) -> bool {
	mode := index < len(modes) ? modes[index] : Param_Mode.Value
	return param_mode_is_pointer(mode) || (index < len(by_ptr) && by_ptr[index])
}

// design.md "Parameter semantics and ABI lowering": move and Loke variadics have no C form.
check_foreign_signature :: proc(
	k: ^Checker,
	params: []Type_Id,
	modes: []Param_Mode,
	by_ptr: []bool,
	result: Type_Id,
	result_inout: bool,
	span: Span,
) {
	for mode in modes {
		#partial switch mode {
		case .Move:
			errorf(k.c, span, "L0621", "a foreign parameter cannot use `move`: a C call acquires no cleanup responsibility")
		case .Variadic:
			errorf(k.c, span, "L0619", "a foreign parameter is not ABI-safe: a variadic `..T` is a slice, which has no C form")
		}
	}
	check_foreign_signature_types(k, Foreign_Signature{params, modes, by_ptr, result, result_inout, span})
}

// A signature that depends on a record still resolving its fields.
Foreign_Signature :: struct {
	params:       []Type_Id,
	modes:        []Param_Mode,
	by_ptr:       []bool,
	result:       Type_Id,
	result_inout: bool,
	span:         Span,
}

check_deferred_foreign_signatures :: proc(k: ^Checker) {
	count := len(k.deferred_foreign_signatures)
	for index in 0 ..< count {
		check_foreign_signature_types(k, k.deferred_foreign_signatures[index])
	}
	remove_range(&k.deferred_foreign_signatures, 0, count)
}

@(private = "file")
check_foreign_signature_types :: proc(k: ^Checker, sig: Foreign_Signature) {
	Unsafe :: struct {
		what, reason: string,
	}
	unsafe := make([dynamic]Unsafe, 0, 2, context.temp_allocator)
	for param, index in sig.params {
		mode := index < len(sig.modes) ? sig.modes[index] : Param_Mode.Value
		if mode == .Move || mode == .Variadic || foreign_param_is_pointer(sig.modes, sig.by_ptr, index) {
			continue
		}
		ok, reason, incomplete := abi_safety(k.c, param)
		if incomplete {
			defer_foreign_signature(k, sig)
			return
		}
		if !ok {
			append(&unsafe, Unsafe{"parameter", reason})
		}
	}
	if sig.result != INVALID_TYPE && !sig.result_inout {
		ok, reason, incomplete := abi_safety(k.c, sig.result)
		if incomplete {
			defer_foreign_signature(k, sig)
			return
		}
		if !ok {
			append(&unsafe, Unsafe{"result", reason})
		}
	}
	for u in unsafe {
		errorf(k.c, sig.span, "L0619", "a foreign %s is not ABI-safe: %s", u.what, u.reason)
	}
}

@(private = "file")
defer_foreign_signature :: proc(k: ^Checker, sig: Foreign_Signature) {
	if cap(k.deferred_foreign_signatures) == 0 {
		k.deferred_foreign_signatures = make([dynamic]Foreign_Signature, 0, 4, k.c.semantic_allocator)
	}
	append(&k.deferred_foreign_signatures, sig)
}

// Arrays may cross as record fields; reason identifies the unsafe member.
foreign_abi_safe :: proc(c: ^Compiler, type: Type_Id, top_level := true) -> (ok: bool, reason: string) {
	ok, reason, _ = abi_safety(c, type, top_level)
	return
}

@(private = "file")
Abi_Walk :: struct {
	visiting, safe: []bool,
	saw_cycle, incomplete: bool,
	cycles: int, // Counts cycles across procedure-pointer scopes.
}

// Incomplete answers must be checked again after fields resolve.
@(private = "file")
abi_safety :: proc(c: ^Compiler, type: Type_Id, top_level := true) -> (ok: bool, reason: string, incomplete: bool) {
	walk := Abi_Walk{
		visiting = make([]bool, len(c.types), context.temp_allocator),
		safe = make([]bool, len(c.types), context.temp_allocator),
	}
	safe, noun, path := abi_walk(c, type, top_level, &walk)
	if safe {
		return true, "", walk.incomplete
	}
	if path == "" {
		return false, fmt.tprintf("`%s` is %s", type_name(c, type), noun), false
	}
	return false, fmt.tprintf("member `%s` of `%s` is %s", path, type_name(c, type), noun), false
}

Abi_Pass :: enum {
	Direct,   // a scalar or pointer, passed as its own LLVM type
	Bool_I1,  // a direct C `_Bool`: `i1 zeroext` in the signature, one byte stored
	Reg_Int,  // an aggregate of size 1/2/4/8, passed in one integer register `iN`
	Indirect, // any other aggregate: a pointer to caller-owned storage, `sret` result
}

abi_pass :: proc(c: ^Compiler, type: Type_Id) -> Abi_Pass {
	under := type_underlying(c, type)
	info := type_of(c, under)
	if info == nil {
		return .Direct
	}
	#partial switch info.kind {
	case .Bool:
		return .Bool_I1
	case .Struct, .Array, .Union:
		switch type_size(c, under) {
		case 1, 2, 4, 8:
			return .Reg_Int
		}
		return .Indirect
	}
	return .Direct
}

abi_reg_bits :: proc(c: ^Compiler, type: Type_Id) -> u64 {
	return type_size(c, type_underlying(c, type)) * 8
}

@(private = "file")
abi_walk :: proc(
	c: ^Compiler,
	type: Type_Id,
	top_level: bool,
	walk: ^Abi_Walk,
) -> (safe: bool, noun: string, path: string) {
	if type == INVALID_TYPE {
		return false, "not a resolved type", ""
	}
	under := type_underlying(c, type)
	info := type_of(c, under)
	if info == nil {
		return false, "not a resolved type", ""
	}
	if top_level && info.kind == .Array {
		return false, "a fixed array (write `[^]T` or `^T` at a C boundary)", ""
	}
	index := int(under)
	marked := false
	if index >= 0 && index < len(walk.visiting) {
		if walk.safe[index] { return true, "", "" }
		if walk.visiting[index] {
			// The finite-size pass diagnoses by-value cycles.
			walk.saw_cycle = true
			walk.cycles += 1
			return true, "", ""
		}
		walk.visiting[index] = true
		marked = true
	}
	cycles_before := walk.cycles
	defer if marked {
		walk.visiting[index] = false
		// Provisional answers from cycles or unresolved fields are never cached.
		if safe && !walk.saw_cycle && !walk.incomplete && walk.cycles == cycles_before {
			walk.safe[index] = true
		}
	}
	// Every Type_Kind must define its boundary rule.
	switch info.kind {
	case .Int:
		// Win64 128-bit scalar lowering is not implemented.
		if info.bits > 64 {
			return false, "an integer wider than 64 bits on the Win64 C ABI", ""
		}
		return true, "", ""
	case .Simd:
		// design.md "SIMD vectors": vectors do not cross foreign boundaries.
		return false, "a SIMD vector", ""
	case .Enum:
		if !info.enum_backing_explicit {
			return false, "an enum without an explicit integer backing type", ""
		}
		return abi_walk(c, info.element, false, walk)
	case .Float, .Rune, .Bool, .Raw_Pointer, .Pointer, .C_Pointer, .CString_View:
		return true, "", ""
	case .Proc:
		if !convention_is_foreign(info.convention) {
			return false, "a `loke`-convention procedure pointer", ""
		}
		// A pointer cycle must not suppress an enclosing record's lifecycle check.
		outer_cycle := walk.saw_cycle
		defer walk.saw_cycle = outer_cycle
		for param, position in info.parameters {
			if foreign_param_is_pointer(info.param_modes, info.param_by_ptr, position) {
				continue
			}
			if s, n, p := abi_walk(c, param, true, walk); !s {
				return false, n, p
			}
		}
		if info.result != INVALID_TYPE && !info.result_inout {
			if s, n, p := abi_walk(c, info.result, true, walk); !s {
				return false, n, p
			}
		}
		return true, "", ""
	case .Array:
		return abi_walk(c, info.element, false, walk)
	case .Struct:
		// Resolve fields before asking for layout or lifecycle.
		if sym := symbol_of(c, info.symbol); sym != nil && sym.decl != nil && sym.decl.sig_state == .Checking {
			walk.incomplete = true
			return true, "", ""
		}
		for field in info.fields {
			sym := symbol_of(c, field)
			if sym == nil {
				continue
			}
			if s, n, p := abi_walk(c, sym.type, false, walk); !s {
				name := identifier_text(c, sym.name)
				if p != "" {
					return false, n, fmt.tprintf("%s.%s", name, p)
				}
				return false, n, name
			}
		}
		if !walk.saw_cycle && !walk.incomplete {
			if type_is_managed(c, under) {
				return false, "a record with a non-trivial lifecycle", ""
			}
			if type_size(c, under) == 0 {
				return false, "a zero-sized record with no compatible Win64 C layout", ""
			}
		}
		return true, "", ""
	case .String:
		return false, "a managed `string`", ""
	case .String_View:
		return false, "a `string_view` (two words, not a C type)", ""
	case .Slice:
		return false, "a slice", ""
	case .Dynamic_Array:
		return false, "a managed dynamic array", ""
	case .Map:
		return false, "a managed map", ""
	case .Union:
		return false, "a tagged union", ""
	case .Any_View:
		return false, "an `any_view`", ""
	case .Dyn:
		return false, "a `dyn` interface value", ""
	case .Interface:
		return false, "an interface, which has no runtime ABI", ""
	case .Typeid:
		return false, "a `typeid`", ""
	case .Type:
		return false, "a compile-time `type`, which has no runtime ABI", ""
	case .Allocator, .Allocator_Error:
		return false, "a Loke-specific runtime handle", ""
	case .Invalid, .Void, .Distinct,
	     .Untyped_Int, .Untyped_Float, .Untyped_Bool, .Untyped_Rune, .Untyped_Nil,
	     .Untyped_String:
		return false, "not foreign-ABI-safe", ""
	}
	return false, "not foreign-ABI-safe", ""
}
