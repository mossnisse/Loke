// Atomic intrinsics (design.md "Concurrency and the memory model"). `core:sync`
// wraps them; each takes a constant ordering, which the wrappers forward through
// `$` parameters.
package lokec

import "core:fmt"

// The orderings in the order `base:runtime.Memory_Order` declares them.
Memory_Order :: enum {
	Relaxed,
	Acquire,
	Release,
	Acquire_Release,
	Sequentially_Consistent,
}

// `base:runtime.Memory_Order`, found by name and cached. INVALID_TYPE when it is
// missing or its members differ from the compiler's copy above.
memory_order_type :: proc(k: ^Checker) -> Type_Id {
	if k.c.memory_order_type != INVALID_TYPE {
		return k.c.memory_order_type
	}
	for index in 1 ..< len(k.c.packages) {
		pkg := &k.c.packages[index]
		if pkg.key != STD_RUNTIME || pkg.scope == nil {
			continue
		}
		symbol_id := pkg.scope.names[intern_identifier(k.c, "Memory_Order")] or_else INVALID_SYMBOL
		if sym := symbol_of(k.c, symbol_id); sym != nil && sym.kind == .Type {
			resolve_symbol_signature_in_place(k, symbol_id)
			type := symbol_of(k.c, symbol_id).type
			if !memory_order_matches(k.c, type) {
				return INVALID_TYPE
			}
			k.c.memory_order_type = type
			return type
		}
	}
	return INVALID_TYPE
}

@(private = "file")
memory_order_matches :: proc(c: ^Compiler, type: Type_Id) -> bool {
	info := type_of(c, type)
	if info == nil || info.kind != .Enum || len(info.fields) != len(Memory_Order) {
		return false
	}
	for member, index in info.fields {
		sym := symbol_of(c, member)
		value, fits := bi_to_i64(c, sym.const_value.integer)
		if sym.name != intern_identifier(c, fmt.tprint(Memory_Order(index))) || !fits || value != i64(index) {
			return false
		}
	}
	return true
}

// `bool`, the integer and rune types, an enum over a supported integer, and every
// pointer. No floats: an atomic float would promise arithmetic it lacks.
atomic_type_supported :: proc(c: ^Compiler, type: Type_Id) -> bool {
	info := underlying_info(c, type)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Bool, .Rune, .Pointer, .C_Pointer, .Raw_Pointer:
		return true
	case .Int, .Enum:
		return atomic_width_bits(c, type) != 0
	}
	return false
}

// The width one operation runs at, in bits, or 0 for a type with none. A `bool`
// is one byte of storage.
atomic_width_bits :: proc(c: ^Compiler, type: Type_Id) -> int {
	info := underlying_info(c, type)
	if info == nil {
		return 0
	}
	#partial switch info.kind {
	case .Bool:
		return 8
	case .Rune:
		return 32
	case .Pointer, .C_Pointer, .Raw_Pointer:
		return int(c.target.pointer_bits)
	case .Int, .Enum:
		bits := type_bits(c, type_underlying(c, type))
		switch bits {
		case 8, 16, 32, 64, 128:
			return bits
		}
	}
	return 0
}

// Read-modify-write arithmetic is integers only; an enum has no arithmetic.
atomic_operation_supported :: proc(c: ^Compiler, kind: Builtin_Kind, type: Type_Id) -> bool {
	#partial switch kind {
	case .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor:
		info := underlying_info(c, type)
		return info != nil && info.kind == .Int
	}
	return true
}

// A load (and a failed compare-exchange, which writes nothing) cannot release; a
// store cannot acquire; a relaxed fence orders nothing.
atomic_order_permitted :: proc(kind: Builtin_Kind, order: Memory_Order, failure: bool) -> bool {
	if failure || kind == .Atomic_Load {
		return order == .Relaxed || order == .Acquire || order == .Sequentially_Consistent
	}
	#partial switch kind {
	case .Atomic_Store:
		return order == .Relaxed || order == .Release || order == .Sequentially_Consistent
	case .Atomic_Fence:
		return order != .Relaxed
	}
	return true
}

// --------------------------------------------------------------- checking --

