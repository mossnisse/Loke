// Composite literals: a struct, array, slice, dynamic array, or map written out
// (design.md "Struct literals", "Fixed arrays", "Slice literals", "Dynamic arrays",
// "Maps"), and the constant one folds to.
package lokec

import "core:slice"
import "core:strings"

check_composite :: proc(k: ^Checker, v: ^Expr_Composite, expected: Type_Id) {
	target := expected
	if v.capture != nil {
		// design.md "Capture literals": a literal of the record it lowers to.
		target = lower_capture_literal(k, v)
		if target == INVALID_TYPE {
			return
		}
	} else if array, is_array := v.type_expr.(^Type_Array); is_array && array.length == nil {
		// `[?]T` takes its length from the literal it types.
		element := resolve_type_syntax(k, array.elem)
		if element == INVALID_TYPE {
			report_unresolved_type(k, array.elem)
			return
		}
		length := len(v.elements)
		if composite_is_designated(v) {
			// The keys set the length, so a key is held to what could be built.
			needed, resolved := resolve_array_slots(k, v, i64(MAX_CONST_ELEMENTS))
			if !resolved {
				return
			}
			length = needed
		}
		array.denoted_type = array_of(k.c, element, u64(length))
		array.resolution.kind = .Type
		target = array.denoted_type
	} else if v.type_expr != nil {
		target = resolve_type_syntax(k, v.type_expr)
		if target == INVALID_TYPE {
			// `resolve_type_syntax` is silent, so a written type reports here.
			report_unresolved_type(k, v.type_expr)
			return
		}
	}
	if target == INVALID_TYPE {
		errorf(k.c, v.span, "L0376", "this composite literal needs a type")
		return
	}
	if !gate_type(k, target, v.span) {
		return
	}
	// Reports `L0364` here for a value whose layout is past the maximum.
	type_size(k.c, target, v.span)

	info := underlying_info(k.c, target)
	if info == nil {
		return
	}
	v.type = target
	v.addressable = true
	v.assignable = false
	v.immutable = .Temporary
	// A container's operation table holds clone beside drop, so even one that is
	// never copied needs both.
	if type_is_managed(k.c, target) {
		contribute_lifecycle_members(k, target)
	}

	// The empty container is its all-zero header. An empty slice is the empty view
	// unless a written type asks for a literal (design.md "Zero values").
	if len(v.elements) == 0 &&
	   (info.kind == .Dynamic_Array || info.kind == .Map || (info.kind == .Slice && v.type_expr == nil)) {
		v.const_value, _ = zero_const(k.c, target)
		return
	}

	#partial switch info.kind {
	case .Struct:
		outer_capture := k.body.building_capture
		if v.capture != nil {
			k.body.building_capture = target
		}
		check_struct_literal(k, v, target, info)
		k.body.building_capture = outer_capture
	case .Array, .Simd:
		// design.md "SIMD vectors": one element per lane, as for an array.
		check_array_literal(k, v, target, info)
	case .Slice:
		check_slice_literal(k, v, target, info)
	case .Dynamic_Array:
		check_dynamic_literal(k, v, target, info)
	case .Map:
		check_map_literal(k, v, target, info)
	case:
		// design.md "Zero values": `{}` is any type's zero value.
		if len(v.elements) == 0 {
			if !require_type_has_zero(k, target, v.span, "`{}`") {
				v.type = INVALID_TYPE
				return
			}
			if zero, ok := zero_const(k.c, target); ok {
				v.const_value = zero
				return
			}
		}
		errorf(k.c, v.span, "L0376", "`%s` cannot be built from a composite literal", type_name(k.c, target))
		v.type = INVALID_TYPE
	}
}

