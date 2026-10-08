// Index recorded semantic choices over written syntax and committed clones.
// No lookup, checking, or compiler registry mutation happens here.
package lokec

@(private)
Query_Index :: struct { c: ^Compiler, q: ^Snapshot_Queries, visited: map[rawptr]bool }

valid_query_span :: proc(c: ^Compiler, span: Span) -> bool {
	return span.file != NO_FILE && int(span.file) < len(c.sources) && span.lo < span.hi && int(span.hi) <= len(c.sources[span.file].text)
}

// Inferred generic bindings and lowering temporaries can carry a use's span.
// They are semantic symbols, but that span is not a written definition.
written_query_binding :: proc(c: ^Compiler, symbol: ^Symbol) -> bool {
	return valid_query_span(c, symbol.span) &&
	       c.sources[symbol.span.file].text[symbol.span.lo:symbol.span.hi] == identifier_text(c, symbol.name)
}

@(private = "file")
query_index_enter :: proc(index: ^Query_Index, node: rawptr) -> bool {
	if node == nil || index.visited[node] { return false }
	index.visited[node] = true
	return true
}

@(private = "file")
index_query_name :: proc(index: ^Query_Index, span: Span, name: string, symbol: Symbol_Id, type: Type_Id) {
	if !valid_query_span(index.c, span) || index.c.sources[span.file].text[span.lo:span.hi] != name { return }
	append(&index.q.occurrences, Query_Occurrence{span, symbol, type, symbol != INVALID_SYMBOL})
}

@(private = "file")
index_query_attributes :: proc(index: ^Query_Index, attributes: []Attribute) {
	for attribute in attributes { index_query_expr(index, attribute.value) }
}

index_query_decl :: proc(index: ^Query_Index, decl: ^Decl) {
	if !query_index_enter(index, decl) { return }
	index_query_attributes(index, decl.attributes)
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
	case ^Decl, ^Item_Impl, ^Stmt_Error, ^Stmt_Branch:
	case ^Block: for inner in v.stmts { index_query_stmt(index, inner) }
	case ^Stmt_Expr: for expr in v.exprs { index_query_expr(index, expr) }
	case ^Stmt_Assign:
		for expr in v.lhs { index_query_expr(index, expr) }
		for expr in v.rhs { index_query_expr(index, expr) }
	case ^Stmt_If:
		index_query_stmt(index, v.init)
		index_query_expr(index, v.cond)
		index_query_stmt(index, v.then)
		index_query_stmt(index, v.otherwise)
	case ^Stmt_For:
		index_query_stmt(index, v.init)
		index_query_expr(index, v.cond)
		index_query_stmt(index, v.post)
		index_query_stmt(index, v.body)
	case ^Stmt_Foreach:
		index_query_expr(index, v.iterable)
		if v.kind == .Static { for body in v.expansion { index_query_stmt(index, body) } } else { index_query_stmt(index, v.body) }
	case ^Stmt_When:
		index_query_expr(index, v.cond)
		index_query_stmt(index, v.selected)
	case ^Stmt_Switch:
		index_query_stmt(index, v.init)
		index_query_expr(index, v.subject)
		for entry in v.cases {
			for value in entry.values { index_query_expr(index, value) }
			for inner in entry.stmts { index_query_stmt(index, inner) }
		}
	case ^Stmt_Defer: index_query_stmt(index, v.stmt)
	case ^Stmt_Return: if v.value != nil { index_query_expr(index, v.value.expr) }
	}
}

index_query_expr :: proc(index: ^Query_Index, expr: Expr) {
	if expr == nil { return }
	base := expr_base(expr)
	if !query_index_enter(index, base) { return }
	type := base.denoted_type != INVALID_TYPE ? base.denoted_type : base.type
	if base.resolution.kind == .Package { type = INVALID_TYPE }
	if valid_query_span(index.c, base.span) {
		append(&index.q.occurrences, Query_Occurrence{span = base.span, type = type})
	}
	switch v in expr {
	case ^Expr_Error, ^Expr_Literal, ^Type_Type, ^Type_Poly:
	case ^Expr_Ident:
		symbol := v.resolution.symbol != INVALID_SYMBOL ? v.resolution.symbol : v.symbol
		index_query_name(index, v.span, v.name, symbol, type)
	case ^Expr_Selector:
		index_query_name(index, v.name.span, v.name.text, v.resolution.symbol, type)
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
		for argument in v.args { index_query_expr(index, argument.value) }
	case ^Expr_Postfix: index_query_expr(index, v.operand)
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
			index_query_attributes(index, parameter.attributes)
			index_query_expr(index, parameter.type)
			index_query_expr(index, parameter.default)
		}
		if v.result != nil { index_query_expr(index, v.result.type) }
	case ^Type_Record:
		index_query_attributes(index, v.attributes)
		for parameter in v.generic_params { index_query_expr(index, parameter.type) }
		for clause in v.where_clauses { index_query_expr(index, clause) }
		for field in v.fields { index_query_attributes(index, field.attributes); index_query_expr(index, field.type) }
		for variant in v.variants { index_query_expr(index, variant.type) }
	case ^Type_Anon_Record: for field in v.fields { index_query_expr(index, field.type) }
	case ^Type_Enum:
		index_query_expr(index, v.backing)
		for field in v.fields { index_query_expr(index, field.value) }
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
