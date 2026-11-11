// Deterministic AST dump of written syntax, for the parser goldens and
// `-dump-ast`. `_` is an absent optional child.
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

// ` @[name,qualified.name=EXPR]`, or nothing.
@(private = "file")
dump_attributes :: proc(b: ^strings.Builder, attributes: []Attribute) {
	if len(attributes) == 0 {
		return
	}
	fmt.sbprint(b, " @[")
	for attribute, i in attributes {
		fmt.sbprint(b, i > 0 ? "," : "")
		for name, j in attribute.path {
			fmt.sbprint(b, j > 0 ? "." : "", name.text, sep = "")
		}
		if attribute.value != nil {
			fmt.sbprint(b, "=")
			dump_expr(b, attribute.value, 0)
		}
	}
	fmt.sbprint(b, "]")
}

@(private = "file")
LITERAL_TAG := [Literal_Kind]string {
	.Int        = "int",
	.Float      = "float",
	.String     = "string",
	.Raw_String = "raw_string",
	.Rune       = "rune",
}

@(private = "file")
DURATION_TAG := [Duration]string {
	.None         = "",
	.Static       = " static",
	.Thread_Local = " thread_local",
}

@(private = "file")
CAPTURE_TAG := [Capture_Mode]string {
	.Copy       = "copy",
	.Borrow     = "borrow",
	.Borrow_Mut = "borrow-mut",
	.Move       = "move",
}

@(private = "file")
PARAM_TAG := [Param_Mode]string {
	.Value    = "",
	.Borrow   = " borrow",
	.Inout    = " inout",
	.Move     = " move",
	.Variadic = " ..",
}

@(private = "file")
ARGUMENT_TAG := [Argument_Mode]string {
	.Value  = "",
	.Inout  = " inout",
	.Spread = " ..",
}

@(private = "file")
dump_indent :: proc(b: ^strings.Builder, depth: int) {
	for _ in 0 ..< depth {
		fmt.sbprint(b, "  ")
	}
}

// How a node on lines of its own opens, up to its first child.
@(private = "file")
dump_head :: proc(b: ^strings.Builder, head: string, attributes: []Attribute, depth: int) {
	dump_indent(b, depth)
	fmt.sbprint(b, head)
	dump_attributes(b, attributes)
}

@(private = "file")
dump_close :: proc(b: ^strings.Builder, depth: int) {
	dump_indent(b, depth)
	fmt.sbprintln(b, ")")
}

// `head`, one child, and the closing parenthesis, inline.
@(private = "file")
dump_wrapped :: proc(b: ^strings.Builder, head: string, expr: Expr, depth: int) {
	fmt.sbprint(b, head)
	dump_child(b, expr, depth)
	fmt.sbprint(b, ")")
}

// Each item on a line of its own, then the node's close.
@(private = "file")
dump_members :: proc(b: ^strings.Builder, items: []Item, depth: int) {
	for item in items {
		dump_item(b, item, depth + 1)
	}
	dump_close(b, depth)
}

@(private = "file")
dump_names :: proc(b: ^strings.Builder, names: []Name) {
	fmt.sbprint(b, "[")
	for name, i in names {
		fmt.sbprint(b, i > 0 ? "," : "")
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
		dump_head(b, "(import", node.attributes, depth)
		if node.alias.text != "" {
			fmt.sbprintf(b, " alias=%q", node.alias.text)
		}
		fmt.sbprintfln(b, " %s)", node.path)

	case ^Item_Foreign_Import:
		dump_head(b, "(foreign-import", node.attributes, depth)
		fmt.sbprintfln(b, " %q %q)", node.name.text, node.path)

	case ^Item_Foreign_Block:
		dump_head(b, "(foreign", node.attributes, depth)
		fmt.sbprintfln(b, " %q", node.library.text)
		for member in node.members {
			dump_item(b, member, depth + 1)
		}
		dump_close(b, depth)

	case ^Item_Impl:
		dump_head(b, "(impl", node.attributes, depth)
		dump_child(b, node.type, depth)
		fmt.sbprintln(b)
		dump_members(b, node.members, depth)

	case ^Item_Delegate:
		dump_head(b, "(delegate", node.attributes, depth)
		for symbol in node.symbols {
			fmt.sbprintf(b, " %q", symbol)
		}
		fmt.sbprintln(b, ")")

	case ^Item_When:
		dump_head(b, "(when", node.attributes, depth)
		fmt.sbprintln(b)
		dump_labeled(b, "cond", node.cond, depth + 1)
		dump_item(b, node.then, depth + 1)
		if node.otherwise != nil {
			dump_indent(b, depth + 1)
			fmt.sbprintln(b, "(else")
			dump_item(b, node.otherwise, depth + 2)
			dump_close(b, depth + 1)
		}
		dump_close(b, depth)

	case ^Item_Block:
		dump_head(b, "(items", node.attributes, depth)
		fmt.sbprintln(b)
		dump_members(b, node.items, depth)

	case ^Item_Static_Assert:
		dump_head(b, "(static_assert", node.attributes, depth)
		dump_child(b, node.call, depth)
		fmt.sbprintln(b, ")")
	}
}

