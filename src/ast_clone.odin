// Deep syntax cloning. Type annotations live on the AST nodes
// (compiler-architecture.md "One annotated AST"), so checking the same syntax
// twice — a generic instance, a static `foreach` copy — needs a fresh copy. A clone keeps spans and written syntax and drops what the
// checker fills in, except `Item_Impl.kind`, which a generic record's instance
// reads from its template. Clones live in the semantic arena.
package lokec

// What a clone rewrites as it copies, each nil for a plain clone.
Clone_Rewrite :: struct {
	// A capture literal's body cloned into its record's `call`: the captured
	// names, which become the receiver's fields (capture.odin).
	capture:      ^Capture_Rewrite,
	// A parametric alias's body cloned into a view: each parameter's written
	// argument, which goes where its `$` name was; and the checker whose scope
	// tells which applications in the clone are aliases to expand the same way
	// (`alias_view` in generic_alias.odin).
	substitution: ^map[Identifier_Id]Expr,
	alias_view:   ^Checker,
}

@(private = "file")
Cloner :: struct {
	using compiler: ^Compiler,
	using rewrite:  Clone_Rewrite,
}

// The same clone with captured names left as written.
@(private = "file")
without_capture :: proc(c: ^Cloner) -> Cloner {
	inner := c^
	inner.capture = nil
	return inner
}

// ----------------------------------------------------------------- entries --

clone_expr :: proc(c: ^Compiler, e: Expr, rewrite := Clone_Rewrite{}) -> Expr {
	cloner := Cloner{c, rewrite}
	return clone_expr_with(&cloner, e)
}

clone_block :: proc(c: ^Compiler, b: ^Block, rewrite := Clone_Rewrite{}) -> ^Block {
	cloner := Cloner{c, rewrite}
	return clone_block_with(&cloner, b)
}

clone_stmts :: proc(c: ^Compiler, list: []Stmt) -> []Stmt {
	cloner := Cloner{compiler = c}
	return clone_stmts_with(&cloner, list)
}

clone_decl :: proc(c: ^Compiler, d: ^Decl) -> ^Decl {
	cloner := Cloner{compiler = c}
	return clone_decl_with(&cloner, d)
}

clone_item :: proc(c: ^Compiler, item: Item) -> Item {
	cloner := Cloner{compiler = c}
	return clone_item_with(&cloner, item)
}

clone_requirement :: proc(c: ^Compiler, requirement: Requirement) -> Requirement {
	cloner := Cloner{compiler = c}
	return clone_requirement_with(&cloner, requirement)
}

// ------------------------------------------------------------------ helpers --

// Zeroed, for the caller to fill; empty stays nil.
@(private = "file")
clone_slice :: proc(c: ^Cloner, list: []$T) -> []T {
	if len(list) == 0 {
		return nil
	}
	return make([]T, len(list), c.semantic_allocator)
}

@(private = "file")
new_clone :: proc(c: ^Cloner, src: ^$T) -> ^T {
	node := new(T, c.semantic_allocator)
	node.span = src.span
	node.has_error = src.has_error
	return node
}

@(private = "file")
new_node_clone :: proc(c: ^Cloner, src: ^$T) -> ^T {
	node := new_clone(c, src)
	node.attributes = clone_attributes(c, src.attributes)
	return node
}

@(private = "file")
clone_attributes :: proc(c: ^Cloner, list: []Attribute) -> []Attribute {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = entry
		out[index].value = clone_expr_with(c, entry.value)
	}
	return out
}

@(private = "file")
clone_exprs :: proc(c: ^Cloner, list: []Expr) -> []Expr {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = clone_expr_with(c, entry)
	}
	return out
}

@(private = "file")
clone_stmts_with :: proc(c: ^Cloner, list: []Stmt) -> []Stmt {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = clone_stmt(c, entry)
	}
	return out
}

@(private = "file")
clone_arguments :: proc(c: ^Cloner, list: []Argument) -> []Argument {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = Argument {
			span  = entry.span,
			name  = entry.name,
			mode  = entry.mode,
			value = clone_expr_with(c, entry.value),
		}
	}
	return out
}

@(private = "file")
clone_elements :: proc(c: ^Cloner, list: []Element) -> []Element {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = entry
		// A bare name before `=` is a field, never a capture.
		if _, is_name := entry.key.(^Expr_Ident); is_name {
			plain := without_capture(c)
			out[index].key = clone_expr_with(&plain, entry.key)
		} else {
			out[index].key = clone_expr_with(c, entry.key)
		}
		out[index].value = clone_expr_with(c, entry.value)
	}
	return out
}

