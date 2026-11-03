// Named constants that need an address share one read-only global per resolved
// symbol, and an untyped constant one per type it takes at a use. Generic
// specializations have distinct symbols and globals.
package lokec

import "core:fmt"

// `type` is set only for an untyped constant.
Materialized_Key :: struct {
	symbol: Symbol_Id,
	type:   Type_Id,
}

Materialized :: struct {
	key:    Materialized_Key,
	type:   Type_Id,
	value:  Const_Value,
	name:   string,
}

// The symbol directly named by a constant expression.
@(private = "file")
constant_symbol_of :: proc(c: ^Compiler, e: Expr) -> Symbol_Id {
	base := expr_base(e)
	if base == nil || !base.is_const {
		return INVALID_SYMBOL
	}
	id := INVALID_SYMBOL
	#partial switch v in e {
	case ^Expr_Ident:
		id = v.resolution.symbol
	case ^Expr_Selector:
		id = v.resolution.symbol
	}
	sym := symbol_of(c, id)
	return sym != nil && (sym.kind == .Const || sym.kind == .Enum_Member) ? id : INVALID_SYMBOL
}

// The named constant at the root of a selector or index chain.
@(private = "file")
constant_root_of :: proc(c: ^Compiler, e: Expr) -> (Expr, Symbol_Id) {
	if symbol := constant_symbol_of(c, e); symbol != INVALID_SYMBOL {
		return e, symbol
	}
	#partial switch v in e {
	case ^Expr_Selector:
		return constant_root_of(c, v.operand)
	case ^Expr_Index:
		return constant_root_of(c, v.operand)
	}
	return nil, INVALID_SYMBOL
}

@(private = "file")
materialized_key :: proc(c: ^Compiler, symbol: Symbol_Id, e: Expr) -> Materialized_Key {
	key := Materialized_Key{symbol = symbol}
	if type_is_untyped(c, symbol_of(c, symbol).type) {
		key.type = expr_base(e).type
	}
	return key
}

// Registers the shared global for a place rooted in a named constant.
request_materialization :: proc(k: ^Checker, e: Expr) -> bool {
	root, symbol := constant_root_of(k.c, e)
	if symbol == INVALID_SYMBOL {
		return false
	}
	base := expr_base(root)
	if base.type == TYPE_UNTYPED_NIL {
		return false
	}
	if !committing(k.c) {
		return true
	}
	key := materialized_key(k.c, symbol, root)
	if key in k.c.materialized {
		return true
	}
	// design.md "Materialization": the storage is read-only, and a synchronized
	// field changes through a `^`, so one there would fault on its first write.
	if field := synchronized_field_within(k.c, base.type); field != nil {
		errorf(
			k.c, expr_span(e), "L0705",
			"`%s` holds the synchronized field `%s`, which changes through a `^`, so this constant cannot be borrowed from read-only storage; declare it as a variable",
			type_name(k.c, base.type), identifier_text(k.c, field.name),
		)
		return true
	}
	entry := new(Materialized, k.c.semantic_allocator)
	entry.key = key
	entry.type = base.type
	entry.value = base.const_value
	entry.name = fmt.aprintf(
		"@.const.%s.%d", identifier_text(k.c, symbol_of(k.c, symbol).name), len(k.c.materialized_order),
		allocator = k.c.semantic_allocator,
	)
	k.c.materialized[key] = entry
	append(&k.c.materialized_order, entry)
	return true
}

materialization_of :: proc(c: ^Compiler, e: Expr) -> ^Materialized {
	symbol := constant_symbol_of(c, e)
	if symbol == INVALID_SYMBOL {
		return nil
	}
	return c.materialized[materialized_key(c, symbol, e)]
}

// A `@(synchronized)` field that a value of `type` holds inline, such as an
// `Atomic`'s `value`: what synchronizing operations write through a read-only
// `^`.
@(private = "file")
synchronized_field_within :: proc(c: ^Compiler, type: Type_Id) -> ^Symbol {
	seen := make(map[Type_Id]bool, context.temp_allocator)
	return synchronized_field_walk(c, type, &seen)
}

@(private = "file")
synchronized_field_walk :: proc(c: ^Compiler, type: Type_Id, seen: ^map[Type_Id]bool) -> ^Symbol {
	if type == INVALID_TYPE || seen[type] {
		return nil
	}
	seen[type] = true
	info := type_of(c, type)
	if info == nil {
		return nil
	}
	#partial switch info.kind {
	case .Distinct, .Array:
		return synchronized_field_walk(c, info.element, seen)
	case .Union:
		for variant in info.variants {
			if found := synchronized_field_walk(c, variant, seen); found != nil {
				return found
			}
		}
	case .Struct:
		for field in info.fields {
			sym := symbol_of(c, field)
			if sym == nil {
				continue
			}
			if sym.synchronized {
				return sym
			}
			if found := synchronized_field_walk(c, sym.type, seen); found != nil {
				return found
			}
		}
	}
	return nil
}
