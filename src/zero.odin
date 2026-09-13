// Zero values and required results.
//
// design.md "Zero values": Loke relies on every semantic zero having an
// all-zero runtime representation — container growth, zero-initialized
// allocation, map insertion, globals, and generated cleanup all depend on it.
// A named union earns a zero only through `@(zero=first_variant)`; an enum
// needs a variant represented by 0. Every zero-manufacturing operation must
// check this instead of quietly producing an invalid representation.
//
// design.md "@(require_results)": `@(require_results)` on a type declaration
// makes a bare call statement an error whenever a result carries that type,
// however deeply a value aggregate wraps it.
package lokec

// Reads `@(require_results)` off a type declaration onto the type itself.
apply_type_metadata :: proc(k: ^Checker, d: ^Decl, type: Type_Id) {
	for attribute in d.attributes {
		if len(attribute.path) == 1 && attribute.path[0].text == "require_results" {
			if info := type_of(k.c, type); info != nil {
				info.requires_results = true
			}
		}
	}
}

// Does a value of this type start at the all-zero representation?
type_has_zero :: proc(c: ^Compiler, type: Type_Id) -> bool {
	seen := make(map[Type_Id]bool, context.temp_allocator)
	return type_has_zero_walk(c, type, &seen)
}

@(private = "file")
type_has_zero_walk :: proc(c: ^Compiler, type: Type_Id, seen: ^map[Type_Id]bool) -> bool {
	if type == INVALID_TYPE {
		return true
	}
	under := type_underlying(c, type)
	if seen[under] {
		// Recursive value graphs contribute no non-zero leaf merely by cycling.
		return true
	}
	seen[under] = true
	info := type_of(c, under)
	if info == nil {
		return true
	}
	#partial switch info.kind {
	case .Enum:
		return enum_member_by_value(c, under, int_const(c, 0)) != INVALID_SYMBOL
	case .Union:
		// Tag 0 plus a zero payload is the all-zero representation, so only the
		// first variant can be the zero, and only if its own payload has one.
		if !info.zero_designated || len(info.variants) == 0 {
			return false
		}
		return type_has_zero_walk(c, info.variants[0], seen)
	case .Struct:
		for field in info.fields {
			symbol := symbol_of(c, field)
			if symbol == nil || symbol.initialized_by != INVALID_SYMBOL {
				// design.md "Uninitialized capacity": the storage behind the live
				// prefix holds no values, so the element type needs no zero -- the
				// same reason a dynamic array's capacity imposes none.
				continue
			}
			if !type_has_zero_walk(c, symbol.type, seen) {
				return false
			}
		}
		return true
	case .Array, .Simd:
		// A zero-length array contains no element, so it has a zero whatever the
		// element type is. Every SIMD lane type has a zero, so a vector always
		// does.
		return info.count == 0 || type_has_zero_walk(c, info.element, seen)
	}
	// Dynamic arrays and maps keep their empty all-zero header whatever they
	// hold: capacity is raw storage, not a sequence of initialized values.
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

// Does a value of this type have to be handled rather than discarded? Pointers,
// views, and procedure values don't inherit the property just because the
// pointee or signature mentions it.
type_requires_results :: proc(c: ^Compiler, type: Type_Id) -> bool {
	seen := make(map[Type_Id]bool, context.temp_allocator)
	return type_requires_results_walk(c, type, &seen)
}

@(private = "file")
type_requires_results_walk :: proc(c: ^Compiler, type: Type_Id, seen: ^map[Type_Id]bool) -> bool {
	if type == INVALID_TYPE {
		return false
	}
	if info := type_of(c, type); info != nil && info.requires_results {
		return true
	}
	under := type_underlying(c, type)
	if seen[under] {
		return false
	}
	seen[under] = true
	info := type_of(c, under)
	if info == nil {
		return false
	}
	if info.requires_results {
		return true
	}
	#partial switch info.kind {
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
