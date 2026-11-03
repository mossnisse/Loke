// Deep syntax cloning. Type annotations live on the AST nodes (decision A1), so
// checking the same syntax twice — a generic instance, a static `foreach` copy —
// needs a fresh copy. A clone keeps spans and written syntax and drops what the
// checker fills in, except `Item_Impl.kind`, which a generic record's instance
// reads from its template. Clones live in the semantic arena.
package lokec

// ------------------------------------------------------------------ helpers --

// Zeroed, for the caller to fill; empty stays nil.
@(private = "file")
clone_slice :: proc(c: ^Compiler, list: []$T) -> []T {
	if len(list) == 0 {
		return nil
	}
	return make([]T, len(list), c.semantic_allocator)
}

@(private = "file")
new_clone :: proc(c: ^Compiler, src: ^$T) -> ^T {
	node := new(T, c.semantic_allocator)
	node.span = src.span
	node.has_error = src.has_error
	return node
}

@(private = "file")
new_node_clone :: proc(c: ^Compiler, src: ^$T) -> ^T {
	node := new_clone(c, src)
	node.attributes = clone_attributes(c, src.attributes)
	return node
}

@(private = "file")
clone_attributes :: proc(c: ^Compiler, list: []Attribute) -> []Attribute {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = entry
		out[index].value = clone_expr(c, entry.value)
	}
	return out
}

@(private = "file")
clone_exprs :: proc(c: ^Compiler, list: []Expr) -> []Expr {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = clone_expr(c, entry)
	}
	return out
}

@(private = "file")
clone_stmts :: proc(c: ^Compiler, list: []Stmt) -> []Stmt {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = clone_stmt(c, entry)
	}
	return out
}

@(private = "file")
clone_arguments :: proc(c: ^Compiler, list: []Argument) -> []Argument {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = Argument {
			span  = entry.span,
			name  = entry.name,
			mode  = entry.mode,
			value = clone_expr(c, entry.value),
		}
	}
	return out
}

@(private = "file")
clone_elements :: proc(c: ^Compiler, list: []Element) -> []Element {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = entry
		// A bare name before `=` is a field, never a capture.
		saved := c.capture_rewrite
		if _, is_name := entry.key.(^Expr_Ident); is_name {
			c.capture_rewrite = nil
		}
		out[index].key = clone_expr(c, entry.key)
		c.capture_rewrite = saved
		out[index].value = clone_expr(c, entry.value)
	}
	return out
}

@(private = "file")
clone_capture :: proc(c: ^Compiler, v: ^Capture_Literal) -> ^Capture_Literal {
	n := new(Capture_Literal, c.semantic_allocator)
	n.procedure = clone_expr(c, v.procedure).(^Expr_Proc)
	n.clause_span = v.clause_span
	n.entries = clone_slice(c, v.entries)
	for entry, index in v.entries {
		n.entries[index] = entry
		n.entries[index].value = clone_expr(c, entry.value)
	}
	return n
}

@(private = "file")
clone_params :: proc(c: ^Compiler, list: []Parameter) -> []Parameter {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = Parameter {
			span       = entry.span,
			attributes = clone_attributes(c, entry.attributes),
			names      = entry.names,
			mode       = entry.mode,
			type       = clone_expr(c, entry.type),
			default    = clone_expr(c, entry.default),
		}
	}
	return out
}

@(private = "file")
clone_result :: proc(c: ^Compiler, result: ^Result) -> ^Result {
	if result == nil {
		return nil
	}
	out := new(Result, c.semantic_allocator)
	out^ = result^
	out.type = clone_expr(c, result.type)
	return out
}

@(private = "file")
clone_fields :: proc(c: ^Compiler, list: []Field) -> []Field {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = Field {
			span       = entry.span,
			attributes = clone_attributes(c, entry.attributes),
			is_using   = entry.is_using,
			names      = entry.names,
			type       = clone_expr(c, entry.type),
		}
	}
	return out
}

@(private = "file")
clone_variants :: proc(c: ^Compiler, list: []Variant) -> []Variant {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = entry
		out[index].type = clone_expr(c, entry.type)
	}
	return out
}

@(private = "file")
clone_enum_fields :: proc(c: ^Compiler, list: []Enum_Field) -> []Enum_Field {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = Enum_Field {
			span  = entry.span,
			name  = entry.name,
			value = clone_expr(c, entry.value),
		}
	}
	return out
}

@(private = "file")
clone_generic_params :: proc(c: ^Compiler, list: []Generic_Param) -> []Generic_Param {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = Generic_Param {
			span  = entry.span,
			names = entry.names,
			type  = clone_expr(c, entry.type),
		}
	}
	return out
}

@(private = "file")
clone_bindings :: proc(c: ^Compiler, list: []Binding_Group) -> []Binding_Group {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = Binding_Group {
			span     = entry.span,
			names    = entry.names,
			is_inout = entry.is_inout,
			type     = clone_expr(c, entry.type),
		}
	}
	return out
}