@(private = "file")
dump_decl :: proc(b: ^strings.Builder, d: ^Decl, depth: int) {
	dump_indent(b, depth)
	fmt.sbprintf(b, "(%s names=", d.kind == .Const ? "const" : "var")
	dump_names(b, d.names)
	dump_attributes(b, d.attributes)
	fmt.sbprint(b, DURATION_TAG[d.duration])
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
	dump_close(b, depth)
}

@(private = "file")
dump_block :: proc(b: ^strings.Builder, block: ^Block, depth: int) {
	if block == nil {
		dump_indent(b, depth)
		fmt.sbprintln(b, "(no-block)")
		return
	}
	dump_head(b, "(block", block.attributes, depth)
	fmt.sbprintln(b)
	for stmt in block.stmts {
		dump_stmt(b, stmt, depth + 1)
	}
	dump_close(b, depth)
}

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

	case ^Item_Impl:
		dump_item(b, node, depth)

	case ^Stmt_Error:
		dump_indent(b, depth)
		fmt.sbprintln(b, "(error-stmt)")

	case ^Stmt_Expr:
		dump_indent(b, depth)
		if len(node.exprs) == 1 && len(node.attributes) == 0 {
			dump_expr(b, node.exprs[0], depth)
		} else {
			dump_head(b, "(exprs", node.attributes, 0)
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
		dump_head(b, "(if", node.attributes, depth)
		fmt.sbprintln(b)
		if node.init != nil {
			dump_stmt(b, node.init, depth + 1)
		}
		dump_labeled(b, "cond", node.cond, depth + 1)
		dump_block(b, node.then, depth + 1)
		dump_else(b, node.otherwise, depth + 1)
		dump_close(b, depth)

	case ^Stmt_When:
		dump_head(b, "(when", node.attributes, depth)
		fmt.sbprintln(b)
		dump_labeled(b, "cond", node.cond, depth + 1)
		dump_block(b, node.then, depth + 1)
		dump_else(b, node.otherwise, depth + 1)
		dump_close(b, depth)

	case ^Stmt_For:
		dump_head(b, node.condition_only ? "(for cond-only" : "(for", node.attributes, depth)
		fmt.sbprintln(b)
		if node.init != nil {
			dump_stmt(b, node.init, depth + 1)
		}
		if node.cond != nil {
			dump_labeled(b, "cond", node.cond, depth + 1)
		}
		// Labelled, or `for (f();;)` and `for (;;f())` would print alike.
		if node.post != nil {
			dump_indent(b, depth + 1)
			fmt.sbprintln(b, "(post")
			dump_stmt(b, node.post, depth + 2)
			dump_close(b, depth + 1)
		}
		dump_block(b, node.body, depth + 1)
		dump_close(b, depth)

	case ^Stmt_Foreach:
		dump_indent(b, depth)
		fmt.sbprint(b, "(foreach [")
		dump_foreach_bindings(b, node.bindings)
		fmt.sbprint(b, "]")
		dump_attributes(b, node.attributes)
		fmt.sbprintln(b)
		dump_labeled(b, "in", node.iterable, depth + 1)
		dump_block(b, node.body, depth + 1)
		dump_close(b, depth)

	case ^Stmt_Switch:
		// Always a value switch: the pattern kind and a case's bindings are the
		// checker's, and every dump is of a tree straight from `parse`.
		dump_head(b, "(switch value", node.attributes, depth)
		fmt.sbprintln(b)
		if node.init != nil {
			dump_stmt(b, node.init, depth + 1)
		}
		dump_labeled(b, "subject", node.subject, depth + 1)
		for entry in node.cases {
			dump_switch_case(b, entry, depth + 1)
		}
		dump_close(b, depth)

	case ^Stmt_Defer:
		dump_head(b, node.on_failure ? "(errdefer" : "(defer", node.attributes, depth)
		fmt.sbprintln(b)
		if node.stmt != nil {
			dump_stmt(b, node.stmt, depth + 1)
		}
		dump_close(b, depth)

	case ^Stmt_Return:
		dump_head(b, "(return", node.attributes, depth)
		dump_return_value(b, node.value, depth)
		fmt.sbprintln(b, ")")

	case ^Stmt_Branch:
		dump_head(b, node.kind == .Break ? "(break" : "(continue", node.attributes, depth)
		fmt.sbprintln(b, ")")

	case ^Stmt_Parallel:
		dump_head(b, "(parallel", node.attributes, depth)
		if node.executor != nil {
			dump_child(b, node.executor, depth)
		}
		fmt.sbprintln(b)
		dump_block(b, node.body, depth + 1)
		dump_close(b, depth)

	case ^Stmt_Spawn:
		dump_head(b, "(spawn", node.attributes, depth)
		if node.result != nil {
			fmt.sbprintf(b, " result=%q", node.result.name)
		}
		dump_child(b, node.call, depth)
		fmt.sbprintln(b, ")")

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
	dump_close(b, depth)
}

