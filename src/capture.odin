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

import "core:fmt"
import "core:strings"

// The receiver every lowered `call` takes. It is spelled `self`, so it is a
// receiver, but no source name reaches it: an enclosing method's `self` stays
// that method's, which the literal cannot capture without saying so.
CAPTURE_RECEIVER :: "self$capture"

// The record type the literal is a value of, or INVALID_TYPE once reported.
lower_capture_literal :: proc(k: ^Checker, v: ^Expr_Composite) -> Type_Id {
	capture := v.capture
	if capture.record != INVALID_TYPE {
		return capture.record
	}
	literal := capture.procedure
	// design.md "where clauses": a literal is a value, so never generic.
	if !proc_shape_ok(k, literal, is_value = true) || !capture_literal_shape_ok(k, v) {
		return INVALID_TYPE
	}

	// The literal is the record's: each entry's value, taken as its mode says,
	// is checked once, here, and its field has the type that check gives it.
	// A second check could give a different type: a capture literal inside
	// one makes a new record each time it is checked.
	v.elements = make([]Element, len(capture.entries), k.c.semantic_allocator)
	types := make([]Type_Id, len(capture.entries), k.c.semantic_allocator)
	checked := true
	for entry, index in capture.entries {
		value := entry.value
		switch entry.mode {
		case .Copy:
		case .Borrow, .Borrow_Mut:
			address := new(Expr_Unary, k.c.semantic_allocator)
			address.span = entry.span
			address.op, address.op_span = .Amp, entry.span
			address.mutable = entry.mode == .Borrow_Mut
			address.operand = entry.value
			value = address
		case .Move:
			moved := new(Expr_Move, k.c.semantic_allocator)
			moved.span = entry.span
			moved.value = entry.value
			value = moved
		}
		v.elements[index] = Element{span = entry.span, value = value}
		type := check_single_expr(k, value)
		if type == INVALID_TYPE {
			checked = false
			continue
		}
		types[index] = default_type(k.c, type)
	}
	if !checked {
		return INVALID_TYPE
	}

	outer := k.scope
	k.scope = new_scope(k.c, outer, .Local)
	defer k.scope = outer

	// Each captured name, reserved where the body can see it: declaring a local
	// of the same name in the body shadows it, and a position the body's
	// rewrite leaves alone resolves to it rather than to an enclosing local.
	fields := make([]Capture_Field, len(capture.entries), k.c.semantic_allocator)
	placeholders := make([]Symbol_Id, len(capture.entries), k.c.semantic_allocator)
	for entry, index in capture.entries {
		text := strings.concatenate({"capture$", entry.name.text}, k.c.semantic_allocator)
		fields[index] = Capture_Field {
			mode  = entry.mode,
			field = Name{text = text, span = entry.name.span, id = intern_identifier(k.c, text)},
		}
		id := name_identifier(k.c, entry.name)
		placeholder := new_symbol(k.c, Symbol{name = id, span = entry.name.span, kind = .Var, pkg = k.pkg})
		k.scope.names[id] = placeholder
		placeholders[index] = placeholder
	}

	// The record, with each field's type bound to a name only this scope has.
	// Its fields are named apart from the source, so a capture called `call`
	// leaves room for the method.
	span := Span{file = v.span.file, lo = v.span.lo, hi = capture.clause_span.hi}
	text := strings.clone(k.c.sources[span.file].text[span.lo:span.hi], k.c.semantic_allocator)
	record_name := Name{text = text, span = span, id = intern_identifier(k.c, text)}
	record := new(Type_Record, k.c.semantic_allocator)
	record.span = span
	record.kind = .Struct
	record.fields = make([]Field, len(capture.entries), k.c.semantic_allocator)
	for entry, index in capture.entries {
		alias := intern_identifier(k.c, fmt.aprintf("capture$type$%d", index, allocator = k.c.semantic_allocator))
		k.scope.names[alias] = new_associated_type(k.c, "capture$type", types[index], INVALID_TYPE)
		field_type := new(Expr_Ident, k.c.semantic_allocator)
		field_type.span = entry.span
		field_type.name = entry.name.text
		field_type.name_id = alias
		names := make([]Name, 1, k.c.semantic_allocator)
		names[0] = fields[index].field
		record.fields[index] = Field{span = entry.span, names = names, type = field_type}
	}
	declaration := new(Decl, k.c.semantic_allocator)
	declaration.span = span
	declaration.kind = .Const
	declaration.names = make([]Name, 1, k.c.semantic_allocator)
	declaration.names[0] = record_name
	declaration.values = make([]Expr, 1, k.c.semantic_allocator)
	declaration.values[0] = record
	check_local_declaration(k, declaration)
	record_symbol := symbol_of(k.c, declaration.symbols[0])
	if record_symbol == nil || record_symbol.type == INVALID_TYPE {
		return INVALID_TYPE
	}
	// Its fields are the captures, which only its `call` reads.
	method := capture_call_method(k, capture, fields)
	k.c.capture_records[record_symbol.type] = method
	for placeholder, index in placeholders {
		k.c.capture_placeholders[placeholder] = Capture_Placeholder{field = fields[index], method = method}
	}
	if info := type_of(k.c, record_symbol.type); info != nil {
		for field in info.fields {
			if sym := symbol_of(k.c, field); sym != nil {
				sym.owner_type = record_symbol.type
			}
		}
	}

	// Its `call`, whose body reads each capture through the receiver.
	subject := new(Expr_Ident, k.c.semantic_allocator)
	subject.span = span
	subject.name, subject.name_id = record_name.text, record_name.id
	member := new(Decl, k.c.semantic_allocator)
	member.span = literal.span
	member.kind = .Const
	member.names = make([]Name, 1, k.c.semantic_allocator)
	member.names[0] = Name{text = "call", span = literal.span, id = intern_identifier(k.c, "call")}
	member.values = make([]Expr, 1, k.c.semantic_allocator)
	member.values[0] = method
	block := new(Item_Impl, k.c.semantic_allocator)
	block.span = span
	block.kind = .Impl
	block.type = subject
	block.members = make([]Item, 1, k.c.semantic_allocator)
	block.members[0] = member
	check_local_impl(k, block)
	capture.method = method

	// A probe's record has no hoisted `call`, so the check that commits makes
	// its own.
	if committing(k.c) {
		capture.record = record_symbol.type
	}
	return record_symbol.type
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
	if literal.signature != nil && literal.signature.convention != "" {
		errorf(
			k.c, capture.clause_span, "L0716",
			"a capture literal is called through a `call` method, which has no `\"%s\"` calling convention",
			literal.signature.convention,
		)
		ok = false
	}
	seen := make(map[Identifier_Id]Span, len(capture.entries), context.temp_allocator)
	for entry in capture.entries {
		id := name_identifier(k.c, entry.name)
		if _, again := seen[id]; again {
			errorf(k.c, entry.name.span, "L0716", "`%s` is already captured by this literal", entry.name.text)
			ok = false
			continue
		}
		seen[id] = entry.name.span
	}
	if literal.signature != nil {
		for parameter in literal.signature.params {
			for name in parameter.names {
				if _, captured := seen[name_identifier(k.c, name.name)]; captured {
					errorf(
						k.c, name.name.span, "L0716",
						"`%s` is both a parameter and a capture of this literal; rename one",
						name.name.text,
					)
					ok = false
				}
			}
		}
	}
	return ok
}

