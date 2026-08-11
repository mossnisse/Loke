// Deterministic, semantic-free AST dump used by M1 parser golden tests and the
// `-dump-ast` driver mode. It intentionally omits addresses and checker
// annotations so output is stable across runs and compiler phases.
package lokec

import "core:fmt"
import "core:strings"

ast_dump :: proc(f: ^File) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	fmt.sbprintfln(&b, "(file package=%q", f.package_name)
	for item in f.items {
		dump_item(&b, item, 1)
	}
	fmt.sbprintln(&b, ")")
	return strings.to_string(b)
}

@(private = "file")
dump_indent :: proc(b: ^strings.Builder, depth: int) {
	for _ in 0 ..< depth {
		fmt.sbprint(b, "  ")
	}
}

@(private = "file")
dump_item :: proc(b: ^strings.Builder, item: Item, depth: int) {
	switch node in item {
	case ^Decl:
		dump_decl(b, node, depth)
	case ^Item_Error:
		dump_indent(b, depth)
		fmt.sbprintln(b, "(error-item)")
	}
}

@(private = "file")
dump_decl :: proc(b: ^strings.Builder, d: ^Decl, depth: int) {
	dump_indent(b, depth)
	fmt.sbprintf(b, "(%s names=[", d.kind == .Const ? "const" : "var")
	for name, i in d.names {
		if i > 0 {
			fmt.sbprint(b, ",")
		}
		fmt.sbprintf(b, "%q", name.text)
	}
	fmt.sbprint(b, "]")
	if d.declared_type != nil {
		fmt.sbprint(b, " type=")
		dump_type(b, d.declared_type)
	}
	if d.body != nil {
		fmt.sbprintln(b)
		dump_block(b, d.body, depth + 1)
		dump_indent(b, depth)
		fmt.sbprintln(b, ")")
		return
	}
	if len(d.values) == 0 {
		fmt.sbprintln(b, ")")
		return
	}
	fmt.sbprintln(b)
	for value in d.values {
		dump_expr_line(b, value, depth + 1)
	}
	dump_indent(b, depth)
	fmt.sbprintln(b, ")")
}

@(private = "file")
dump_type :: proc(b: ^strings.Builder, t: Type_Syntax) {
	switch node in t {
	case ^Type_Error:
		fmt.sbprint(b, "(error-type)")
	case ^Type_Name:
		fmt.sbprintf(b, "(name %q)", node.name)
	}
}

@(private = "file")
dump_block :: proc(b: ^strings.Builder, block: ^Block, depth: int) {
	dump_indent(b, depth)
	fmt.sbprintln(b, "(block")
	for stmt in block.stmts {
		dump_stmt(b, stmt, depth + 1)
	}
	dump_indent(b, depth)
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
		dump_expr_line(b, node.expr, depth)
	case ^Stmt_Return:
		dump_indent(b, depth)
		fmt.sbprintln(b, "(return)")
	case ^Block:
		dump_block(b, node, depth)
	}
}

@(private = "file")
dump_expr_line :: proc(b: ^strings.Builder, expr: Expr, depth: int) {
	dump_indent(b, depth)
	dump_expr(b, expr, depth)
	fmt.sbprintln(b)
}

@(private = "file")
dump_expr :: proc(b: ^strings.Builder, expr: Expr, depth: int) {
	switch node in expr {
	case ^Expr_Error:
		fmt.sbprint(b, "(error-expr)")
	case ^Expr_Ident:
		fmt.sbprintf(b, "(ident %q)", node.name)
	case ^Expr_Int:
		fmt.sbprintf(b, "(int %d)", node.value)
	case ^Expr_Unary:
		fmt.sbprintf(b, "(unary %v ", node.op)
		dump_expr(b, node.operand, depth)
		fmt.sbprint(b, ")")
	case ^Expr_Binary:
		fmt.sbprintf(b, "(binary %v ", node.op)
		dump_expr(b, node.lhs, depth)
		fmt.sbprint(b, " ")
		dump_expr(b, node.rhs, depth)
		fmt.sbprint(b, ")")
	case ^Expr_Call:
		fmt.sbprint(b, "(call ")
		dump_expr(b, node.callee, depth)
		for arg in node.args {
			fmt.sbprint(b, " ")
			dump_expr(b, arg, depth)
		}
		fmt.sbprint(b, ")")
	}
}
