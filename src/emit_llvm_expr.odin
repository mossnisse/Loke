// Expressions, branching expressions, and unsafe operations.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

// ------------------------------------------------------------ expressions --

// An operand: a literal, a `%name`, or a large value's address.
@(private)
emit_expr :: proc(e: ^Emitter, expr: Expr) -> string {
	if expr == nil {
		return "0"
	}
	return emit_expr_at(e, expr, expr_base(expr).type)
}

// `expr` at `type`, cloned when its copy site `clones`: through `allocator`,
// or through the allocator of the variable `destination` initializes, which is
// evaluated after the value. A widened union is cloned at its own type and the
// copy remapped (design.md "Widening by label"), since the wider union may
// have a move-only alternative that the smaller one lacks.
@(private)
emit_copied_expr :: proc(
	e: ^Emitter, expr: Expr, type: Type_Id, clones: bool, allocator := "", destination := INVALID_SYMBOL,
) -> string {
	if !clones {
		return emit_expr(e, expr)
	}
	from := copied_type(expr, type)
	value := from == type ? emit_expr(e, expr) : emit_expr_at(e, expr, from)
	provider := allocator
	if destination != INVALID_SYMBOL {
		provider = emit_destination_allocator(e, destination)
	}
	if emit_lifecycle(e, from).managed {
		value = emit_clone_value(e, from, value, provider)
	}
	return from == type ? value : emit_union_widen(e, value, from, type)
}

@(private = "file")
emit_move :: proc(e: ^Emitter, v: ^Expr_Move) -> string {
	value := emit_expr(e, v.value)
	if ident, is_ident := v.value.(^Expr_Ident); is_ident {
		kill_place(e, ident.symbol)
	}
	return value
}

// Addressable storage for `expr` at `as_type`. A non-addressable value gets a
// slot, and an owned temporary is dropped when its full expression ends.
@(private)
spill_viewed_at :: proc(e: ^Emitter, expr: Expr, as_type: Type_Id) -> string {
	base := expr_base(expr)
	if base.addressable {
		return emit_lent_address(e, expr, as_type)
	}
	value := emit_expr_at(e, expr, as_type)
	slot := spill(e, as_type, value)
	if !base_is_const(base) {
		hold_addressed_temporary(e, expr, as_type, slot)
	}
	return slot
}

// The address an erased view of `expr` holds: the place itself, or a temporary
// holding the value. A view reads its target at the type's alignment, so it
// views an aligned copy of a packed place.
@(private)
emit_viewed_address :: proc(e: ^Emitter, expr: Expr, from: Type_Id) -> string {
	return aligned_copy_if_needed(e, from, spill_viewed_at(e, expr, from))
}

// `address`, or where it is less aligned than `type` asks, as a packed field
// may be (design.md "@(packed)"), an aligned copy of what it holds, for a
// reader that reads at the type's alignment.
@(private)
aligned_copy_if_needed :: proc(e: ^Emitter, type: Type_Id, address: string) -> string {
	if align, known := e.place_align[address]; !known || align >= type_align(e.c, type) {
		return address
	}
	aligned := temporary_slot(e, type)
	copy_bytes(e, aligned, address, type_size(e.c, type))
	return aligned
}

// A fixed array's or vector's `len()` folds to a constant, but its receiver is
// still evaluated once (and a bare name has nothing to run).
@(private = "file")
emit_const_len_receiver :: proc(e: ^Emitter, expr: Expr) {
	call, is_call := expr.(^Expr_Call)
	if !is_call || len(call.bound) == 0 || call.bound[0] == nil {
		return
	}
	if chosen := symbol_of(e.c, call.resolution.chosen_overload); chosen == nil || chosen.synth != .Standard_Len {
		return
	}
	receiver := call.bound[0]
	if _, is_name := receiver.(^Expr_Ident); is_name {
		return
	}
	emit_discarded_temporary(e, receiver, emit_expr(e, receiver))
}