// `call :: proc(self, <the literal's parameters>) -> <its result> { <body> }`,
// with every captured name in the body rewritten to the receiver's field.
@(private = "file")
capture_call_method :: proc(k: ^Checker, capture: ^Capture_Literal, fields: []Capture_Field) -> ^Expr_Proc {
	literal := capture.procedure
	receiver := intern_identifier(k.c, CAPTURE_RECEIVER)
	signature := clone_expr(k.c, literal.signature).(^Type_Proc)
	params := make([]Parameter, len(signature.params) + 1, k.c.semantic_allocator)
	self_name := make([]Param_Name, 1, k.c.semantic_allocator)
	self_name[0] = Param_Name{name = Name{text = "self", span = capture.clause_span, id = receiver}}
	params[0] = Parameter{span = capture.clause_span, names = self_name, mode = .Value}
	copy(params[1:], signature.params)
	signature.params = params

	rewrite := Capture_Rewrite{receiver = receiver}
	rewrite.captures = make(map[Identifier_Id]Capture_Field, len(capture.entries), k.c.semantic_allocator)
	for entry, index in capture.entries {
		rewrite.captures[name_identifier(k.c, entry.name)] = fields[index]
	}
	saved := k.c.capture_rewrite
	k.c.capture_rewrite = &rewrite
	body := clone_block(k.c, literal.body)
	k.c.capture_rewrite = saved

	method := new(Expr_Proc, k.c.semantic_allocator)
	method.span = literal.span
	method.signature = signature
	method.body = body
	return method
}

// The place a name reserved for a capture reads, as the body's rewrite would
// have written it, when a position that rewrite left alone resolves to it.
// Nil for any other name.
capture_place_of :: proc(k: ^Checker, name: ^Expr_Ident) -> Expr {
	placeholder, reserved := k.c.capture_placeholders[lookup_symbol(k.scope, identifier_of(k.c, name))]
	if !reserved || placeholder.method != k.proc_literal {
		return nil
	}
	return capture_field_place(k.c, intern_identifier(k.c, CAPTURE_RECEIVER), placeholder.field, name.span)
}

// A name a capture literal reserves for one of its captures.
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
	method, is_capture := k.c.capture_records[sym.owner_type]
	if sym.kind != .Field || !is_capture {
		return true
	}
	return k.body.proc_literal == method || k.body.building_capture == sym.owner_type
}

// A local in a capture literal's body cannot take a capture's name: every use
// of that name in the body is the capture.
note_shadowed_capture :: proc(k: ^Checker, outer: Symbol_Id) {
	if _, reserved := k.c.capture_placeholders[outer]; reserved {
		if sym := symbol_of(k.c, outer); sym != nil {
			add_notef(k.c, sym.span, "it is captured here, and in the literal's body the name is the capture")
		}
	}
}
