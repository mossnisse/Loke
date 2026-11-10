// Conversions: `T(value)` between scalars, lanes and references with their
// checks, and the union constructions and narrowings written as calls.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"

@(private)
emit_conversion :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	source := expr_base(v.bound[0]).type
	value := emit_expr(e, v.bound[0])
	if v.operation.(Call_Conversion).clones {
		value = emit_clone_value(e, source, value)
	}
	return emit_value_conversion(e, value, source, as_type, checked = true)
}

// The types a conversion's instruction reads: a vector pair's lane types, or the
// operands themselves.
@(private = "file")
conversion_lanes :: proc(c: ^Compiler, from, to: Type_Id) -> (from_lane, to_lane: Type_Id, lanes: bool) {
	if type_is_simd(c, from) && type_is_simd(c, to) {
		return type_underlying(c, type_of(c, from).element), type_underlying(c, type_of(c, to).element), true
	}
	return from, to, false
}

// A built-in conversion of an evaluated value. `checked` is `T(v)`'s promise
// that an integer keeps its value; `math.wrap` keeps the low bits instead.
@(private)
emit_value_conversion :: proc(e: ^Emitter, value: string, source, target: Type_Id, checked: bool) -> string {
	// design.md "Widening by label": the tag is remapped even where two unions
	// share one storage type.
	if union_widens_to(e.c, source, target) {
		return emit_union_widen(e, value, source, target)
	}
	from := type_underlying(e.c, source)
	to := type_underlying(e.c, target)
	if checked {
		guard_integer_conversion(e, value, from, to)
		guard_null_reference(e, value, from, to)
	}
	if llvm_type(e, from) == llvm_type(e, to) {
		return value
	}

	// SIMD conversions use the same instruction over lane types.
	from_lane, to_lane, _ := conversion_lanes(e.c, from, to)
	from_float := type_is_float(e.c, from_lane)
	to_float := type_is_float(e.c, to_lane)
	from_bits, to_bits := type_bits(e.c, from_lane), type_bits(e.c, to_lane)
	from_signed := type_signed(e.c, from_lane)
	to_signed := type_signed(e.c, to_lane)

	operation := ""
	switch {
	case from_float && to_float:
		operation = from_bits > to_bits ? "fptrunc" : "fpext"
	case from_float:
		operation = to_signed ? "fptosi" : "fptoui"
		guard_float_to_int(e, value, from, from_lane, to_lane)
	case to_float:
		operation = from_signed ? "sitofp" : "uitofp"
	case from_bits > to_bits:
		operation = "trunc"
	case from_bits < to_bits:
		operation = from_signed ? "sext" : "zext"
	case:
		return value
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s to %s", out, operation, llvm_type(e, from), value, llvm_type(e, to))
	return out
}

// design.md "Type conversion": an integer converts only to a type that holds its
// value, checked in the source type against the destination's bounds. A vector
// is checked lane-wise and, as a panic is not lane-wise, fails as a whole.
@(private = "file")
guard_integer_conversion :: proc(e: ^Emitter, value: string, from, to: Type_Id) {
	from_lane, to_lane, lanes := conversion_lanes(e.c, from, to)
	info := type_of(e.c, from)
	integral :: proc(c: ^Compiler, type: Type_Id) -> bool {
		return type_is_integer(c, type) || type_is_rune(c, type) || underlying_kind(c, type) == .Enum
	}
	if !integral(e.c, from_lane) || !integral(e.c, to_lane) {
		return
	}
	from_bits, to_bits := type_bits(e.c, from_lane), type_bits(e.c, to_lane)
	from_signed := type_signed(e.c, from_lane)
	to_signed := type_signed(e.c, to_lane)
	// Only a bound the source can pass needs a test.
	to_value_bits := to_bits - (to_signed ? 1 : 0)
	test_high := to_value_bits < from_bits - (from_signed ? 1 : 0)
	test_low := from_signed && (!to_signed || to_bits < from_bits)
	if !test_high && !test_low {
		return
	}
	form := lanes ? lane_int_form(e, info, llvm_type(e, from)) : scalar_int_form(e, from)
	bad := ""
	if test_high {
		to_max := bi_sub(e.c, bi_pow2(e.c, to_value_bits), bi_from_i64(e.c, 1))
		bad = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = icmp %s %s %s, %s", bad, from_signed ? "sgt" : "ugt", form.llvm, value,
			form_const(e, form, bi_text(e.c, to_max)),
		)
	}
	if test_low {
		to_min := to_signed ? bi_neg(e.c, bi_pow2(e.c, to_bits - 1)) : bi_zero(e.c)
		under := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp slt %s %s, %s", under, form.llvm, value, form_const(e, form, bi_text(e.c, to_min)))
		if bad == "" {
			bad = under
		} else {
			joined := temp(e)
			fmt.sbprintfln(&e.b, "  %s = or %s %s, %s", joined, form.mask, bad, under)
			bad = joined
		}
	}
	panic_if(e, form_any(e, form, bad), "cast.int", "an integer outside the destination type's range; `math.wrap` keeps the low bits")
}