// The implicit conversion the checker recorded on `expr`'s node, when one applies
// at `as_type`.
@(private = "file")
emit_implicit_conversion :: proc(e: ^Emitter, expr: Expr, as_type: Type_Id) -> (string, bool) {
	base := expr_base(expr)
	// design.md "Widening by label": the smaller union remapped into the wider.
	if from := base.widened_from; from != INVALID_TYPE && union_widens_to(e.c, from, as_type) {
		return emit_union_widen(e, emit_expr_at(e, expr, from), from, as_type), true
	}
	// design.md "Borrowed callable views": a procedure or capture value becoming
	// a `dyn proc` view.
	if from := base.erased_from; from != INVALID_TYPE && type_is_dyn(e.c, as_type) &&
	   dyn_proc_signature(e.c, base.type) != INVALID_TYPE {
		return emit_dyn_proc_value(e, expr, from, as_type), true
	}
	// design.md "Variadic parameters": a value a `..dyn I` pack views, with the
	// witness of its type. A `dyn` value passed as it is keeps its own type and
	// is not viewed again.
	if from := base.erased_from; from != INVALID_TYPE && as_type == base.type && type_is_dyn(e.c, as_type) {
		return emit_dyn_view_value(e, emit_viewed_address(e, expr, from), from, as_type), true
	}
	if from := base.view_from; from != INVALID_TYPE {
		#partial switch underlying_kind(e.c, as_type) {
		case .String_View:
			// A `string` borrowed as a `string_view`: the owning word is dropped, and
			// addressing the source keeps an owned temporary alive. A packed field's
			// header may be byte-aligned (design.md "@(packed)").
			return string_as_view(e, STRING_TYPE, load_place(e, from, emit_lent_address(e, expr, from))), true
		case .Pointer:
			// A `Box(T)` lent as the `^T` of its payload.
			if underlying_kind(e.c, from) == .Box {
				return emit_box_payload_address(e, from, load_place(e, from, emit_lent_address(e, expr, from))), true
			}
			// design.md "Variadic parameters": a `T` a `..^T` pack lends, where it is
			// or in a temporary that lives through the call.
			if pointee, lends := variadic_lent_pointee(e.c, as_type); lends && pointee == from {
				return emit_lent_address(e, expr, from), true
			}
		case .Slice:
			// A `[N]T` read as a `[]T` of all its elements.
			if underlying_kind(e.c, from) == .Array {
				address := emit_lent_address(e, expr, from)
				length := fmt.tprintf("%d", underlying_info(e.c, from).count)
				return emit_slice_value(e, as_type, address, length), true
			}
			// A `[dynamic]T` read as a `[]T` of its live elements.
			value := load_place(e, from, emit_lent_address(e, expr, from))
			data := extract(e, CONTAINER_TYPE, value, CONTAINER_STORAGE)
			length := extract(e, CONTAINER_TYPE, value, CONTAINER_LEN)
			return emit_slice_value(e, as_type, data, length), true
		}
	}
	// design.md "SIMD vectors": a scalar widened to every lane.
	if from := base.splat_from; from != INVALID_TYPE && type_is_simd(e.c, as_type) {
		return emit_simd_splat(e, emit_expr_at(e, expr, from), as_type), true
	}
	return "", false
}

// Emits `expr` at `as_type`: its checked type, or the source type an implicit
// conversion recorded on this node. Children keep their own checked types.
@(private)
emit_expr_at :: proc(e: ^Emitter, expr: Expr, as_type: Type_Id) -> string {
	if converted, is_converted := emit_implicit_conversion(e, expr, as_type); is_converted {
		return converted
	}
	base := expr_base(expr)
	if base_is_const(base) && !projects_managed_literal(e, expr) {
		emit_const_len_receiver(e, expr)
		return const_operand(e, base.const_value, as_type)
	}

	switch v in expr {
	case ^Expr_Error:
		return "0"

	case ^Expr_Literal:
		return const_operand(e, v.const_value, as_type)

	case ^Expr_Ident:
		// A default argument reading a parameter to its left.
		if bound, ok := e.param_values[v.symbol]; ok {
			return bound.by_address ? load_place(e, as_type, bound.operand) : bound.operand
		}
		symbol := symbol_of(e.c, v.symbol)
		if symbol != nil && symbol.kind == .Proc {
			return symbol_name(e, v.symbol)
		}
		address, ok := e.names[v.symbol]
		if !ok {
			backend_fail(e, "a resolved value has no storage")
			return "0"
		}
		return load_place(e, as_type, address)

	case ^Expr_Slice:
		if v.resolution.kind == .User_Operator {
			return emit_operator_call(e, v.resolution.symbol, v.bound)
		}
		return emit_builtin_slice(e, v, as_type)

	case ^Expr_Postfix:
		if v.op == .Or_Return {
			return emit_or_return(e, v)
		}
		return load_place(e, as_type, emit_address_at(e, expr, as_type))

	case ^Expr_Propagated_Error:
		if error, ok := e.propagated_errors[v.owner]; ok {
			// The mapper's argument takes it over from here.
			finish_temporary_drop(e, error.hold)
			return error.value
		}
		backend_fail(e, "an `or_return` mapper's error has no value")
		return "0"

	case ^Expr_Selector, ^Expr_Index:
		if index, is_index := expr.(^Expr_Index); is_index {
			// A read does not insert and panics for a missing key (design.md "Maps").
			if !index.map_inserts && type_is_map(e.c, expr_base(index.operand).type) {
				return emit_map_lookup(e, index)
			}
			// A value `operator([])` produces the element; an `inout` one its address.
			if base.resolution.kind == .User_Operator {
				result := emit_operator_call(e, index.resolution.symbol, index.bound)
				if base.value_category != .Place {
					return result
				}
				return load_place(e, as_type, result)
			}
		}
		// `pkg.f` as a value is the procedure itself, not storage holding one.
		if symbol := symbol_of(e.c, base.resolution.symbol); symbol != nil && symbol.kind == .Proc {
			return symbol_name(e, base.resolution.symbol)
		}
		return load_place(e, as_type, emit_address_at(e, expr, as_type))

	case ^Expr_Unary:
		return emit_unary(e, v, as_type)

	case ^Expr_Binary:
		return emit_binary(e, v, as_type)

	case ^Expr_Cond:
		return emit_cond(e, v, as_type)

	case ^Expr_Call:
		result := emit_call(e, v, as_type)
		if base.value_category != .Place {
			return result
		}
		return load_place(e, as_type, result)

	case ^Expr_Or_Else:
		return emit_or_else(e, v)

	case ^Expr_Composite:
		if v.backing != INVALID_TYPE {
			return emit_slice_literal(e, v, as_type)
		}
		return load_temporary(e, as_type, emit_address_at(e, expr, as_type))

	case ^Expr_Proc:
		// Every reachable literal is hoisted and named before any body is emitted.
		return symbol_name(e, v.symbol)

	case ^Expr_Range:
		return emit_range_value(e, v, as_type)

	case ^Expr_Move:
		return emit_move(e, v)

	case ^Expr_Proc_Group, ^Expr_Operator,
	     ^Type_Pointer, ^Type_C_Pointer, ^Type_Slice, ^Type_Dynamic_Array,
	     ^Type_Array, ^Type_Map, ^Type_Distinct, ^Type_Dyn, ^Type_Type,
	     ^Type_Poly, ^Type_Proc, ^Type_Record, ^Type_Anon_Record, ^Type_Anon_Union, ^Type_Enum, ^Type_Interface:
	}
	backend_fail(e, "an unresolved expression reached emission")
	return "0"
}

