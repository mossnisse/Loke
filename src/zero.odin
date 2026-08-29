// Zero values and required results.
//
// design.md "Zero values": Loke relies on every semantic zero having an
// all-zero runtime representation. Container growth, zero-initialized
// allocation, map insertion, globals, and generated cleanup all depend on it.
// A named union earns a zero only through `@(zero=first_variant)`, so a type
// may now legitimately have *no* zero, and every operation that manufactures
// one has to say so instead of quietly producing tag 0.
//
// design.md "Required results": `@(require_results)` on a type declaration
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
type_has_zero :: proc(c: ^Compiler, type: Type_Id, depth := 0) -> bool {
	if type == INVALID_TYPE || depth > 32 {
		return true
	}
	info := type_of(c, type_underlying(c, type))
	if info == nil {
		return true
	}
	#partial switch info.kind {
	case .Union:
		// Tag 0 plus a zero payload is the all-zero representation, so only the
		// first variant can be the zero, and only if its own payload has one.
		if !info.zero_designated || len(info.variants) == 0 {
			return false
		}
		return type_has_zero(c, info.variants[0], depth + 1)
	case .Struct:
		for field in info.fields {
			symbol := symbol_of(c, field)
			if symbol != nil && !type_has_zero(c, symbol.type, depth + 1) {
				return false
			}
		}
		return true
	case .Array:
		// A zero-length array contains no element, so it has a zero whatever the
		// element type is.
		return info.count == 0 || type_has_zero(c, info.element, depth + 1)
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
	add_notef(k.c, span, "give the union a zero with `@(zero=first_variant)`, or construct the value explicitly")
	return false
}

// Does a value of this type have to be handled rather than discarded? Pointers,
// views, and procedure values do not inherit the property merely because the
// pointee or the signature mentions it.
type_requires_results :: proc(c: ^Compiler, type: Type_Id, depth := 0) -> bool {
	if type == INVALID_TYPE || depth > 32 {
		return false
	}
	if info := type_of(c, type); info != nil && info.requires_results {
		return true
	}
	under := type_underlying(c, type)
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
			if symbol != nil && type_requires_results(c, symbol.type, depth + 1) {
				return true
			}
		}
	case .Union:
		for variant in info.variants {
			if type_requires_results(c, variant, depth + 1) {
				return true
			}
		}
	case .Array:
		return type_requires_results(c, info.element, depth + 1)
	}
	return false
}
