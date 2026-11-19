// Syntax the compiler writes itself: lowered forms that are then checked as the
// code a programmer would write. Each builder fills in only what the parser
// would, in the semantic arena; the caller names any span that differs.
package lokec

import "core:fmt"
import "core:slice"

synth_name :: proc(c: ^Compiler, text: string, span: Span) -> Name {
	return Name{text = text, span = span, id = intern_identifier(c, text)}
}

synth_ident :: proc(c: ^Compiler, text: string, span: Span) -> ^Expr_Ident {
	return synth_ident_as(c, text, intern_identifier(c, text), span)
}

// An identifier reading `text` that resolves through `id`: a name no source can
// spell, bound only where the lowering wants it found.
synth_ident_as :: proc(c: ^Compiler, text: string, id: Identifier_Id, span: Span) -> ^Expr_Ident {
	ident := new(Expr_Ident, c.semantic_allocator)
	ident.span = span
	ident.name, ident.name_id = text, id
	return ident
}

// `operand.field`, or the implicit `.field` for a nil operand.
synth_selector :: proc(c: ^Compiler, operand: Expr, field: string, span: Span) -> ^Expr_Selector {
	selector := new(Expr_Selector, c.semantic_allocator)
	selector.span = span
	selector.operand = operand
	selector.name = synth_name(c, field, span)
	return selector
}

synth_deref :: proc(c: ^Compiler, operand: Expr, span: Span) -> ^Expr_Postfix {
	deref := new(Expr_Postfix, c.semantic_allocator)
	deref.span = span
	deref.op, deref.op_span = .Caret, span
	deref.operand = operand
	return deref
}

synth_address :: proc(c: ^Compiler, operand: Expr, mutable: bool, span: Span) -> ^Expr_Unary {
	address := new(Expr_Unary, c.semantic_allocator)
	address.span = span
	address.op, address.op_span = .Amp, span
	address.mutable = mutable
	address.operand = operand
	return address
}

synth_move :: proc(c: ^Compiler, value: Expr, span: Span) -> Expr {
	moved := new(Expr_Move, c.semantic_allocator)
	moved.span = span
	moved.value = value
	return moved
}

synth_call :: proc(c: ^Compiler, callee: Expr, values: []Expr, span: Span) -> ^Expr_Call {
	call := new(Expr_Call, c.semantic_allocator)
	call.span = span
	call.callee = callee
	call.args = make([]Argument, len(values), c.semantic_allocator)
	for value, index in values {
		call.args[index] = Argument{span = span, value = value}
	}
	return call
}

synth_expr_stmt :: proc(c: ^Compiler, value: Expr, span: Span) -> Stmt {
	s := new(Stmt_Expr, c.semantic_allocator)
	s.span = span
	s.exprs = make([]Expr, 1, c.semantic_allocator)
	s.exprs[0] = value
	return s
}

synth_return :: proc(c: ^Compiler, value: ^Return_Value, span: Span) -> ^Stmt_Return {
	exit := new(Stmt_Return, c.semantic_allocator)
	exit.span = span
	exit.value = value
	return exit
}

synth_return_value :: proc(c: ^Compiler, value: Expr, span: Span) -> ^Return_Value {
	returned := new(Return_Value, c.semantic_allocator)
	returned.span = span
	returned.expr = value
	return returned
}

synth_block :: proc(c: ^Compiler, stmts: []Stmt, span: Span) -> ^Block {
	block := new(Block, c.semantic_allocator)
	block.span = span
	block.stmts = stmts
	return block
}

// `name := value;`, `name :: value;`, or either with its type written.
synth_decl :: proc(c: ^Compiler, kind: Decl_Kind, name: string, value: Expr, span: Span, declared_type: Expr = nil) -> ^Decl {
	d := new(Decl, c.semantic_allocator)
	d.span = span
	d.kind = kind
	d.names = make([]Name, 1, c.semantic_allocator)
	d.names[0] = synth_name(c, name, span)
	d.declared_type = declared_type
	d.values = make([]Expr, 1, c.semantic_allocator)
	d.values[0] = value
	return d
}

// `lhs = rhs;`: each value stored to the destination at its position.
synth_assign :: proc(c: ^Compiler, lhs, rhs: []Expr, op_span, span: Span) -> ^Stmt_Assign {
	assign := new(Stmt_Assign, c.semantic_allocator)
	assign.span = span
	assign.op, assign.op_span = .Assign, op_span
	assign.lhs = slice.clone(lhs, c.semantic_allocator)
	assign.rhs = slice.clone(rhs, c.semantic_allocator)
	return assign
}

// A name for `type` that only `scope` binds, written where a type is: `text` is
// how it reads, and `name`, which no source can spell, how it resolves.
synth_type_name :: proc(c: ^Compiler, scope: ^Scope, text, name: string, type: Type_Id, span: Span) -> Expr {
	alias := intern_identifier(c, name)
	scope.names[alias] = new_associated_type(c, text, type, INVALID_TYPE)
	return synth_ident_as(c, text, alias, span)
}

// A record field whose type is bound to a name only the current scope has.
synth_record_field :: proc(k: ^Checker, alias_prefix: string, index: int, name: Name, type: Type_Id, span: Span) -> Field {
	c := k.c
	names := make([]Name, 1, c.semantic_allocator)
	names[0] = name
	type_name := synth_type_name(c, k.scope, alias_prefix, fmt.tprintf("%s$%d", alias_prefix, index), type, span)
	return Field{span = span, names = names, type = type_name}
}

// A struct declared in the current scope, or INVALID_TYPE once reported.
synth_record :: proc(k: ^Checker, name, alias_prefix: string, field_names: []string, types: []Type_Id, span: Span) -> Type_Id {
	c := k.c
	record := new(Type_Record, c.semantic_allocator)
	record.span = span
	record.kind = .Struct
	record.fields = make([]Field, len(types), c.semantic_allocator)
	for type, index in types {
		record.fields[index] = synth_record_field(k, alias_prefix, index, synth_name(c, field_names[index], span), type, span)
	}
	decl := synth_decl(c, .Const, name, record, span)
	check_local_declaration(k, decl)
	if len(decl.symbols) != 1 {
		return INVALID_TYPE
	}
	sym := symbol_of(c, decl.symbols[0])
	return sym == nil ? INVALID_TYPE : sym.type
}
