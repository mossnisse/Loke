// Capture literals: design.md "Capture literals".
//
// `proc(a, b: int) -> bool capture(limit) { ... }` is checked as the record and
// `call` method a programmer would write in the body by hand: one field per
// capture, a plain `self` receiver, and the literal's body with each captured
// name read through that receiver. The literal itself becomes the record's
// composite literal, so ownership, borrowing, and emission see only ordinary
// code. The record's name is the literal's own text, which no declaration can
// spell, and it lives in a scope of its own.
package lokec

import "core:strings"

// The receiver every lowered `call` takes. It is spelled `self`, so it is a
// receiver, but no source name reaches it: an enclosing method's `self` stays
// that method's, which the literal cannot capture without saying so.
CAPTURE_RECEIVER :: "self$capture"

// What a capture's record field is called, before the captured name.
CAPTURE_FIELD_PREFIX :: "capture$"

// The record type the literal is a value of, or INVALID_TYPE once reported.
lower_capture_literal :: proc(k: ^Checker, v: ^Expr_Composite) -> Type_Id {
	capture := v.capture
	if capture.record != INVALID_TYPE {
		return capture.record
	}
	// design.md "where clauses": a literal is a value, so never generic.
	if !proc_shape_ok(k, capture.procedure, is_value = true) || !capture_literal_shape_ok(k, v) {
		return INVALID_TYPE
	}
	types, checked := check_capture_values(k, v)
	if !checked {
		return INVALID_TYPE
	}

	outer := k.scope
	k.scope = new_scope(k.c, outer, .Local)
	defer k.scope = outer

	span := Span{file = v.span.file, lo = v.span.lo, hi = capture.clause_span.hi}
	text := span_text(k.c, span)
	name := synth_name(k.c, text, span)
	record, fields := capture_record_syntax(k, capture, types, span)
	method := capture_call_method(k, capture, fields)
	reserve_captured_names(k, capture, fields, method)
	record_type := declare_capture_record(k, name, record, method)
	if record_type == INVALID_TYPE {
		return INVALID_TYPE
	}
	declare_capture_call(k, name, method)
	capture.method = method

	// A probe's record has no hoisted `call`, so the check that commits makes
	// its own.
	if committing(k.c) {
		capture.record = record_type
	}
	return record_type
}

// The literal is the record's: each entry's value, taken as its mode says, is
// checked once, here, and its field has the type that check gives it. A second
// check could give a different type: a capture literal inside one makes a new
// record each time it is checked.
@(private = "file")
check_capture_values :: proc(k: ^Checker, v: ^Expr_Composite) -> (types: []Type_Id, checked: bool) {
	capture := v.capture
	v.elements = make([]Element, len(capture.entries), k.c.semantic_allocator)
	types = make([]Type_Id, len(capture.entries), k.c.semantic_allocator)
	checked = true
	for entry, index in capture.entries {
		value := entry.value
		switch entry.mode {
		case .Copy:
		case .Borrow, .Borrow_Mut:
			value = synth_address(k.c, entry.value, entry.mode == .Borrow_Mut, entry.span)
		case .Move:
			value = synth_move(k.c, entry.value, entry.span)
		}
		v.elements[index] = Element{span = entry.span, value = value}
		type := check_single_expr(k, value)
		if type == INVALID_TYPE {
			checked = false
			continue
		}
		types[index] = default_type(k.c, type)
		if types[index] == INVALID_TYPE {
			errorf(k.c, expr_span(value), "L0310", "`nil` has no type to infer here")
			checked = false
		}
	}
	return types, checked
}

// The record, with each field's type bound to a name only this scope has. Its
// fields are named apart from the source, so a capture called `call` leaves room
// for the method.
@(private = "file")
capture_record_syntax :: proc(
	k: ^Checker,
	capture: ^Capture_Literal,
	types: []Type_Id,
	span: Span,
) -> (
	record: ^Type_Record,
	fields: []Capture_Field,
) {
	record = new(Type_Record, k.c.semantic_allocator)
	record.span = span
	record.kind = .Struct
	record.fields = make([]Field, len(capture.entries), k.c.semantic_allocator)
	fields = make([]Capture_Field, len(capture.entries), k.c.semantic_allocator)
	for entry, index in capture.entries {
		text := strings.concatenate({CAPTURE_FIELD_PREFIX, entry.name.text}, k.c.semantic_allocator)
		field := synth_name(k.c, text, entry.name.span)
		fields[index] = Capture_Field{mode = entry.mode, field = field}
		record.fields[index] = synth_record_field(k, "capture$type", index, field, types[index], entry.span)
	}
	return record, fields
}