// A slice literal views a hidden fixed array owned by the enclosing scope
// (design.md "Slice literals"), which drops its elements like a named `[N]T`.
@(private = "file")
emit_slice_literal :: proc(e: ^Emitter, v: ^Expr_Composite, as_type: Type_Id) -> string {
	backing := v.backing
	info := type_of(e.c, backing)
	root := alloca(e, llvm_type(e, backing))

	// Each element is the literal's to drop, on a panic or an exit from a later
	// one, until the scope owns the array.
	guards := make([]Deferred, len(v.elements))
	for element, index in v.elements {
		slot := element_address(e, backing, root, index)
		value := emit_copied_expr(e, element.value, info.element, index < len(v.element_clones) && v.element_clones[index])
		store(e, info.element, value, slot)
		guards[index] = hold_built_part(e, info.element, slot)
	}
	for guard in guards {
		finish_temporary_drop(e, guard)
	}
	register_scope_place(e, backing, root)
	return emit_slice_value(e, as_type, root, fmt.aprintf("%d", len(v.elements)))
}

@(private)
emit_composite_into :: proc(e: ^Emitter, v: ^Expr_Composite, address: string, as_type: Type_Id) {
	// Start from all-zero bits so an omitted field holds its zero value
	// (design.md "Struct literals", "Zero values"). The literal's own type may
	// have no zero, as with a `Box` field: every part without one is supplied.
	store(e, as_type, "zeroinitializer", address)
	info := underlying_info(e.c, as_type)
	if info == nil {
		return
	}
	if info.kind == .Dynamic_Array {
		emit_dynamic_literal_into(e, v, address, info.element, as_type)
		return
	}
	if info.kind == .Map {
		emit_map_literal_into(e, v, address, info.element, as_type)
		return
	}
	// design.md "What the unwind runs, and what it does not": a part is the
	// unwind's to drop from when it is stored until the literal is complete, so
	// a later element that panics releases exactly the parts already built. So
	// does one that exits, with `or_return` or an `or_else` exit (design.md
	// "or_else expression"): the parts are held meanwhile.
	guards := make([dynamic]Deferred)
	defer delete(guards)
	for element, index in v.elements {
		slot := index
		element_type := info.element
		if info.kind == .Struct {
			if len(v.field_indices) != len(v.elements) ||
			   v.field_indices[index] < 0 || v.field_indices[index] >= len(info.fields) {
				backend_fail(e, "a struct literal element has no resolved field index")
				return
			}
			slot = v.field_indices[index]
			element_type = symbol_of(e.c, info.fields[slot]).type
		}
		value := emit_copied_expr(e, element.value, element_type, index < len(v.element_clones) && v.element_clones[index])
		// A designated index range stores one evaluation in every slot; each
		// slot after the first owns a copy.
		end := slot + 1
		if info.kind == .Array {
			slot, end = composite_element_slots(v, index)
		}
		for target in slot ..< end {
			stored := value
			if target > slot && emit_lifecycle(e, element_type).managed {
				stored = emit_clone_value(e, element_type, value)
			}
			field_address := gep_field(e, llvm_type(e, as_type), address, target)
			record_field_align(e, as_type, address, field_address, element_type)
			store(e, element_type, stored, field_address)
			if info.kind == .Struct {
				append(&guards, hold_record_part(e, as_type, address, target))
			} else {
				append(&guards, hold_built_part(e, element_type, field_address))
			}
		}
	}
	for guard in guards {
		finish_temporary_drop(e, guard)
	}
}

@(private = "file")
emit_unary :: proc(e: ^Emitter, v: ^Expr_Unary, as_type: Type_Id) -> string {
	if v.op == .Amp {
		if expression_converts_storage(v.operand) {
			return emit_address(e, v.operand)
		}
		return emit_lent_address(e, v.operand, expr_base(v.operand).type)
	}
	if v.resolution.kind == .User_Operator {
		operands := [1]Expr{v.operand}
		return emit_operator_call(e, v.resolution.symbol, operands[:])
	}
	return emit_unary_op(e, v.op, as_type, emit_expr(e, v.operand))
}

