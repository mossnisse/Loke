// Constant materialization (m5a-plan step 2).
//
// design.md "Materialization": a constant is a value, not a variable, and an
// ordinary use is substituted with no storage involved. Three uses need storage
// anyway — indexing by a non-constant index, a slice expression, and `&C` —
// and **all uses of that constant share one backing object**.
//
// That object is read-only. Assigning through it is rejected and a slice of it
// is `[]T` and never `[]mut T`. `&C`, `&C[i]`, and `&C.field` are permitted and
// yield a `^T`; `&mut` of any of them is not, which is what keeps a writable
// pointer out of read-only storage.
//
// Identity is the resolved constant symbol. M4b clones each generic declaration
// before checking it, so two specializations already hold two symbols and get
// two globals, while every use of one concrete constant shares one.
package lokec

import "core:fmt"

Materialized :: struct {
	symbol: Symbol_Id,
	type:   Type_Id,
	value:  Const_Value,
	// The backend spelling, assigned when the global is registered so the use
	// site and the definition cannot disagree.
	name:   string,
}

// The constant symbol an expression denotes, or INVALID_SYMBOL when it is not a
// named constant. Only a named constant is materialised: an inline composite
// literal is already addressable temporary storage and needs no shared object.
constant_symbol_of :: proc(c: ^Compiler, e: Expr) -> Symbol_Id {
	base := expr_base(e)
	if base == nil || !base.is_const {
		return INVALID_SYMBOL
	}
	#partial switch v in e {
	case ^Expr_Ident:
		return constant_symbol(c, v.resolution.symbol)
	case ^Expr_Selector:
		return constant_symbol(c, v.resolution.symbol)
	}
	return INVALID_SYMBOL
}

// The named constant a place expression is rooted in, and the sub-expression
// that names it. `&C`, `&C[i]`, and `&C.field` all root in `C`, and one shared
// object serves all three; anything else roots in ordinary storage and returns
// INVALID_SYMBOL.
constant_root_of :: proc(c: ^Compiler, e: Expr) -> (Expr, Symbol_Id) {
	current := e
	for current != nil {
		if symbol := constant_symbol_of(c, current); symbol != INVALID_SYMBOL {
			return current, symbol
		}
		#partial switch v in current {
		case ^Expr_Selector:
			current = v.operand
		case ^Expr_Index:
			current = v.operand
		case:
			return nil, INVALID_SYMBOL
		}
	}
	return nil, INVALID_SYMBOL
}

@(private = "file")
constant_symbol :: proc(c: ^Compiler, id: Symbol_Id) -> Symbol_Id {
	sym := symbol_of(c, id)
	if sym == nil || sym.kind != .Const {
		return INVALID_SYMBOL
	}
	return id
}

// Registers the one read-only global this constant's runtime uses share. Safe to
// call from every such use; the first call decides the object.
//
// Returns false when the expression is not a named constant, in which case the
// caller keeps its ordinary temporary-storage behavior.
request_materialization :: proc(k: ^Checker, e: Expr) -> bool {
	symbol := constant_symbol_of(k.c, e)
	if symbol == INVALID_SYMBOL {
		return false
	}
	if k.c.speculation_depth > 0 {
		// The hypothetical expression still type-checks as a named constant, but
		// an accepted, non-speculative use is what gives it module storage.
		return true
	}
	if _, found := k.c.materialized[symbol]; found {
		return true
	}
	base := expr_base(e)
	sym := symbol_of(k.c, symbol)
	entry := new(Materialized, k.c.semantic_allocator)
	entry.symbol = symbol
	entry.type = base.type
	entry.value = base.const_value
	entry.name = materialized_global_name(k.c, sym, len(k.c.materialized_order))
	k.c.materialized[symbol] = entry
	append(&k.c.materialized_order, entry)
	return true
}

// Already registered, or nil. The backend asks this rather than re-deciding
// which uses needed storage.
materialization_of :: proc(c: ^Compiler, e: Expr) -> ^Materialized {
	symbol := constant_symbol_of(c, e)
	if symbol == INVALID_SYMBOL {
		return nil
	}
	entry, found := c.materialized[symbol]
	return found ? entry : nil
}

@(private = "file")
materialized_global_name :: proc(c: ^Compiler, sym: ^Symbol, index: int) -> string {
	text := "const"
	if sym != nil && sym.name != INVALID_IDENTIFIER {
		text = identifier_text(c, sym.name)
	}
	// The index keeps two same-named constants in different packages or generic
	// instances apart without depending on a mangling scheme.
	return fmt.aprintf("@.const.%s.%d", text, index, allocator = c.semantic_allocator)
}