// Each captured name, reserved where the body can see it: declaring a local of
// the same name in the body shadows it, and a position the body's rewrite leaves
// alone resolves to it rather than to an enclosing local.
@(private = "file")
reserve_captured_names :: proc(k: ^Checker, capture: ^Capture_Literal, fields: []Capture_Field, method: ^Expr_Proc) {
	for entry, index in capture.entries {
		id := name_identifier(k.c, entry.name)
		placeholder := new_symbol(k.c, Symbol{name = id, span = entry.name.span, kind = .Var, pkg = k.pkg})
		k.scope.names[id] = placeholder
		k.c.capture_placeholders[placeholder] = Capture_Placeholder{field = fields[index], method = method}
	}
}

// The record's type, or INVALID_TYPE once reported.
@(private = "file")
declare_capture_record :: proc(k: ^Checker, name: Name, record: ^Type_Record, method: ^Expr_Proc) -> Type_Id {
	declaration := synth_decl(k.c, .Const, name.text, record, name.span)
	check_local_declaration(k, declaration)
	record_symbol := symbol_of(k.c, declaration.symbols[0])
	if record_symbol == nil || record_symbol.type == INVALID_TYPE {
		return INVALID_TYPE
	}
	k.c.capture_records[record_symbol.type] = method
	if info := type_of(k.c, record_symbol.type); info != nil {
		for field in info.fields {
			if sym := symbol_of(k.c, field); sym != nil {
				sym.owner_type = record_symbol.type
			}
		}
	}
	return record_symbol.type
}

@(private = "file")
declare_capture_call :: proc(k: ^Checker, record_name: Name, method: ^Expr_Proc) {
	member := synth_decl(k.c, .Const, "call", method, method.span)
	block := new(Item_Impl, k.c.semantic_allocator)
	block.span = record_name.span
	block.kind = .Impl
	block.type = synth_ident(k.c, record_name.text, record_name.span)
	block.members = make([]Item, 1, k.c.semantic_allocator)
	block.members[0] = member
	check_local_impl(k, block)
}

// The rules a capture literal's shape alone decides (design.md "Capture
// literals"). The checks that need types are the record literal's own.
@(private = "file")
capture_literal_shape_ok :: proc(k: ^Checker, v: ^Expr_Composite) -> bool {
	capture := v.capture
	literal := capture.procedure
	ok := true
	if k.scope == nil || k.scope.owner_proc == nil {
		errorf(
			k.c, capture.clause_span, "L0716",
			"a capture literal belongs in a procedure body, whose locals it captures",
		)
		return false
	}
	if literal.signature.convention != "" {
		errorf(
			k.c, capture.clause_span, "L0716",
			"a capture literal is called through a `call` method, which has no `\"%s\"` calling convention",
			literal.signature.convention,
		)
		ok = false
	}
	seen := make(map[Identifier_Id]bool, len(capture.entries), context.temp_allocator)
	for entry in capture.entries {
		id := name_identifier(k.c, entry.name)
		if entry.name.text == "_" {
			errorf(k.c, entry.name.span, "L0716", "`_` binds nothing, so it cannot name a capture")
			ok = false
			continue
		}
		if reject_reserved_name(k, id, entry.name.span) {
			ok = false
			continue
		}
		if id in seen {
			errorf(k.c, entry.name.span, "L0716", "`%s` is already captured by this literal", entry.name.text)
			ok = false
			continue
		}
		seen[id] = true
	}
	for parameter in literal.signature.params {
		for name in parameter.names {
			if name_identifier(k.c, name.name) in seen {
				errorf(
					k.c, name.name.span, "L0716",
					"`%s` is both a parameter and a capture of this literal; rename one",
					name.name.text,
				)
				ok = false
			}
		}
	}
	return ok
}

