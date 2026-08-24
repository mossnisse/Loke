// Deterministic, semantic-free AST dump used by the parser golden tests and the
// `-dump-ast` driver mode. It intentionally omits addresses and checker
// annotations so output is stable across runs and compiler phases.
//
// `_` stands for an absent optional child everywhere it appears.
package lokec

import "core:fmt"
import "core:strings"

ast_dump :: proc(f: ^File) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	fmt.sbprintf(&b, "(file package=%q", f.package_name)
	dump_attributes(&b, f.attributes)
	fmt.sbprintln(&b)
	for item in f.items {
		dump_item(&b, item, 1)
	}
	fmt.sbprintln(&b, ")")
	return strings.to_string(b)
}

// ` @[name, qualified.name=EXPR]`, or nothing when there are none.
@(private = "file")
dump_attributes :: proc(b: ^strings.Builder, attributes: []Attribute) {
	if len(attributes) == 0 {
		return
	}
	fmt.sbprint(b, " @[")
	for attribute, i in attributes {
		if i > 0 {
			fmt.sbprint(b, ",")
		}
		for name, j in attribute.path {
			if j > 0 {
				fmt.sbprint(b, ".")
			}
			fmt.sbprint(b, name.text)
		}
		if attribute.value != nil {
			fmt.sbprint(b, "=")
			dump_expr(b, attribute.value, 0)
		}
	}
	fmt.sbprint(b, "]")
}

@(private = "file")
dump_indent :: proc(b: ^strings.Builder, depth: int) {
	for _ in 0 ..< depth {
		fmt.sbprint(b, "  ")
	}
}

@(private = "file")
dump_names :: proc(b: ^strings.Builder, names: []Name) {
	fmt.sbprint(b, "[")
	for name, i in names {
		if i > 0 {
			fmt.sbprint(b, ",")
		}
		fmt.sbprintf(b, "%q", name.text)
	}
	fmt.sbprint(b, "]")
}

@(private = "file")
dump_item :: proc(b: ^strings.Builder, item: Item, depth: int) {
	switch node in item {
	case ^Decl:
		dump_decl(b, node, depth)

	case ^Item_Error:
		dump_indent(b, depth)
		fmt.sbprintln(b, "(error-item)")

	case ^Item_Import:
		dump_indent(b, depth)
		fmt.sbprint(b, "(import")
		dump_attributes(b, node.attributes)
		if node.alias.text != "" {
			fmt.sbprintf(b, " alias=%q", node.alias.text)
		}
		fmt.sbprintfln(b, " %s)", node.path)

	case ^Item_Foreign_Import:
		dump_indent(b, depth)
		fmt.sbprint(b, "(foreign-import")
		dump_attributes(b, node.attributes)
		// The stored path is unquoted; the dump shows it as the written literal.
		fmt.sbprintfln(b, " %q %q)", node.name.text, node.path)

	case ^Item_Foreign_Block:
		dump_indent(b, depth)
		fmt.sbprint(b, "(foreign")
		dump_attributes(b, node.attributes)
		fmt.sbprintfln(b, " %q", node.library.text)
		for member in node.members {
			dump_item(b, member, depth + 1)
		}
		dump_indent(b, depth)
		fmt.sbprintln(b, ")")

	case ^Item_Impl:
		dump_indent(b, depth)
		fmt.sbprint(b, "(impl")
		dump_attributes(b, node.attributes)
		dump_child(b, node.type, depth)
		fmt.sbprintln(b)
		for member in node.members {
			dump_item(b, member, depth + 1)
		}
		dump_indent(b, depth)
		fmt.sbprintln(b, ")")

	case ^Item_Delegate:
		dump_indent(b, depth)
		fmt.sbprint(b, "(delegate")
		for symbol in node.symbols {
			fmt.sbprintf(b, " %q", symbol)
		}
		fmt.sbprintln(b, ")")

	case ^Item_When:
		dump_indent(b, depth)
		fmt.sbprint(b, "(when")
		dump_attributes(b, node.attributes)
		fmt.sbprintln(b)
		dump_labeled(b, "cond", node.cond, depth + 1)
		dump_item(b, node.then, depth + 1)
		if node.otherwise != nil {
			dump_indent(b, depth + 1)
			fmt.sbprintln(b, "(else")
			dump_item(b, node.otherwise, depth + 2)
			dump_indent(b, depth + 1)
			fmt.sbprintln(b, ")")
		}
		dump_indent(b, depth)
		fmt.sbprintln(b, ")")

	case ^Item_Block:
		dump_indent(b, depth)
		fmt.sbprint(b, "(items")
		dump_attributes(b, node.attributes)
		fmt.sbprintln(b)
		for inner in node.items {
			dump_item(b, inner, depth + 1)
		}
		dump_indent(b, depth)
		fmt.sbprintln(b, ")")
	}
}