@(private = "file")
clone_capture :: proc(c: ^Cloner, v: ^Capture_Literal) -> ^Capture_Literal {
	n := new(Capture_Literal, c.semantic_allocator)
	n.procedure = clone_expr_with(c, v.procedure).(^Expr_Proc)
	n.clause_span = v.clause_span
	n.entries = clone_slice(c, v.entries)
	for entry, index in v.entries {
		n.entries[index] = entry
		n.entries[index].value = clone_expr_with(c, entry.value)
	}
	return n
}

// The list cloners copy each entry whole, so a field added later is kept, and
// clear only what the checker fills in: a clone declares its own symbols.
@(private = "file")
clone_params :: proc(c: ^Cloner, list: []Parameter) -> []Parameter {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = entry
		out[index].attributes = clone_attributes(c, entry.attributes)
		out[index].type = clone_expr_with(c, entry.type)
		out[index].default = clone_expr_with(c, entry.default)
		out[index].symbols = nil
	}
	return out
}

@(private = "file")
clone_result :: proc(c: ^Cloner, result: ^Result) -> ^Result {
	if result == nil {
		return nil
	}
	out := new(Result, c.semantic_allocator)
	out^ = result^
	out.type = clone_expr_with(c, result.type)
	return out
}

@(private = "file")
clone_fields :: proc(c: ^Cloner, list: []Field) -> []Field {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = entry
		out[index].attributes = clone_attributes(c, entry.attributes)
		out[index].type = clone_expr_with(c, entry.type)
		out[index].symbols = nil
	}
	return out
}

@(private = "file")
clone_variants :: proc(c: ^Cloner, list: []Variant) -> []Variant {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = entry
		out[index].type = clone_expr_with(c, entry.type)
	}
	return out
}

@(private = "file")
clone_enum_fields :: proc(c: ^Cloner, list: []Enum_Field) -> []Enum_Field {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = entry
		out[index].value = clone_expr_with(c, entry.value)
		out[index].symbol = INVALID_SYMBOL
	}
	return out
}

@(private = "file")
clone_generic_params :: proc(c: ^Cloner, list: []Generic_Param) -> []Generic_Param {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = entry
		out[index].type = clone_expr_with(c, entry.type)
		out[index].symbols = nil
	}
	return out
}

@(private = "file")
clone_bindings :: proc(c: ^Cloner, list: []Binding_Group) -> []Binding_Group {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = entry
		out[index].type = clone_expr_with(c, entry.type)
		out[index].symbols = nil
	}
	return out
}

@(private = "file")
clone_requirement_with :: proc(c: ^Cloner, requirement: Requirement) -> Requirement {
	out := requirement
	out.bindings = clone_bindings(c, requirement.bindings)
	out.expr = clone_expr_with(c, requirement.expr)
	out.result = clone_expr_with(c, requirement.result)
	out.slot_type = clone_expr_with(c, requirement.slot_type)
	return out
}

@(private = "file")
clone_requirements :: proc(c: ^Cloner, list: []Requirement) -> []Requirement {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = clone_requirement_with(c, entry)
	}
	return out
}

// ------------------------------------------------------------ expressions --

