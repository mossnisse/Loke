// Zero values and required results.
//
// design.md "Types with no zero value": every operation that manufactures a zero
// asks `type_has_zero` first.
package lokec

type_has_zero :: proc(c: ^Compiler, type: Type_Id) -> bool {
	seen: Type_Walk
	defer delete(seen)
	return type_has_zero_walk(c, type, &seen)
}

// A cycle contributes no non-zero leaf.
@(private = "file")
type_has_zero_walk :: proc(c: ^Compiler, type: Type_Id, seen: ^Type_Walk) -> bool {
	info := type_of(c, type)
	if info == nil || !type_walk_enter(seen, type, info) {
		return true
	}
	if type_is_non_null(c, type) {
		return false
	}
	#partial switch info.kind {
	case .Distinct:
		return type_has_zero_walk(c, info.element, seen)
	case .Enum:
		return enum_member_by_value(c, type, int_const(c, 0)) != INVALID_SYMBOL
	case .Union:
		// The payload until `check_union_zero_payload` has judged it.
		return info.zero_designated && type_has_zero_walk(c, info.variants[0], seen)
	case .Struct:
		for field in info.fields {
			symbol := symbol_of(c, field)
			// design.md "Uninitialized capacity": storage past the live prefix holds
			// no values.
			if symbol == nil || symbol.initialized_by != INVALID_SYMBOL {
				continue
			}
			// design.md "Required fields": zero is not a value this field may hold.
			if symbol.required || !type_has_zero_walk(c, symbol.type, seen) {
				return false
			}
		}
	case .Array:
		return info.count == 0 || type_has_zero_walk(c, info.element, seen)
	}
	// Scalars, SIMD vectors, and container headers, whose capacity is raw storage.
	return true
}

// The one diagnostic every zero-manufacturing operation raises.
require_type_has_zero :: proc(k: ^Checker, type: Type_Id, span: Span, what: string) -> bool {
	if type_has_zero(k.c, type) {
		return true
	}
	errorf(
		k.c, span, "L0424",
		"`%s` has no zero value, so it cannot be produced by %s",
		type_name(k.c, type), what,
	)
	add_notef(k.c, span, "construct the value explicitly, or provide a zero variant (an enum member represented by 0, or a union's `@(zero=first_variant)`)")
	return false
}

type_requires_results :: proc(c: ^Compiler, type: Type_Id) -> bool {
	seen: Type_Walk
	defer delete(seen)
	return type_requires_results_walk(c, type, &seen)
}

// Only values held inline: pointers, views, procedure values, and heap
// containers don't inherit the requirement from what they reach.
@(private = "file")
type_requires_results_walk :: proc(c: ^Compiler, type: Type_Id, seen: ^Type_Walk) -> bool {
	info := type_of(c, type)
	if info == nil || !type_walk_enter(seen, type, info) {
		return false
	}
	if info.requires_results {
		return true
	}
	#partial switch info.kind {
	case .Distinct, .Array:
		return type_requires_results_walk(c, info.element, seen)
	case .Struct:
		for field in info.fields {
			symbol := symbol_of(c, field)
			if symbol != nil && type_requires_results_walk(c, symbol.type, seen) {
				return true
			}
		}
	case .Union:
		for variant in info.variants {
			if type_requires_results_walk(c, variant, seen) {
				return true
			}
		}
	}
	return false
}