@(private = "file")
dump_decl :: proc(b: ^strings.Builder, d: ^Decl, depth: int) {
	dump_indent(b, depth)
	fmt.sbprintf(b, "(%s names=", d.kind == .Const ? "const" : "var")
	dump_names(b, d.names)
	dump_attributes(b, d.attributes)
	switch d.duration {
	case .None:
	case .Static:
		fmt.sbprint(b, " static")
	case .Thread_Local:
		fmt.sbprint(b, " thread_local")
	}
	if d.manual {
		fmt.sbprint(b, " manual")
	}
	if d.declared_type != nil {
		fmt.sbprint(b, " type=")
		dump_expr(b, d.declared_type, depth)
	}
	if d.via != nil {
		fmt.sbprint(b, " via=")
		dump_expr(b, d.via, depth)
	}
	if len(d.values) == 0 {
		fmt.sbprintln(b, ")")
		return
	}

	fmt.sbprintln(b)
	for value in d.values {
		dump_indent(b, depth + 1)
		if value == nil {
			fmt.sbprint(b, "(uninit)") // the `---` marker
		} else {
			dump_expr(b, value, depth + 1)
		}
		fmt.sbprintln(b)
	}
	dump_indent(b, depth)
	fmt.sbprintln(b, ")")
}

@(private = "file")
dump_block :: proc(b: ^strings.Builder, block: ^Block, depth: int) {
	if block == nil {
		dump_indent(b, depth)
		fmt.sbprintln(b, "(no-block)")
		return
	}
	dump_indent(b, depth)
	fmt.sbprint(b, "(block")
	dump_attributes(b, block.attributes)
	fmt.sbprintln(b)
	for stmt in block.stmts {
		dump_stmt(b, stmt, depth + 1)
	}
	dump_indent(b, depth)
	fmt.sbprintln(b, ")")
}

// One line per child keeps compound statements deterministic without inventing
// a layout: `(label ...)` children sit one level in from their statement.
@(private = "file")
dump_labeled :: proc(b: ^strings.Builder, label: string, expr: Expr, depth: int) {
	dump_indent(b, depth)
	fmt.sbprintf(b, "(%s", label)
	dump_child(b, expr, depth)
	fmt.sbprintln(b, ")")
}