clone_requirement :: proc(c: ^Compiler, requirement: Requirement) -> Requirement {
	out := requirement
	out.bindings = clone_bindings(c, requirement.bindings)
	out.expr = clone_expr(c, requirement.expr)
	out.result = clone_expr(c, requirement.result)
	out.slot_type = clone_expr(c, requirement.slot_type)
	return out
}

@(private = "file")
clone_requirements :: proc(c: ^Compiler, list: []Requirement) -> []Requirement {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = clone_requirement(c, entry)
	}
	return out
}

// ------------------------------------------------------------ expressions --

clone_expr :: proc(c: ^Compiler, e: Expr) -> Expr {
	switch v in e {
	case ^Expr_Error:
		return new_clone(c, v)

	case ^Expr_Literal:
		n := new_clone(c, v)
		n.kind, n.text = v.kind, v.text
		return n

	case ^Expr_Ident:
		if c.capture_rewrite != nil {
			if rewritten := rewrite_capture(c, v); rewritten != nil {
				return rewritten
			}
		}
		n := new_clone(c, v)
		n.name, n.name_id = v.name, v.name_id
		return n

	case ^Expr_Selector:
		n := new_clone(c, v)
		n.operand = clone_expr(c, v.operand)
		n.name = v.name
		return n

	case ^Expr_Index:
		n := new_clone(c, v)
		n.operand = clone_expr(c, v.operand)
		n.indices = clone_exprs(c, v.indices)
		return n

	case ^Expr_Slice:
		n := new_clone(c, v)
		n.mutable = v.mutable
		n.operand = clone_expr(c, v.operand)
		n.lo = clone_expr(c, v.lo)
		n.hi = clone_expr(c, v.hi)
		return n

	case ^Expr_Call:
		if c.alias_view != nil {
			if view := alias_view_of_application(c.alias_view, v); view != nil {
				return view
			}
		}
		n := new_clone(c, v)
		n.callee = clone_expr(c, v.callee)
		n.args = clone_arguments(c, v.args)
		return n

	case ^Expr_Postfix:
		n := new_clone(c, v)
		n.op, n.op_span = v.op, v.op_span
		n.operand = clone_expr(c, v.operand)
		n.failure = clone_expr(c, v.failure)
		return n

	case ^Expr_Propagated_Error:
		// The checker builds it under a checked `or_return`, which a clone drops.
		unreachable()

	case ^Expr_Unary:
		n := new_clone(c, v)
		n.op, n.op_span = v.op, v.op_span
		n.mutable = v.mutable
		n.operand = clone_expr(c, v.operand)
		return n

	case ^Expr_Binary:
		n := new_clone(c, v)
		n.op, n.op_span = v.op, v.op_span
		n.lhs = clone_expr(c, v.lhs)
		n.rhs = clone_expr(c, v.rhs)
		return n

	case ^Expr_Range:
		n := new_clone(c, v)
		n.op, n.op_span = v.op, v.op_span
		n.lo = clone_expr(c, v.lo)
		n.hi = clone_expr(c, v.hi)
		return n

	case ^Expr_Or_Else:
		n := new_clone(c, v)
		n.value = clone_expr(c, v.value)
		n.fallback = clone_expr(c, v.fallback)
		n.exit = clone_stmt(c, v.exit)
		return n

	case ^Expr_Cond:
		n := new_clone(c, v)
		n.then = clone_expr(c, v.then)
		n.cond = clone_expr(c, v.cond)
		n.otherwise = clone_expr(c, v.otherwise)
		return n

	case ^Expr_Move:
		n := new_clone(c, v)
		n.value = clone_expr(c, v.value)
		return n

	case ^Expr_Composite:
		n := new_clone(c, v)
		if v.capture != nil {
			// Its type and elements are what checking lowered it to.
			n.capture = clone_capture(c, v.capture)
			return n
		}
		n.type_expr = clone_expr(c, v.type_expr)
		n.elements = clone_elements(c, v.elements)
		return n

	case ^Expr_Proc:
		// A nested literal's body is its own: it captures nothing from this one
		// unless its clause names it, and that clause is rewritten by the caller.
		saved := c.capture_rewrite
		c.capture_rewrite = nil
		defer c.capture_rewrite = saved
		n := new_clone(c, v)
		n.signature = clone_expr(c, v.signature).(^Type_Proc)
		n.where_clauses = clone_exprs(c, v.where_clauses)
		n.body = clone_block(c, v.body)
		n.bodiless = v.bodiless
		return n

	case ^Expr_Proc_Group:
		n := new_clone(c, v)
		n.names = v.names
		return n

	case ^Expr_Operator:
		n := new_clone(c, v)
		n.symbol, n.symbol_span, n.hook = v.symbol, v.symbol_span, v.hook
		n.value = clone_expr(c, v.value)
		return n

	case ^Type_Pointer:
		n := new_clone(c, v)
		n.mutable = v.mutable
		n.elem = clone_expr(c, v.elem)
		return n

	case ^Type_C_Pointer:
		n := new_clone(c, v)
		n.elem = clone_expr(c, v.elem)
		return n

	case ^Type_Slice:
		n := new_clone(c, v)
		n.mutable = v.mutable
		n.elem = clone_expr(c, v.elem)
		return n

	case ^Type_Dynamic_Array:
		n := new_clone(c, v)
		n.elem = clone_expr(c, v.elem)
		return n

	case ^Type_Array:
		n := new_clone(c, v)
		n.length = clone_expr(c, v.length)
		n.inferred = v.inferred
		n.elem = clone_expr(c, v.elem)
		return n

	case ^Type_Map:
		n := new_clone(c, v)
		n.key = clone_expr(c, v.key)
		n.value = clone_expr(c, v.value)
		return n

	case ^Type_Distinct:
		n := new_clone(c, v)
		n.elem = clone_expr(c, v.elem)
		return n

	case ^Type_Dyn:
		n := new_clone(c, v)
		n.mutable = v.mutable
		n.interface_expr = clone_expr(c, v.interface_expr)
		return n

	case ^Type_Type:
		return new_clone(c, v)

	case ^Type_Poly:
		if c.poly_substitution != nil {
			if written, found := c.poly_substitution[name_identifier(c, v.name)]; found {
				saved_substitution, saved_view := c.poly_substitution, c.alias_view
				c.poly_substitution, c.alias_view = nil, nil
				defer c.poly_substitution, c.alias_view = saved_substitution, saved_view
				return clone_expr(c, written)
			}
		}
		n := new_clone(c, v)
		n.name = v.name
		return n

	case ^Type_Proc:
		n := new_clone(c, v)
		n.convention = v.convention
		n.params = clone_params(c, v.params)
		n.result = clone_result(c, v.result)
		return n

	case ^Type_Record:
		n := new_clone(c, v)
		n.kind = v.kind
		n.move_only = v.move_only
		n.generic_params = clone_generic_params(c, v.generic_params)
		n.attributes = clone_attributes(c, v.attributes)
		n.where_clauses = clone_exprs(c, v.where_clauses)
		n.fields = clone_fields(c, v.fields)
		n.variants = clone_variants(c, v.variants)
		return n

	case ^Type_Anon_Record:
		n := new_clone(c, v)
		n.fields = clone_fields(c, v.fields)
		return n

	case ^Type_Anon_Union:
		n := new_clone(c, v)
		n.variants = clone_variants(c, v.variants)
		return n

	case ^Type_Enum:
		n := new_clone(c, v)
		n.backing = clone_expr(c, v.backing)
		n.fields = clone_enum_fields(c, v.fields)
		return n

	case ^Type_Interface:
		n := new_clone(c, v)
		n.generic_params = clone_generic_params(c, v.generic_params)
		n.where_clauses = clone_exprs(c, v.where_clauses)
		n.requirements = clone_requirements(c, v.requirements)
		return n
	}
	return nil
}

