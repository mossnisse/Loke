// Name resolution and type checking (compiler-plan B6/B8, minimal), plus the
// constant folding that stands in for the compile-time engine until M3.
//
// Annotations are written back onto the AST nodes; there is no separate typed
// tree (decision A1).
package lokec

Symbol_Kind :: enum {
	Var,
	Const,
	Proc,
	Builtin,
}

Symbol :: struct {
	name:        string,
	span:        Span,
	kind:        Symbol_Kind,
	type:        Type, // result type for Proc and Builtin
	const_value: i64,
	params:      []Type, // Builtin and Proc
	llvm_name:   string, // filled in by the backend
	decl:        ^Decl,
}

Scope_Kind :: enum {
	Universe,
	Package,
	Local,
}

Scope :: struct {
	parent: ^Scope,
	names:  map[string]^Symbol,
	kind:   Scope_Kind,
}

@(private = "file")
Checker :: struct {
	c:     ^Compiler,
	file:  u32,
	scope: ^Scope,
}

// The M0 stand-in for `core:fmt`.
// ponytail: scaffolding, not a language feature; delete when the seed runtime
// and core:fmt land in M6 (B14).
PRINT_BUILTIN :: "print_int"

check :: proc(c: ^Compiler, f: ^File) {
	k := Checker {
		c    = c,
		file = f.file,
	}

	universe := new_scope(nil, .Universe)
	print_sym := new(Symbol)
	print_sym^ = Symbol {
		name   = PRINT_BUILTIN,
		kind   = .Builtin,
		type   = .Void,
		params = []Type{.Int},
	}
	universe.names[PRINT_BUILTIN] = print_sym

	k.scope = new_scope(universe, .Package)
	package_scope := k.scope

	if f.package_name != "" && f.package_name != "main" {
		errorf(
			c,
			f.package_span,
			"L0301",
			"an executable is built from a package named `main`, found `%s`",
			f.package_name,
		)
	}

	// Pass 1: collect top-level declarations so they are order-independent.
	for item in f.items {
		if d, ok := item.(^Decl); ok {
			declare_all(&k, d, top_level = true)
		}
	}

	// Pass 2: check initialisers and bodies.
	for item in f.items {
		if d, ok := item.(^Decl); ok {
			check_decl(&k, d)
		}
	}

	entry, has_entry := package_scope.names["main"]
	if !has_entry {
		errorf(c, no_span(), "L0302", "package `main` has no `main` procedure")
	} else if entry.kind != .Proc {
		errorf(c, entry.span, "L0303", "`main` must be a procedure: `main :: proc() { ... }`")
	}
}

@(private = "file")
new_scope :: proc(parent: ^Scope, kind: Scope_Kind) -> ^Scope {
	s := new(Scope)
	s.parent = parent
	s.kind = kind
	s.names = make(map[string]^Symbol)
	return s
}

@(private = "file")
lookup :: proc(scope: ^Scope, name: string) -> ^Symbol {
	for s := scope; s != nil; s = s.parent {
		if sym, ok := s.names[name]; ok {
			return sym
		}
	}
	return nil
}

@(private = "file")
lookup_with_scope :: proc(scope: ^Scope, name: string) -> (symbol: ^Symbol, owner: ^Scope) {
	for s := scope; s != nil; s = s.parent {
		if sym, ok := s.names[name]; ok {
			return sym, s
		}
	}
	return nil, nil
}

// Creates the symbols for one declaration. Shadowing is rejected, which is the
// default design.md's open question records.
@(private = "file")
declare_all :: proc(k: ^Checker, d: ^Decl, top_level := false) {
	d.top_level = top_level
	symbols := make([dynamic]^Symbol)
	for name in d.names {
		if name.text == "_" {
			append(&symbols, nil) // the discard identifier binds nothing
			continue
		}

		if existing, ok := k.scope.names[name.text]; ok {
			errorf(k.c, name.span, "L0304", "`%s` is already declared in this scope", name.text)
			_ = existing
			append(&symbols, nil)
			continue
		}
		outer, owner := lookup_with_scope(k.scope.parent, name.text)
		if outer != nil && owner.kind == .Local {
			errorf(k.c, name.span, "L0305", "`%s` shadows an outer declaration", name.text)
		}

		sym := new(Symbol)
		sym.name = name.text
		sym.span = name.span
		sym.decl = d
		switch {
		case d.body != nil:
			sym.kind = .Proc
			sym.type = .Void
		case d.kind == .Const:
			sym.kind = .Const
		case:
			sym.kind = .Var
		}
		k.scope.names[name.text] = sym
		append(&symbols, sym)
	}
	d.symbols = symbols[:]
}