// Every argument is checked even after one fails, so each reports its own error.
check_atomic_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	v.value_category = .Value
	v.type = INVALID_TYPE
	order_type := memory_order_type(k)
	if order_type == INVALID_TYPE {
		errorf(k.c, v.span, "L0661", "`base:runtime` does not declare the `Memory_Order` the compiler expects")
		return
	}

	// The place and values come first, then one ordering (two for a compare-exchange).
	operands, orders := 2, 1
	#partial switch kind {
	case .Atomic_Fence:            operands = 0
	case .Atomic_Load:             operands = 1
	case .Atomic_Compare_Exchange: operands, orders = 3, 2
	}
	wanted := operands + orders
	if len(v.args) != wanted {
		errorf(
			k.c, v.span, "L0661",
			"`%s` takes %d argument%s, found %d",
			ident.name, wanted, wanted == 1 ? "" : "s", len(v.args),
		)
		return
	}

	ok := true
	for arg in v.args {
		if arg.name.text != "" || arg.mode != .Value {
			reject_builtin_argument_shape(k, arg)
			ok = false
		}
	}

	element := INVALID_TYPE
	if operands > 0 {
		element = check_atomic_place(k, v, ident, kind)
		ok = ok && element != INVALID_TYPE
	}
	bound := make([]Expr, operands, k.c.semantic_allocator)
	for index in 0 ..< operands {
		argument := v.args[index].value
		bound[index] = argument
		if index == 0 {
			continue
		}
		if element == INVALID_TYPE {
			check_single_expr(k, argument)
			continue
		}
		value, passed := check_argument_value(k, argument, element)
		bound[index] = value
		ok = ok && passed
	}

	order, order_ok := check_atomic_order(k, v.args[operands].value, order_type, kind, false)
	operation := Call_Atomic{type = element, order = int(order)}
	ok = ok && order_ok
	if kind == .Atomic_Compare_Exchange {
		failure, failure_ok := check_atomic_order(k, v.args[operands + 1].value, order_type, kind, true)
		operation.failure_order = int(failure)
		ok = ok && failure_ok
	}
	if !ok {
		return
	}

	v.bound = bound
	v.operation = operation
	#partial switch kind {
	case .Atomic_Store, .Atomic_Fence:
		v.type = TYPE_VOID
	case .Atomic_Compare_Exchange:
		// `.none` when it swapped, `.some(observed)` when it did not.
		v.type = option_type(k, element)
	case:
		v.type = element
	}
}

// The address operand: a pointer to a supported type, `^mut` unless the
// operation only loads. Returns the pointee, or INVALID_TYPE after an error.
@(private = "file")
check_atomic_place :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) -> Type_Id {
	argument := v.args[0].value
	address := check_single_expr(k, argument)
	if address == INVALID_TYPE {
		return INVALID_TYPE
	}
	info := underlying_info(k.c, address)
	if info == nil || info.kind != .Pointer {
		errorf(
			k.c, expr_span(argument), "L0661",
			"`%s` takes the address of the atomic place, found `%s`",
			ident.name, type_name(k.c, address),
		)
		return INVALID_TYPE
	}
	if kind != .Atomic_Load && !info.mutable {
		errorf(
			k.c, expr_span(argument), "L0661",
			"`%s` writes through its operand, so it needs a `^mut` pointer, found `%s`",
			ident.name, type_name(k.c, address),
		)
		return INVALID_TYPE
	}
	if !atomic_type_supported(k.c, info.element) {
		errorf(
			k.c, expr_span(argument), "L0662",
			"`%s` is not an atomic type: the set is `bool`, the integer and rune types, an enum over one, and any pointer",
			type_name(k.c, info.element),
		)
		return INVALID_TYPE
	}
	if !atomic_operation_supported(k.c, kind, info.element) {
		errorf(
			k.c, v.span, "L0663",
			"`%s` is arithmetic, which `%s` does not have; it has load, store, exchange, and compare-exchange",
			ident.name, type_name(k.c, info.element),
		)
		return INVALID_TYPE
	}
	return info.element
}

// One ordering argument: a constant `Memory_Order` this operation permits. Only
// `base:runtime` and `core:sync` reach an intrinsic, so a non-constant here is a
// stdlib author's mistake.
@(private = "file")
check_atomic_order :: proc(
	k: ^Checker,
	argument: Expr,
	order_type: Type_Id,
	kind: Builtin_Kind,
	failure: bool,
) -> (Memory_Order, bool) {
	if !check_value_expr(k, argument, order_type, "pass") {
		return .Relaxed, false
	}
	if !expr_base(argument).is_const {
		errorf(
			k.c, expr_span(argument), "L0666",
			"an atomic ordering must be a constant; a `$` parameter is what keeps one constant across a wrapper",
		)
		return .Relaxed, false
	}
	folded, evaluated := require_const(k, argument, "an atomic ordering", "L0666")
	if !evaluated {
		return .Relaxed, false
	}
	raw, fits := bi_to_i64(k.c, folded.integer)
	if folded.kind != .Integer || !fits || raw < 0 || raw > i64(max(Memory_Order)) {
		errorf(k.c, expr_span(argument), "L0666", "this value names no `Memory_Order` member")
		return .Relaxed, false
	}
	order := Memory_Order(raw)
	if !atomic_order_permitted(kind, order, failure) {
		if kind == .Atomic_Fence {
			errorf(
				k.c, expr_span(argument), "L0665",
				"a relaxed fence orders nothing; `fence` needs at least `.Acquire`",
			)
		} else {
			errorf(
				k.c, expr_span(argument), "L0664",
				"%s does not permit the ordering `%v`",
				failure ? "the failure path of a compare-exchange" : "this operation",
				order,
			)
		}
		return order, false
	}
	return order, true
}