@(private = "file")
dump_stmt :: proc(b: ^strings.Builder, stmt: Stmt, depth: int) {
	switch node in stmt {
	case ^Decl:
		dump_decl(b, node, depth)

	case ^Stmt_Error:
		dump_indent(b, depth)
		fmt.sbprintln(b, "(error-stmt)")

	case ^Stmt_Expr:
		dump_indent(b, depth)
		if len(node.exprs) == 1 && len(node.attributes) == 0 {
			dump_expr(b, node.exprs[0], depth)
		} else {
			fmt.sbprint(b, "(exprs")
			dump_attributes(b, node.attributes)
			for expr in node.exprs {
				dump_child(b, expr, depth)
			}
			fmt.sbprint(b, ")")
		}
		fmt.sbprintln(b)

	case ^Stmt_Assign:
		dump_indent(b, depth)
		fmt.sbprintf(b, "(assign %v", node.op)
		dump_attributes(b, node.attributes)
		fmt.sbprint(b, " (lhs")
		for expr in node.lhs {
			dump_child(b, expr, depth)
		}
		fmt.sbprint(b, ") (rhs")
		for expr in node.rhs {
			dump_child(b, expr, depth)
		}
		fmt.sbprintln(b, "))")

	case ^Stmt_If:
		dump_indent(b, depth)
		fmt.sbprintln(b, "(if")
		if node.init != nil {
			dump_stmt(b, node.init, depth + 1)
		}
		dump_labeled(b, "cond", node.cond, depth + 1)
		dump_block(b, node.then, depth + 1)
		dump_else(b, node.otherwise, depth + 1)
		dump_indent(b, depth)
		fmt.sbprintln(b, ")")

	case ^Stmt_When:
		dump_indent(b, depth)
		fmt.sbprint(b, "(when")
		dump_attributes(b, node.attributes)
		fmt.sbprintln(b)
		dump_labeled(b, "cond", node.cond, depth + 1)
		dump_block(b, node.then, depth + 1)
		dump_else(b, node.otherwise, depth + 1)
		dump_indent(b, depth)
		fmt.sbprintln(b, ")")

	case ^Stmt_For:
		dump_indent(b, depth)
		fmt.sbprintln(b, node.condition_only ? "(for cond-only" : "(for")
		if node.init != nil {
			dump_stmt(b, node.init, depth + 1)
		}
		if node.cond != nil {
			dump_labeled(b, "cond", node.cond, depth + 1)
		}
		if node.post != nil {
			dump_stmt(b, node.post, depth + 1)
		}
		dump_block(b, node.body, depth + 1)
		dump_indent(b, depth)
		fmt.sbprintln(b, ")")

	case ^Stmt_Foreach:
		dump_indent(b, depth)
		fmt.sbprint(b, "(foreach [")
		for binding, i in node.bindings {
			if i > 0 {
				fmt.sbprint(b, ",")
			}
			fmt.sbprintf(
				b,
				"\"%s%s%s\"",
				binding.is_static ? "$" : "",
				binding.is_ref ? "&" : "",
				binding.name.text,
			)
		}
		fmt.sbprintln(b, "]")
		dump_labeled(b, "in", node.iterable, depth + 1)
		dump_block(b, node.body, depth + 1)
		dump_indent(b, depth)
		fmt.sbprintln(b, ")")

	case ^Stmt_Switch:
		dump_indent(b, depth)
		fmt.sbprint(b, node.kind == .Type ? "(switch type" : "(switch value")
		if node.kind == .Type {
			fmt.sbprintf(b, " %q", node.binding.text)
		}
		dump_attributes(b, node.attributes)
		fmt.sbprintln(b)
		if node.init != nil {
			dump_stmt(b, node.init, depth + 1)
		}
		dump_labeled(b, "subject", node.subject, depth + 1)
		for entry in node.cases {
			dump_indent(b, depth + 1)
			fmt.sbprint(b, "(case")
			for value in entry.values {
				dump_child(b, value, depth + 1)
			}
			fmt.sbprintln(b)
			for inner in entry.stmts {
				dump_stmt(b, inner, depth + 2)
			}
			dump_indent(b, depth + 1)
			fmt.sbprintln(b, ")")
		}
		dump_indent(b, depth)
		fmt.sbprintln(b, ")")

	case ^Stmt_Defer:
		dump_indent(b, depth)
		fmt.sbprintln(b, "(defer")
		if node.stmt != nil {
			dump_stmt(b, node.stmt, depth + 1)
		}
		dump_indent(b, depth)
		fmt.sbprintln(b, ")")

	case ^Stmt_Return:
		dump_indent(b, depth)
		fmt.sbprint(b, "(return")
		for value in node.values {
			if value.is_inout {
				fmt.sbprint(b, " (inout")
				dump_child(b, value.expr, depth)
				fmt.sbprint(b, ")")
			} else {
				dump_child(b, value.expr, depth)
			}
		}
		fmt.sbprintln(b, ")")

	case ^Stmt_Branch:
		dump_indent(b, depth)
		fmt.sbprintln(b, node.kind == .Break ? "(break)" : "(continue)")

	case ^Block:
		dump_block(b, node, depth)
	}
}

@(private = "file")
dump_else :: proc(b: ^strings.Builder, otherwise: Stmt, depth: int) {
	if otherwise == nil {
		return
	}
	dump_indent(b, depth)
	fmt.sbprintln(b, "(else")
	dump_stmt(b, otherwise, depth + 1)
	dump_indent(b, depth)
	fmt.sbprintln(b, ")")
}