@(private = "file")
resolve_type_name :: proc(k: ^Checker, d: ^Decl) -> Type {
	if d.declared_type == nil {
		return .Invalid // inferred
	}
	switch syntax in d.declared_type {
	case ^Type_Error:
		return .Invalid
	case ^Type_Name:
		if syntax.name == "int" {
			return .Int
		}
		errorf(k.c, syntax.span, "L0306", "unknown type `%s`", syntax.name)
		return .Invalid
	}
	return .Invalid
}

@(private = "file")
check_decl :: proc(k: ^Checker, d: ^Decl) {
	if d.check_state == .Checked {
		return
	}
	if d.check_state == .Checking {
		errorf(k.c, d.span, "L0324", "constant initialisation cycle")
		return
	}
	d.check_state = .Checking
	check_decl_inner(k, d)
	d.check_state = .Checked
}

@(private = "file")
check_decl_inner :: proc(k: ^Checker, d: ^Decl) {
	if d.body != nil {
		check_proc(k, d)
		return
	}

	declared := resolve_type_name(k, d)

	if len(d.values) == 0 {
		if d.kind == .Const {
			errorf(k.c, d.span, "L0307", "a constant needs an initialiser")
		}
		assign_symbol_types(d, declared == .Invalid ? .Int : declared)
		return
	}
	if len(d.values) != len(d.names) {
		errorf(
			k.c,
			d.span,
			"L0308",
			"%d name%s but %d initialiser%s",
			len(d.names),
			len(d.names) == 1 ? "" : "s",
			len(d.values),
			len(d.values) == 1 ? "" : "s",
		)
	}

	for value, i in d.values {
		if value == nil {
			continue
		}
		type := check_expr(k, value)
		if type == .Void {
			errorf(k.c, expr_span(value), "L0309", "this expression produces no value")
			type = .Invalid
		}

		if declared != .Invalid && type != .Invalid && !assignable(type, declared) {
			errorf(
				k.c,
				expr_span(value),
				"L0310",
				"cannot initialise `%s` with `%s`",
				type_name(declared),
				type_name(type),
			)
		}

		if d.top_level && d.kind == .Var && !is_const_expr(value) {
			errorf(
				k.c,
				expr_span(value),
				"L0325",
				"a file-scope initializer must be a compile-time constant",
			)
		}

		final := declared != .Invalid ? declared : default_type(type)
		if i < len(d.symbols) && d.symbols[i] != nil {
			sym := d.symbols[i]
			sym.type = final
			if d.kind == .Const {
				if type != .Invalid && !is_const_expr(value) {
					errorf(
						k.c,
						expr_span(value),
						"L0311",
						"a constant initialiser must be a compile-time constant",
					)
				}
				if is_const_expr(value) {
					sym.const_value = const_value_of(value)
				}
			}
		}
	}
}

@(private = "file")
assign_symbol_types :: proc(d: ^Decl, type: Type) {
	for sym in d.symbols {
		if sym != nil {
			sym.type = type
		}
	}
}

@(private = "file")
check_proc :: proc(k: ^Checker, d: ^Decl) {
	if len(d.names) != 1 {
		errorf(k.c, d.span, "L0312", "a procedure declaration binds exactly one name")
	}
	outer := k.scope
	k.scope = new_scope(outer, .Local)
	check_block(k, d.body)
	k.scope = outer
}