// ------------------------------------------------------------- statements --

clone_block :: proc(c: ^Compiler, b: ^Block) -> ^Block {
	if b == nil {
		return nil
	}
	n := new_node_clone(c, b)
	n.stmts = clone_stmts(c, b.stmts)
	return n
}

@(private = "file")
clone_stmt :: proc(c: ^Compiler, s: Stmt) -> Stmt {
	switch v in s {
	case ^Decl:
		return clone_decl(c, v)

	case ^Item_Impl:
		return clone_item(c, v).(^Item_Impl)

	case ^Stmt_Error:
		n := new_node_clone(c, v)
		n.partial = clone_stmt(c, v.partial)
		return n

	case ^Stmt_Expr:
		n := new_node_clone(c, v)
		n.exprs = clone_exprs(c, v.exprs)
		return n

	case ^Stmt_Assign:
		n := new_node_clone(c, v)
		n.op, n.op_span = v.op, v.op_span
		n.lhs = clone_exprs(c, v.lhs)
		n.rhs = clone_exprs(c, v.rhs)
		return n

	case ^Stmt_If:
		n := new_node_clone(c, v)
		n.init = clone_stmt(c, v.init)
		n.cond = clone_expr(c, v.cond)
		n.then = clone_block(c, v.then)
		n.otherwise = clone_stmt(c, v.otherwise)
		return n

	case ^Stmt_For:
		n := new_node_clone(c, v)
		n.init = clone_stmt(c, v.init)
		n.cond = clone_expr(c, v.cond)
		n.post = clone_stmt(c, v.post)
		n.body = clone_block(c, v.body)
		n.condition_only = v.condition_only
		return n

	case ^Stmt_Foreach:
		n := new_node_clone(c, v)
		n.bindings = clone_foreach_bindings(c, v.bindings)
		n.iterable = clone_expr(c, v.iterable)
		n.body = clone_block(c, v.body)
		return n

	case ^Stmt_When:
		n := new_node_clone(c, v)
		n.cond = clone_expr(c, v.cond)
		n.then = clone_block(c, v.then)
		n.otherwise = clone_stmt(c, v.otherwise)
		return n

	case ^Stmt_Switch:
		n := new_node_clone(c, v)
		n.kind = v.kind
		n.init = clone_stmt(c, v.init)
		n.subject = clone_expr(c, v.subject)
		written := v.written != nil ? v.written : v.cases
		n.cases = clone_slice(c, written)
		for entry, index in written {
			n.cases[index] = Switch_Case {
				span    = entry.span,
				values  = clone_exprs(c, entry.values),
				stmts   = clone_stmts(c, entry.stmts),
				binding = entry.binding,
				binding_ref = entry.binding_ref,
				fields  = clone_case_fields(c, entry.fields),
			}
		}
		return n

	case ^Stmt_Defer:
		n := new_node_clone(c, v)
		n.stmt = clone_stmt(c, v.stmt)
		n.on_failure = v.on_failure
		return n

	case ^Stmt_Return:
		n := new_node_clone(c, v)
		if v.value != nil {
			n.value = new(Return_Value, c.semantic_allocator)
			n.value^ = Return_Value {
				span     = v.value.span,
				is_inout = v.value.is_inout,
				expr     = clone_expr(c, v.value.expr),
			}
		}
		return n

	case ^Stmt_Branch:
		n := new_node_clone(c, v)
		n.kind = v.kind
		return n

	case ^Stmt_Parallel:
		n := new_node_clone(c, v)
		n.keyword = v.keyword
		n.executor = clone_expr(c, v.executor)
		n.body = clone_block(c, v.body)
		return n

	case ^Stmt_Spawn:
		n := new_node_clone(c, v)
		n.keyword = v.keyword
		if v.result != nil {
			// Not rewritten: a capture is no place for a task's result, and
			// `check_spawn` says so of the name as written.
			saved := c.capture_rewrite
			c.capture_rewrite = nil
			n.result = clone_expr(c, v.result).(^Expr_Ident)
			c.capture_rewrite = saved
		}
		n.call = clone_expr(c, v.call)
		return n

	case ^Block:
		return clone_block(c, v)
	}
	return nil
}

