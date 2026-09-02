package lokec

// The foreign ABI surface (m7-plan step 3). Two things live here:
//
//   - Calling-convention acceptance: `""` (default `loke`), `"c"`, and
//     `"stdcall"` are the only spellings a signature may carry, every other
//     rejected by name. `loke` keeps LLVM's own aggregate lowering unchanged;
//     a foreign convention triggers Windows x64 classification in the emitter.
//
//   - The foreign-ABI-safety predicate (design.md "Foreign-ABI-safe types"),
//     one recursive rule reused by foreign parameters, results, globals,
//     procedure-pointer signatures, exported declarations, and C variadic
//     arguments. Its diagnostic names the offending member path, not just the
//     outermost type.

import "core:fmt"

// A foreign convention is any accepted spelling other than the default `loke`.
convention_is_foreign :: proc(convention: string) -> bool {
	return convention == "c" || convention == "stdcall"
}

// design.md "Calling conventions": `"c"` and `"stdcall"` are the two foreign
// spellings; `loke` is written as the empty string. Everything else is a typo
// or an unimplemented convention and is rejected by name (L0618).
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

// design.md "Foreign-ABI-safe types" / "Parameter semantics": every by-value
// parameter and result of a foreign-convention signature must be ABI-safe (a
// `move` parameter and more than one result have no C representation). An
// `inout` parameter lowers to a pointer, so its pointee need not be ABI-safe
// itself (m7-plan step 3).
check_foreign_signature :: proc(
	k: ^Checker,
	params: []Type_Id,
	modes: []Param_Mode,
	by_ptr: []bool,
	result: Type_Id,
	result_inout: bool,
	span: Span,
) {
	for param, index in params {
		mode := index < len(modes) ? modes[index] : Param_Mode.Value
		#partial switch mode {
		case .Move:
			errorf(k.c, span, "L0621", "a foreign parameter cannot use `move`: a C call acquires no cleanup responsibility")
			continue
		case .Inout, .Variadic:
			continue
		}
		if index < len(by_ptr) && by_ptr[index] {
			continue
		}
		if ok, reason := foreign_abi_safe(k.c, param); !ok {
			errorf(k.c, span, "L0619", "a foreign parameter is not ABI-safe: %s", reason)
		}
	}
	if result != INVALID_TYPE && !result_inout {
		if ok, reason := foreign_abi_safe(k.c, result); !ok {
			errorf(k.c, span, "L0619", "a foreign result is not ABI-safe: %s", reason)
		}
	}
}

// design.md "Foreign-ABI-safe types". `top_level` is false inside a struct,
// where a fixed array is permitted (it becomes a C array field); at a
// parameter, result, or global it is true, since C adjusts those to pointers.
// On failure `reason` names the member path.
foreign_abi_safe :: proc(c: ^Compiler, type: Type_Id, top_level := true) -> (ok: bool, reason: string) {
	visiting := make([]bool, len(c.types), context.temp_allocator)
	saw_cycle := false
	safe, noun, path := abi_walk(c, type, top_level, visiting, &saw_cycle)
	if safe {
		return true, ""
	}
	if path == "" {
		return false, fmt.tprintf("`%s` is %s", type_name(c, type), noun)
	}
	return false, fmt.tprintf("member `%s` of `%s` is %s", path, type_name(c, type), noun)
}

// The Windows x64 classification of one by-value foreign parameter or result
// (m7-plan decision "Win64 classification"), confirmed against clang's own IR.
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

// The integer register width (in bits) a `Reg_Int` aggregate occupies: its
// byte-exact size, 8/16/32/64.
abi_reg_bits :: proc(c: ^Compiler, type: Type_Id) -> u64 {
	return type_size(c, type_underlying(c, type)) * 8
}