@(private = "file")
check_block :: proc(k: ^Checker, b: ^Block) {
	if b == nil {
		return
	}
	for stmt in b.stmts {
		switch s in stmt {
		case ^Stmt_Error:
			// Parser diagnostics already describe this retained recovery node.
		case ^Decl:
			declare_all(k, s)
			check_decl(k, s)
		case ^Stmt_Expr:
			if _, is_call := s.expr.(^Expr_Call); !is_call && s.expr != nil {
				errorf(k.c, s.span, "L0313", "this expression statement has no effect")
			}
			check_expr(k, s.expr)
		case ^Stmt_Return:
		// `main` has no results, so a bare `return;` is always valid here.
		case ^Block:
			outer := k.scope
			k.scope = new_scope(outer, .Local)
			check_block(k, s)
			k.scope = outer
		}
	}
}

// `untyped int` materialises as `int`, its default type (design.md "Untyped
// types").
@(private = "file")
default_type :: proc(t: Type) -> Type {
	return t == .Untyped_Int ? .Int : t
}

@(private = "file")
assignable :: proc(from: Type, to: Type) -> bool {
	if from == to {
		return true
	}
	return from == .Untyped_Int && to == .Int
}

@(private = "file")
is_numeric :: proc(t: Type) -> bool {
	return t == .Int || t == .Untyped_Int
}

is_const_expr :: proc(e: Expr) -> bool {
	switch v in e {
	case ^Expr_Error:
		return false
	case ^Expr_Ident:
		return v.is_const
	case ^Expr_Int:
		return v.is_const
	case ^Expr_Unary:
		return v.is_const
	case ^Expr_Binary:
		return v.is_const
	case ^Expr_Call:
		return false
	}
	return false
}

const_value_of :: proc(e: Expr) -> i64 {
	switch v in e {
	case ^Expr_Error:
		return 0
	case ^Expr_Ident:
		return v.const_value
	case ^Expr_Int:
		return v.const_value
	case ^Expr_Unary:
		return v.const_value
	case ^Expr_Binary:
		return v.const_value
	case ^Expr_Call:
		return 0
	}
	return 0
}

