// AST (compiler-plan B4). Every node carries a Span; the checker annotates
// these same nodes in place, which is the "typed AST" of decision A1.
package lokec

import "core:mem"

// The whole M0 type system. B7's interned table arrives with M2.
Type :: enum {
	Invalid,
	Void,
	Untyped_Int,
	Int,
}

type_name :: proc(t: Type) -> string {
	switch t {
	case .Invalid:
		return "<invalid>"
	case .Void:
		return "()"
	case .Untyped_Int:
		return "untyped int"
	case .Int:
		return "int"
	}
	return "<invalid>"
}

Expr_Base :: struct {
	span:        Span,
	type:        Type,
	const_value: i64,
	is_const:    bool,
}

Expr :: union {
	^Expr_Error,
	^Expr_Ident,
	^Expr_Int,
	^Expr_Unary,
	^Expr_Binary,
	^Expr_Call,
}

// Error nodes are retained in the tree instead of being represented by nil.
// Later parser recovery can therefore preserve surrounding syntax and AST
// dumps remain useful even for malformed files.
Expr_Error :: struct {
	using base: Expr_Base,
}

Expr_Ident :: struct {
	using base: Expr_Base,
	name:       string,
	symbol:     ^Symbol,
}

Expr_Int :: struct {
	using base: Expr_Base,
	value:      i64,
}

Expr_Unary :: struct {
	using base: Expr_Base,
	op:         Token_Kind,
	op_span:    Span,
	operand:    Expr,
}

Expr_Binary :: struct {
	using base: Expr_Base,
	op:         Token_Kind,
	op_span:    Span,
	lhs:        Expr,
	rhs:        Expr,
}

Expr_Call :: struct {
	using base: Expr_Base,
	callee:     Expr,
	args:       []Expr,
}

expr_span :: proc(e: Expr) -> Span {
	switch v in e {
	case ^Expr_Error:
		return v.span
	case ^Expr_Ident:
		return v.span
	case ^Expr_Int:
		return v.span
	case ^Expr_Unary:
		return v.span
	case ^Expr_Binary:
		return v.span
	case ^Expr_Call:
		return v.span
	}
	return no_span()
}

expr_has_error :: proc(e: Expr) -> bool {
	#partial switch v in e {
	case ^Expr_Error:
		return true
	case ^Expr_Unary:
		return expr_has_error(v.operand)
	case ^Expr_Binary:
		return expr_has_error(v.lhs) || expr_has_error(v.rhs)
	case ^Expr_Call:
		if expr_has_error(v.callee) {
			return true
		}
		for arg in v.args {
			if expr_has_error(arg) {
				return true
			}
		}
	}
	return false
}

Stmt :: union {
	^Decl,
	^Stmt_Error,
	^Stmt_Expr,
	^Stmt_Return,
	^Block,
}

Stmt_Error :: struct {
	span: Span,
}

Block :: struct {
	span:  Span,
	stmts: []Stmt,
}

Stmt_Expr :: struct {
	span: Span,
	expr: Expr,
}

Stmt_Return :: struct {
	span: Span,
}

Decl_Kind :: enum {
	Var,
	Const,
}

Check_State :: enum {
	Unchecked,
	Checking,
	Checked,
}

Name :: struct {
	text: string,
	span: Span,
}


// Syntactic types are deliberately separate from the semantic `Type` above.
// M1 grows this union to cover the complete grammar; M2 resolves it to an
// interned semantic type. Keeping the two domains distinct prevents parser
// structure from becoming coupled to type checking.
Type_Syntax :: union {
	^Type_Error,
	^Type_Name,
}

Type_Error :: struct {
	span: Span,
}

Type_Name :: struct {
	span: Span,
	name: string,
}

type_syntax_span :: proc(t: Type_Syntax) -> Span {
	switch v in t {
	case ^Type_Error:
		return v.span
	case ^Type_Name:
		return v.span
	}
	return no_span()
}

// One declaration, covering `x: int;`, `x: int = e;`, `x := e;` and
// `x: int : e;`. A constant whose value is a procedure definition carries it in
// `body` instead of `values`.
Decl :: struct {
	span:      Span,
	kind:      Decl_Kind,
	names:     []Name,
	declared_type: Type_Syntax, // nil when the type is inferred
	values:    []Expr,
	body:      ^Block, // set for `name :: proc() { ... }`
	symbols:   []^Symbol,
	top_level: bool,
	check_state: Check_State,
}

// Top-level syntax has its own union. M1 can add imports, foreign blocks,
// impl/extend blocks, and top-level when nodes here without turning Decl into a
// catch-all record.
Item :: union {
	^Decl,
	^Item_Error,
}

Item_Error :: struct {
	span: Span,
}

item_span :: proc(item: Item) -> Span {
	switch v in item {
	case ^Decl:
		return v.span
	case ^Item_Error:
		return v.span
	}
	return no_span()
}

File :: struct {
	// All syntax nodes and syntax-owned slices live in this arena. The source
	// manager owns source text separately, so source-backed names remain valid.
	arena:        mem.Dynamic_Arena,
	file:         u32,
	package_name: string,
	package_span: Span,
	items:        []Item,
}

destroy_ast :: proc(f: ^File) {
	mem.dynamic_arena_destroy(&f.arena)
}
