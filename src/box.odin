// `box(T)`: an owner of one allocated value (design.md "Owned values").
//
// `box` is a predeclared built-in that is also a type constructor, as `Simd`
// is: `box(Node)` names the type, and `box(value)` or `box(value, allocator)`
// builds one. A box is one address. The allocation it names holds the
// allocator that made it and then the payload, so dropping or cloning a box
// needs nothing but the box.
package lokec

// The allocation behind a box: the allocator, then the payload at its own
// alignment. Shared by the checker's size questions and the emitter.
box_payload_offset :: proc(c: ^Compiler, element: Type_Id) -> u64 {
	return align_to(u64(c.target.pointer_bits) / 8, type_align(c, element))
}

box_block_size :: proc(c: ^Compiler, element: Type_Id) -> u64 {
	return align_to(box_payload_offset(c, element) + type_size(c, element), box_block_align(c, element))
}

box_block_align :: proc(c: ^Compiler, element: Type_Id) -> u64 {
	return max(u64(c.target.pointer_bits) / 8, type_align(c, element))
}

// The payload type of a box, or INVALID_TYPE for anything else.
box_element :: proc(c: ^Compiler, box_type: Type_Id) -> Type_Id {
	info := underlying_info(c, box_type)
	if info == nil || info.kind != .Box {
		return INVALID_TYPE
	}
	return info.element
}

// The predeclared `box`, not a declaration that shadows it.
box_callee :: proc(k: ^Checker, callee: Expr) -> bool {
	ident, is_ident := callee.(^Expr_Ident)
	if !is_ident {
		return false
	}
	sym := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident)))
	return sym != nil && sym.kind == .Builtin && sym.builtin == .Box_New
}

// `box(T)` in type position.
resolve_box_application :: proc(k: ^Checker, v: ^Expr_Call) -> Type_Id {
	if v.denoted_type != INVALID_TYPE {
		return v.denoted_type
	}
	if len(v.args) != 1 || v.args[0].name.text != "" || v.args[0].mode != .Value {
		errorf(k.c, v.span, "L0713", "`box` as a type takes one element type, as in `box(Node)`")
		return INVALID_TYPE
	}
	element := resolve_type_syntax(k, v.args[0].value)
	if element == INVALID_TYPE {
		report_unresolved_type(k, v.args[0].value)
		return INVALID_TYPE
	}
	if type_is_compile_time_only(k.c, element) {
		errorf(k.c, expr_span(v.args[0].value), "L0713", "a box holds a runtime value, found `%s`", type_name(k.c, element))
		return INVALID_TYPE
	}
	v.denoted_type = box_of(k.c, element)
	v.resolution.kind = .Type
	v.value_category = .Type
	return v.denoted_type
}

// `box(value[, allocator])` and `try_box(value[, allocator])`. The value is
// taken the way an initialization takes it: a place is cloned, a temporary or
// `move(x)` is handed over.
check_box_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind, expected: Type_Id) {
	v.value_category = .Value
	v.type = INVALID_TYPE
	if kind == .Box_New && callee_argument_denotes_type(k, v) {
		set_type_call(v, resolve_box_application(k, v))
		return
	}
	if len(v.args) < 1 || len(v.args) > 2 {
		errorf(k.c, v.span, "L0714", "`%s` takes a value and an optional allocator", ident.name)
		return
	}
	if !builtin_arguments_ok(k, v) {
		return
	}
	// `b: box(Node) = box({1, .none})` gives the payload its type.
	payload_expected := INVALID_TYPE
	if kind == .Box_New && type_is_box(k.c, expected) {
		payload_expected = underlying_info(k.c, expected).element
	}
	argument := v.args[0].value
	payload := check_single_expr(k, argument, payload_expected)
	if payload == INVALID_TYPE || !gate_type(k, payload, expr_span(argument)) {
		return
	}
	if type_is_untyped(k.c, payload) {
		payload = default_type(k.c, payload)
		if payload == INVALID_TYPE || !materialize(k, argument, payload) {
			return
		}
	}
	if type_is_compile_time_only(k.c, payload) {
		errorf(k.c, expr_span(argument), "L0713", "a box holds a runtime value, found `%s`", type_name(k.c, payload))
		return
	}
	classify_copy(k, argument, payload, .Box)
	classify_copy_cost(k, argument, payload, .Box)

	bound := make([]Expr, len(v.args), k.c.semantic_allocator)
	bound[0] = argument
	if len(v.args) == 2 {
		allocator := check_single_expr(k, v.args[1].value, TYPE_ALLOCATOR)
		if allocator == INVALID_TYPE {
			return
		}
		if type_underlying(k.c, allocator) != TYPE_ALLOCATOR {
			errorf(
				k.c, expr_span(v.args[1].value), "L0490",
				"an allocator argument is an `Allocator`, found `%s`", type_name(k.c, allocator),
			)
			return
		}
		bound[1] = v.args[1].value
	}
	v.bound = bound
	fallible := kind == .Try_Box
	v.operation = Call_Allocation{type = payload, fallible = fallible}
	boxed := box_of(k.c, payload)
	contribute_lifecycle_members(k, boxed)
	v.type = fallible ? result_type(k, boxed, TYPE_ALLOCATOR_ERROR) : boxed
}


// design.md "Owned values": a box lends its payload as a read-only `^T`, as a
// `[dynamic]T` lends a `[]T`. `&mut b^` is the written mutable borrow.
box_views_as :: proc(c: ^Compiler, from, to: Type_Id) -> bool {
	source, view := type_of(c, from), type_of(c, to)
	return source != nil && view != nil && source.kind == .Box &&
		view.kind == .Pointer && !view.mutable && source.element == view.element
}

// `move(b).unbox()`: consumes the box and yields its payload, releasing the
// allocation. `move` cannot name a payload and `exchange` needs a replacement
// the payload type may not have, so this is how a move-only payload leaves.
check_box_unbox :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) -> bool {
	if sel.name.text != "unbox" {
		return false
	}
	if ident, ok := sel.operand.(^Expr_Ident); ok {
		if sym := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident))); sym != nil && sym.kind == .Package_Alias {
			return false
		}
	}
	subject := check_single_expr(k, sel.operand)
	if !type_is_box(k.c, subject) {
		return false
	}
	v.value_category = .Value
	v.resolution = Resolution{kind = .Builtin_Operator}
	v.type = INVALID_TYPE
	if len(v.args) != 0 {
		errorf(k.c, v.span, "L0715", "`unbox` takes no arguments")
		return true
	}
	if expression_is_borrowed_place(sel.operand) {
		errorf(k.c, expr_span(sel.operand), "L0715", "`unbox` consumes its box; write `move(...).unbox()` to give the box up")
		return true
	}
	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = sel.operand
	v.bound = bound
	v.operation = Call_Box_Unbox{}
	v.type = box_element(k.c, subject)
	return true
}