// Checks a literal's element against `type`, and records how it reaches its slot.
// A capture literal's lowering checked its elements to type its fields.
@(private = "file")
check_composite_element :: proc(k: ^Checker, v: ^Expr_Composite, index: int, type: Type_Id) -> bool {
	value := v.elements[index].value
	// design.md "Returned constructions": an element of a returned literal is
	// returned with it. A capture's entries state their own modes, and a
	// designated array element may fill several slots.
	returned := v.returned && v.capture == nil && v.slot_ends == nil
	if returned {
		mark_returned(value)
	}
	checked := v.capture != nil ? materialize_value_expr(k, value, type, "initialise") : check_value_expr(k, value, type, "initialise")
	if checked {
		if returned {
			v.elements[index].value = transfer_returned_operand(k, &v.base, value, type)
		}
		// The storage owns its elements, so a borrowed one is cloned.
		classify_composite_element(k, v, index, type)
	}
	return checked
}

// A slice literal has its written type, never the destination's (design.md
// "Slice literals"). It views a hidden fixed array in the enclosing scope.
@(private = "file")
check_slice_literal :: proc(k: ^Checker, v: ^Expr_Composite, target: Type_Id, info: ^Type_Info) {
	if v.type_expr == nil {
		// The braces are not in the format string, where `{` is a directive.
		errorf(k.c, v.span, "L0479", "a slice literal must be written with its type, as in `%s`", concat(k.c, type_name(k.c, target), "{ ... }"))
		v.type = INVALID_TYPE
		return
	}
	v.backing = array_of(k.c, info.element, u64(len(v.elements)))
	ok := true
	for element, index in v.elements {
		if element.key != nil {
			errorf(k.c, element.span, "L0479", "a slice literal has no keyed elements")
			ok = false
			continue
		}
		if !check_composite_element(k, v, index, info.element) {
			ok = false
		}
	}
	if !ok {
		v.type = INVALID_TYPE
		return
	}
	v.addressable = false
}

@(private = "file")
check_struct_literal :: proc(k: ^Checker, v: ^Expr_Composite, target: Type_Id, info: ^Type_Info) {
	// A `Shared(T)`'s one field has a zero, but the handle has none (design.md
	// "Types with no zero value").
	if len(v.elements) == 0 && type_info_is_shared(k.c, info) {
		require_type_has_zero(k, target, v.span, "`{}`")
		v.type = INVALID_TYPE
		return
	}
	// Positional elements fill the named fields; padding stays zero.
	positional := named_fields(k.c, info)
	seen := make([]bool, len(info.fields), context.temp_allocator)
	v.field_indices = make([]int, len(v.elements), k.c.semantic_allocator)
	for &slot in v.field_indices { slot = -1 }
	named := false
	ok := true

	for element, index in v.elements {
		field := INVALID_SYMBOL
		if element.key != nil {
			key, is_ident := element.key.(^Expr_Ident)
			if !is_ident {
				errorf(k.c, element.span, "L0376", "a struct literal key must be a field name")
				ok = false
				continue
			}
			named = true
			field = field_named(k.c, target, identifier_of(k.c, key))
			if field == INVALID_SYMBOL {
				errorf(k.c, element.span, "L0363", "`%s` has no field `%s`", type_name(k.c, target), key.name)
				ok = false
				continue
			}
			if !require_visible_field(k, element.span, target, field, "L0473", "initialised") {
				ok = false
				continue
			}
			if seen[symbol_of(k.c, field).index] {
				errorf(k.c, element.span, "L0376", "field `%s` is set twice", key.name)
				ok = false
				continue
			}
		} else {
			if named {
				errorf(k.c, element.span, "L0372", "a positional element cannot follow a named one")
				ok = false
				continue
			}
			if index >= len(positional) {
				named_count := len(positional)
				errorf(k.c, element.span, "L0376", "`%s` has %d field%s", type_name(k.c, target), named_count, named_count == 1 ? "" : "s")
				ok = false
				continue
			}
			field = positional[index]
			// Supplying an inaccessible field is rejected; omitting one is not.
			if !require_visible_field(k, element.span, target, field, "L0474", "initialised positionally") {
				ok = false
				continue
			}
			// design.md "Struct literals": positional only where the fields are
			// declared. Positional elements come first, so the first reports.
			if record_order_is_foreign(k, target) {
				if index == 0 {
					errorf(
						k.c, element.span, "L0709",
						"the fields of `%s` are declared in another package, so its literal must name them",
						type_name(k.c, target),
					)
					add_notef(
						k.c, element.span, "write `%s = ...`; that package may reorder its fields",
						identifier_text(k.c, symbol_of(k.c, field).name),
					)
				}
				ok = false
				continue
			}
		}
		symbol := symbol_of(k.c, field)
		seen[symbol.index] = true
		v.field_indices[index] = int(symbol.index)
		if !check_composite_element(k, v, index, symbol.type) {
			ok = false
		}
	}
	// A rejected literal has no type: a constant or `when` condition reading it
	// must not evaluate past the error.
	if !ok || !check_omitted_fields(k, v, info, seen) {
		v.type = INVALID_TYPE
		return
	}
	// A capture runs where the literal is evaluated: never folded.
	if v.capture == nil {
		fold_aggregate(k, v, target, info.fields)
	}
}