// A unary operation on an evaluated operand of `type`, lane-wise on a vector; a
// delegated operator applies it to the unwrapped value too.
emit_unary_op :: proc(e: ^Emitter, op: Token_Kind, type: Type_Id, operand: string) -> string {
	llvm := llvm_type(e, type)
	info := underlying_info(e.c, type)
	vector := info.kind == .Simd
	out := temp(e)
	#partial switch op {
	case .Plus:
		return operand
	case .Minus:
		if type_is_float(e.c, vector ? info.element : type) {
			fmt.sbprintfln(&e.b, "  %s = fneg %s %s", out, llvm, operand)
		} else if vector {
			return emit_simd_checked(e, .Minus, info, llvm, "zeroinitializer", operand)
		} else {
			return emit_checked_integer(e, .Minus, type_signed(e.c, type), llvm, "0", operand)
		}
	case .Tilde:
		fmt.sbprintfln(&e.b, "  %s = xor %s %s, %s", out, llvm, operand, vector ? simd_all_ones(e, info) : "-1")
	case .Not:
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", out, operand)
	}
	return out
}

@(private = "file")
emit_binary :: proc(e: ^Emitter, v: ^Expr_Binary, as_type: Type_Id) -> string {
	if v.resolution.kind == .User_Operator {
		operands := [2]Expr{v.lhs, v.rhs}
		result := emit_operator_call(e, v.resolution.symbol, operands[:])
		if !v.negated {
			return result
		}
		// The `!=` fallback: `!(a == b)`.
		return not_i1(e, result)
	}
	// SIMD is lane-wise, and its comparisons produce a mask, not a `bool`.
	if type_is_simd(e.c, expr_base(v.lhs).type) || type_is_simd(e.c, expr_base(v.rhs).type) {
		return emit_simd_binary(e, v)
	}
	#partial switch v.op {
	case .And_And, .Or_Or:
		return emit_short_circuit(e, v)
	case .In:
		if info := type_of(e.c, expr_base(v.rhs).type); info != nil && info.is_range {
			return emit_range_membership(e, v)
		}
		return emit_map_membership(e, v)
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		operand_type := expr_base(v.lhs).type
		lhs := emit_borrowed_operand(e, v.lhs)
		rhs := emit_borrowed_operand(e, v.rhs)
		return emit_compare(e, v.op, operand_type, lhs, rhs)
	}
	if v.op == .Plus && type_is_utf8_text(e.c, expr_base(v.lhs).type) {
		return emit_text_concat(e, v)
	}
	lhs := emit_expr(e, v.lhs)
	rhs := emit_expr(e, v.rhs)
	return emit_binary_op(e, v.op, as_type, expr_base(v.rhs).type, lhs, rhs)
}

// Concatenation allocates from the default allocator and follows its failure
// policy. Both operands are valid UTF-8, so the result is too.
@(private = "file")
emit_text_concat :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	left_data, left_len := emit_text_parts(e, v.lhs)
	right_data, right_len := emit_text_parts(e, v.rhs)
	return emit_text_concat_parts(e, left_data, left_len, right_data, right_len)
}

// Two evaluated operands of one text `type`, as a delegated `+` has them.
@(private)
emit_text_concat_values :: proc(e: ^Emitter, type: Type_Id, lhs, rhs: string) -> string {
	storage := llvm_type(e, type)
	left_data, left_len := string_parts(e, storage, lhs)
	right_data, right_len := string_parts(e, storage, rhs)
	return emit_text_concat_parts(e, left_data, left_len, right_data, right_len)
}

@(private = "file")
emit_text_concat_parts :: proc(e: ^Emitter, left_data, left_len, right_data, right_len: string) -> string {
	provider := emit_default_allocator(e)
	return emit_text_allocating_call(
		e, "loke_rt_v1_string_concat",
		fmt.aprintf(
			"ptr %s, i64 %s, ptr %s, i64 %s, ptr %s",
			left_data, left_len, right_data, right_len, provider,
		),
		provider,
	)
}

// A checked integer `+`, `-`, or `*` and an integer `/` or `%` have lowerings of
// their own, and a float has no bitwise operators.
Arith_Mnemonic :: struct {
	integer, float: string,
}

arith_mnemonic :: proc(op: Token_Kind) -> Arith_Mnemonic {
	#partial switch op {
	case .Plus:       return {"",    "fadd"}
	case .Minus:      return {"",    "fsub"}
	case .Star:       return {"",    "fmul"}
	case .Slash:      return {"",    "fdiv"}
	case .Plus_Wrap:  return {"add", ""}
	case .Minus_Wrap: return {"sub", ""}
	case .Star_Wrap:  return {"mul", ""}
	case .Amp:        return {"and", ""}
	case .Pipe:       return {"or",  ""}
	case .Tilde:      return {"xor", ""}
	}
	return {}
}

