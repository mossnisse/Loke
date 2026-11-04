// Which statements have no way to panic, from the syntax and the types alone.
// The control-flow walk asks, to skip the unwind path of one that cannot.
package lokec

// Whether no operation in this statement, its nested statements included, is
// one design.md "Panics and unwinding" lists as able to panic. Conservative: a
// call, an index, a slice, an extraction, a copy of a managed value, a signed
// or rune `+`, `-`, `*`, or negation, and a division whose divisor is not a
// nonzero constant all may. A `drop` panics only through a `drop` hook it runs.
// `known` remembers the answers for statements holding others.
@(private)
stmt_cannot_panic :: proc(c: ^Compiler, stmt: Stmt, known: ^map[^Node_Base]bool) -> bool {
	// A statement holding others is asked again for each of them; only they are
	// remembered, since nothing else repeats its visit.
	#partial switch _ in stmt {
	case ^Stmt_If, ^Stmt_For, ^Block:
		key := stmt_base(stmt)
		if answer, found := known[key]; found {
			return answer
		}
		answer := classify_stmt(c, stmt, known)
		known[key] = answer
		return answer
	}
	return classify_stmt(c, stmt, known)
}

@(private = "file")
classify_stmt :: proc(c: ^Compiler, stmt: Stmt, known: ^map[^Node_Base]bool) -> bool {
	switch s in stmt {
	case ^Decl:
		if s.kind == .Const {
			return true
		}
		if s.via != nil || s.duration != .None || (len(s.values) != 0 && len(s.values) != len(s.symbols)) {
			return false
		}
		for id, index in s.symbols {
			sym := symbol_of(c, id)
			if sym == nil || !type_is_panic_free_scalar(c, sym.type) && (index >= len(s.values) || !moves_whole_local(s.values[index])) {
				return false
			}
		}
		for value in s.values {
			if !moves_whole_local(value) && !expr_cannot_panic(c, value) {
				return false
			}
		}
		return true
	case ^Stmt_Expr:
		for e in s.exprs {
			if !expr_cannot_panic(c, e) && !drop_cannot_panic(c, e) {
				return false
			}
		}
		return true
	case ^Stmt_Assign:
		if s.op != .Assign || len(s.lhs) != len(s.rhs) {
			return false
		}
		for target in s.lhs {
			if !is_effect_free_place(target) || !expr_cannot_panic(c, target) {
				return false
			}
		}
		for value in s.rhs {
			if !expr_cannot_panic(c, value) {
				return false
			}
		}
		return true
	case ^Stmt_If:
		return (s.init == nil || stmt_cannot_panic(c, s.init, known)) && expr_cannot_panic(c, s.cond) &&
			stmt_cannot_panic(c, s.then, known) && (s.otherwise == nil || stmt_cannot_panic(c, s.otherwise, known))
	case ^Stmt_For:
		return (s.init == nil || stmt_cannot_panic(c, s.init, known)) && (s.cond == nil || expr_cannot_panic(c, s.cond)) &&
			(s.post == nil || stmt_cannot_panic(c, s.post, known)) && stmt_cannot_panic(c, s.body, known)
	case ^Block:
		if s == nil {
			return true
		}
		for inner in s.stmts {
			if !stmt_cannot_panic(c, inner, known) {
				return false
			}
		}
		return true
	case ^Stmt_Return:
		if s.value == nil {
			return true
		}
		if s.value.is_inout {
			return false
		}
		// A bare local is moved or copied out as a scalar, unless it is cloned.
		_, is_ident := s.value.expr.(^Expr_Ident)
		return is_ident && !s.value.clone_on_return || moves_whole_local(s.value.expr) || expr_cannot_panic(c, s.value.expr)
	case ^Stmt_Branch:
		return true
	case ^Item_Impl, ^Stmt_Error, ^Stmt_Foreach, ^Stmt_When, ^Stmt_Switch, ^Stmt_Defer, ^Stmt_Parallel, ^Stmt_Spawn:
	}
	return false
}

// `move(x)` of a whole local only transfers it.
@(private = "file")
moves_whole_local :: proc(e: Expr) -> bool {
	moved, is_move := e.(^Expr_Move)
	if !is_move {
		return false
	}
	_, is_ident := moved.value.(^Expr_Ident)
	return is_ident
}