// design.md "Zero values": an omitted field is filled with its type's zero, and a
// no-zero type has none to fill it with.
@(private = "file")
check_omitted_fields :: proc(k: ^Checker, v: ^Expr_Composite, info: ^Type_Info, seen: []bool) -> bool {
	ok := true
	for field, index in info.fields {
		if seen[index] {
			continue
		}
		symbol := symbol_of(k.c, field)
		if symbol == nil || symbol.initialized_by != INVALID_SYMBOL {
			continue
		}
		// design.md "Required fields".
		if symbol.required {
			errorf(
				k.c, v.span, "L0424",
				"the field `%s` is `@(required)`, so this literal must supply it",
				identifier_text(k.c, symbol.name),
			)
			ok = false
			continue
		}
		if !require_type_has_zero(k, symbol.type, v.span, strings.concatenate({"the omitted field `", identifier_text(k.c, symbol.name), "`"}, context.temp_allocator)) {
			ok = false
		}
	}
	return ok
}

// A sequence literal lists its elements positionally. Reported once per literal.
@(private = "file")
reject_keyed_element :: proc(k: ^Checker, element: Element, target: Type_Id) {
	errorf(
		k.c, element.span, "L0372",
		"a `%s` literal lists its elements positionally",
		type_name(k.c, target),
	)
}

@(private = "file")
check_array_literal :: proc(k: ^Checker, v: ^Expr_Composite, target: Type_Id, info: ^Type_Info) {
	count := int(info.count)
	designated := composite_is_designated(v)
	// design.md "SIMD vectors": one element per lane, positionally.
	if designated && info.kind == .Simd {
		for element in v.elements {
			if element.key != nil {
				reject_keyed_element(k, element, target)
				break
			}
		}
		v.type = INVALID_TYPE
		return
	}
	if designated && v.slot_ends == nil {
		// Built at run time if need be, so only the length limits a key.
		if _, resolved := resolve_array_slots(k, v, max(i64) - 1); !resolved {
			v.type = INVALID_TYPE
			return
		}
	}
	// Written slots, kept for a designated literal: only keys can repeat a slot.
	written := make([dynamic]Written_Slots, 0, designated ? len(v.elements) : 0, context.temp_allocator)
	filled := 0
	ok := true
	for element, index in v.elements {
		lo, hi := composite_element_slots(v, index)
		if hi > count {
			if designated {
				errorf(
					k.c, expr_span(element.key != nil ? element.key : element.value), "L0361",
					"index %d is out of range for `%s`", hi - 1, type_name(k.c, target),
				)
			} else {
				errorf(k.c, element.span, "L0376", "`%s` holds %d element%s", type_name(k.c, target), count, count == 1 ? "" : "s")
			}
			ok = false
			continue
		}
		if designated {
			append(&written, Written_Slots{lo, hi, index})
		}
		filled += hi - lo
		if !check_composite_element(k, v, index, info.element) {
			ok = false
		}
	}
	if report_repeated_slots(k, v, target, written[:]) || !ok {
		return
	}
	if filled < count && !require_type_has_zero(k, info.element, v.span, "omitted array elements") {
		v.type = INVALID_TYPE
		return
	}
	fold_aggregate(k, v, target, nil)
}