@(private)
emit_binary_op :: proc(e: ^Emitter, op: Token_Kind, type: Type_Id, rhs_type: Type_Id, lhs, rhs: string) -> string {
	llvm := llvm_type(e, type)
	if type_is_float(e.c, type) {
		return emit_value(e, "%s %s %s, %s", arith_mnemonic(op).float, llvm, lhs, rhs)
	}

	signed := type_signed(e.c, type)
	#partial switch op {
	case .Plus, .Minus, .Star:
		return emit_checked_integer(e, op, signed, llvm, lhs, rhs)
	case .Slash, .Percent:
		return emit_divrem(e, op, scalar_int_form(e, type), lhs, rhs)
	case .Shl, .Shr:
		return emit_shift(e, op, scalar_int_form(e, type), scalar_int_form(e, rhs_type), lhs, rhs)
	case .Amp_Tilde:
		complement := emit_value(e, "xor %s %s, -1", llvm, rhs)
		return emit_value(e, "and %s %s, %s", llvm, lhs, complement)
	}
	return emit_value(e, "%s %s %s, %s", arith_mnemonic(op).integer, llvm, lhs, rhs)
}

// design.md "Integer overflow": a `+`, `-`, or `*` result that does not fit its
// integer type panics.
emit_checked_integer :: proc(e: ^Emitter, op: Token_Kind, signed: bool, llvm, lhs, rhs: string) -> string {
	wrapped, overflowed := emit_overflow_call(e, checked_intrinsic(op, signed, llvm), llvm, "i1", lhs, rhs)
	panic_if(e, overflowed, "int.overflow", overflow_message(signed))
	return wrapped
}

// A `*.with.overflow` intrinsic answers the wrapped value and whether it wrapped,
// the latter in a `flag` of `i1` or `<N x i1>`.
emit_overflow_call :: proc(e: ^Emitter, key, llvm, flag, lhs, rhs: string) -> (wrapped, overflowed: string) {
	pair_type := strings.concatenate({"{ ", llvm, ", ", flag, " }"})
	declare_intrinsic(e, key, pair_type, strings.concatenate({llvm, ", ", llvm}))
	pair := emit_value(e, "call %s @%s(%s %s, %s %s)", pair_type, key, llvm, lhs, llvm, rhs)
	return extract(e, pair_type, pair, 0), extract(e, pair_type, pair, 1)
}

// The intrinsic's name, with `suffix` the mangling of its operand type.
checked_intrinsic :: proc(op: Token_Kind, signed: bool, suffix: string) -> string {
	operation := signed ? "smul" : "umul"
	#partial switch op {
	case .Plus:  operation = signed ? "sadd" : "uadd"
	case .Minus: operation = signed ? "ssub" : "usub"
	}
	return strings.concatenate({"llvm.", operation, ".with.overflow.", suffix})
}

overflow_message :: proc(signed: bool) -> string {
	return signed ? "signed integer overflow" : "unsigned integer overflow"
}

// What `emit_divrem` and `emit_shift` lower over: one integer, or a vector's lanes,
// where `mask` is the comparison type and `lanes` the vector's type. Over lanes, a
// failing lane panics the whole operation (design.md "Lane-wise operators").
@(private)
Int_Form :: struct {
	llvm, mask: string,
	bits:       int,
	signed:     bool,
	lanes:      ^Type_Info,
}

@(private)
scalar_int_form :: proc(e: ^Emitter, type: Type_Id) -> Int_Form {
	return Int_Form {
		llvm = llvm_type(e, type),
		mask = "i1",
		bits = type_bits(e.c, type),
		signed = type_signed(e.c, type),
	}
}

@(private)
form_const :: proc(e: ^Emitter, form: Int_Form, value: string) -> string {
	return form.lanes == nil ? value : simd_repeated(e, form.lanes, value)
}

@(private = "file")
form_zero :: proc(form: Int_Form) -> string {
	return form.lanes == nil ? "0" : "zeroinitializer"
}

// The `i1` a `panic_if` tests: whether any lane of `mask` is set.
@(private)
form_any :: proc(e: ^Emitter, form: Int_Form, mask: string) -> string {
	return form.lanes == nil ? mask : simd_any_lane(e, form.lanes, mask)
}

@(private = "file")
form_select :: proc(e: ^Emitter, form: Int_Form, condition, if_true, if_false: string) -> string {
	return emit_value(e, "select %s %s, %s %s, %s %s", form.mask, condition, form.llvm, if_true, form.llvm, if_false)
}

// Zero takes the trap seam. `MIN / -1` does not fit, so it panics as any signed
// overflow does, and `MIN % -1` is 0 (design.md "Integer operators"); neither
// reaches `sdiv`/`srem`, where it would be poison.
@(private)
emit_divrem :: proc(e: ^Emitter, op: Token_Kind, form: Int_Form, lhs, rhs: string) -> string {
	llvm := form.llvm

	is_zero := emit_value(e, "icmp eq %s %s, %s", llvm, rhs, form_zero(form))
	panic_if(e, form_any(e, form, is_zero), "div.zero", "integer division by zero")

	if !form.signed {
		return emit_value(e, "%s %s %s, %s", op == .Slash ? "udiv" : "urem", llvm, lhs, rhs)
	}

	minimum := form_const(e, form, bi_text(e.c, bi_neg(e.c, bi_pow2(e.c, form.bits - 1))))
	is_min := temp(e)
	is_neg_one := temp(e)
	is_overflow := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", is_min, llvm, lhs, minimum)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", is_neg_one, llvm, rhs, form_const(e, form, "-1"))
	fmt.sbprintfln(&e.b, "  %s = and %s %s, %s", is_overflow, form.mask, is_min, is_neg_one)
	if op == .Slash {
		panic_if(e, form_any(e, form, is_overflow), "int.overflow", "signed integer overflow")
		return emit_value(e, "sdiv %s %s, %s", llvm, lhs, rhs)
	}
	// `MIN % -1` is 0, and so is `MIN % 1`, which `srem` defines.
	divisor := form_select(e, form, is_overflow, form_const(e, form, "1"), rhs)
	return emit_value(e, "srem %s %s, %s", llvm, lhs, divisor)
}

