// Index recorded semantic choices over written syntax and committed clones.
// No lookup, checking, or compiler registry mutation happens here.
package lokec

@(private = "file")
Query_Index :: struct {
	c:         ^Compiler,
	q:         ^Snapshot_Queries,
	visited:   map[rawptr]bool,
	// Syntax that opens a lexical scope.
	regions:   [dynamic]Span,
	// The span of the statement a lowered block stands for, which the nodes
	// lowering made up carry.
	generated: Span,
}

// Written syntax first, then the clones and generated declarations only symbols
// reach. Returns the regions, in the temporary allocator like the rest of what
// only the walk reads.
@(private)
index_query_syntax :: proc(c: ^Compiler, q: ^Snapshot_Queries) -> []Span {
	index := Query_Index{c = c, q = q, visited = make(map[rawptr]bool, allocator = context.temp_allocator), regions = make([dynamic]Span, context.temp_allocator)}
	for file in c.parsed_files { for item in file.items { index_query_item(&index, item) } }
	for symbol in c.symbols {
		if symbol.decl != nil { index_query_decl(&index, symbol.decl) }
		if symbol.proc_literal != nil { index_query_expr(&index, symbol.proc_literal) }
	}
	return index.regions[:]
}

@(private)
valid_query_span :: proc(c: ^Compiler, span: Span) -> bool {
	source := span_source(c, span)
	return source != nil && span.lo < span.hi && int(span.hi) <= len(source.text)
}

@(private = "file")
query_span_spells :: proc(c: ^Compiler, span: Span, name: string) -> bool {
	return valid_query_span(c, span) && span_text(c, span) == name
}

// Inferred generic bindings and lowering temporaries can carry a use's span.
// They are semantic symbols, but that span is not a written definition. A
// generated declaration named after the syntax it stands for, such as a capture
// literal's record, is not one either: a written name is an identifier.
@(private)
written_query_binding :: proc(c: ^Compiler, symbol: ^Symbol) -> bool {
	name := identifier_text(c, symbol.name)
	return query_span_spells(c, symbol.span, name) && identifier_spelling(name)
}

@(private = "file")
query_index_enter :: proc(index: ^Query_Index, node: rawptr) -> bool {
	if node == nil || index.visited[node] { return false }
	index.visited[node] = true
	return true
}

@(private = "file")
index_query_name :: proc(index: ^Query_Index, span: Span, name: string, symbol: Symbol_Id, type: Type_Id, type_value := false) {
	if !query_span_spells(index.c, span, name) || !identifier_spelling(name) { return }
	append(&index.q.occurrences[span.file], Query_Occurrence{span, symbol, type, symbol != INVALID_SYMBOL, type_value})
}

// A written name, bound to the candidates spelled the same.
@(private = "file")
index_query_bound_name :: proc(index: ^Query_Index, name: Name, candidates: []Symbol_Id) {
	for candidate in candidates {
		if bound := symbol_of(index.c, candidate); bound != nil && identifier_text(index.c, bound.name) == name.text {
			index_query_name(index, name.span, name.text, candidate, symbol_value_type(bound))
		}
	}
}

// Records a written binding's declaration extent once, on the binding clones
// share; the first walk is over written syntax.
@(private = "file")
index_query_binding :: proc(index: ^Query_Index, id: Symbol_Id, written: Span) {
	if id == INVALID_SYMBOL { return }
	symbol := &index.q.symbols[index.q.canonical[id]]
	span := symbol.definition.span
	if span.file == NO_FILE || span.file != written.file || symbol.extent.span.file != NO_FILE { return }
	symbol.extent.span = Span{file = span.file, lo = min(written.lo, span.lo), hi = max(written.hi, span.hi)}
}

@(private = "file")
index_query_region :: proc(index: ^Query_Index, span: Span) {
	if valid_query_span(index.c, span) { append(&index.regions, span) }
}

@(private = "file")
index_query_attributes :: proc(index: ^Query_Index, attributes: []Attribute) {
	for attribute in attributes { index_query_expr(index, attribute.value) }
}