clone_decl :: proc(c: ^Compiler, d: ^Decl) -> ^Decl {
	n := new_node_clone(c, d)
	n.kind = d.kind
	n.names = d.names
	n.duration = d.duration
	n.declared_type = clone_expr(c, d.declared_type)
	n.via = clone_expr(c, d.via)
	n.values = clone_exprs(c, d.values)
	n.top_level = d.top_level
	return n
}

// Entered only with an impl, whose members are declarations, delegates and error
// items (grammar.md "Source files").
clone_item :: proc(c: ^Compiler, item: Item) -> Item {
	switch v in item {
	case ^Decl:
		return clone_decl(c, v)

	case ^Item_Error:
		return new_node_clone(c, v)

	case ^Item_Impl:
		n := new_node_clone(c, v)
		n.kind = v.kind
		n.type = clone_expr(c, v.type)
		n.members = clone_items(c, v.members)
		return n

	case ^Item_Delegate:
		n := new_node_clone(c, v)
		n.symbols = v.symbols
		return n

	case ^Item_Import, ^Item_Foreign_Import, ^Item_Foreign_Block, ^Item_When, ^Item_Block, ^Item_Static_Assert:
		unreachable()
	}
	return nil
}

@(private = "file")
clone_items :: proc(c: ^Compiler, list: []Item) -> []Item {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = clone_item(c, entry)
	}
	return out
}

// A binding pattern is a tree (design.md "Element bindings").
@(private = "file")
clone_foreach_bindings :: proc(c: ^Compiler, source: []Foreach_Binding) -> []Foreach_Binding {
	bindings := clone_slice(c, source)
	for binding, index in source {
		bindings[index] = Foreach_Binding {
			name      = binding.name,
			is_static = binding.is_static,
			is_ref    = binding.is_ref,
			group     = clone_foreach_bindings(c, binding.group),
		}
	}
	return bindings
}

// A case's field bindings, unresolved (design.md "Inspecting a union").
@(private = "file")
clone_case_fields :: proc(c: ^Compiler, source: []Case_Field) -> []Case_Field {
	fields := clone_slice(c, source)
	for field, index in source {
		fields[index] = Case_Field{name = field.name, is_ref = field.is_ref}
	}
	return fields
}
