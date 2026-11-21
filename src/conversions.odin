// Which types a value may take: implicitly (design.md "Implicit type conversions")
// or as written (design.md "Type conversion").
package lokec

// design.md "Zero values": `nil` is the null unchecked address and nothing
// else. A reference has no null state, and every other zero is written `{}`.
type_accepts_nil :: proc(c: ^Compiler, to: Type_Id) -> bool {
	#partial switch underlying_kind(c, to) {
	case .C_Pointer, .Raw_Pointer:
		return true
	}
	return false
}

// Does a constant of `from` that is `.Nil` stay a value of `to`? The written
// `nil` converts only to an unchecked address; a typed zero keeps its type's.
nil_converts :: proc(c: ^Compiler, from, to: Type_Id) -> bool {
	return from != TYPE_UNTYPED_NIL || type_accepts_nil(c, to)
}

// Is a value of `from` acceptable where `to` is wanted, with no written
// conversion? Representability of an untyped constant is settled by
// `materialize` before this is asked. One conversion depends on the expression
// and is not here: `expr_assignable` adds it.
assignable :: proc(c: ^Compiler, from, to: Type_Id) -> bool {
	if from == to {
		return true
	}
	if from == INVALID_TYPE || to == INVALID_TYPE {
		return false
	}
	if from == TYPE_UNTYPED_NIL {
		return type_accepts_nil(c, to)
	}
	if signature := dyn_proc_signature(c, to); signature != INVALID_TYPE {
		return dyn_proc_accepts(c, from, signature)
	}
	// design.md "SIMD vectors": a scalar splats into a `Simd(T, N)`; nothing
	// else converts. A distinct vector takes only an unfixed constant, as
	// design.md "Distinct types" lets it take one its underlying type would.
	if type_is_simd(c, to) && !type_is_simd(c, from) {
		if type_kind(c, to) != .Simd && !type_is_untyped(c, from) {
			return false
		}
		return assignable(c, from, underlying_info(c, to).element)
	}
	if carrier_weakens_to(c, from, to) || record_drops_labels_to(c, from, to) || union_widens_to(c, from, to) {
		return true
	}
	// design.md "Escape levels".
	if proc_type_weakens_to(c, from, to) {
		return true
	}
	if from == TYPE_UNTYPED_STRING {
		#partial switch underlying_kind(c, to) {
		case .String, .String_View, .CString_View:
			return true
		}
		return false
	}
	if type_views_as(c, from, to) {
		return true
	}
	// design.md "Implicit type conversions": the underlying kind decides, here
	// and for a string above, so a distinct type takes an unfixed constant as
	// its underlying type does. Whether the value fits is `materialize`'s.
	if type_is_untyped(c, from) {
		kind := type_kind(c, from)
		#partial switch underlying_kind(c, to) {
		case .Float:
			// Never a rune constant.
			return kind == .Untyped_Int || kind == .Untyped_Float
		case .Int, .Rune:
			// Never a float constant.
			return kind == .Untyped_Int || kind == .Untyped_Rune
		case .Bool:
			return kind == .Untyped_Bool
		}
		return false
	}
	// Nominal: a distinct pointer converts only as written.
	if to == TYPE_RAWPTR {
		#partial switch type_kind(c, from) {
		case .Pointer, .C_Pointer:
			return true
		}
	}
	return false
}

// design.md "Implicit type conversions": a named procedure or a procedure
// literal takes a distinct procedure type whose signature its own type converts
// to, as an unfixed constant takes a distinct type. `assignable` sees two types
// and cannot ask this: a procedure value that already has a type converts only
// as written, so the expression decides.
procedure_constant_converts :: proc(c: ^Compiler, e: Expr, to: Type_Id) -> bool {
	if e == nil || type_kind(c, to) != .Distinct || underlying_kind(c, to) != .Proc {
		return false
	}
	sym := symbol_of(c, named_value_symbol(e))
	if sym == nil || sym.kind != .Proc {
		return false
	}
	from, dest := expr_base(e).type, type_underlying(c, to)
	return type_kind(c, from) == .Proc && (from == dest || proc_type_weakens_to(c, from, dest))
}

// `assignable` for a value whose expression is known.
expr_assignable :: proc(c: ^Compiler, e: Expr, to: Type_Id) -> bool {
	return assignable(c, expr_base(e).type, to) || procedure_constant_converts(c, e, to)
}

// Is `T(v)` legal? Built-in conversions only.
convertible :: proc(c: ^Compiler, from, to: Type_Id) -> bool {
	if assignable(c, from, to) {
		return true
	}
	source := type_underlying(c, from)
	dest := type_underlying(c, to)
	// design.md "Distinct types": a distinct type converts to and from the type
	// it wraps, itself distinct or not; two others meet only through
	// `hook(convert)`, even when they share a representation.
	if type_kind(c, from) == .Distinct && type_kind(c, to) == .Distinct &&
	   type_of(c, from).element != to && type_of(c, to).element != from {
		return false
	}
	if source == dest {
		return true // between a distinct type and what it wraps, either way
	}
	// design.md "Distinct types": a procedure value crosses in one step with
	// the weakening its signature allows.
	if proc_type_weakens_to(c, source, dest) {
		return true
	}
	source_kind, dest_kind := type_kind(c, source), type_kind(c, dest)
	if dest_kind == .Enum {
		return false // only an existing value of the same enum may convert
	}

	// design.md "SIMD vectors": lane-wise, with the same lane count.
	if source_kind == .Simd || dest_kind == .Simd {
		if source_kind != .Simd || dest_kind != .Simd {
			return false // the scalar splat is the assignable path above
		}
		source_info, dest_info := type_of(c, source), type_of(c, dest)
		if source_info.count != dest_info.count {
			return false
		}
		return convertible(c, source_info.element, dest_info.element)
	}

	numeric :: proc(kind: Type_Kind) -> bool {
		#partial switch kind {
		case .Int, .Float, .Rune, .Enum, .Untyped_Int, .Untyped_Float, .Untyped_Rune:
			return true
		}
		return false
	}
	if numeric(source_kind) && numeric(dest_kind) {
		return true
	}
	pointerish :: proc(kind: Type_Kind) -> bool {
		#partial switch kind {
		case .Pointer, .C_Pointer, .Raw_Pointer:
			return true
		}
		return false
	}
	if pointerish(source_kind) && pointerish(dest_kind) {
		// `^T` never converts directly to `^mut T`.
		if source_kind == .Pointer && dest_kind == .Pointer {
			if !type_of(c, source).mutable && type_of(c, dest).mutable {
				return false
			}
		}
		return true
	}
	return false
}

// design.md "The `unsafe` package": a conversion that gives an unchecked
// address, or another pointee, a checked shape. Losing provenance (anything to
// `rawptr`, a `^T` to `[^]T`) and weakening `^mut T` to `^T` are not.
unchecked_pointer_conversion :: proc(c: ^Compiler, from, to: Type_Id) -> bool {
	source, dest := type_underlying(c, from), type_underlying(c, to)
	if source == dest {
		return false
	}
	if dest_kind := type_kind(c, dest); dest_kind != .Pointer && dest_kind != .C_Pointer {
		return false
	}
	#partial switch type_kind(c, source) {
	case .Raw_Pointer, .C_Pointer:
		return true
	case .Pointer:
		return type_of(c, source).element != type_of(c, dest).element
	}
	return false
}