// The slots `lo ..< hi` that element `index` of an array literal sets.
@(private = "file")
Written_Slots :: struct {
	lo, hi, index: int,
}

// design.md "Fixed arrays": each slot is set once. Sorted, so a literal is checked
// by what it lists and not by the array's length, which may be past what a table
// could hold.
@(private = "file")
report_repeated_slots :: proc(k: ^Checker, v: ^Expr_Composite, target: Type_Id, written: []Written_Slots) -> bool {
	slice.sort_by(written, proc(a, b: Written_Slots) -> bool { return a.lo < b.lo })
	reported := false
	covered := Written_Slots{}
	for slots in written {
		if slots.lo < covered.hi {
			element := v.elements[max(slots.index, covered.index)]
			errorf(k.c, element.span, "L0376", "element %d of `%s` is set twice", slots.lo, type_name(k.c, target))
			reported = true
		}
		if slots.hi > covered.hi {
			covered = slots
		}
	}
	return reported
}

composite_is_designated :: proc(v: ^Expr_Composite) -> bool {
	for element in v.elements {
		if element.key != nil {
			return true
		}
	}
	return false
}

// design.md "Fixed arrays": positional elements first, then elements keyed by
// a constant index or index range. Records each element's slots and returns
// the length they need.
@(private = "file")
resolve_array_slots :: proc(k: ^Checker, v: ^Expr_Composite, limit: i64) -> (int, bool) {
	v.field_indices = make([]int, len(v.elements), k.c.semantic_allocator)
	v.slot_ends = make([]int, len(v.elements), k.c.semantic_allocator)
	needed := 0
	ok := true
	keyed := false
	for element, index in v.elements {
		lo, hi := index, index + 1
		if element.key == nil {
			if keyed {
				errorf(k.c, element.span, "L0372", "a positional element cannot follow a designated one")
				ok = false
				continue
			}
		} else {
			keyed = true
			resolved: bool
			lo, hi, resolved = array_key_slots(k, element.key, limit)
			if !resolved {
				ok = false
				continue
			}
		}
		v.field_indices[index], v.slot_ends[index] = lo, hi
		needed = max(needed, hi)
	}
	return needed, ok
}

// A designated key: a constant integer or rune index, or a constant range of
// them, `lo ..= hi` or `lo ..< hi`. The range is matching syntax, not a value.
@(private = "file")
array_key_slots :: proc(k: ^Checker, key: Expr, limit: i64) -> (lo, hi: int, ok: bool) {
	bound :: proc(k: ^Checker, e: Expr, limit: i64) -> (int, bool) {
		if !check_integer_index(k, e) {
			return 0, false
		}
		base := expr_base(e)
		if base.const_value.kind != .Integer && base.const_value.kind != .Rune {
			errorf(k.c, expr_span(e), "L0372", "an array element index must be a constant integer")
			return 0, false
		}
		value, fits := bi_to_i64(k.c, base.const_value.integer)
		if !fits || value < 0 || value > limit {
			errorf(k.c, expr_span(e), "L0361", "index %s is out of range", bi_text(k.c, base.const_value.integer))
			return 0, false
		}
		return int(value), true
	}
	range, is_range := key.(^Expr_Range)
	if !is_range {
		index := bound(k, key, limit) or_return
		return index, index + 1, true
	}
	range.type = TYPE_INT
	if range.op != .Range_Incl && range.op != .Range_Excl {
		errorf(k.c, range.op_span, "L0372", "an index range is written `lo ..= hi` or `lo ..< hi`")
		return 0, 0, false
	}
	first := bound(k, range.lo, limit) or_return
	last := bound(k, range.hi, limit) or_return
	end := range.op == .Range_Incl ? last + 1 : last
	if end <= first {
		errorf(k.c, range.op_span, "L0372", "this index range is empty")
		return 0, 0, false
	}
	return first, end, true
}