@(private = "file")
dump_switch_case :: proc(b: ^strings.Builder, entry: Switch_Case, depth: int) {
	dump_indent(b, depth)
	fmt.sbprint(b, "(case")
	for value in entry.values {
		dump_child(b, value, depth)
	}
	fmt.sbprintln(b)
	for inner in entry.stmts {
		dump_stmt(b, inner, depth + 1)
	}
	dump_close(b, depth)
}

@(private = "file")
dump_return_value :: proc(b: ^strings.Builder, value: ^Return_Value, depth: int) {
	if value == nil {
		return
	}
	if value.is_inout {
		fmt.sbprint(b, " ")
		dump_wrapped(b, "(inout", value.expr, depth)
	} else {
		dump_child(b, value.expr, depth)
	}
}

// The exit of an `or_else`, inline: `(break)`, `(continue)`, `(return x)`.
@(private = "file")
dump_or_else_exit :: proc(b: ^strings.Builder, exit: Stmt, depth: int) {
	#partial switch node in exit {
	case ^Stmt_Branch:
		fmt.sbprint(b, node.kind == .Break ? " (break)" : " (continue)")
	case ^Stmt_Return:
		fmt.sbprint(b, " (return")
		dump_return_value(b, node.value, depth)
		fmt.sbprint(b, ")")
	}
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
		fmt.sbprintf(b, "(%s %q)", LITERAL_TAG[node.kind], node.text)

	case ^Expr_Ident:
		fmt.sbprintf(b, "(ident %q)", node.name)

	case ^Expr_Selector:
		fmt.sbprint(b, "(selector")
		dump_child(b, node.operand, depth)
		fmt.sbprintf(b, " %q)", node.name.text)

	case ^Expr_Index:
		fmt.sbprint(b, "(index")
		dump_child(b, node.operand, depth)
		for index in node.indices {
			dump_child(b, index, depth)
		}
		fmt.sbprint(b, ")")

	case ^Expr_Slice:
		fmt.sbprint(b, node.mutable ? "(slice-of mut" : "(slice-of")
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
		if node.failure != nil {
			dump_child(b, node.failure, depth)
		}
		fmt.sbprint(b, ")")

	case ^Expr_Propagated_Error:
		fmt.sbprint(b, "(propagated-error)")

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
		if node.exit != nil {
			dump_or_else_exit(b, node.exit, depth)
		} else {
			dump_child(b, node.fallback, depth)
		}
		fmt.sbprint(b, ")")

	case ^Expr_Cond:
		fmt.sbprint(b, "(cond")
		dump_child(b, node.then, depth)
		dump_child(b, node.cond, depth)
		dump_child(b, node.otherwise, depth)
		fmt.sbprint(b, ")")

	case ^Expr_Move:
		dump_wrapped(b, "(move", node.value, depth)

	case ^Expr_Composite:
		if node.capture != nil {
			dump_capture(b, node.capture, depth)
			return
		}
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
		dump_where_clauses(b, node.where_clauses, depth)
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
		dump_wrapped(b, node.mutable ? "(ptr mut" : "(ptr", node.elem, depth)

	case ^Type_C_Pointer:
		dump_wrapped(b, "(c-ptr", node.elem, depth)

	case ^Type_Slice:
		dump_wrapped(b, node.mutable ? "(slice mut" : "(slice", node.elem, depth)

	case ^Type_Dynamic_Array:
		dump_wrapped(b, "(dyn-array", node.elem, depth)

	case ^Type_Array:
		fmt.sbprint(b, "(array")
		if node.length == nil {
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
		dump_wrapped(b, "(distinct", node.elem, depth)

	case ^Type_Dyn:
		dump_wrapped(b, node.mutable ? "(dyn mut" : "(dyn", node.interface_expr, depth)

	case ^Type_Type:
		fmt.sbprint(b, "(type)")

	case ^Type_Poly:
		fmt.sbprintf(b, "(poly %q)", node.name.text)

	case ^Type_Proc:
		fmt.sbprint(b, "(proc-type")
		if node.convention != "" {
			fmt.sbprintf(b, " %q", node.convention)
		}
		for param in node.params {
			dump_parameter(b, param, depth)
		}
		if node.result != nil {
			dump_result(b, node.result^, depth)
		}
		fmt.sbprint(b, ")")

	case ^Type_Record:
		fmt.sbprint(b, node.kind == .Union ? "(union" : "(struct")
		dump_generic_params(b, node.generic_params, depth)
		dump_where_clauses(b, node.where_clauses, depth)
		dump_fields(b, node.fields, depth)
		dump_variants(b, node.variants, depth)
		fmt.sbprint(b, ")")

	case ^Type_Anon_Record:
		fmt.sbprint(b, "(record")
		dump_fields(b, node.fields, depth)
		fmt.sbprint(b, ")")

	case ^Type_Anon_Union:
		fmt.sbprint(b, "(anonymous-union")
		dump_variants(b, node.variants, depth)
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
		dump_where_clauses(b, node.where_clauses, depth)
		for requirement in node.requirements {
			dump_requirement(b, requirement, depth)
		}
		fmt.sbprint(b, ")")
	}
}