@(private = "file")
clone_expr_with :: proc(c: ^Cloner, e: Expr) -> Expr {
	switch v in e {
	case ^Expr_Error:
		return new_clone(c, v)

	case ^Expr_Literal:
		n := new_clone(c, v)
		n.kind, n.text = v.kind, v.text
		return n

	case ^Expr_Ident:
		if c.capture != nil {
			if rewritten := rewrite_capture(c.compiler, c.capture, v); rewritten != nil {
				return rewritten
			}
		}
		n := new_clone(c, v)
		n.name, n.name_id = v.name, v.name_id
		return n

	case ^Expr_Selector:
		n := new_clone(c, v)
		n.operand = clone_expr_with(c, v.operand)
		n.name = v.name
		return n

	case ^Expr_Index:
		n := new_clone(c, v)
		n.operand = clone_expr_with(c, v.operand)
		n.indices = clone_exprs(c, v.indices)
		return n

	case ^Expr_Slice:
		n := new_clone(c, v)
		n.mutable = v.mutable
		n.operand = clone_expr_with(c, v.operand)
		n.lo = clone_expr_with(c, v.lo)
		n.hi = clone_expr_with(c, v.hi)
		return n

	case ^Expr_Call:
		if c.alias_view != nil {
			if view := alias_view_of_application(c.alias_view, v, c.rewrite); view != nil {
				return view
			}
		}
		n := new_clone(c, v)
		n.callee = clone_expr_with(c, v.callee)
		n.args = clone_arguments(c, v.args)
		return n

	case ^Expr_Postfix:
		n := new_clone(c, v)
		n.op, n.op_span = v.op, v.op_span
		n.operand = clone_expr_with(c, v.operand)
		n.failure = clone_expr_with(c, v.failure)
		return n

	case ^Expr_Propagated_Error:
		// The checker builds it under a checked `or_return`, which a clone drops.
		unreachable()

	case ^Expr_Unary:
		n := new_clone(c, v)
		n.op, n.op_span = v.op, v.op_span
		n.mutable = v.mutable
		n.operand = clone_expr_with(c, v.operand)
		return n

	case ^Expr_Binary:
		n := new_clone(c, v)
		n.op, n.op_span = v.op, v.op_span
		n.lhs = clone_expr_with(c, v.lhs)
		n.rhs = clone_expr_with(c, v.rhs)
		return n

	case ^Expr_Range:
		n := new_clone(c, v)
		n.op, n.op_span = v.op, v.op_span
		n.lo = clone_expr_with(c, v.lo)
		n.hi = clone_expr_with(c, v.hi)
		return n

	case ^Expr_Or_Else:
		n := new_clone(c, v)
		n.value = clone_expr_with(c, v.value)
		n.fallback = clone_expr_with(c, v.fallback)
		n.exit = clone_stmt(c, v.exit)
		return n

	case ^Expr_Cond:
		n := new_clone(c, v)
		n.then = clone_expr_with(c, v.then)
		n.cond = clone_expr_with(c, v.cond)
		n.otherwise = clone_expr_with(c, v.otherwise)
		return n

	case ^Expr_Move:
		n := new_clone(c, v)
		n.value = clone_expr_with(c, v.value)
		return n

	case ^Expr_Composite:
		n := new_clone(c, v)
		if v.capture != nil {
			// Its type and elements are what checking lowered it to.
			n.capture = clone_capture(c, v.capture)
			return n
		}
		n.type_expr = clone_expr_with(c, v.type_expr)
		n.elements = clone_elements(c, v.elements)
		return n

	case ^Expr_Proc:
		// A nested literal's body is its own: it captures nothing from this one
		// unless its clause names it, and that clause is rewritten by the caller.
		inner := without_capture(c)
		n := new_clone(c, v)
		n.signature = clone_expr_with(&inner, v.signature).(^Type_Proc)
		n.where_clauses = clone_exprs(&inner, v.where_clauses)
		n.body = clone_block_with(&inner, v.body)
		n.bodiless = v.bodiless
		return n

	case ^Expr_Proc_Group:
		n := new_clone(c, v)
		n.names = v.names
		return n

	case ^Expr_Operator:
		n := new_clone(c, v)
		n.symbol, n.symbol_span, n.hook = v.symbol, v.symbol_span, v.hook
		n.value = clone_expr_with(c, v.value)
		return n

	case ^Type_Pointer:
		n := new_clone(c, v)
		n.mutable = v.mutable
		n.elem = clone_expr_with(c, v.elem)
		return n

	case ^Type_C_Pointer:
		n := new_clone(c, v)
		n.elem = clone_expr_with(c, v.elem)
		return n

	case ^Type_Slice:
		n := new_clone(c, v)
		n.mutable = v.mutable
		n.elem = clone_expr_with(c, v.elem)
		return n

	case ^Type_Dynamic_Array:
		n := new_clone(c, v)
		n.elem = clone_expr_with(c, v.elem)
		return n

	case ^Type_Array:
		n := new_clone(c, v)
		n.length = clone_expr_with(c, v.length)
		n.elem = clone_expr_with(c, v.elem)
		return n

	case ^Type_Map:
		n := new_clone(c, v)
		n.key = clone_expr_with(c, v.key)
		n.value = clone_expr_with(c, v.value)
		return n

	case ^Type_Distinct:
		n := new_clone(c, v)
		n.elem = clone_expr_with(c, v.elem)
		return n

	case ^Type_Dyn:
		n := new_clone(c, v)
		n.mutable = v.mutable
		n.interface_expr = clone_expr_with(c, v.interface_expr)
		return n

	case ^Type_Type:
		return new_clone(c, v)

	case ^Type_Poly:
		if c.substitution != nil {
			// The argument was already viewed where it was written.
			if written, found := c.substitution[name_identifier(c.compiler, v.name)]; found {
				return clone_expr(c.compiler, written, {capture = c.capture})
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
		n.body_lo = v.body_lo
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
		n.backing = clone_expr_with(c, v.backing)
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

@(private = "file")
clone_block_with :: proc(c: ^Cloner, b: ^Block) -> ^Block {
	if b == nil {
		return nil
	}
	n := new_node_clone(c, b)
	n.stmts = clone_stmts_with(c, b.stmts)
	return n
}

@(private = "file")
clone_stmt :: proc(c: ^Cloner, s: Stmt) -> Stmt {
	switch v in s {
	case ^Decl:
		return clone_decl_with(c, v)

	case ^Item_Impl:
		return clone_item_with(c, v).(^Item_Impl)

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
		n.cond = clone_expr_with(c, v.cond)
		n.then = clone_block_with(c, v.then)
		n.otherwise = clone_stmt(c, v.otherwise)
		return n

	case ^Stmt_For:
		n := new_node_clone(c, v)
		n.init = clone_stmt(c, v.init)
		n.cond = clone_expr_with(c, v.cond)
		n.post = clone_stmt(c, v.post)
		n.body = clone_block_with(c, v.body)
		n.condition_only = v.condition_only
		return n

	case ^Stmt_Foreach:
		n := new_node_clone(c, v)
		n.bindings = clone_foreach_bindings(c, v.bindings)
		n.iterable = clone_expr_with(c, v.iterable)
		n.body = clone_block_with(c, v.body)
		return n

	case ^Stmt_When:
		n := new_node_clone(c, v)
		n.cond = clone_expr_with(c, v.cond)
		n.then = clone_block_with(c, v.then)
		n.otherwise = clone_stmt(c, v.otherwise)
		return n

	case ^Stmt_Switch:
		n := new_node_clone(c, v)
		n.init = clone_stmt(c, v.init)
		n.subject = clone_expr_with(c, v.subject)
		written := v.written != nil ? v.written : v.cases
		n.cases = clone_slice(c, written)
		for entry, index in written {
			n.cases[index] = Switch_Case {
				span    = entry.span,
				values  = clone_exprs(c, entry.values),
				stmts   = clone_stmts_with(c, entry.stmts),
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
				expr     = clone_expr_with(c, v.value.expr),
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
		n.executor = clone_expr_with(c, v.executor)
		n.body = clone_block_with(c, v.body)
		return n

	case ^Stmt_Spawn:
		n := new_node_clone(c, v)
		n.keyword = v.keyword
		if v.result != nil {
			// Not rewritten: a capture is no place for a task's result, and
			// `check_spawn` says so of the name as written.
			plain := without_capture(c)
			n.result = clone_expr_with(&plain, v.result).(^Expr_Ident)
		}
		n.call = clone_expr_with(c, v.call)
		return n

	case ^Block:
		return clone_block_with(c, v)
	}
	return nil
}

@(private = "file")
clone_decl_with :: proc(c: ^Cloner, d: ^Decl) -> ^Decl {
	n := new_node_clone(c, d)
	n.kind = d.kind
	n.names = d.names
	n.duration = d.duration
	n.declared_type = clone_expr_with(c, d.declared_type)
	n.via = clone_expr_with(c, d.via)
	n.values = clone_exprs(c, d.values)
	n.top_level = d.top_level
	return n
}

// Entered only with an impl, whose members are declarations, delegates and error
// items (grammar.md "Source files").
@(private = "file")
clone_item_with :: proc(c: ^Cloner, item: Item) -> Item {
	switch v in item {
	case ^Decl:
		return clone_decl_with(c, v)

	case ^Item_Error:
		return new_node_clone(c, v)

	case ^Item_Impl:
		n := new_node_clone(c, v)
		n.kind = v.kind
		n.type = clone_expr_with(c, v.type)
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
clone_items :: proc(c: ^Cloner, list: []Item) -> []Item {
	out := clone_slice(c, list)
	for entry, index in list {
		out[index] = clone_item_with(c, entry)
	}
	return out
}

// A binding pattern is a tree (design.md "Element bindings").
@(private = "file")
clone_foreach_bindings :: proc(c: ^Cloner, source: []Foreach_Binding) -> []Foreach_Binding {
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
clone_case_fields :: proc(c: ^Cloner, source: []Case_Field) -> []Case_Field {
	fields := clone_slice(c, source)
	for field, index in source {
		fields[index] = Case_Field{name = field.name, is_ref = field.is_ref}
	}
	return fields
}