@(private = "file")
literal_tag :: proc(kind: Literal_Kind) -> string {
	switch kind {
	case .Int:
		return "int"
	case .Float:
		return "float"
	case .String:
		return "string"
	case .Raw_String:
		return "raw_string"
	case .Rune:
		return "rune"
	}
	return "literal"
}

@(private = "file")
dump_child :: proc(b: ^strings.Builder, expr: Expr, depth: int) {
	fmt.sbprint(b, " ")
	dump_expr(b, expr, depth)
}

@(private = "file")
dump_expr :: proc(b: ^strings.Builder, expr: Expr, depth: int) {
	if expr == nil {
		fmt.sbprint(b, "_")
		return
	}

	switch node in expr {
	case ^Expr_Error:
		fmt.sbprint(b, "(error-expr)")

	case ^Expr_Literal:
		fmt.sbprintf(b, "(%s %q)", literal_tag(node.kind), node.text)

	case ^Expr_Ident:
		fmt.sbprintf(b, "(ident %q)", node.name)

	case ^Expr_Selector:
		fmt.sbprint(b, "(selector")
		dump_child(b, node.operand, depth)
		fmt.sbprintf(b, " %q)", node.name.text)

	case ^Expr_Checked_Extract:
		fmt.sbprint(b, "(assert")
		dump_child(b, node.operand, depth)
		dump_child(b, node.target, depth)
		fmt.sbprint(b, ")")

	case ^Expr_Index:
		fmt.sbprint(b, "(index")
		dump_child(b, node.operand, depth)
		for index in node.indices {
			dump_child(b, index, depth)
		}
		fmt.sbprint(b, ")")

	case ^Expr_Slice:
		fmt.sbprint(b, "(slice-of")
		dump_child(b, node.operand, depth)
		dump_child(b, node.lo, depth)
		dump_child(b, node.hi, depth)
		fmt.sbprint(b, ")")

	case ^Expr_Call:
		fmt.sbprint(b, "(call")
		dump_child(b, node.callee, depth)
		for arg in node.args {
			dump_argument(b, arg, depth)
		}
		fmt.sbprint(b, ")")

	case ^Expr_Postfix:
		fmt.sbprintf(b, "(postfix %v", node.op)
		dump_child(b, node.operand, depth)
		fmt.sbprint(b, ")")

	case ^Expr_Unary:
		fmt.sbprintf(b, node.mutable ? "(unary %v mut" : "(unary %v", node.op)
		dump_child(b, node.operand, depth)
		fmt.sbprint(b, ")")

	case ^Expr_Binary:
		fmt.sbprintf(b, "(binary %v", node.op)
		dump_child(b, node.lhs, depth)
		dump_child(b, node.rhs, depth)
		fmt.sbprint(b, ")")

	case ^Expr_Range:
		fmt.sbprintf(b, "(range %v", node.op)
		dump_child(b, node.lo, depth)
		dump_child(b, node.hi, depth)
		fmt.sbprint(b, ")")

	case ^Expr_Or_Else:
		fmt.sbprint(b, "(or_else")
		dump_child(b, node.value, depth)
		dump_child(b, node.fallback, depth)
		fmt.sbprint(b, ")")

	case ^Expr_Cond:
		// Source order: `then if cond else otherwise`.
		fmt.sbprint(b, "(cond")
		dump_child(b, node.then, depth)
		dump_child(b, node.cond, depth)
		dump_child(b, node.otherwise, depth)
		fmt.sbprint(b, ")")

	case ^Expr_Move:
		fmt.sbprint(b, "(move")
		dump_child(b, node.value, depth)
		fmt.sbprint(b, ")")

	case ^Expr_Composite:
		fmt.sbprint(b, "(composite")
		dump_child(b, node.type_expr, depth)
		for element in node.elements {
			if element.key != nil {
				fmt.sbprint(b, " (=")
				dump_child(b, element.key, depth)
				dump_child(b, element.value, depth)
				fmt.sbprint(b, ")")
			} else {
				dump_child(b, element.value, depth)
			}
		}
		fmt.sbprint(b, ")")

	case ^Expr_Proc:
		fmt.sbprint(b, "(proc")
		dump_child(b, node.signature, depth)
		for clause in node.where_clauses {
			fmt.sbprint(b, " (where")
			dump_child(b, clause, depth)
			fmt.sbprint(b, ")")
		}
		if node.bodiless {
			fmt.sbprint(b, " ---)")
			return
		}
		fmt.sbprintln(b)
		dump_block(b, node.body, depth + 1)
		dump_indent(b, depth)
		fmt.sbprint(b, ")")

	case ^Expr_Proc_Group:
		fmt.sbprint(b, "(proc-group ")
		dump_names(b, node.names)
		fmt.sbprint(b, ")")

	case ^Expr_Operator:
		if node.hook != .None {
			fmt.sbprintf(b, "(hook %s", hook_name(node.hook))
		} else {
			fmt.sbprintf(b, "(operator %q", node.symbol)
		}
		dump_child(b, node.value, depth)
		fmt.sbprint(b, ")")

	case ^Type_Pointer:
		fmt.sbprint(b, node.mutable ? "(ptr mut" : "(ptr")
		dump_child(b, node.elem, depth)
		fmt.sbprint(b, ")")

	case ^Type_Multi_Pointer:
		fmt.sbprint(b, "(multi-ptr")
		dump_child(b, node.elem, depth)
		fmt.sbprint(b, ")")

	case ^Type_Slice:
		fmt.sbprint(b, node.mutable ? "(slice mut" : "(slice")
		dump_child(b, node.elem, depth)
		fmt.sbprint(b, ")")

	case ^Type_Dynamic_Array:
		fmt.sbprint(b, "(dyn-array")
		dump_child(b, node.elem, depth)
		fmt.sbprint(b, ")")

	case ^Type_Array:
		fmt.sbprint(b, "(array")
		if node.inferred {
			fmt.sbprint(b, " ?")
		} else {
			dump_child(b, node.length, depth)
		}
		dump_child(b, node.elem, depth)
		fmt.sbprint(b, ")")

	case ^Type_Map:
		fmt.sbprint(b, "(map")
		dump_child(b, node.key, depth)
		dump_child(b, node.value, depth)
		fmt.sbprint(b, ")")

	case ^Type_Distinct:
		fmt.sbprint(b, "(distinct")
		dump_child(b, node.elem, depth)
		fmt.sbprint(b, ")")

	case ^Type_Dyn:
		fmt.sbprint(b, node.mutable ? "(dyn mut" : "(dyn")
		dump_child(b, node.interface_expr, depth)
		fmt.sbprint(b, ")")

	case ^Type_Type:
		fmt.sbprint(b, "(type)")

	case ^Type_Poly:
		fmt.sbprintf(b, "(poly %q", node.name.text)
		if node.constraint != nil {
			dump_child(b, node.constraint, depth)
		}
		fmt.sbprint(b, ")")

	case ^Type_Proc:
		fmt.sbprint(b, "(proc-type")
		if node.convention != "" {
			// The stored convention is unquoted; the dump shows it as the source
			// string literal it was written as.
			fmt.sbprintf(b, " %q", node.convention)
		}
		for param in node.params {
			dump_parameter(b, param, depth)
		}
		for result in node.results {
			dump_result(b, result, depth)
		}
		fmt.sbprint(b, ")")

	case ^Type_Record:
		fmt.sbprint(b, node.kind == .Union ? "(union" : node.move_only ? "(move-only-struct" : "(struct")
		dump_attributes(b, node.attributes)
		dump_generic_params(b, node.generic_params, depth)
		for clause in node.where_clauses {
			fmt.sbprint(b, " (where")
			dump_child(b, clause, depth)
			fmt.sbprint(b, ")")
		}
		for field in node.fields {
			fmt.sbprint(b, " (field")
			dump_attributes(b, field.attributes)
			if field.is_using {
				fmt.sbprint(b, " using")
			}
			fmt.sbprint(b, " ")
			dump_names(b, field.names)
			dump_child(b, field.type, depth)
			fmt.sbprint(b, ")")
		}
		for variant in node.variants {
			dump_child(b, variant, depth)
		}
		fmt.sbprint(b, ")")

	case ^Type_Enum:
		fmt.sbprint(b, "(enum")
		if node.backing != nil {
			dump_child(b, node.backing, depth)
		}
		for field in node.fields {
			fmt.sbprintf(b, " (member %q", field.name.text)
			if field.value != nil {
				dump_child(b, field.value, depth)
			}
			fmt.sbprint(b, ")")
		}
		fmt.sbprint(b, ")")

	case ^Type_Interface:
		fmt.sbprint(b, "(interface")
		dump_generic_params(b, node.generic_params, depth)
		for requirement in node.requirements {
			dump_requirement(b, requirement, depth)
		}
		fmt.sbprint(b, ")")
	}
}