// design.md "Arithmetic operators": a negative count panics, and a count at or
// beyond the width is defined (zero, or the sign bit for an arithmetic right
// shift), so none reaches an LLVM shift as poison. A vector's count has its form.
@(private)
emit_shift :: proc(e: ^Emitter, op: Token_Kind, form, count_form: Int_Form, lhs, rhs: string) -> string {
	llvm := form.llvm
	count_llvm := count_form.llvm

	if count_form.signed {
		negative := emit_value(e, "icmp slt %s %s, %s", count_llvm, rhs, form_zero(count_form))
		panic_if(e, form_any(e, count_form, negative), "shift.negative", "negative shift count")
	}

	// Compared in the count's own width, before truncation could hide its size.
	oversized := emit_value(
		e, "icmp uge %s %s, %s",
		count_llvm, rhs, form_const(e, count_form, fmt.aprintf("%d", form.bits)),
	)

	count := rhs
	if count_form.bits != form.bits {
		converted := temp(e)
		operation := count_form.bits > form.bits ? "trunc" : "zext"
		fmt.sbprintfln(&e.b, "  %s = %s %s %s to %s", converted, operation, count_llvm, rhs, llvm)
		count = converted
	}

	if op == .Shr && form.signed {
		clamped := form_select(e, form, oversized, form_const(e, form, fmt.aprintf("%d", form.bits - 1)), count)
		return emit_value(e, "ashr %s %s, %s", llvm, lhs, clamped)
	}

	safe := form_select(e, form, oversized, form_zero(form), count)
	raw := emit_value(e, "%s %s %s, %s", op == .Shl ? "shl" : "lshr", llvm, lhs, safe)
	return form_select(e, form, oversized, form_zero(form), raw)
}

// ---------------------------------------------------- branching expressions --

@(private = "file")
emit_short_circuit :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	lhs := emit_expr(e, v.lhs)
	// The left operand may have opened blocks of its own; the phi names the last.
	entry_label := current_block(e, "sc.entry")
	rhs_label := new_label(e, "sc.rhs")
	done_label := new_label(e, "sc.done")
	if v.op == .And_And {
		branch_if(e, lhs, rhs_label, done_label)
	} else {
		branch_if(e, lhs, done_label, rhs_label)
	}

	place_label(e, rhs_label)
	begin_conditional(e)
	rhs := emit_expr(e, v.rhs)
	end_conditional(e)
	rhs_exit := current_block(e, "sc.rhs.exit")
	branch(e, done_label)

	place_label(e, done_label)
	out := temp(e)
	short := v.op == .And_And ? "false" : "true"
	fmt.sbprintfln(
		&e.b,
		"  %s = phi i1 [ %s, %%%s ], [ %s, %%%s ]",
		out, short, entry_label, rhs, rhs_exit,
	)
	return out
}

// One arm of a conditional, and, when the arms meet in a phi, the block it ends
// in, for the phi to name.
@(private = "file")
emit_cond_arm :: proc(
	e: ^Emitter, label, exit_prefix: string, arm: Expr, as_type: Type_Id, clones: bool, joined, done: string,
) -> (value, exit: string) {
	place_label(e, label)
	begin_conditional(e)
	value = emit_copied_expr(e, arm, as_type, clones)
	end_conditional(e)
	if joined != "" {
		store(e, as_type, value, joined)
	} else {
		exit = current_block(e, exit_prefix)
	}
	branch(e, done)
	return value, exit
}

@(private = "file")
emit_cond :: proc(e: ^Emitter, v: ^Expr_Cond, as_type: Type_Id) -> string {
	cond := emit_expr(e, v.cond)
	// A large value cannot be a phi operand, so each arm writes one slot.
	joined := is_large_value(e, as_type) ? temporary_slot(e, as_type) : ""
	then_label := new_label(e, "cond.then")
	else_label := new_label(e, "cond.else")
	done_label := new_label(e, "cond.done")
	branch_if(e, cond, then_label, else_label)

	then_value, then_exit := emit_cond_arm(e, then_label, "cond.then.exit", v.then, as_type, v.then_clone, joined, done_label)
	else_value, else_exit := emit_cond_arm(e, else_label, "cond.else.exit", v.otherwise, as_type, v.else_clone, joined, done_label)

	place_label(e, done_label)
	if joined != "" {
		return joined
	}
	return emit_value(
		e, "phi %s [ %s, %%%s ], [ %s, %%%s ]",
		llvm_type(e, as_type), then_value, then_exit, else_value, else_exit,
	)
}

@(private)
emit_union_failed :: proc(e: ^Emitter, union_type: Type_Id, value: string) -> string {
	shape, _ := fallible_of(e.c, union_type)
	return emit_union_tag_is(e, union_type, value, shape.failure)
}

