// `Box(T)`: an owner of one allocated value (design.md "Owned values").
package lokec

// The payload type of a box, or INVALID_TYPE for anything else.
box_element :: proc(c: ^Compiler, box_type: Type_Id) -> Type_Id {
	info := underlying_info(c, box_type)
	if info == nil || info.kind != .Box {
		return INVALID_TYPE
	}
	return info.element
}

// The predeclared type constructor `Box`, not a user declaration that shares
// the name.
box_type_callee :: proc(k: ^Checker, callee: Expr) -> bool {
	ident, is_ident := callee.(^Expr_Ident)
	if !is_ident || ident.name != "Box" {
		return false
	}
	return lookup_symbol(k.scope, identifier_of(k.c, ident)) == INVALID_SYMBOL
}

// design.md "Owned values", "Shared ownership": reports `box(T)`, `shared(T)`, or
// `weak(T)` written for the handle type, in type position or with a type
// argument. `weak` names nothing.
report_handle_type_spelling :: proc(k: ^Checker, call: ^Expr_Call, type_position: bool) -> bool {
	ident, is_ident := call.callee.(^Expr_Ident)
	if !is_ident || (ident.name != "weak" && ident.name != "box" && ident.name != "shared") {
		return false
	}
	named := lookup_symbol(k.scope, identifier_of(k.c, ident))
	sym := symbol_of(k.c, named)
	spelled := ""
	switch {
	case ident.name == "weak" && named == INVALID_SYMBOL:
		spelled = "Weak"
	case ident.name == "box" && sym != nil && sym.kind == .Builtin && sym.builtin == .Box_New:
		spelled = "Box"
	case ident.name == "shared" && named != INVALID_SYMBOL && named == k.c.shared_construct_symbol:
		spelled = "Shared"
	case:
		return false
	}
	if spelled != "Weak" && !type_position && !callee_argument_denotes_type(k, call) {
		return false
	}
	errorf(k.c, ident.span, "L0713", "the handle type is spelled `%s(...)`, not `%s(...)`", spelled, ident.name)
	return true
}

// Whether a one-argument application names a type; the probe is silent.
@(private = "file")
callee_argument_denotes_type :: proc(k: ^Checker, v: ^Expr_Call) -> bool {
	if !has_one_plain_argument(v) {
		return false
	}
	return resolve_type_syntax(k, v.args[0].value) != INVALID_TYPE
}

// The payload a successful `box(value)` holds, or nil for any other call. Not
// `try_box`'s: a refused allocation drops the payload, so a moved provider
// would end while the result survives.
boxed_payload :: proc(c: ^Compiler, v: ^Expr_Call) -> Expr {
	sym := symbol_of(c, v.resolution.symbol)
	if sym == nil || sym.builtin != .Box_New || len(v.bound) == 0 {
		return nil
	}
	return v.bound[0]
}

// `Box(T)` in type position.
resolve_box_application :: proc(k: ^Checker, v: ^Expr_Call) -> Type_Id {
	if v.denoted_type != INVALID_TYPE {
		return v.denoted_type
	}
	if !has_one_plain_argument(v) {
		errorf(k.c, v.span, "L0713", "`Box` takes one element type, as in `Box(Node)`")
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

// design.md "Owned values": the value is taken as an initialization takes it.
//
// `unsafe.new` and `unsafe.try_new` take their value the same way and answer
// the unchecked `[^]T` of an allocation with no header, which the caller
// releases with `unsafe.free` (design.md "The `unsafe` package").
check_box_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind, expected: Type_Id) {
	v.type = INVALID_TYPE
	if kind == .Box_New && report_handle_type_spelling(k, v, type_position = false) {
		return
	}
	if len(v.args) < 1 || len(v.args) > 2 {
		errorf(k.c, v.span, "L0714", "`%s` takes a value and an optional allocator", ident.name)
		return
	}
	if !builtin_arguments_ok(k, v) {
		return
	}
	base, fallible := allocation_builtin(kind)
	is_box := base == .Box_New
	argument := v.args[0].value
	payload, typed := check_defaulted_operand(k, argument, allocation_payload_expected(k.c, kind, expected))
	if !typed || !gate_type(k, payload, expr_span(argument)) {
		return
	}
	if type_is_compile_time_only(k.c, payload) {
		errorf(k.c, expr_span(argument), "L0713", "`%s` takes a runtime value, found `%s`", ident.name, type_name(k.c, payload))
		return
	}
	site: Copy_Site = is_box ? .Box : .Unsafe_Allocation
	classify_copy(k, argument, payload, site)
	if !type_clone_disabled(k.c, payload) {
		classify_copy_cost(k, argument, payload, site)
	}

	bound := make([]Expr, len(v.args), k.c.semantic_allocator)
	bound[0] = argument
	if len(v.args) == 2 {
		if !check_allocator_argument(k, v.args[1].value) {
			return
		}
		bound[1] = v.args[1].value
	}
	v.bound = bound
	v.operation = Call_Allocation{type = payload, fallible = fallible}
	made := is_box ? box_of(k.c, payload) : c_pointer_to(k.c, payload)
	contribute_lifecycle_members(k, is_box ? made : payload)
	v.type = fallible ? result_type(k, made, TYPE_ALLOCATOR_ERROR) : made
}

// The payload type `expected` asks of an allocating call: `box` builds a
// `Box(T)`, `unsafe.new` a `[^]T`, and each `try_` form a `Result` of that.
// INVALID_TYPE when it asks for none.
@(private = "file")
allocation_payload_expected :: proc(c: ^Compiler, kind: Builtin_Kind, expected: Type_Id) -> Type_Id {
	base, fallible := allocation_builtin(kind)
	made := expected
	if fallible {
		shape, is_fallible := fallible_of(c, expected)
		if !is_fallible {
			return INVALID_TYPE
		}
		made = shape.success_type
	}
	if base == .Box_New {
		return box_element(c, made)
	}
	info := underlying_info(c, made)
	return info != nil && info.kind == .C_Pointer ? info.element : INVALID_TYPE
}

// design.md "Owned values": a box lends its payload as a read-only `^T`, as a
// `[dynamic]T` lends a `[]T`. `&mut b^` is the written mutable borrow.
box_views_as :: proc(c: ^Compiler, from, to: Type_Id) -> bool {
	source, view := type_of(c, from), type_of(c, to)
	return source != nil && view != nil && source.kind == .Box &&
		view.kind == .Pointer && !view.mutable && source.element == view.element
}

// design.md "Owned values": `move(b).unbox()`.
check_box_unbox :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) -> bool {
	if sel.name.text != "unbox" {
		return false
	}
	subject := check_receiver(k, sel)
	if !type_is_box(k.c, subject) {
		return false
	}
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
	v.bound = bound_exprs(k, sel.operand)
	v.operation = Call_Box_Unbox{}
	v.type = box_element(k.c, subject)
	return true
}