@(private = "file")
dump_generic_params :: proc(b: ^strings.Builder, params: []Generic_Param, depth: int) {
	for param in params {
		fmt.sbprint(b, " (generic ")
		dump_names(b, param.names)
		dump_child(b, param.type, depth)
		fmt.sbprint(b, ")")
	}
}

@(private = "file")
dump_parameter :: proc(b: ^strings.Builder, param: Parameter, depth: int) {
	fmt.sbprint(b, " (param")
	dump_attributes(b, param.attributes)
	switch param.mode {
	case .Value:
	case .Inout:
		fmt.sbprint(b, " inout")
	case .Move:
		fmt.sbprint(b, " move")
	case .Variadic:
		fmt.sbprint(b, " ..")
	}
	fmt.sbprint(b, " [")
	for entry, i in param.names {
		if i > 0 {
			fmt.sbprint(b, ",")
		}
		if entry.is_poly {
			fmt.sbprintf(b, "\"$%s\"", entry.name.text)
		} else {
			fmt.sbprintf(b, "%q", entry.name.text)
		}
	}
	fmt.sbprint(b, "]")
	dump_child(b, param.type, depth)
	if param.default != nil {
		fmt.sbprint(b, " (default")
		dump_child(b, param.default, depth)
		fmt.sbprint(b, ")")
	}
	fmt.sbprint(b, ")")
}

