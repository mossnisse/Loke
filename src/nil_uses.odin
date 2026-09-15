// Provably nil uses of a checked borrow, a procedure value, or a dynamic view.
//
// design.md "What is not checked": `^T`, a procedure value, and `dyn I` all have
// a nil state and fail on use. A body that gives a local nothing but `nil` and
// then dereferences, calls, or dispatches through it cannot do anything else at
// run time, so it is said here rather than at the trap.
//
// The question is asked over the whole body rather than along its paths. A must
// analysis over the flow graph would answer the same programs: the interesting
// bug -- a pointer left nil on *one* path -- is a may-nil, and reporting it
// would reject code whose author knows the path is unreachable. So one non-nil
// write anywhere, or one exposure to a write this pass cannot see, settles the
// question for the whole body and nothing is reported.
//
// This is a diagnostic and nothing else. If absence ever moves into `Option` and
// borrows become non-null, this file goes away with the state it describes.
package lokec

// Where a nil value would reach a trap. The verb names the operation in the
// diagnostic, so each site supplies its own.
Nil_Use :: struct {
	symbol: Symbol_Id,
	span:   Span,
	verb:   string,
}

// Whether the type has a nil state that fails on use. `[^]T` is outside the
// checked axis entirely and is not asked about.
@(private = "file")
type_fails_on_nil :: proc(c: ^Compiler, type: Type_Id) -> bool {
	info := underlying_info(c, type)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Pointer, .Proc, .Dyn:
		return true
	}
	return false
}

// The local this expression names, or INVALID_SYMBOL. Only a bare name is
// followed: a field or element is storage this pass does not track.
@(private = "file")
nil_tracked_local :: proc(k: ^Checker, value: Expr) -> Symbol_Id {
	ident, is_ident := value.(^Expr_Ident)
	if !is_ident {
		return INVALID_SYMBOL
	}
	sym := symbol_of(k.c, ident.symbol)
	if sym == nil || sym.kind != .Var || sym.decl == nil || sym.decl.top_level {
		return INVALID_SYMBOL
	}
	if sym.duration != .None || !type_fails_on_nil(k.c, sym.type) {
		return INVALID_SYMBOL
	}
	return ident.symbol
}

// One write of `value` into `target`. A written `nil` keeps the local's answer;
// anything else settles it, because the pass has no idea what the value is.
note_nil_write :: proc(k: ^Checker, target: Expr, value: Expr) {
	note_nil_write_to(k, nil_tracked_local(k, target), value)
}

// The same, where the destination is a declaration's binding rather than a
// written place.
note_nil_write_to :: proc(k: ^Checker, id: Symbol_Id, value: Expr) {
	sym := symbol_of(k.c, id)
	if sym == nil || sym.kind != .Var || sym.nil_writes == .Unknown {
		return
	}
	if !type_fails_on_nil(k.c, sym.type) {
		return
	}
	base := expr_base(value)
	if base != nil && base.const_value.kind == .Nil {
		sym.nil_writes = .Nil_Only
		return
	}
	sym.nil_writes = .Unknown
}

// A write this pass cannot read: `&mut local`, an `inout` argument, a compound
// assignment, a destructuring target.
note_unknown_nil_write :: proc(k: ^Checker, target: Expr) {
	if id := nil_tracked_local(k, target); id != INVALID_SYMBOL {
		if sym := symbol_of(k.c, id); sym != nil {
			sym.nil_writes = .Unknown
		}
	}
}

// A use that traps on nil. Recorded rather than reported: a write later in the
// body has not been checked yet, and it is what decides the answer.
note_nil_use :: proc(k: ^Checker, value: Expr, verb: string) {
	if id := nil_tracked_local(k, value); id != INVALID_SYMBOL {
		append(&k.nil_uses, Nil_Use{symbol = id, span = expr_span(value), verb = verb})
	}
}

// Reports the uses recorded since `mark`, which is taken when a body's check
// begins. A nested procedure literal is checked inside its parent's body, so
// draining by mark keeps each body's answers to itself.
report_nil_uses :: proc(k: ^Checker, mark: int) {
	for use in k.nil_uses[mark:] {
		sym := symbol_of(k.c, use.symbol)
		if sym == nil || sym.nil_writes != .Nil_Only {
			continue
		}
		errorf(
			k.c, use.span, "L0701",
			"`%s` is `nil` everywhere it is given a value, so this %s always fails",
			identifier_text(k.c, sym.name), use.verb,
		)
		add_notef(k.c, sym.span, "`%s` is declared here", identifier_text(k.c, sym.name))
	}
	resize(&k.nil_uses, mark)
}
