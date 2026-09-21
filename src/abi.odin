package lokec

// The foreign ABI surface. Two things live here:
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

// design.md "Receiver forms" and "Parameter semantics and ABI lowering": an
// `inout` parameter and an immutable receiver both designate the caller's
// storage, so both cross as one pointer. Every definition, call, thunk, and
// synthesized member asks here, so no two of them can classify the same
// parameter differently. Redundant materialization of a small receiver is left
// to the inliner rather than bought back with a second ABI.
param_mode_is_pointer :: proc(mode: Param_Mode) -> bool {
	return mode == .Inout || mode == .Borrow
}

// design.md "Parameter semantics and ABI lowering": an ordinary `value: T`
// holding a managed owner shares the caller's allocations for the call, cloning
// nothing and transferring nothing. So at a call the argument is borrowed until
// the callee returns. It is still a value: no result derives from it, and in
// the callee nothing borrowed from it outlives the call.
//
// This answers about lifetimes, not about the ABI: `param_mode_is_pointer` is
// still what decides how the parameter crosses.
param_borrows_caller_storage :: proc(c: ^Compiler, mode: Param_Mode, type: Type_Id) -> bool {
	return param_mode_is_pointer(mode) || (mode == .Value && type_is_managed(c, type))
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

// design.md "Foreign-ABI-safe types" / "Parameter semantics": whether one
// parameter of a foreign signature crosses as a pointer (`borrow`, `inout`, or
// `@(by_ptr)`), so its pointee need not be ABI-safe itself. A declaration and a
// procedure pointer nested in another foreign type both ask here, so one
// signature cannot be accepted in one place and rejected in the other.
foreign_param_is_pointer :: proc(modes: []Param_Mode, by_ptr: []bool, index: int) -> bool {
	mode := index < len(modes) ? modes[index] : Param_Mode.Value
	return param_mode_is_pointer(mode) || (index < len(by_ptr) && by_ptr[index])
}

// design.md "Foreign-ABI-safe types" / "Parameter semantics": every by-value
// parameter and result of a foreign-convention signature must be ABI-safe. A
// `move` parameter and more than one result have no C representation, and
// neither has a Loke variadic `..T`, which is a slice. A C variadic is
// `@(c_vararg)`, which never joins `params`.
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

// A foreign signature whose type safety could not be answered yet: a procedure
// type written inside a record names that record before its fields exist.
Foreign_Signature :: struct {
	params:       []Type_Id,
	modes:        []Param_Mode,
	by_ptr:       []bool,
	result:       Type_Id,
	result_inout: bool,
	span:         Span,
}

// Answers the signatures deferred while a record they name was still resolving.
// Nothing is on the resolution stack between phases, so none is deferred again.
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

// design.md "Foreign-ABI-safe types". `top_level` is false inside a struct,
// where a fixed array is permitted (it becomes a C array field); at a
// parameter, result, or global it is true, since C adjusts those to pointers.
// On failure `reason` names the member path.
//
// A global or a C-variadic argument is checked once its type has resolved, so
// only a signature (`check_foreign_signature`) can meet a record still resolving
// its fields, and only it has to wait.
foreign_abi_safe :: proc(c: ^Compiler, type: Type_Id, top_level := true) -> (ok: bool, reason: string) {
	ok, reason, _ = abi_safety(c, type, top_level)
	return
}

// `incomplete` means the walk met a record still resolving its own fields, whose
// answer is not known yet; `ok` is then true and says nothing.
@(private = "file")
abi_safety :: proc(c: ^Compiler, type: Type_Id, top_level := true) -> (ok: bool, reason: string, incomplete: bool) {
	visiting := make([]bool, len(c.types), context.temp_allocator)
	saw_cycle := false
	safe, noun, path := abi_walk(c, type, top_level, visiting, &saw_cycle, &incomplete)
	if safe {
		return true, "", incomplete
	}
	if path == "" {
		return false, fmt.tprintf("`%s` is %s", type_name(c, type), noun), false
	}
	return false, fmt.tprintf("member `%s` of `%s` is %s", path, type_name(c, type), noun), false
}

// The Windows x64 classification of one by-value foreign parameter or result,
// confirmed against clang's own IR.
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
		// A top-level array or any union is rejected by `foreign_abi_safe` before
		// emission. They stay here so a missed check still lowers by size, never
		// silently as a direct LLVM aggregate.
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
	incomplete: ^bool,
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
		// Only an address crosses, so reaching a record under walk from inside this
		// signature is a legal cycle, not an infinite-size one. Keep it from
		// switching off the enclosing records' lifecycle check.
		outer_cycle := saw_cycle^
		defer saw_cycle^ = outer_cycle
		// Not `index`: the `defer` above still has to clear this type's own slot.
		for param, position in info.parameters {
			if foreign_param_is_pointer(info.param_modes, info.param_by_ptr, position) {
				continue
			}
			if s, n, p := abi_walk(c, param, true, visiting, saw_cycle, incomplete); !s {
				return false, n, p
			}
		}
		if info.result != INVALID_TYPE && !info.result_inout {
			if s, n, p := abi_walk(c, info.result, true, visiting, saw_cycle, incomplete); !s {
				return false, n, p
			}
		}
		return true, "", ""
	case .Array:
		if top_level {
			return false, "a fixed array (write `[^]T` or `^T` at a C boundary)", ""
		}
		return abi_walk(c, info.element, false, visiting, saw_cycle, incomplete)
	case .Struct:
		// A procedure type written inside a record can name it before its fields
		// exist. Neither the fields nor the lifecycle can answer yet, and asking
		// `type_is_managed` would cache the partial answer for good, so the
		// signature waits for `check_deferred_foreign_signatures`.
		if sym := symbol_of(c, info.symbol); sym != nil && sym.decl != nil && sym.decl.sig_state == .Checking {
			incomplete^ = true
			return true, "", ""
		}
		// A plain struct with a trivial lifecycle whose fields are recursively
		// safe. Fields are checked before the lifecycle, so a managed field is
		// named rather than the whole record; a custom hook with otherwise-safe
		// fields falls through to the lifecycle check.
		for field in info.fields {
			sym := symbol_of(c, field)
			if sym == nil {
				continue
			}
			if s, n, p := abi_walk(c, sym.type, false, visiting, saw_cycle, incomplete); !s {
				name := identifier_text(c, sym.name)
				if p != "" {
					return false, n, fmt.tprintf("%s.%s", name, p)
				}
				return false, n, name
			}
		}
		if !saw_cycle^ && !incomplete^ && type_is_managed(c, under) {
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
