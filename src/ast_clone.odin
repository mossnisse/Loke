// Deep syntax cloning (m4b-plan decision "Instantiation representation").
//
// Type annotations live on the AST nodes themselves (decision A1), so a second
// instantiation of a generic declaration — or a second copy of a static
// `foreach` body — cannot reuse the syntax the first one annotated. Cloning is
// the only way a declaration body is checked more than once.
//
// A clone keeps its source spans, so every diagnostic still points at the
// written code, and drops every semantic annotation: types, constant values,
// resolutions, bound argument lists, and the symbol IDs of parameters, results,
// fields, and members. Clones are allocated from the compilation's semantic
// arena rather than a file arena, because they outlive no file but belong to no
// one file either.
package lokec

// ------------------------------------------------------------------ helpers --

@(private = "file")
clone_base :: proc(dst: ^Expr_Base, src: ^Expr_Base) {
	dst.span = src.span
	dst.has_error = src.has_error
}

@(private = "file")
clone_node_base :: proc(c: ^Compiler, dst: ^Node_Base, src: ^Node_Base) {
	dst.span = src.span
	dst.has_error = src.has_error
	dst.attributes = clone_attributes(c, src.attributes)
}

@(private = "file")
new_clone :: proc(c: ^Compiler, $T: typeid, src: ^Expr_Base) -> ^T {
	node := new(T, c.semantic_allocator)
	clone_base(&node.base, src)
	return node
}

clone_attributes :: proc(c: ^Compiler, list: []Attribute) -> []Attribute {
	if len(list) == 0 {
		return nil
	}
	out := make([]Attribute, len(list), c.semantic_allocator)
	for entry, index in list {
		out[index] = Attribute {
			span  = entry.span,
			path  = entry.path,
			value = clone_expr(c, entry.value),
		}
	}
	return out
}

clone_exprs :: proc(c: ^Compiler, list: []Expr) -> []Expr {
	if len(list) == 0 {
		return nil
	}
	out := make([]Expr, len(list), c.semantic_allocator)
	for entry, index in list {
		out[index] = clone_expr(c, entry)
	}
	return out
}

@(private = "file")
clone_arguments :: proc(c: ^Compiler, list: []Argument) -> []Argument {
	if len(list) == 0 {
		return nil
	}
	out := make([]Argument, len(list), c.semantic_allocator)
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
	if len(list) == 0 {
		return nil
	}
	out := make([]Element, len(list), c.semantic_allocator)
	for entry, index in list {
		out[index] = Element {
			span  = entry.span,
			key   = clone_expr(c, entry.key),
			value = clone_expr(c, entry.value),
		}
	}
	return out
}

