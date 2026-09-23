// Named constants that need an address share one read-only global per resolved
// symbol. Generic specializations have distinct symbols and globals.
package lokec

import "core:fmt"

Materialized :: struct {
	symbol: Symbol_Id,
	type:   Type_Id,
	value:  Const_Value,
	name:   string,
}

// The symbol directly named by a constant expression.
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

// The named constant at the root of a selector or index chain.
@(private = "file")
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

// Registers the shared global for a place rooted in a named constant.
request_materialization :: proc(k: ^Checker, e: Expr) -> bool {
	root, symbol := constant_root_of(k.c, e)
	if symbol == INVALID_SYMBOL {
		return false
	}
	if k.c.speculation_depth > 0 {
		return true
	}
	if _, found := k.c.materialized[symbol]; found {
		return true
	}
	base := expr_base(root)
	// design.md "Materialization": the storage is read-only, and an atomic's
	// operations write through a `^`, so one there would fault on its first write.
	if type_holds_atomic(k.c, base.type) {
		errorf(
			k.c, expr_span(e), "L0705",
			"`%s` is or holds a `sync.Atomic`, which changes through a `^`, so this constant cannot be borrowed from read-only storage; declare a variable or `static` storage instead",
			type_name(k.c, base.type),
		)
		return true
	}
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
	return fmt.aprintf("@.const.%s.%d", text, index, allocator = c.semantic_allocator)
}

// Whether a value of `type` holds a `core:sync` `Atomic` inline: the one leaf
// whose operations write through a read-only `^`.
type_holds_atomic :: proc(c: ^Compiler, type: Type_Id) -> bool {
	seen := make(map[Type_Id]bool, context.temp_allocator)
	return type_holds_atomic_walk(c, type, &seen)
}

@(private = "file")
type_holds_atomic_walk :: proc(c: ^Compiler, type: Type_Id, seen: ^map[Type_Id]bool) -> bool {
	if type == INVALID_TYPE || seen[type] {
		return false
	}
	seen[type] = true
	info := type_of(c, type)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Distinct, .Array:
		return type_holds_atomic_walk(c, info.element, seen)
	case .Union:
		for variant in info.variants {
			if type_holds_atomic_walk(c, variant, seen) {
				return true
			}
		}
	case .Struct:
		if template := symbol_of(c, info.instance_of); template != nil {
			pkg := package_of(c, template.pkg)
			if pkg != nil && pkg.key == STD_SYNC && identifier_text(c, template.name) == "Atomic" {
				return true
			}
		}
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil && type_holds_atomic_walk(c, sym.type, seen) {
				return true
			}
		}
	}
	return false
}