// design.md "Capture literals": in the body a captured name is the place it
// captured, the receiver's field for a copy or a move and what the field
// points at for a borrow.
Capture_Rewrite :: struct {
	captures: map[Identifier_Id]Capture_Field,
}

// A capture's field, whose name the source cannot spell, and its mode.
Capture_Field :: struct {
	mode:  Capture_Mode,
	field: Name,
}

rewrite_capture :: proc(c: ^Compiler, v: ^Expr_Ident) -> Expr {
	field, captured := c.capture_rewrite.captures[identifier_of(c, v)]
	if !captured {
		return nil
	}
	return capture_field_place(c, field, v.span)
}

// `self.field`, or `self.field^` for a borrow, spelled at `span`.
capture_field_place :: proc(c: ^Compiler, field: Capture_Field, span: Span) -> Expr {
	receiver := synth_ident_as(c, "self", intern_identifier(c, CAPTURE_RECEIVER), span)
	selected := synth_selector(c, receiver, field.field.text, span)
	if field.mode == .Copy || field.mode == .Move {
		return selected
	}
	return synth_deref(c, selected, span)
}

// `call :: proc(self, <the literal's parameters>) -> <its result> { <body> }`,
// with every captured name in the body rewritten to the receiver's field.
@(private = "file")
capture_call_method :: proc(k: ^Checker, capture: ^Capture_Literal, fields: []Capture_Field) -> ^Expr_Proc {
	literal := capture.procedure
	signature := clone_expr(k.c, literal.signature).(^Type_Proc)
	params := make([]Parameter, len(signature.params) + 1, k.c.semantic_allocator)
	self_name := make([]Param_Name, 1, k.c.semantic_allocator)
	self_name[0] = Param_Name {
		name = Name{text = "self", span = capture.clause_span, id = intern_identifier(k.c, CAPTURE_RECEIVER)},
	}
	params[0] = Parameter{span = capture.clause_span, names = self_name, mode = .Value}
	copy(params[1:], signature.params)
	signature.params = params

	rewrite := Capture_Rewrite {
		captures = make(map[Identifier_Id]Capture_Field, len(capture.entries), context.temp_allocator),
	}
	for entry, index in capture.entries {
		rewrite.captures[name_identifier(k.c, entry.name)] = fields[index]
	}
	// Restored rather than cleared, as `src/ast_clone.odin` does at each nested
	// literal, so an outer rewrite survives.
	outer := k.c.capture_rewrite
	k.c.capture_rewrite = &rewrite
	body := clone_block(k.c, literal.body)
	k.c.capture_rewrite = outer

	method := new(Expr_Proc, k.c.semantic_allocator)
	method.span = literal.span
	method.signature = signature
	method.body = body
	return method
}

// What a reserved capture name reads where the rewrite left it alone, such as a
// map literal's bare key; nil for any other name.
capture_place_of :: proc(k: ^Checker, name: ^Expr_Ident) -> Expr {
	placeholder, reserved := k.c.capture_placeholders[lookup_symbol(k.scope, identifier_of(k.c, name))]
	if !reserved || placeholder.method != k.proc_literal {
		return nil
	}
	return capture_field_place(k.c, placeholder.field, name.span)
}

Capture_Placeholder :: struct {
	field:  Capture_Field,
	method: ^Expr_Proc,
}

// Whether `type` is a capture literal's record: its fields are its own
// `call`'s, and it is neither compared nor printed.
type_is_capture_record :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return type in c.capture_records
}

// A capture is read only by its literal's body and set only by the literal
// itself; to everything else, reflection included, the record has no fields.
capture_field_visible :: proc(k: ^Checker, sym: ^Symbol) -> bool {
	if sym.kind != .Field {
		return true
	}
	method, is_capture := k.c.capture_records[sym.owner_type]
	if !is_capture {
		return true
	}
	return k.body.proc_literal == method || k.body.building_capture == sym.owner_type
}

// A local in a capture literal's body cannot take a capture's name: every use
// of that name in the body is the capture.
note_shadowed_capture :: proc(k: ^Checker, outer: Symbol_Id) {
	if _, reserved := k.c.capture_placeholders[outer]; reserved {
		add_notef(k.c, symbol_of(k.c, outer).span, "it is captured here, and in the literal's body the name is the capture")
	}
}