@(private = "file")
emit_failure_conversion :: proc(e: ^Emitter, value: string, from, into: Type_Id) -> string {
	if from == into {
		return value
	}
	if underlying_kind(e.c, from) == .String && underlying_kind(e.c, into) == .String_View {
		return string_as_view(e, STRING_TYPE, value)
	}
	// design.md "Widening by label": a smaller error set propagates into a
	// larger one.
	if union_widens_to(e.c, from, into) {
		return emit_union_widen(e, value, from, into)
	}
	// Carrier weakening, procedure escape weakening, checked/C-pointer
	// interchange, and pointer-to-rawptr all share one backend representation.
	return value
}

// A failure path's exit statement, whose temporaries are made only on this path.
@(private = "file")
emit_conditional_exit :: proc(e: ^Emitter, exit: Stmt) {
	begin_conditional(e)
	emit_stmt(e, exit)
	end_conditional(e)
	if !e.terminated {
		emit_unreachable(e)
	}
}

// The fallback is evaluated only for the failure variant.
@(private = "file")
emit_or_else :: proc(e: ^Emitter, v: ^Expr_Or_Else) -> string {
	operand_type := type_underlying(e.c, expr_base(v.value).type)
	shape, _ := fallible_of(e.c, operand_type)
	// A success that carries nothing yields `Unit`.
	unit := shape.success_type == TYPE_VOID
	payload_type := payload_value_type(e.c, shape.success_type)

	value := emit_expr(e, v.value)
	slot := emit_union_spill(e, operand_type, value)
	failed := emit_union_failed(e, operand_type, value)
	joined := temporary_slot(e, payload_type)
	success_label := new_label(e, "orelse.success")
	fallback_label := new_label(e, "orelse.fallback")
	done := new_label(e, "orelse.done")
	branch_if(e, failed, fallback_label, success_label)

	place_label(e, success_label)
	taken := "zeroinitializer"
	if !unit {
		taken = emit_union_payload(e, operand_type, payload_type, slot)
	}
	if v.borrows && emit_lifecycle(e, payload_type).managed {
		taken = emit_clone_value(e, payload_type, taken)
	}
	store(e, payload_type, taken, joined)
	branch(e, done)

	place_label(e, fallback_label)
	// design.md: `or_else` never copies the error, so a managed failure payload of
	// a *temporary* is dropped here, before the fallback runs, since the operand's
	// value is discarded on this path. A place still owns its own.
	if !v.borrows && emit_lifecycle(e, shape.failure_type).managed {
		emit_drop_place(e, shape.failure_type, gep_field(e, llvm_type(e, operand_type), slot, 0))
	}
	// design.md "or_else expression": an exit leaves here, and only the success
	// arm reaches the rest of the expression.
	if v.exit != nil {
		emit_conditional_exit(e, v.exit)
	} else {
		begin_conditional(e)
		fallback := emit_copied_expr(e, v.fallback, payload_type, v.fallback_clone)
		end_conditional(e)
		store(e, payload_type, fallback, joined)
		branch(e, done)
	}

	place_label(e, done)
	return load_temporary(e, payload_type, joined)
}

// Rewraps a failure and exits through the ordinary epilogue.
@(private = "file")
emit_or_return :: proc(e: ^Emitter, v: ^Expr_Postfix) -> string {
	operand_type := type_underlying(e.c, expr_base(v.operand).type)
	shape, _ := fallible_of(e.c, operand_type)
	operand_address := ""
	value := ""
	if v.borrows {
		// A place is evaluated once and retained as an address.
		operand_address = emit_address(e, v.operand)
		value = load_place(e, operand_type, operand_address)
	} else {
		value = emit_expr(e, v.operand)
	}
	slot := emit_union_spill(e, operand_type, value)
	failed := emit_union_failed(e, operand_type, value)

	fail_label := new_label(e, "orreturn.fail")
	ok_label := new_label(e, "orreturn.ok")
	branch_if(e, failed, fail_label, ok_label)

	place_label(e, fail_label)
	if v.failure_exit != nil {
		// design.md "or_return operator": the failure operand runs only here. A
		// mapper takes the error, copied out of a place; a replacement leaves a
		// place's error where it is and drops a temporary's first, as `or_else`
		// does.
		failure_type := shape.failure_type
		if v.failure_maps {
			error := emit_union_payload(e, operand_type, failure_type, slot)
			if v.borrows && emit_lifecycle(e, failure_type).managed {
				error = emit_clone_value(e, failure_type, error)
			}
			// Held until the mapper takes it, so an exit or a panic while the
			// mapper is selected still drops it.
			e.propagated_errors[v] = {error, hold_temporary_value(e, failure_type, error)}
		} else if !v.borrows && failure_type != TYPE_VOID && emit_lifecycle(e, failure_type).managed {
			emit_drop_place(e, failure_type, gep_field(e, llvm_type(e, operand_type), slot, 0))
		}
		emit_conditional_exit(e, v.failure_exit)
	} else {
		target, _ := fallible_of(e.c, e.result_type)
		error := ""
		if failure_type := shape.failure_type; failure_type != TYPE_VOID {
			error = emit_union_payload(e, operand_type, failure_type, slot)
			failure_into := target.failure_type
			if v.borrows && emit_lifecycle(e, failure_type).managed &&
			   !failure_assignment_borrows(e.c, failure_type, failure_into) {
				error = emit_clone_value(e, failure_type, error)
			}
			error = emit_failure_conversion(e, error, failure_type, failure_into)
		}
		wrapped := emit_union_value(e, e.result_type, target.failure, error)
		store(e, e.result_type, wrapped, e.result_slot)
		emit_epilogue(e)
	}

	place_label(e, ok_label)
	if shape.success_type == TYPE_VOID {
		return "zeroinitializer"
	}
	out := emit_union_payload(e, operand_type, shape.success_type, slot)
	if v.borrows && emit_lifecycle(e, shape.success_type).managed {
		out = emit_clone_value(e, shape.success_type, out)
	}
	return out
}