@(private = "file")
index_query_decl :: proc(index: ^Query_Index, decl: ^Decl) {
	if !query_index_enter(index, decl) { return }
	index_query_attributes(index, decl.attributes)
	for symbol in decl.symbols { index_query_binding(index, symbol, decl.span) }
	index_query_expr(index, decl.declared_type)
	index_query_expr(index, decl.via)
	for value in decl.values {
		index_query_expr(index, value)
		grouped := value
		if operator, is_operator := value.(^Expr_Operator); is_operator { grouped = operator.value }
		if group, found := grouped.(^Expr_Proc_Group); found && len(decl.symbols) == 1 {
			if symbol := symbol_of(index.c, decl.symbols[0]); symbol != nil && symbol.kind == .Proc_Group {
				for name in group.names { index_query_bound_name(index, name, symbol.members) }
			}
		}
	}
}

@(private = "file")
index_query_item :: proc(index: ^Query_Index, item: Item) {
	if decl, found := item.(^Decl); found { index_query_decl(index, decl); return }
	base := item_base(item)
	if !query_index_enter(index, base) { return }
	index_query_attributes(index, base.attributes)
	switch v in item {
	case ^Decl, ^Item_Error, ^Item_Import, ^Item_Foreign_Import, ^Item_Delegate:
	case ^Item_Foreign_Block: for member in v.members { index_query_decl(index, member) }
	case ^Item_Impl:
		index_query_expr(index, v.type)
		for member in v.members { index_query_item(index, member) }
	case ^Item_Block: for member in v.items { index_query_item(index, member) }
	case ^Item_When:
		index_query_expr(index, v.cond)
		index_query_item(index, item_when_selected(v))
	case ^Item_Static_Assert: index_query_expr(index, v.call)
	}
}

@(private = "file")
index_query_stmt :: proc(index: ^Query_Index, stmt: Stmt) {
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
		// Its operands were checked as clones in the block checking ran instead.
		if v.lowered != nil {
			enclosing := index.generated
			index.generated = v.span
			for inner in v.lowered.stmts { index_query_stmt(index, inner) }
			index.generated = enclosing
		}
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
		if query_index_enter(index, v.selected) {
			for inner in v.selected.stmts { index_query_stmt(index, inner) }
		}
		if chained, found := v.otherwise.(^Stmt_When); found { index_query_stmt(index, chained) }
	case ^Stmt_Switch:
		index_query_region(index, v.span)
		index_query_stmt(index, v.init)
		index_query_expr(index, v.subject)
		for entry in v.cases {
			index_query_region(index, entry.span)
			// An expanded case's copies name their variants with selectors the
			// source never wrote (design.md "Per-variant switch cases").
			if entry.descriptor.aggregate == nil {
				for value in entry.values { index_query_expr(index, value) }
			}
			for inner in entry.stmts { index_query_stmt(index, inner) }
		}
	case ^Stmt_Defer: index_query_stmt(index, v.stmt)
	case ^Stmt_Parallel:
		index_query_region(index, v.span)
		index_query_expr(index, v.executor)
		index_query_stmt(index, v.body)
	case ^Stmt_Spawn:
		index_query_expr(index, v.result)
		index_query_expr(index, v.call)
	case ^Stmt_Return: if v.value != nil { index_query_expr(index, v.value.expr) }
	}
}

// design.md "Promoted struct fields": a promoted selector's added links carry the
// name's span, so the written operand is below them, and below any implicit `p^`,
// since the pointer's own members come first (design.md "Methods and implementation
// blocks").
@(private = "file")
index_query_operand :: proc(index: ^Query_Index, selector: ^Expr_Selector) {
	span := selector.name.span
	if !query_span_spells(index.c, span, selector.name.text) { return }
	operand := selector.operand
	for {
		link, added := operand.(^Expr_Selector)
		if !added || link.name.span != span { break }
		operand = link.operand
	}
	if is_implicit_deref(operand) { operand = operand.(^Expr_Postfix).operand }
	base := expr_base(operand)
	if base == nil { return }
	symbol := base.resolution.symbol
	if ident, named := operand.(^Expr_Ident); named && symbol == INVALID_SYMBOL { symbol = ident.symbol }
	append(&index.q.operands[span.file], Query_Occurrence{span, symbol, query_node_type(base), false, base.denoted_type != INVALID_TYPE})
}

// The type a node denotes, or its value's. A package has neither.
@(private = "file")
query_node_type :: proc(base: ^Expr_Base) -> Type_Id {
	if base.resolution.kind == .Package { return INVALID_TYPE }
	return base.denoted_type != INVALID_TYPE ? base.denoted_type : base.type
}