// design.md "Dynamic arrays": a literal allocates, so only the empty one is a
// constant: the all-zero header.
@(private = "file")
check_dynamic_literal :: proc(k: ^Checker, v: ^Expr_Composite, target: Type_Id, info: ^Type_Info) {
	// Insertion clones a borrowed element, so its copy entry point has to exist.
	contribute_lifecycle_members(k, info.element)
	reported := false
	for element, index in v.elements {
		if element.key != nil {
			if !reported {
				reject_keyed_element(k, element, target)
				reported = true
			}
			continue
		}
		check_composite_element(k, v, index, info.element)
	}
}

// `{key = value, ...}` (design.md "Maps"); allocates like a dynamic array's.
@(private = "file")
check_map_literal :: proc(k: ^Checker, v: ^Expr_Composite, target: Type_Id, info: ^Type_Info) {
	// Insertion clones both halves, so both copy entry points have to exist.
	contribute_lifecycle_members(k, info.key)
	contribute_lifecycle_members(k, info.element)
	for element, index in v.elements {
		if element.key == nil {
			errorf(
				k.c, element.span, "L0376",
				"a `%s` literal writes each entry as `key = value`", type_name(k.c, target),
			)
			continue
		}
		// design.md "Capture literals": a capture's bare name before `=`, which
		// the body's rewrite took for a field name, is the capture here.
		if name, is_name := element.key.(^Expr_Ident); is_name {
			if place := capture_place_of(k, name); place != nil {
				v.elements[index].key = place
			}
		}
		if check_value_expr(k, v.elements[index].key, info.key, "use as a key") {
			check_composite_element(k, v, index, info.element)
		}
	}
}

// A literal whose written elements all folded is a constant, with zero values
// for the rest. `fields` is a struct's, and nil for an array.
@(private = "file")
fold_aggregate :: proc(k: ^Checker, v: ^Expr_Composite, target: Type_Id, fields: []Symbol_Id) {
	// Too large to build: the literal is constructed at run time instead.
	if const_element_count(k.c, target) > MAX_CONST_ELEMENTS {
		return
	}
	for element in v.elements {
		if !is_const_expr(element.value) {
			return
		}
	}
	info := underlying_info(k.c, target)
	elements := make([]Const_Value, fields == nil ? int(info.count) : len(fields), k.c.semantic_allocator)
	written := make([]bool, len(elements), context.temp_allocator)
	for element, index in v.elements {
		lo, hi: int
		if fields == nil {
			lo, hi = composite_element_slots(v, index)
		} else {
			lo, hi = v.field_indices[index], v.field_indices[index] + 1
		}
		for slot in lo ..< hi {
			elements[slot] = expr_base(element.value).const_value
			written[slot] = true
		}
	}
	if fields == nil {
		// An array's unwritten elements share one zero, as `zero_const`'s do.
		zero: Maybe(Const_Value)
		for &element, index in elements {
			if written[index] {
				continue
			}
			if zero == nil {
				built, ok := zero_const(k.c, info.element)
				if !ok {
					return
				}
				zero = built
			}
			element = zero.?
		}
	} else {
		for &element, index in elements {
			if written[index] {
				continue
			}
			field := symbol_of(k.c, fields[index])
			if field.initialized_by != INVALID_SYMBOL {
				element = capacity_const(k.c, field.type)
				continue
			}
			ok: bool
			if element, ok = zero_const(k.c, field.type); !ok {
				return
			}
		}
	}
	v.const_value = aggregate_const(k.c, target, elements)
}
