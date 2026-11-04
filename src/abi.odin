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

// design.md "Foreign-ABI-safe types": a pointer's pointee need not be ABI-safe.
foreign_param_is_pointer :: proc(modes: []Param_Mode, by_ptr: []bool, index: int) -> bool {
	mode := index < len(modes) ? modes[index] : Param_Mode.Value
	return param_mode_is_pointer(mode) || (index < len(by_ptr) && by_ptr[index])
}

report_unknown_convention :: proc(k: ^Checker, convention: string, span: Span) {
	errorf(k.c, span, "L0618", "unknown calling convention `%s`; the accepted conventions are `c` and `stdcall`", convention)
}

// design.md "Calling conventions": the default is spelled as an empty string.
// design.md "Parameter semantics and ABI lowering": move and Loke variadics have no C form.
check_signature_convention :: proc(
	k: ^Checker,
	convention: string,
	params: []Type_Id,
	modes: []Param_Mode,
	by_ptr: []bool,
	result: Type_Id,
	result_inout: bool,
	span: Span,
) {
	if convention == "" {
		return
	}
	if !convention_is_foreign(convention) {
		report_unknown_convention(k, convention, span)
		return
	}
	for param, index in params {
		#partial switch modes[index] {
		case .Move:
			errorf(k.c, span, "L0621", "a foreign parameter cannot use `move`: a C call acquires no cleanup responsibility")
		case .Variadic:
			errorf(k.c, span, "L0619", "a foreign parameter is not ABI-safe: a variadic `..T` is a slice, which has no C form")
		case:
			if !foreign_param_is_pointer(modes, by_ptr, index) {
				check_foreign_part(k, Foreign_Part{param, "parameter", span})
			}
		}
	}
	if result != INVALID_TYPE && !result_inout {
		check_foreign_part(k, Foreign_Part{result, "result", span})
	}
}

// A by-value part of a foreign signature, and what it is called in a report.
Foreign_Part :: struct {
	type: Type_Id,
	what: string,
	span: Span,
}

check_deferred_foreign_parts :: proc(k: ^Checker) {
	count := len(k.deferred_foreign_parts)
	for index in 0 ..< count {
		check_foreign_part(k, k.deferred_foreign_parts[index])
	}
	remove_range(&k.deferred_foreign_parts, 0, count)
}

@(private = "file")
check_foreign_part :: proc(k: ^Checker, part: Foreign_Part) {
	ok, reason, incomplete := abi_safety(k.c, part.type)
	if incomplete {
		if cap(k.deferred_foreign_parts) == 0 {
			k.deferred_foreign_parts = make([dynamic]Foreign_Part, 0, 4, k.c.semantic_allocator)
		}
		append(&k.deferred_foreign_parts, part)
	} else if !ok {
		errorf(k.c, part.span, "L0619", "a foreign %s is not ABI-safe: %s", part.what, reason)
	}
}

// reason names the unsafe member.
foreign_abi_safe :: proc(c: ^Compiler, type: Type_Id) -> (ok: bool, reason: string) {
	ok, reason, _ = abi_safety(c, type)
	return
}

@(private = "file")
Abi_Walk :: struct {
	// Each record and array reached: true while it is still open.
	seen:       map[Type_Id]bool,
	// A by-value cycle or an unresolved type, which are reported elsewhere, so a
	// record's lifecycle and layout are no answer yet.
	reported:   bool,
	incomplete: bool,
}

// Incomplete answers must be checked again after fields resolve.
@(private = "file")
abi_safety :: proc(c: ^Compiler, type: Type_Id) -> (ok: bool, reason: string, incomplete: bool) {
	walk := Abi_Walk{seen = make(map[Type_Id]bool, context.temp_allocator)}
	safe, noun, path := abi_walk(c, type, true, &walk)
	if safe {
		return true, "", walk.incomplete
	}
	if path == "" {
		return false, fmt.tprintf("`%s` is %s", type_name(c, type), noun), false
	}
	return false, fmt.tprintf("member `%s` of `%s` is %s", path, type_name(c, type), noun), false
}

// Whether the walk has been at this type: an unsafe member would have ended it, and
// the finite-size pass diagnoses a by-value cycle. If not, it is now open.
@(private = "file")
abi_seen :: proc(walk: ^Abi_Walk, type: Type_Id) -> bool {
	if open, seen := walk.seen[type]; seen {
		walk.reported ||= open
		return true
	}
	walk.seen[type] = true
	return false
}

@(private = "file")
abi_walk :: proc(
	c: ^Compiler,
	type: Type_Id,
	top_level: bool,
	walk: ^Abi_Walk,
) -> (safe: bool, noun: string, path: string) {
	under := type_underlying(c, type)
	info := type_of(c, under)
	if info == nil || info.kind == .Invalid {
		walk.reported = true
		return true, "", ""
	}
	if top_level && info.kind == .Array {
		return false, "a fixed array (write `[^]T` or `^T` at a C boundary)", ""
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
	case .Box:
		// An owner whose drop releases through a Loke allocator.
		return false, "a `box`", ""
	case .Enum:
		if !info.enum_backing_explicit {
			return false, "an enum without an explicit integer backing type", ""
		}
		return abi_walk(c, info.element, false, walk)
	case .Float:
		// design.md "Foreign-ABI-safe types": safe only where the target ABI classifies it.
		if info.bits == 16 {
			return false, "not classified by the Win64 C ABI", ""
		}
		return true, "", ""
	case .Rune, .Bool, .Raw_Pointer, .Pointer, .C_Pointer, .CString_View:
		return true, "", ""
	case .Proc:
		if !convention_is_foreign(info.convention) {
			return false, "a `loke`-convention procedure pointer", ""
		}
		// Its signature is checked where the type is written.
		return true, "", ""
	case .Array:
		if abi_seen(walk, under) {
			return true, "", ""
		}
		defer walk.seen[under] = false
		return abi_walk(c, info.element, false, walk)
	case .Struct:
		// Resolve fields before asking for layout or lifecycle.
		if record_resolving(c, info) {
			walk.incomplete = true
			return true, "", ""
		}
		if abi_seen(walk, under) {
			return true, "", ""
		}
		defer walk.seen[under] = false
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
		if !walk.reported && !walk.incomplete {
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
		// design.md "Foreign-ABI-safe types": a nullable C pointer.
		if some := union_niche_variant(c, under); some >= 0 {
			payload := info.variants[some]
			#partial switch underlying_kind(c, payload) {
			case .Pointer, .CString_View, .Proc:
				return abi_walk(c, payload, false, walk)
			}
		}
		return false, "a tagged union", ""
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