// An implicit `p^` spans what the source wrote and types what it does not. Recorded
// at that span it would conflict with its operand's type, as two instantiations do.
@(private = "file")
is_implicit_deref :: proc(expr: Expr) -> bool {
	deref, found := expr.(^Expr_Postfix)
	if !found || deref.op != .Caret { return false }
	inner := expr_base(deref.operand)
	return inner != nil && deref.op_span == inner.span
}

@(private = "file")
index_query_expr :: proc(index: ^Query_Index, expr: Expr) {
	base := expr_base(expr)
	if !query_index_enter(index, base) { return }
	type := query_node_type(base)
	if valid_query_span(index.c, base.span) && base.span != index.generated && !is_implicit_deref(expr) {
		append(&index.q.occurrences[base.span.file], Query_Occurrence{span = base.span, type = type, type_value = base.denoted_type != INVALID_TYPE})
	}
	switch v in expr {
	case ^Expr_Error, ^Expr_Literal, ^Expr_Propagated_Error, ^Expr_Proc_Group, ^Type_Type, ^Type_Poly:
	// Forms whose children are all that hold names.
	case ^Expr_Index, ^Expr_Slice, ^Expr_Postfix, ^Expr_Unary, ^Expr_Binary, ^Expr_Range, ^Expr_Or_Else, ^Expr_Cond,
	     ^Expr_Move, ^Expr_Operator, ^Type_Pointer, ^Type_C_Pointer, ^Type_Slice, ^Type_Dynamic_Array, ^Type_Distinct,
	     ^Type_Array, ^Type_Map, ^Type_Dyn, ^Type_Anon_Union:
		expr_children(expr, index, proc(data: rawptr, child: Expr) -> bool {
			index_query_expr((^Query_Index)(data), child)
			return false
		})
	case ^Expr_Ident:
		symbol := v.resolution.symbol != INVALID_SYMBOL ? v.resolution.symbol : v.symbol
		index_query_name(index, v.span, v.name, symbol, type)
	case ^Expr_Selector:
		index_query_name(index, v.name.span, v.name.text, v.resolution.symbol, type, v.denoted_type != INVALID_TYPE)
		index_query_operand(index, v)
		index_query_expr(index, v.operand)
	case ^Expr_Call:
		// design.md "Union argument expansion": each variant's call resolved the
		// written callee; their arguments are the expansion's own.
		if v.dispatch != nil {
			index_query_expr(index, v.dispatch.subject)
			for entry in v.dispatch.cases {
				if arm, is_call := entry.arm.(^Expr_Call); is_call { index_query_expr(index, arm.callee) }
			}
			return
		}
		index_query_expr(index, v.callee)
		// A named argument names a parameter of the procedure the call chose.
		callee := symbol_of(index.c, expr_base(v.callee).resolution.symbol)
		for argument in v.args {
			if argument.name.text != "" && callee != nil { index_query_bound_name(index, argument.name, callee.param_symbols) }
			index_query_expr(index, argument.value)
		}
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
		if v.capture != nil { index_query_expr(index, v.capture.method) }
	case ^Expr_Proc:
		index_query_region(index, v.span)
		index_query_expr(index, v.signature)
		for clause in v.where_clauses { index_query_expr(index, clause) }
		index_query_stmt(index, v.body)
	case ^Type_Proc:
		for parameter in v.params {
			for symbol in parameter.symbols { index_query_binding(index, symbol, parameter.span) }
			index_query_attributes(index, parameter.attributes)
			index_query_expr(index, parameter.type)
			index_query_expr(index, parameter.default)
		}
		if v.result != nil { index_query_expr(index, v.result.type) }
	case ^Type_Record:
		for parameter in v.generic_params { index_query_expr(index, parameter.type) }
		for clause in v.where_clauses { index_query_expr(index, clause) }
		for field in v.fields {
			for symbol in field.symbols { index_query_binding(index, symbol, field.span) }
			index_query_attributes(index, field.attributes)
			index_query_expr(index, field.type)
		}
		for variant in v.variants { index_query_expr(index, variant.type) }
	case ^Type_Anon_Record:
		for field in v.fields {
			for symbol in field.symbols { index_query_binding(index, symbol, field.span) }
			index_query_expr(index, field.type)
		}
	case ^Type_Enum:
		index_query_expr(index, v.backing)
		for field in v.fields {
			index_query_binding(index, field.symbol, field.span)
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
