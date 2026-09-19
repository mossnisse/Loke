// Reports uses of locals given only `nil`. This is deliberately a whole-body
// summary: any non-nil or opaque write suppresses the diagnostic, even after an
// earlier use. It diagnoses certainty cheaply; it does not prove non-nullness.
package lokec

Nil_Use :: struct {
	symbol: Symbol_Id,
	span:   Span,
	verb:   string,
}

// Checked types whose nil state traps on use.
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

// Only bare local names are tracked; fields and elements are not.
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

// A non-nil write makes the whole-body result unknown.
note_nil_write :: proc(k: ^Checker, target: Expr, value: Expr) {
	note_nil_write_to(k, nil_tracked_local(k, target), value)
}

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

// Marks a write whose value this pass cannot inspect.
note_unknown_nil_write :: proc(k: ^Checker, target: Expr) {
	if id := nil_tracked_local(k, target); id != INVALID_SYMBOL {
		if sym := symbol_of(k.c, id); sym != nil {
			sym.nil_writes = .Unknown
		}
	}
}

// Reporting is deferred until every write in the body has been seen.
note_nil_use :: proc(k: ^Checker, value: Expr, verb: string) {
	if id := nil_tracked_local(k, value); id != INVALID_SYMBOL {
		append(&k.nil_uses, Nil_Use{symbol = id, span = expr_span(value), verb = verb})
	}
}

// A mark keeps nested procedure literals separate from their parent body.
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