// `(capture (copy limit limit) (borrow cfg self.config) (proc ...))`
@(private = "file")
dump_capture :: proc(b: ^strings.Builder, capture: ^Capture_Literal, depth: int) {
	fmt.sbprint(b, "(capture")
	for entry in capture.entries {
		fmt.sbprintf(b, " (%s %s", CAPTURE_TAG[entry.mode], entry.name.text)
		dump_child(b, entry.value, depth)
		fmt.sbprint(b, ")")
	}
	dump_child(b, capture.procedure, depth)
	fmt.sbprint(b, ")")
}

@(private = "file")
dump_fields :: proc(b: ^strings.Builder, fields: []Field, depth: int) {
	for field in fields {
		fmt.sbprint(b, " (field")
		dump_attributes(b, field.attributes)
		fmt.sbprint(b, " ")
		dump_names(b, field.names)
		dump_child(b, field.type, depth)
		fmt.sbprint(b, ")")
	}
}

@(private = "file")
dump_variants :: proc(b: ^strings.Builder, variants: []Variant, depth: int) {
	for variant in variants {
		fmt.sbprintf(b, " (variant %q", variant.name.text)
		if variant.type != nil {
			dump_child(b, variant.type, depth)
		}
		fmt.sbprint(b, ")")
	}
}

@(private = "file")
dump_where_clauses :: proc(b: ^strings.Builder, clauses: []Expr, depth: int) {
	for clause in clauses {
		dump_wrapped(b, " (where", clause, depth)
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
	fmt.sbprint(b, PARAM_TAG[param.mode], " [", sep = "")
	for entry, i in param.names {
		fmt.sbprint(b, i > 0 ? "," : "")
		fmt.sbprintf(b, entry.is_poly ? "\"$%s\"" : "%q", entry.name.text)
	}
	fmt.sbprint(b, "]")
	dump_child(b, param.type, depth)
	if param.default != nil {
		dump_wrapped(b, " (default", param.default, depth)
	}
	fmt.sbprint(b, ")")
}

@(private = "file")
dump_result :: proc(b: ^strings.Builder, result: Result, depth: int) {
	fmt.sbprint(b, " (result")
	if result.diverges {
		fmt.sbprint(b, " !")
	}
	if result.is_inout {
		fmt.sbprint(b, " inout")
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
	fmt.sbprint(b, ARGUMENT_TAG[arg.mode])
	dump_child(b, arg.value, depth)
	fmt.sbprint(b, ")")
}

@(private = "file")
dump_foreach_bindings :: proc(b: ^strings.Builder, bindings: []Foreach_Binding) {
	for binding, i in bindings {
		fmt.sbprint(b, i > 0 ? "," : "")
		if len(binding.group) > 0 {
			fmt.sbprint(b, "[")
			dump_foreach_bindings(b, binding.group)
			fmt.sbprint(b, "]")
			continue
		}
		fmt.sbprintf(
			b,
			"\"%s%s%s\"",
			binding.is_static ? "$" : "",
			binding.is_ref ? "&mut " : "",
			binding.name.text,
		)
	}
}