// ------------------------------------------------------ unsafe operations --

// `unsafe.transmute(T, value)`: the same bits read as a `T`. The checker has
// settled equal size and trivial lifecycles, so only the LLVM spelling is left:
// a register cast where one exists, a stack round trip otherwise.
@(private)
emit_transmute :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	source := expr_base(v.bound[0]).type
	value := emit_expr(e, v.bound[0])
	// A `bool` is `i1` in registers but a byte in memory, so it crosses as `i8`.
	from := llvm_type(e, source)
	if underlying_kind(e.c, source) == .Bool {
		widened := emit_value(e, "zext i1 %s to i8", value)
		value, from = widened, "i8"
	}
	to_bool := underlying_kind(e.c, as_type) == .Bool
	to := to_bool ? "i8" : llvm_type(e, as_type)
	result := reinterpret_bits(e, source, as_type, from, to, value)
	if to_bool {
		// Bit 0 is the `bool`; a valid pattern is the caller's obligation
		// (design.md "Invalid representations").
		return emit_value(e, "trunc i8 %s to i1", result)
	}
	return result
}

@(private = "file")
reinterpret_bits :: proc(e: ^Emitter, source, target: Type_Id, from, to, value: string) -> string {
	if from == to {
		return value
	}
	out := temp(e)
	switch {
	case pointer_shaped(e.c, source) && to[0] == 'i':
		fmt.sbprintfln(&e.b, "  %s = ptrtoint %s %s to %s", out, from, value, to)
	case pointer_shaped(e.c, target) && from[0] == 'i':
		fmt.sbprintfln(&e.b, "  %s = inttoptr %s %s to %s", out, from, value, to)
	case is_large_value(e, target):
		// Both sides are addresses; the copy is aligned for `target`.
		slot := temporary_slot(e, target)
		copy_bytes(e, slot, value, type_size(e.c, target))
		return slot
	case bitcastable(e.c, source) && bitcastable(e.c, target):
		fmt.sbprintfln(&e.b, "  %s = bitcast %s %s to %s", out, from, value, to)
	case:
		// An aggregate: through equally sized storage aligned for the stricter side.
		slot := alloca(e, type_align(e.c, target) > type_align(e.c, source) ? to : from)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", from, value, slot)
		return load(e, to, slot)
	}
	return out
}

@(private = "file")
pointer_shaped :: proc(c: ^Compiler, type: Type_Id) -> bool {
	#partial switch underlying_kind(c, type) {
	case .Raw_Pointer, .C_Pointer, .Proc:
		return true
	}
	return false
}

// First-class, non-aggregate, non-pointer types, which `bitcast` accepts.
@(private = "file")
bitcastable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	#partial switch underlying_kind(c, type) {
	case .Bool, .Int, .Float, .Rune, .Enum, .Simd:
		return true
	}
	return false
}

// `unsafe.raw_data`, `unsafe.cstring_view` and `unsafe.string_view`; the last
// still validates, since `string_view` promises UTF-8.
@(private)
emit_unsafe_builtin :: proc(e: ^Emitter, v: ^Expr_Call, kind: Builtin_Kind, as_type: Type_Id) -> string {
	out := "null"
	operand_kind := underlying_kind(e.c, expr_base(v.bound[0]).type)
	#partial switch kind {
	case .Unsafe_Raw_Data:
		#partial switch operand_kind {
		case .Slice:
			data, _ := emit_slice_parts(e, v.bound[0])
			out = data
		case .String, .String_View:
			data, _ := emit_text_parts(e, v.bound[0])
			out = data
		case .Dynamic_Array:
			// The current allocation's first element; nothing keeps it current.
			out = extract(e, CONTAINER_TYPE, emit_borrowed_operand(e, v.bound[0]), CONTAINER_STORAGE)
		case:
			// A pointer to a fixed array, or a `cstring_view`, is already the address.
			out = emit_expr(e, v.bound[0])
		}

	case .Unsafe_C_String_View:
		out = emit_expr(e, v.bound[0])
		guard_null_reference(e, out, expr_base(v.bound[0]).type, TYPE_CSTRING_VIEW)

	case .Unsafe_String_View:
		// design.md "string type conversions": a negative length is a bounds
		// error, as in `pointer[0:length]`, not input to report.
		data := emit_expr(e, v.bound[0])
		length := checked_index_to_i64(e, emit_expr(e, v.bound[1]), expr_base(v.bound[1]).type)
		negative := emit_value(e, "icmp slt i64 %s, 0", length)
		panic_if(e, negative, "slice.bounds", "slice bounds out of range")
		return emit_checked_view(e, as_type, data, length)
	}
	return out
}