// Parameters, results, fields, and bindings all carry `symbols`, which name the
// instance's own storage: a clone starts with none.
@(private = "file")
clone_params :: proc(c: ^Compiler, list: []Parameter) -> []Parameter {
	if len(list) == 0 {
		return nil
	}
	out := make([]Parameter, len(list), c.semantic_allocator)
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
clone_results :: proc(c: ^Compiler, list: []Result) -> []Result {
	if len(list) == 0 {
		return nil
	}
	out := make([]Result, len(list), c.semantic_allocator)
	for entry, index in list {
		out[index] = Result {
			span     = entry.span,
			names    = entry.names,
			is_inout = entry.is_inout,
			type     = clone_expr(c, entry.type),
		}
	}
	return out
}

@(private = "file")
clone_fields :: proc(c: ^Compiler, list: []Field) -> []Field {
	if len(list) == 0 {
		return nil
	}
	out := make([]Field, len(list), c.semantic_allocator)
	for entry, index in list {
		out[index] = Field {
			span       = entry.span,
			attributes = clone_attributes(c, entry.attributes),
			is_using   = entry.is_using,
			names      = entry.names,
			type       = clone_expr(c, entry.type),
			tag        = entry.tag,
		}
	}
	return out
}

@(private = "file")
clone_enum_fields :: proc(c: ^Compiler, list: []Enum_Field) -> []Enum_Field {
	if len(list) == 0 {
		return nil
	}
	out := make([]Enum_Field, len(list), c.semantic_allocator)
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
	if len(list) == 0 {
		return nil
	}
	out := make([]Generic_Param, len(list), c.semantic_allocator)
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
	if len(list) == 0 {
		return nil
	}
	out := make([]Binding_Group, len(list), c.semantic_allocator)
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

clone_requirements :: proc(c: ^Compiler, list: []Requirement) -> []Requirement {
	if len(list) == 0 {
		return nil
	}
	out := make([]Requirement, len(list), c.semantic_allocator)
	for entry, index in list {
		out[index] = Requirement {
			span         = entry.span,
			kind         = entry.kind,
			bindings     = clone_bindings(c, entry.bindings),
			expr         = clone_expr(c, entry.expr),
			result_inout = entry.result_inout,
			result       = clone_expr(c, entry.result),
			name         = entry.name,
			slot_type    = clone_expr(c, entry.slot_type),
		}
	}
	return out
}

// ------------------------------------------------------------ expressions --

clone_expr :: proc(c: ^Compiler, e: Expr) -> Expr {
	if e == nil {
		return nil
	}
	switch v in e {
	case ^Expr_Error:
		return new_clone(c, Expr_Error, &v.base)

	case ^Expr_Literal:
		n := new_clone(c, Expr_Literal, &v.base)
		n.kind, n.text = v.kind, v.text
		return n

	case ^Expr_Ident:
		n := new_clone(c, Expr_Ident, &v.base)
		n.name, n.name_id = v.name, v.name_id
		return n

	case ^Expr_Selector:
		n := new_clone(c, Expr_Selector, &v.base)
		n.operand = clone_expr(c, v.operand)
		n.name = v.name
		return n

	case ^Expr_Type_Assert:
		n := new_clone(c, Expr_Type_Assert, &v.base)
		n.operand = clone_expr(c, v.operand)
		n.target = clone_expr(c, v.target)
		n.optional = v.optional
		return n

	case ^Expr_Index:
		n := new_clone(c, Expr_Index, &v.base)
		n.operand = clone_expr(c, v.operand)
		n.indices = clone_exprs(c, v.indices)
		return n

	case ^Expr_Slice:
		n := new_clone(c, Expr_Slice, &v.base)
		n.operand = clone_expr(c, v.operand)
		n.lo = clone_expr(c, v.lo)
		n.hi = clone_expr(c, v.hi)
		return n

	case ^Expr_Call:
		n := new_clone(c, Expr_Call, &v.base)
		n.callee = clone_expr(c, v.callee)
		n.args = clone_arguments(c, v.args)
		return n

	case ^Expr_Postfix:
		n := new_clone(c, Expr_Postfix, &v.base)
		n.op, n.op_span = v.op, v.op_span
		n.operand = clone_expr(c, v.operand)
		return n

	case ^Expr_Unary:
		n := new_clone(c, Expr_Unary, &v.base)
		n.op, n.op_span = v.op, v.op_span
		n.operand = clone_expr(c, v.operand)
		return n

	case ^Expr_Binary:
		n := new_clone(c, Expr_Binary, &v.base)
		n.op, n.op_span = v.op, v.op_span
		n.lhs = clone_expr(c, v.lhs)
		n.rhs = clone_expr(c, v.rhs)
		return n

	case ^Expr_Range:
		n := new_clone(c, Expr_Range, &v.base)
		n.op, n.op_span = v.op, v.op_span
		n.lo = clone_expr(c, v.lo)
		n.hi = clone_expr(c, v.hi)
		return n

	case ^Expr_Or_Else:
		n := new_clone(c, Expr_Or_Else, &v.base)
		n.value = clone_expr(c, v.value)
		n.fallback = clone_expr(c, v.fallback)
		return n

	case ^Expr_Cond:
		n := new_clone(c, Expr_Cond, &v.base)
		n.then = clone_expr(c, v.then)
		n.cond = clone_expr(c, v.cond)
		n.otherwise = clone_expr(c, v.otherwise)
		return n

	case ^Expr_Move:
		n := new_clone(c, Expr_Move, &v.base)
		n.value = clone_expr(c, v.value)
		return n

	case ^Expr_Hash:
		n := new_clone(c, Expr_Hash, &v.base)
		n.name = v.name
		return n

	case ^Expr_Composite:
		n := new_clone(c, Expr_Composite, &v.base)
		n.type_expr = clone_expr(c, v.type_expr)
		n.elements = clone_elements(c, v.elements)
		// Re-derived when the cloned literal is checked in its specialization.
		n.element_clones = nil
		// Re-derived when the clone is checked at its own substitution.
		n.backing = INVALID_TYPE
		return n

	case ^Expr_Proc:
		n := new_clone(c, Expr_Proc, &v.base)
		if v.signature != nil {
			n.signature = clone_expr(c, v.signature).(^Type_Proc)
		}
		n.where_clauses = clone_exprs(c, v.where_clauses)
		n.body = clone_block(c, v.body)
		n.bodiless = v.bodiless
		return n

	case ^Expr_Proc_Group:
		n := new_clone(c, Expr_Proc_Group, &v.base)
		n.names = v.names
		return n

	case ^Expr_Operator:
		n := new_clone(c, Expr_Operator, &v.base)
		n.symbol, n.symbol_span = v.symbol, v.symbol_span
		n.value = clone_expr(c, v.value)
		return n

	case ^Type_Pointer:
		n := new_clone(c, Type_Pointer, &v.base)
		n.elem = clone_expr(c, v.elem)
		return n

	case ^Type_Multi_Pointer:
		n := new_clone(c, Type_Multi_Pointer, &v.base)
		n.elem = clone_expr(c, v.elem)
		return n

	case ^Type_Slice:
		n := new_clone(c, Type_Slice, &v.base)
		n.mutable = v.mutable
		n.elem = clone_expr(c, v.elem)
		return n

	case ^Type_Dynamic_Array:
		n := new_clone(c, Type_Dynamic_Array, &v.base)
		n.elem = clone_expr(c, v.elem)
		return n

	case ^Type_Array:
		n := new_clone(c, Type_Array, &v.base)
		n.length = clone_expr(c, v.length)
		n.inferred = v.inferred
		n.elem = clone_expr(c, v.elem)
		return n

	case ^Type_Map:
		n := new_clone(c, Type_Map, &v.base)
		n.key = clone_expr(c, v.key)
		n.value = clone_expr(c, v.value)
		return n

	case ^Type_Distinct:
		n := new_clone(c, Type_Distinct, &v.base)
		n.elem = clone_expr(c, v.elem)
		return n

	case ^Type_Dyn:
		n := new_clone(c, Type_Dyn, &v.base)
		n.interface_expr = clone_expr(c, v.interface_expr)
		return n

	case ^Type_Type:
		return new_clone(c, Type_Type, &v.base)

	case ^Type_Poly:
		n := new_clone(c, Type_Poly, &v.base)
		n.name = v.name
		n.constraint = clone_expr(c, v.constraint)
		return n

	case ^Type_Proc:
		n := new_clone(c, Type_Proc, &v.base)
		n.convention = v.convention
		n.params = clone_params(c, v.params)
		n.results = clone_results(c, v.results)
		return n

	case ^Type_Record:
		n := new_clone(c, Type_Record, &v.base)
		n.kind = v.kind
		n.generic_params = clone_generic_params(c, v.generic_params)
		n.attributes = clone_attributes(c, v.attributes)
		n.where_clauses = clone_exprs(c, v.where_clauses)
		n.fields = clone_fields(c, v.fields)
		n.variants = clone_exprs(c, v.variants)
		return n

	case ^Type_Enum:
		n := new_clone(c, Type_Enum, &v.base)
		n.backing = clone_expr(c, v.backing)
		n.fields = clone_enum_fields(c, v.fields)
		return n

	case ^Type_Interface:
		n := new_clone(c, Type_Interface, &v.base)
		n.generic_params = clone_generic_params(c, v.generic_params)
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
	n := new(Block, c.semantic_allocator)
	clone_node_base(c, &n.base, &b.base)
	if len(b.stmts) > 0 {
		stmts := make([]Stmt, len(b.stmts), c.semantic_allocator)
		for stmt, index in b.stmts {
			stmts[index] = clone_stmt(c, stmt)
		}
		n.stmts = stmts
	}
	return n
}

clone_stmt :: proc(c: ^Compiler, s: Stmt) -> Stmt {
	if s == nil {
		return nil
	}
	switch v in s {
	case ^Decl:
		return clone_decl(c, v)

	case ^Stmt_Error:
		n := new(Stmt_Error, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		return n

	case ^Stmt_Expr:
		n := new(Stmt_Expr, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		n.exprs = clone_exprs(c, v.exprs)
		return n

	case ^Stmt_Assign:
		n := new(Stmt_Assign, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		n.op, n.op_span = v.op, v.op_span
		n.lhs = clone_exprs(c, v.lhs)
		n.rhs = clone_exprs(c, v.rhs)
		return n

	case ^Stmt_If:
		n := new(Stmt_If, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		n.init = clone_stmt(c, v.init)
		n.cond = clone_expr(c, v.cond)
		n.then = clone_block(c, v.then)
		n.otherwise = clone_stmt(c, v.otherwise)
		return n

	case ^Stmt_For:
		n := new(Stmt_For, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		n.init = clone_stmt(c, v.init)
		n.cond = clone_expr(c, v.cond)
		n.post = clone_stmt(c, v.post)
		n.body = clone_block(c, v.body)
		n.condition_only = v.condition_only
		return n

	case ^Stmt_Foreach:
		n := new(Stmt_Foreach, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		if len(v.bindings) > 0 {
			bindings := make([]Foreach_Binding, len(v.bindings), c.semantic_allocator)
			for binding, index in v.bindings {
				bindings[index] = Foreach_Binding {
					name      = binding.name,
					is_static = binding.is_static,
					is_ref    = binding.is_ref,
				}
			}
			n.bindings = bindings
		}
		n.iterable = clone_expr(c, v.iterable)
		n.body = clone_block(c, v.body)
		return n

	case ^Stmt_When:
		// The selection itself is not copied: a clone re-evaluates its own
		// condition, which may differ once generic arguments are bound.
		n := new(Stmt_When, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		n.cond = clone_expr(c, v.cond)
		n.then = clone_block(c, v.then)
		n.otherwise = clone_stmt(c, v.otherwise)
		return n

	case ^Stmt_Switch:
		n := new(Stmt_Switch, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		n.kind = v.kind
		n.init = clone_stmt(c, v.init)
		n.binding = v.binding
		n.subject = clone_expr(c, v.subject)
		if len(v.cases) > 0 {
			cases := make([]Switch_Case, len(v.cases), c.semantic_allocator)
			for entry, index in v.cases {
				stmts: []Stmt
				if len(entry.stmts) > 0 {
					stmts = make([]Stmt, len(entry.stmts), c.semantic_allocator)
					for stmt, position in entry.stmts {
						stmts[position] = clone_stmt(c, stmt)
					}
				}
				cases[index] = Switch_Case {
					span   = entry.span,
					values = clone_exprs(c, entry.values),
					stmts  = stmts,
				}
			}
			n.cases = cases
		}
		return n

	case ^Stmt_Defer:
		n := new(Stmt_Defer, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		n.stmt = clone_stmt(c, v.stmt)
		return n

	case ^Stmt_Return:
		n := new(Stmt_Return, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		if len(v.values) > 0 {
			values := make([]Return_Value, len(v.values), c.semantic_allocator)
			for entry, index in v.values {
				values[index] = Return_Value {
					span     = entry.span,
					is_inout = entry.is_inout,
					expr     = clone_expr(c, entry.expr),
				}
			}
			n.values = values
		}
		return n

	case ^Stmt_Branch:
		n := new(Stmt_Branch, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		n.kind = v.kind
		return n

	case ^Block:
		return clone_block(c, v)
	}
	return nil
}

clone_decl :: proc(c: ^Compiler, d: ^Decl) -> ^Decl {
	if d == nil {
		return nil
	}
	n := new(Decl, c.semantic_allocator)
	clone_node_base(c, &n.base, &d.base)
	n.kind = d.kind
	n.names = d.names
	n.duration = d.duration
	n.manual = d.manual
	n.declared_type = clone_expr(c, d.declared_type)
	n.via = clone_expr(c, d.via)
	n.values = clone_exprs(c, d.values)
	n.top_level = d.top_level
	return n
}

// `impl`/`extend` blocks are cloned per record instantiation, so their members
// follow the same rules as any other declaration.
clone_item :: proc(c: ^Compiler, item: Item) -> Item {
	switch v in item {
	case ^Decl:
		return clone_decl(c, v)

	case ^Item_Error:
		n := new(Item_Error, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		return n

	case ^Item_Import:
		n := new(Item_Import, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		n.alias, n.path = v.alias, v.path
		return n

	case ^Item_Foreign_Import:
		n := new(Item_Foreign_Import, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		n.name, n.path = v.name, v.path
		return n

	case ^Item_Foreign_Block:
		n := new(Item_Foreign_Block, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		n.library = v.library
		n.members = clone_items(c, v.members)
		return n

	case ^Item_Impl:
		n := new(Item_Impl, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		n.kind = v.kind
		n.type = clone_expr(c, v.type)
		n.members = clone_items(c, v.members)
		return n

	case ^Item_Delegate:
		n := new(Item_Delegate, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		n.symbols = v.symbols
		return n

	case ^Item_When:
		n := new(Item_When, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		n.cond = clone_expr(c, v.cond)
		if v.then != nil {
			n.then = clone_item(c, v.then).(^Item_Block)
		}
		n.otherwise = clone_item(c, v.otherwise)
		return n

	case ^Item_Block:
		n := new(Item_Block, c.semantic_allocator)
		clone_node_base(c, &n.base, &v.base)
		n.items = clone_items(c, v.items)
		return n
	}
	return nil
}

clone_items :: proc(c: ^Compiler, list: []Item) -> []Item {
	if len(list) == 0 {
		return nil
	}
	out := make([]Item, len(list), c.semantic_allocator)
	for entry, index in list {
		out[index] = clone_item(c, entry)
	}
	return out
}