// design.md "The `unsafe` package": an unchecked address becomes a reference
// only if it is not null, so no reference is ever null once checked code holds
// it and nothing that uses one tests it again.
@(private)
guard_null_reference :: proc(e: ^Emitter, value: string, from, to: Type_Id) {
	#partial switch underlying_kind(e.c, from) {
	case .Raw_Pointer, .C_Pointer:
	case:
		return
	}
	#partial switch underlying_kind(e.c, to) {
	case .Pointer, .CString_View:
	case:
		return
	}
	panic_if(e, is_null(e, value), "cast.null", "a null address converted to a reference")
}

// Guard LLVM float-to-integer casts from poison on invalid inputs.
@(private = "file")
guard_float_to_int :: proc(e: ^Emitter, value: string, from, from_lane, to_lane: Type_Id) {
	width := u16(type_bits(e.c, from_lane))
	signed := type_signed(e.c, to_lane)
	magnitude := int(type_bits(e.c, to_lane)) - (signed ? 1 : 0)
	low_value := signed ? -power_of_two(magnitude) : 0
	high_value := power_of_two(magnitude)

	// A destination wider than the source's exponent range rounds its bound to an
	// infinity. Every finite value is then in range and only the infinity itself
	// is not, so an equal operand has to fail rather than pass.
	below := float_from_pattern(float_pattern(low_value, width), width) == low_value ? "ult" : "ule"
	low := llvm_float(float_pattern(low_value, width), width)
	high := llvm_float(float_pattern(high_value, width), width)

	info := underlying_info(e.c, from)
	lanes := type_is_simd(e.c, from)
	if lanes {
		low, high = simd_repeated(e, info, low), simd_repeated(e, info, high)
	}
	llvm := llvm_type(e, from)
	under, over, bad := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = fcmp %s %s %s, %s", under, below, llvm, value, low)
	fmt.sbprintfln(&e.b, "  %s = fcmp uge %s %s, %s", over, llvm, value, high)
	predicate := lanes ? fmt.aprintf("<%d x i1>", info.count) : "i1"
	fmt.sbprintfln(&e.b, "  %s = or %s %s, %s", bad, predicate, under, over)
	// A panic is not lane-wise, so one invalid lane faults the whole conversion.
	if lanes {
		bad = simd_any_lane(e, info, bad)
	}
	panic_if(e, bad, "cast.range", "a float outside the destination integer type's range")
}

// `U.name(payload)`.
@(private)
emit_union_construct :: proc(e: ^Emitter, v: ^Expr_Call, operation: Call_Union_Construct, as_type: Type_Id) -> string {
	payload := emit_copied_expr(e, v.bound[0], expr_base(v.bound[0]).type, operation.clone)
	return emit_union_value(e, as_type, operation.index, payload)
}

// `u.as(.name)` borrows `u`: the payload is cloned only once the tag matched,
// and the option is written only on that path.
@(private)
emit_union_as :: proc(e: ^Emitter, v: ^Expr_Call, index: int, as_type: Type_Id) -> string {
	subject := type_underlying(e.c, expr_base(v.bound[0]).type)
	value := emit_borrowed_operand(e, v.bound[0])
	matched := emit_union_tag_is(e, subject, value, index)

	slot := spill(e, as_type, emit_union_value(e, as_type, union_index_of(e.c, as_type, "none"), ""))
	then_label, done_label := new_label(e, "unionas.match"), new_label(e, "unionas.done")
	branch_if(e, matched, then_label, done_label)
	place_label(e, then_label)
	payload_type := option_payload(e.c, as_type)
	payload := "zeroinitializer"
	if union_variant_payload(e.c, subject, index) != TYPE_VOID {
		payload = emit_union_payload(e, subject, payload_type, emit_union_spill(e, subject, value))
		if emit_lifecycle(e, payload_type).managed {
			payload = emit_clone_value(e, payload_type, payload)
		}
	}
	store(e, as_type, emit_option_some(e, as_type, payload), slot)
	place_label(e, done_label)
	return load_place(e, as_type, slot)
}
