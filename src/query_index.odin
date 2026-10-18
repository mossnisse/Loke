// Index recorded semantic choices over written syntax and committed clones.
// No lookup, checking, or compiler registry mutation happens here.
package lokec

@(private)
Query_Index :: struct { c: ^Compiler, q: ^Snapshot_Queries, visited: map[rawptr]bool }

valid_query_span :: proc(c: ^Compiler, span: Span) -> bool {
	return span.file != NO_FILE && int(span.file) < len(c.sources) && span.lo < span.hi && int(span.hi) <= len(c.sources[span.file].text)
}

// Inferred generic bindings and lowering temporaries can carry a use's span.
// They are semantic symbols, but that span is not a written definition. A
// generated declaration named after the syntax it stands for, such as a capture
// literal's record, is not one either: a written name is an identifier.
written_query_binding :: proc(c: ^Compiler, symbol: ^Symbol) -> bool {
	if !valid_query_span(c, symbol.span) { return false }
	text := c.sources[symbol.span.file].text[symbol.span.lo:symbol.span.hi]
	return text == identifier_text(c, symbol.name) && identifier_spelling(text)
}

@(private)
identifier_spelling :: proc(text: string) -> bool {
	if text == "" || (text[0] >= '0' && text[0] <= '9') { return false }
	for b in transmute([]byte)text {
		if !(b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')) { return false }
	}
	return true
}

@(private = "file")
query_index_enter :: proc(index: ^Query_Index, node: rawptr) -> bool {
	if node == nil || index.visited[node] { return false }
	index.visited[node] = true
	return true
}

@(private = "file")
index_query_name :: proc(index: ^Query_Index, span: Span, name: string, symbol: Symbol_Id, type: Type_Id) {
	if !valid_query_span(index.c, span) || index.c.sources[span.file].text[span.lo:span.hi] != name || !identifier_spelling(name) { return }
	append(&index.q.occurrences, Query_Occurrence{span, symbol, type, symbol != INVALID_SYMBOL, false})
}

// Records a written binding's declaration extent once, on the binding clones
// share; the first walk is over written syntax.
@(private = "file")
index_query_binding :: proc(index: ^Query_Index, id: Symbol_Id, written: Span, attributes: []Attribute) {
	if id == INVALID_SYMBOL || int(id) >= len(index.q.symbols) { return }
	symbol := &index.q.symbols[index.q.canonical[id]]
	span := symbol.definition.span
	if span.file == NO_FILE || span.file != written.file || symbol.extent.span.file != NO_FILE { return }
	lo, hi := written.lo, written.hi
	text := index.c.sources[span.file].text
	extent := Span{file = span.file, lo = min(written_start(text, lo, attributes), span.lo), hi = max(hi, span.hi)}
	if int(extent.hi) > len(text) { return }
	symbol.extent.span = extent
}

// Syntax a local declared inside it cannot be reached outside of.
@(private = "file")
index_query_region :: proc(index: ^Query_Index, span: Span) {
	if valid_query_span(index.c, span) { append(&index.q.regions, span) }
}

@(private = "file")
index_query_attributes :: proc(index: ^Query_Index, attributes: []Attribute) {
	for attribute in attributes { index_query_expr(index, attribute.value) }
}

index_query_decl :: proc(index: ^Query_Index, decl: ^Decl) {
	if !query_index_enter(index, decl) { return }
	index_query_attributes(index, decl.attributes)
	if len(decl.names) > 0 {
		for symbol in decl.symbols { index_query_binding(index, symbol, Span{file = decl.names[0].span.file, lo = decl.names[0].span.lo, hi = decl.span.hi}, decl.attributes) }
	}
	index_query_expr(index, decl.declared_type)
	index_query_expr(index, decl.via)
	for value in decl.values {
		index_query_expr(index, value)
		if group, found := value.(^Expr_Proc_Group); found && len(decl.symbols) == 1 {
			if symbol := symbol_of(index.c, decl.symbols[0]); symbol != nil && symbol.kind == .Proc_Group {
				for name in group.names {
					for member in symbol.members {
						if bound := symbol_of(index.c, member); bound != nil && identifier_text(index.c, bound.name) == name.text {
							index_query_name(index, name.span, name.text, member, bound.proc_type)
						}
					}
				}
			}
		}
	}
}

index_query_item :: proc(index: ^Query_Index, item: Item) {
	if item == nil { return }
	if decl, found := item.(^Decl); found { index_query_decl(index, decl); return }
	base := item_base(item)
	if !query_index_enter(index, base) { return }
	index_query_attributes(index, base.attributes)
	switch v in item {
	case ^Decl, ^Item_Error, ^Item_Import, ^Item_Foreign_Import, ^Item_Delegate:
	case ^Item_Foreign_Block: for member in v.members { index_query_item(index, member) }
	case ^Item_Impl:
		index_query_expr(index, v.type)
		for member in v.members { index_query_item(index, member) }
	case ^Item_Block: for member in v.items { index_query_item(index, member) }
	case ^Item_When:
		index_query_expr(index, v.cond)
		if v.resolved {
			if v.taken { index_query_item(index, v.then) } else { index_query_item(index, v.otherwise) }
		}
	case ^Item_Static_Assert: index_query_expr(index, v.call)
	}
}

@(private = "file")
index_query_stmt :: proc(index: ^Query_Index, stmt: Stmt) {
	if stmt == nil { return }
	if decl, found := stmt.(^Decl); found { index_query_decl(index, decl); return }
	if impl, found := stmt.(^Item_Impl); found { index_query_item(index, impl); return }
	base := stmt_base(stmt)
	if !query_index_enter(index, base) { return }
	index_query_attributes(index, base.attributes)
	switch v in stmt {
	case ^Decl, ^Item_Impl, ^Stmt_Branch:
	case ^Stmt_Error: index_query_stmt(index, v.partial)
	case ^Block:
		index_query_region(index, v.span)
		for inner in v.stmts { index_query_stmt(index, inner) }
	case ^Stmt_Expr: for expr in v.exprs { index_query_expr(index, expr) }
	case ^Stmt_Assign:
		for expr in v.lhs { index_query_expr(index, expr) }
		for expr in v.rhs { index_query_expr(index, expr) }
	case ^Stmt_If:
		index_query_region(index, v.span)
		index_query_stmt(index, v.init)
		index_query_expr(index, v.cond)
		index_query_stmt(index, v.then)
		index_query_stmt(index, v.otherwise)
	case ^Stmt_For:
		index_query_region(index, v.span)
		index_query_stmt(index, v.init)
		index_query_expr(index, v.cond)
		index_query_stmt(index, v.post)
		index_query_stmt(index, v.body)
	case ^Stmt_Foreach:
		index_query_region(index, v.span)
		index_query_expr(index, v.iterable)
		if v.kind == .Static { for body in v.expansion { index_query_stmt(index, body) } } else { index_query_stmt(index, v.body) }
	case ^Stmt_When:
		index_query_expr(index, v.cond)
		// design.md "when statement": the selected branch's braces open no
		// scope, so its statements belong to the enclosing one.
		if v.selected != nil && query_index_enter(index, v.selected) {
			for inner in v.selected.stmts { index_query_stmt(index, inner) }
		}
	case ^Stmt_Switch:
		index_query_region(index, v.span)
		index_query_stmt(index, v.init)
		index_query_expr(index, v.subject)
		for entry in v.cases {
			index_query_region(index, entry.span)
			for value in entry.values { index_query_expr(index, value) }
			for inner in entry.stmts { index_query_stmt(index, inner) }
		}
	case ^Stmt_Defer: index_query_stmt(index, v.stmt)
	case ^Stmt_Return: if v.value != nil { index_query_expr(index, v.value.expr) }
	}
}

// The operand a written selector selects from. design.md "Promoted struct
// fields": the checker turns `e.x` into `e.position.x`, and each link it adds
// carries the written name's span, so the written operand is the one below them.
// Below those, an implicit `p^` through a pointer or box spans its operand,
// where a written one ends at its `^`; the receiver is the pointer or box, whose
// own members a selector reaches first (design.md "Methods and implementation
// blocks").
@(private = "file")
index_query_operand :: proc(index: ^Query_Index, selector: ^Expr_Selector) {
	span := selector.name.span
	if !valid_query_span(index.c, span) || index.c.sources[span.file].text[span.lo:span.hi] != selector.name.text { return }
	operand := selector.operand
	for {
		link, added := operand.(^Expr_Selector)
		if !added || link.name.span != span { break }
		operand = link.operand
	}
	if deref, found := operand.(^Expr_Postfix); found && deref.op == .Caret {
		if inner := expr_base(deref.operand); inner != nil && deref.op_span == inner.span { operand = deref.operand }
	}
	base := expr_base(operand)
	if base == nil { return }
	type := base.denoted_type != INVALID_TYPE ? base.denoted_type : base.type
	if base.resolution.kind == .Package { type = INVALID_TYPE }
	symbol := base.resolution.symbol
	if ident, named := operand.(^Expr_Ident); named && symbol == INVALID_SYMBOL { symbol = ident.symbol }
	append(&index.q.operands, Query_Occurrence{span, symbol, type, false, base.denoted_type != INVALID_TYPE})
}

index_query_expr :: proc(index: ^Query_Index, expr: Expr) {
	if expr == nil { return }
	base := expr_base(expr)
	if !query_index_enter(index, base) { return }
	type := base.denoted_type != INVALID_TYPE ? base.denoted_type : base.type
	if base.resolution.kind == .Package { type = INVALID_TYPE }
	if valid_query_span(index.c, base.span) {
		append(&index.q.occurrences, Query_Occurrence{span = base.span, type = type, type_value = base.denoted_type != INVALID_TYPE})
	}
	switch v in expr {
	case ^Expr_Error, ^Expr_Literal, ^Type_Type, ^Type_Poly:
	case ^Expr_Ident:
		symbol := v.resolution.symbol != INVALID_SYMBOL ? v.resolution.symbol : v.symbol
		index_query_name(index, v.span, v.name, symbol, type)
	case ^Expr_Selector:
		index_query_name(index, v.name.span, v.name.text, v.resolution.symbol, type)
		index_query_operand(index, v)
		index_query_expr(index, v.operand)
	case ^Expr_Checked_Extract:
		index_query_expr(index, v.operand)
		index_query_expr(index, v.target)
	case ^Expr_Index:
		index_query_expr(index, v.operand)
		for value in v.indices { index_query_expr(index, value) }
	case ^Expr_Slice:
		index_query_expr(index, v.operand)
		index_query_expr(index, v.lo)
		index_query_expr(index, v.hi)
	case ^Expr_Call:
		index_query_expr(index, v.callee)
		// A named argument names a parameter of the procedure the call chose.
		callee := symbol_of(index.c, expr_base(v.callee).resolution.symbol)
		for argument in v.args {
			if argument.name.text != "" && callee != nil {
				for parameter in callee.param_symbols {
					if bound := symbol_of(index.c, parameter); bound != nil && identifier_text(index.c, bound.name) == argument.name.text {
						index_query_name(index, argument.name.span, argument.name.text, parameter, bound.type)
					}
				}
			}
			index_query_expr(index, argument.value)
		}
	case ^Expr_Postfix:
		index_query_expr(index, v.operand)
		index_query_expr(index, v.failure)
	case ^Expr_Propagated_Error:
	case ^Expr_Unary: index_query_expr(index, v.operand)
	case ^Expr_Binary:
		index_query_expr(index, v.lhs)
		index_query_expr(index, v.rhs)
	case ^Expr_Range:
		index_query_expr(index, v.lo)
		index_query_expr(index, v.hi)
	case ^Expr_Or_Else:
		index_query_expr(index, v.value)
		index_query_expr(index, v.fallback)
		index_query_expr(index, or_else_exit_value(v))
	case ^Expr_Cond:
		index_query_expr(index, v.cond)
		index_query_expr(index, v.then)
		index_query_expr(index, v.otherwise)
	case ^Expr_Move: index_query_expr(index, v.value)
	case ^Expr_Composite:
		index_query_expr(index, v.type_expr)
		index_query_expr(index, v.via)
		info := underlying_info(index.c, type)
		for element, slot in v.elements {
			if name, named := element.key.(^Expr_Ident); named && info != nil && info.kind == .Struct && slot < len(v.field_indices) && v.field_indices[slot] >= 0 && v.field_indices[slot] < len(info.fields) {
				field := info.fields[v.field_indices[slot]]
				index_query_name(index, name.span, name.name, field, symbol_of(index.c, field).type)
			} else { index_query_expr(index, element.key) }
			index_query_expr(index, element.value)
		}
		// A capture literal's body is checked as its record's `call`.
		if v.capture != nil && v.capture.method != nil {
			index_query_expr(index, v.capture.method)
		}
	case ^Expr_Proc:
		index_query_region(index, v.span)
		index_query_expr(index, v.signature)
		for clause in v.where_clauses { index_query_expr(index, clause) }
		index_query_stmt(index, v.body)
	case ^Expr_Proc_Group:
	case ^Expr_Operator: index_query_expr(index, v.value)
	case ^Type_Pointer: index_query_expr(index, v.elem)
	case ^Type_C_Pointer: index_query_expr(index, v.elem)
	case ^Type_Slice: index_query_expr(index, v.elem)
	case ^Type_Dynamic_Array: index_query_expr(index, v.elem)
	case ^Type_Distinct: index_query_expr(index, v.elem)
	case ^Type_Array:
		index_query_expr(index, v.length)
		index_query_expr(index, v.elem)
	case ^Type_Map:
		index_query_expr(index, v.key)
		index_query_expr(index, v.value)
	case ^Type_Dyn: index_query_expr(index, v.interface_expr)
	case ^Type_Proc:
		for parameter in v.params {
			for symbol in parameter.symbols { index_query_binding(index, symbol, parameter.span, parameter.attributes) }
			index_query_attributes(index, parameter.attributes)
			index_query_expr(index, parameter.type)
			index_query_expr(index, parameter.default)
		}
		if v.result != nil { index_query_expr(index, v.result.type) }
	case ^Type_Record:
		index_query_attributes(index, v.attributes)
		for parameter in v.generic_params { index_query_expr(index, parameter.type) }
		for clause in v.where_clauses { index_query_expr(index, clause) }
		for field in v.fields {
			for symbol in field.symbols { index_query_binding(index, symbol, field.span, field.attributes) }
			index_query_attributes(index, field.attributes)
			index_query_expr(index, field.type)
		}
		for variant in v.variants { index_query_expr(index, variant.type) }
	case ^Type_Anon_Record:
		for field in v.fields {
			for symbol in field.symbols { index_query_binding(index, symbol, field.span, field.attributes) }
			index_query_expr(index, field.type)
		}
	case ^Type_Anon_Union:
		for variant in v.variants { index_query_expr(index, variant.type) }
	case ^Type_Enum:
		index_query_expr(index, v.backing)
		for field in v.fields {
			index_query_binding(index, field.symbol, field.span, nil)
			index_query_expr(index, field.value)
		}
	case ^Type_Interface:
		for parameter in v.generic_params { index_query_expr(index, parameter.type) }
		for clause in v.where_clauses { index_query_expr(index, clause) }
		for requirement in v.requirements {
			for binding in requirement.bindings { index_query_expr(index, binding.type) }
			index_query_expr(index, requirement.expr)
			index_query_expr(index, requirement.result)
			index_query_expr(index, requirement.slot_type)
		}
	}
}