@(private = "file")
check_expr :: proc(k: ^Checker, e: Expr) -> Type {
	switch v in e {
	case ^Expr_Error:
		v.type = .Invalid
		return .Invalid
	case ^Expr_Int:
		v.type = .Untyped_Int
		v.is_const = true
		v.const_value = v.value
		return v.type

	case ^Expr_Ident:
		sym := lookup(k.scope, v.name)
		if sym == nil {
			if v.name == "_" {
				errorf(k.c, v.span, "L0314", "`_` cannot be read")
			} else {
				errorf(k.c, v.span, "L0315", "unknown name `%s`", v.name)
			}
			v.type = .Invalid
			return v.type
		}
		if sym.kind == .Const && sym.decl != nil {
			switch sym.decl.check_state {
			case .Unchecked:
				check_decl(k, sym.decl)
			case .Checking:
				errorf(k.c, v.span, "L0324", "constant initialisation cycle involving `%s`", v.name)
				v.type = .Invalid
				return v.type
			case .Checked:
			}
		}
		v.symbol = sym
		if sym.kind == .Proc || sym.kind == .Builtin {
			// Only legal as a callee; Expr_Call handles that case itself.
			errorf(k.c, v.span, "L0316", "`%s` is a procedure and must be called", v.name)
			v.type = .Invalid
			return v.type
		}
		v.type = sym.type
		if sym.kind == .Const {
			v.is_const = true
			v.const_value = sym.const_value
		}
		return v.type

	case ^Expr_Unary:
		operand := check_expr(k, v.operand)
		if operand != .Invalid && !is_numeric(operand) {
			errorf(
				k.c,
				v.op_span,
				"L0317",
				"`%s` does not apply to `%s`",
				v.op == .Minus ? "-" : "+",
				type_name(operand),
			)
			v.type = .Invalid
			return v.type
		}
		v.type = operand
		if is_const_expr(v.operand) {
			v.is_const = true
			v.const_value = v.op == .Minus ? -const_value_of(v.operand) : const_value_of(v.operand)
		}
		return v.type

	case ^Expr_Binary:
		lhs := check_expr(k, v.lhs)
		rhs := check_expr(k, v.rhs)
		if lhs == .Invalid || rhs == .Invalid {
			v.type = .Invalid
			return v.type
		}
		if !is_numeric(lhs) || !is_numeric(rhs) {
			errorf(
				k.c,
				v.op_span,
				"L0318",
				"`%s` does not apply to `%s` and `%s`",
				operator_text(v.op),
				type_name(lhs),
				type_name(rhs),
			)
			v.type = .Invalid
			return v.type
		}
		if v.op == .Shl || v.op == .Shr {
			if rhs != .Untyped_Int || !is_const_expr(v.rhs) || const_value_of(v.rhs) < 0 {
				errorf(
					k.c,
					v.op_span,
					"L0326",
					"the M0 shift count must be a non-negative untyped constant",
				)
				v.type = .Invalid
				return v.type
			}
		}
		// One untyped operand takes the other's type; two stay untyped.
		v.type = (lhs == .Untyped_Int && rhs == .Untyped_Int) ? .Untyped_Int : .Int

		if is_const_expr(v.lhs) && is_const_expr(v.rhs) {
			a, b := const_value_of(v.lhs), const_value_of(v.rhs)
			if (v.op == .Slash || v.op == .Percent) && b == 0 {
				errorf(k.c, v.op_span, "L0319", "division by zero")
				v.type = .Invalid
				return v.type
			}
			v.is_const = true
			v.const_value = fold(v.op, a, b)
		}
		return v.type

	case ^Expr_Call:
		callee, is_ident := v.callee.(^Expr_Ident)
		if !is_ident {
			errorf(k.c, expr_span(v.callee), "L0320", "this expression is not callable")
			v.type = .Invalid
			return v.type
		}
		sym := lookup(k.scope, callee.name)
		if sym == nil {
			errorf(k.c, callee.span, "L0315", "unknown name `%s`", callee.name)
			v.type = .Invalid
			return v.type
		}
		callee.symbol = sym
		if sym.kind != .Proc && sym.kind != .Builtin {
			errorf(k.c, callee.span, "L0321", "`%s` is not a procedure", callee.name)
			v.type = .Invalid
			return v.type
		}

		if len(v.args) != len(sym.params) {
			errorf(
				k.c,
				v.span,
				"L0322",
				"`%s` takes %d argument%s, found %d",
				callee.name,
				len(sym.params),
				len(sym.params) == 1 ? "" : "s",
				len(v.args),
			)
		}
		for arg, i in v.args {
			type := check_expr(k, arg)
			if i < len(sym.params) && type != .Invalid && !assignable(type, sym.params[i]) {
				errorf(
					k.c,
					expr_span(arg),
					"L0323",
					"expected `%s`, found `%s`",
					type_name(sym.params[i]),
					type_name(type),
				)
			}
		}
		v.type = sym.type
		return v.type
	}
	return .Invalid
}

@(private = "file")
fold :: proc(op: Token_Kind, a: i64, b: i64) -> i64 {
	#partial switch op {
	case .Plus:
		return a + b
	case .Minus:
		return a - b
	case .Star:
		return a * b
	case .Slash:
		if a == min(i64) && b == -1 {
			return min(i64)
		}
		return a / b
	case .Percent:
		if a == min(i64) && b == -1 {
			return 0
		}
		return a % b
	case .Amp:
		return a & b
	case .Pipe:
		return a | b
	case .Tilde:
		return a ~ b
	case .Amp_Tilde:
		return a &~ b
	case .Shl:
		if b >= 64 {
			return 0
		}
		return a << u64(b)
	case .Shr:
		if b >= 64 {
			return a < 0 ? -1 : 0
		}
		return a >> u64(b)
	}
	return 0
}

operator_text :: proc(op: Token_Kind) -> string {
	#partial switch op {
	case .Plus:
		return "+"
	case .Minus:
		return "-"
	case .Star:
		return "*"
	case .Slash:
		return "/"
	case .Percent:
		return "%"
	case .Amp:
		return "&"
	case .Pipe:
		return "|"
	case .Tilde:
		return "~"
	case .Amp_Tilde:
		return "&~"
	case .Shl:
		return "<<"
	case .Shr:
		return ">>"
	}
	return "?"
}