// Returns whether `type` is safe, and on failure the noun describing the
// offending leaf plus the dotted field path from `type` down to it.
@(private = "file")
abi_walk :: proc(
	c: ^Compiler,
	type: Type_Id,
	top_level: bool,
	visiting: []bool,
	saw_cycle: ^bool,
) -> (safe: bool, noun: string, path: string) {
	if type == INVALID_TYPE {
		return false, "not a resolved type", ""
	}
	under := type_underlying(c, type)
	info := type_of(c, under)
	if info == nil {
		return false, "not a resolved type", ""
	}
	index := int(under)
	marked := false
	if index >= 0 && index < len(visiting) {
		if visiting[index] {
			// Signature resolution precedes the finite-size pass. Let that pass own
			// the diagnostic for an illegal by-value cycle without recursing here.
			saw_cycle^ = true
			return true, "", ""
		}
		visiting[index] = true
		marked = true
	}
	defer if marked {
		visiting[index] = false
	}
	// Exhaustive on purpose: this is the whole answer to "may this cross a C
	// boundary", so a new `Type_Kind` states its own answer rather than
	// inheriting the rejection below.
	switch info.kind {
	case .Int:
		// Clang's Win64 ABI does not lower `__int128` as Loke's direct `i128`.
		// Reject it until the target-specific indirect/vector classification exists.
		if info.bits > 64 {
			return false, "an integer wider than 64 bits on the Win64 C ABI", ""
		}
		return true, "", ""
	case .Simd:
		// design.md "SIMD vectors": "`Simd(T, N)` is **not foreign-ABI-safe**" —
		// a vector's C classification is target- and extension-dependent in a way
		// this subset deliberately excludes. A binding passes a pointer to an
		// array instead.
		return false, "a SIMD vector", ""
	case .Float, .Rune, .Bool, .Enum, .Raw_Pointer, .Pointer, .C_Pointer, .CString_View:
		// Scalars and pointers pass as themselves; an enum has integer backing;
		// a pointer's pointee need not be safe because only an address crosses.
		return true, "", ""
	case .Proc:
		// A procedure pointer is safe only when it itself uses a foreign
		// convention and its whole signature is safe.
		if !convention_is_foreign(info.convention) {
			return false, "a `loke`-convention procedure pointer", ""
		}
		// Not `index`: the `defer` above still has to clear this type's own slot.
		for param, position in info.parameters {
			mode := position < len(info.param_modes) ? info.param_modes[position] : Param_Mode.Value
			if mode == .Inout || (position < len(info.param_by_ptr) && info.param_by_ptr[position]) {
				continue
			}
			if s, n, p := abi_walk(c, param, true, visiting, saw_cycle); !s {
				return false, n, p
			}
		}
		if info.result != INVALID_TYPE && !info.result_inout {
			if s, n, p := abi_walk(c, info.result, true, visiting, saw_cycle); !s {
				return false, n, p
			}
		}
		return true, "", ""
	case .Array:
		if top_level {
			return false, "a fixed array (write `[^]T` or `^T` at a C boundary)", ""
		}
		return abi_walk(c, info.element, false, visiting, saw_cycle)
	case .Struct:
		// A plain struct with a trivial lifecycle whose fields are recursively
		// safe. Fields are checked before the lifecycle, so a managed field is
		// named rather than the whole record; a custom hook with otherwise-safe
		// fields falls through to the lifecycle check.
		for field in info.fields {
			sym := symbol_of(c, field)
			if sym == nil {
				continue
			}
			if s, n, p := abi_walk(c, sym.type, false, visiting, saw_cycle); !s {
				name := identifier_text(c, sym.name)
				if p != "" {
					return false, n, fmt.tprintf("%s.%s", name, p)
				}
				return false, n, name
			}
		}
		if !saw_cycle^ && type_is_managed(c, under) {
			return false, "a record with a non-trivial lifecycle", ""
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
		// `under` has already resolved a `distinct`, and nothing untyped survives
		// checking, so none of these is a written parameter type.
		return false, "not foreign-ABI-safe", ""
	}
	return false, "not foreign-ABI-safe", ""
}
