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

// The all-zero bytes of a fixed array field whose elements are not yet values.
// Invalid element constants preserve that distinction for the evaluator, while
// the backend writes their inert representation as `zeroinitializer`.
capacity_const :: proc(c: ^Compiler, type: Type_Id) -> Const_Value {
	info := underlying_info(c, type)
	elements := make([]Const_Value, info.count, c.semantic_allocator)
	return aggregate_const(c, type, elements)
}

// Constant construction is held to the evaluator's scratch budget, counted as
// the elements `const_element_count` measures.
MAX_CONST_ELEMENTS :: u64(EVAL_MAX_MEMORY / size_of(Const_Value))

// The constants a value of `type` is built from, counting through arrays and
// struct fields; saturates rather than overflowing.
const_element_count :: proc(c: ^Compiler, type: Type_Id) -> u64 {
	info := underlying_info(c, type)
	if info == nil {
		return 1
	}
	#partial switch info.kind {
	case .Array, .Simd:
		element := const_element_count(c, info.element)
		if info.count > max(u64) / element {
			return max(u64)
		}
		return max(info.count * element, 1)
	case .Union:
		if !info.zero_designated || info.size_state == .Cyclic {
			return 1
		}
		element := const_element_count(c, info.variants[0])
		return element == max(u64) ? element : element + 1
	case .Struct:
		if info.size_state == .Cyclic {
			return 1
		}
		total := u64(1)
		for field in info.fields {
			if symbol := symbol_of(c, field); symbol != nil {
				total += min(const_element_count(c, symbol.type), max(u64) - total)
			}
		}
		return total
	}
	return 1
}

// The compile-time zero value of every runtime type (design.md "Zero
// values"). Recursive for aggregates. Without `build`, only whether one exists
// is answered, and an aggregate comes back as an empty `.Aggregate`; with it,
// an aggregate past `MAX_CONST_ELEMENTS` is not built and reports false.
zero_const :: proc(c: ^Compiler, type: Type_Id, build := true) -> (Const_Value, bool) {
	under := type_underlying(c, type)
	info := type_of(c, under)
	if info == nil {
		return Const_Value{}, false
	}
	if build && const_element_count(c, type) > MAX_CONST_ELEMENTS {
		return Const_Value{}, false
	}
	#partial switch info.kind {
	case .Bool:
		return bool_const(false), true
	case .Int:
		return int_const(c, 0), true
	case .Rune:
		return rune_const(bi_from_i64(c, 0)), true
	case .Float:
		return float_const(0, info.bits), true
	case .Enum:
		return int_const(c, 0), type_has_zero(c, type)
	case .Typeid:
		// design.md "`type` and `typeid`": `Invalid`, numerically 0.
		return type_const(INVALID_TYPE), true
	// A slice constant's elements are the viewed ones, so the empty view is the
	// all-zero `.Nil` rather than an aggregate of its two fields.
	case .Pointer, .C_Pointer, .Raw_Pointer, .Proc, .Allocator, .Allocator_Error,
	     .CString_View, .Slice:
		return nil_const(), true
	case .Union:
		// With no designated zero, all-zero bits are no value of the type, as for a
		// reference.
		if !info.zero_designated {
			return nil_const(), true
		}
		if info.size_state == .Cyclic {
			return Const_Value{}, false
		}
		payload := Const_Value{}
		if info.variants[0] != TYPE_VOID {
			ok: bool
			payload, ok = zero_const(c, info.variants[0], build)
			if !ok {
				return Const_Value{}, false
			}
		}
		if !build {
			return Const_Value{kind = .Aggregate}, true
		}
		return union_const(c, type, 0, payload), true
	case .String, .String_View:
		return Const_Value{kind = .String}, true
	case .Array, .Simd:
		element := Const_Value{}
		if info.count > 0 {
			ok: bool
			element, ok = zero_const(c, info.element, build)
			if !ok {
				return Const_Value{}, false
			}
		}
		if !build {
			return Const_Value{kind = .Aggregate}, true
		}
		elements := make([]Const_Value, info.count, c.semantic_allocator)
		for &slot in elements {
			slot = element
		}
		return aggregate_const(c, type, elements), true
	case .Struct, .Dyn, .Dynamic_Array, .Map:
		// A record containing itself by value was already reported and has no
		// zero value to build.
		if info.size_state == .Cyclic {
			return Const_Value{}, false
		}
		// All-zero fields: a nil view, or an empty container.
		elements: []Const_Value
		if build {
			elements = make([]Const_Value, len(info.fields), c.semantic_allocator)
		}
		for field, index in info.fields {
			symbol := symbol_of(c, field)
			if symbol == nil {
				return Const_Value{}, false
			}
			if symbol.initialized_by != INVALID_SYMBOL {
				if build {
					elements[index] = capacity_const(c, symbol.type)
				}
				continue
			}
			element, ok := zero_const(c, symbol.type, build)
			if !ok {
				return Const_Value{}, false
			}
			if build {
				elements[index] = element
			}
		}
		if !build {
			return Const_Value{kind = .Aggregate}, true
		}
		return aggregate_const(c, type, elements), true
	}
	return Const_Value{}, false
}