@(private = "file")
dump_result :: proc(b: ^strings.Builder, result: Result, depth: int) {
	fmt.sbprint(b, " (result")
	if result.is_inout {
		fmt.sbprint(b, " inout")
	}
	if len(result.names) > 0 {
		fmt.sbprint(b, " ")
		dump_names(b, result.names)
	}
	dump_child(b, result.type, depth)
	fmt.sbprint(b, ")")
}

@(private = "file")
dump_requirement :: proc(b: ^strings.Builder, requirement: Requirement, depth: int) {
	if requirement.kind == .Slot {
		fmt.sbprintf(b, " (slot %q", requirement.name.text)
		dump_child(b, requirement.slot_type, depth)
		fmt.sbprint(b, ")")
		return
	}

	fmt.sbprint(b, " (req")
	for group in requirement.bindings {
		fmt.sbprint(b, " (binding ")
		dump_names(b, group.names)
		if group.is_inout {
			fmt.sbprint(b, " inout")
		}
		dump_child(b, group.type, depth)
		fmt.sbprint(b, ")")
	}
	dump_child(b, requirement.expr, depth)
	if requirement.result != nil {
		fmt.sbprint(b, " (->")
		if requirement.result_inout {
			fmt.sbprint(b, " inout")
		}
		dump_child(b, requirement.result, depth)
		fmt.sbprint(b, ")")
	}
	fmt.sbprint(b, ")")
}

@(private = "file")
dump_argument :: proc(b: ^strings.Builder, arg: Argument, depth: int) {
	named := arg.name.text != ""
	if !named && arg.mode == .Value {
		dump_child(b, arg.value, depth)
		return
	}

	fmt.sbprint(b, " (arg")
	if named {
		fmt.sbprintf(b, " %q", arg.name.text)
	}
	switch arg.mode {
	case .Value:
	case .Inout:
		fmt.sbprint(b, " inout")
	case .Spread:
		fmt.sbprint(b, " ..")
	}
	dump_child(b, arg.value, depth)
	fmt.sbprint(b, ")")
}
