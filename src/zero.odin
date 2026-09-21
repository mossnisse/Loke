// Zero values and required results.
//
// design.md "Zero values": every semantic zero must be all-zero bits, so every
// operation that manufactures one asks `type_has_zero` first.
// design.md "@(require_results)": a type carrying it makes every value
// aggregate containing it require its results too.
package lokec

apply_type_metadata :: proc(k: ^Checker, d: ^Decl, type: Type_Id) {
	if !has_attribute(d.attributes, "require_results") {
		return
	}
	if info := type_of(k.c, type); info != nil {
		info.requires_results = true
	}
}

type_has_zero :: proc(c: ^Compiler, type: Type_Id) -> bool {
	seen := make(map[Type_Id]bool, context.temp_allocator)
	return type_has_zero_walk(c, type, &seen)
}

@(private = "file")
type_has_zero_walk :: proc(c: ^Compiler, type: Type_Id, seen: ^map[Type_Id]bool) -> bool {
	// A cycle contributes no non-zero leaf.
	if type == INVALID_TYPE || seen[type] {
		return true
	}
	seen[type] = true
	info := type_of(c, type)
	if info == nil {
		return true
	}
	#partial switch info.kind {
	case .Distinct:
		return type_has_zero_walk(c, info.element, seen)
	case .Enum:
		return enum_member_by_value(c, type, int_const(c, 0)) != INVALID_SYMBOL
	case .Union:
		// A generic instance can bind a zero variant's payload to a type with no zero.
		return info.zero_designated && len(info.variants) > 0 && type_has_zero_walk(c, info.variants[0], seen)
	case .Struct:
		for field in info.fields {
			symbol := symbol_of(c, field)
			// design.md "Uninitialized capacity": storage past the live prefix holds
			// no values.
			if symbol == nil || symbol.initialized_by != INVALID_SYMBOL {
				continue
			}
			if !type_has_zero_walk(c, symbol.type, seen) {
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
	seen := make(map[Type_Id]bool, context.temp_allocator)
	return type_requires_results_walk(c, type, &seen)
}

// Only values held inline: pointers, views, procedure values, and heap
// containers don't inherit the requirement from what they reach.
@(private = "file")
type_requires_results_walk :: proc(c: ^Compiler, type: Type_Id, seen: ^map[Type_Id]bool) -> bool {
	if type == INVALID_TYPE || seen[type] {
		return false
	}
	seen[type] = true
	info := type_of(c, type)
	if info == nil {
		return false
	}
	if info.requires_results {
		return true
	}
	#partial switch info.kind {
	case .Distinct:
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
	case .Array:
		return type_requires_results_walk(c, info.element, seen)
	}
	return false
}