// A type whose values copy as plain bits and whose built-in comparisons call
// nothing.
type_is_panic_free_scalar :: proc(c: ^Compiler, type: Type_Id) -> bool {
	#partial switch underlying_kind(c, type) {
	case .Bool, .Int, .Float, .Rune, .Enum, .Pointer, .C_Pointer, .Raw_Pointer:
		return true
	}
	return false
}

@(private = "file")
expr_cannot_panic :: proc(c: ^Compiler, e: Expr) -> bool {
	base := expr_base(e)
	if base == nil || base.has_error {
		return false
	}
	if base_is_const(base) {
		return true
	}
	if !type_is_panic_free_scalar(c, base.type) {
		return false
	}
	#partial switch v in e {
	case ^Expr_Literal, ^Expr_Ident:
		return true
	case ^Expr_Selector:
		return v.resolution.kind == .Field && expr_cannot_panic_operand(c, v.operand)
	case ^Expr_Postfix:
		// A reference is never null (design.md "Pointers").
		return v.op == .Caret && !v.boxed && expr_cannot_panic(c, v.operand)
	case ^Expr_Unary:
		#partial switch v.op {
		case .Amp:
			return is_effect_free_place(v.operand) && expr_cannot_panic_operand(c, v.operand)
		case .Not, .Tilde:
			return expr_cannot_panic(c, v.operand)
		case .Minus:
			return underlying_kind(c, base.type) == .Float && expr_cannot_panic(c, v.operand)
		}
	case ^Expr_Binary:
		if v.resolution.kind != .Builtin_Operator || !expr_cannot_panic(c, v.lhs) || !expr_cannot_panic(c, v.rhs) {
			return false
		}
		#partial switch v.op {
		case .And_And, .Or_Or, .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq,
		     .Amp, .Amp_Tilde, .Pipe, .Tilde, .Plus_Wrap, .Minus_Wrap, .Star_Wrap:
			return true
		case .Shl, .Shr:
			// design.md "Arithmetic operators": only a negative count panics, and
			// the checker rejects a constant one.
			count := expr_base(v.rhs)
			return !type_signed(c, count.type) ||
				(count.const_value.kind == .Integer && bi_sign(count.const_value.integer) >= 0)
		case .Plus, .Minus, .Star:
			// design.md "Integer overflow": floating-point arithmetic never panics;
			// integer arithmetic does when the result does not fit.
			return underlying_kind(c, base.type) == .Float
		case .Slash, .Percent:
			// design.md "Integer operators": only an integer divisor of zero, or a
			// signed `MIN / -1`, panics.
			if underlying_kind(c, base.type) == .Float {
				return true
			}
			divisor := expr_base(v.rhs)
			return !type_signed(c, base.type) && divisor.const_value.kind == .Integer &&
				!bi_is_zero(divisor.const_value.integer)
		}
	case ^Expr_Cond:
		return expr_cannot_panic(c, v.cond) && expr_cannot_panic(c, v.then) && expr_cannot_panic(c, v.otherwise)
	}
	return false
}

// A place a selector or `&` only names, which reads nothing it could copy.
@(private = "file")
expr_cannot_panic_operand :: proc(c: ^Compiler, e: Expr) -> bool {
	#partial switch v in e {
	case ^Expr_Ident:
		return true
	case ^Expr_Selector:
		return v.resolution.kind == .Field && expr_cannot_panic_operand(c, v.operand)
	case ^Expr_Postfix:
		return v.op == .Caret && !v.boxed && expr_cannot_panic(c, v.operand)
	}
	return false
}

// `drop(x)` of a local whose cleanup runs no `drop` hook: releasing storage is
// not among the operations that panic.
@(private = "file")
drop_cannot_panic :: proc(c: ^Compiler, e: Expr) -> bool {
	if !is_builtin_call(c, e, .Drop) {
		return false
	}
	call := e.(^Expr_Call)
	if len(call.args) != 1 {
		return false
	}
	ident, is_ident := call.args[0].value.(^Expr_Ident)
	return is_ident && !type_drop_runs_hook(c, ident.type)
}
