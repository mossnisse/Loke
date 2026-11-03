// Which temporaries a local's declaration or assignment extends to its block's end.
package lokec

// design.md "Temporaries and procedure boundaries": a temporary that a local's
// declaration or whole assignment borrows along an extending path lives until
// the end of the block holding the statement. Marks, for each such value, the
// borrowed nodes from the borrowed value down to the temporary that holds it;
// the borrow checker and the backend each consult the node they materialize.
mark_extended_temporaries :: proc(c: ^Compiler, stmt: Stmt) {
	#partial switch s in stmt {
	case ^Decl:
		if s.kind == .Const || s.top_level || s.destructure.active {
			return
		}
		for value, index in s.values {
			if index < len(s.symbols) && extends_into_local(c, s.symbols[index]) {
				mark_extending_path(c, value)
			}
		}
	case ^Stmt_Assign:
		if s.op != .Assign || s.destructure.active || s.lowered != nil || s.place_setter != INVALID_SYMBOL {
			return
		}
		for target, index in s.lhs {
			ident, is_ident := target.(^Expr_Ident)
			if is_ident && index < len(s.rhs) && extends_into_local(c, ident.symbol) {
				mark_extending_path(c, s.rhs[index])
			}
		}
	}
}

// A procedure's own variable; a parameter, `static`, or global is not one.
@(private = "file")
extends_into_local :: proc(c: ^Compiler, id: Symbol_Id) -> bool {
	sym := symbol_of(c, id)
	return sym != nil && sym.kind == .Var && sym.duration == .None
}

// The value a local receives: an implicit view conversion borrows the value it
// converts, and `&`, `&mut`, and slicing borrow their operand. Reslicing a view
// borrows what the view does, so the path goes on through it. Calls end it,
// except an explicit `dyn proc` conversion, which is the implicit one written
// out (design.md "Borrowed callable views").
@(private = "file")
mark_extending_path :: proc(c: ^Compiler, value: Expr) {
	base := expr_base(value)
	if base == nil {
		return
	}
	if base.erased_from != INVALID_TYPE || base.view_from != INVALID_TYPE {
		mark_borrowed_temporary(value)
	}
	if operand, viewing := explicit_view_operand(value); viewing {
		mark_extending_path(c, operand)
		return
	}
	#partial switch v in value {
	case ^Expr_Unary:
		if v.op == .Amp {
			mark_borrowed_temporary(v.operand)
		}
	case ^Expr_Slice:
		if v.resolution.kind == .User_Operator {
			return
		}
		#partial switch underlying_kind(c, expr_base(v.operand).type) {
		case .Slice, .String_View:
			mark_extending_path(c, v.operand)
		case:
			mark_borrowed_temporary(v.operand)
		}
	}
}

// The operand of an explicit view or `dyn proc` conversion, through identity conversions.
explicit_view_operand :: proc(value: Expr) -> (Expr, bool) {
	call, is_call := value.(^Expr_Call)
	if !is_call || len(call.bound) != 1 || call.bound[0] == nil {
		return nil, false
	}
	if _, conversion := call.operation.(Call_Conversion); !conversion {
		return nil, false
	}
	operand := call.bound[0]
	base := expr_base(operand)
	if base == nil {
		return nil, false
	}
	if base.erased_from == INVALID_TYPE && base.view_from == INVALID_TYPE {
		if base.type != call.type {
			return nil, false
		}
		return explicit_view_operand(operand)
	}
	return operand, true
}

// A borrowed value and the projections leading to the temporary holding it:
// a field, an element, or a box's payload is part of its owner.
@(private = "file")
mark_borrowed_temporary :: proc(value: Expr) {
	for node := value; node != nil; {
		base := expr_base(node)
		if base == nil {
			return
		}
		base.extended = true
		#partial switch v in node {
		case ^Expr_Selector:
			if v.resolution.kind == .Value {
				return
			}
			node = v.operand
		case ^Expr_Index:
			if v.resolution.kind == .User_Operator {
				return
			}
			node = v.operand
		case ^Expr_Postfix:
			if !v.boxed {
				return
			}
			node = v.operand
		case:
			return
		}
	}
}
