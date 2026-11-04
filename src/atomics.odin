// Atomic intrinsics (design.md "Concurrency and the memory model"). `core:sync`
// wraps them; each takes a constant ordering, which the wrappers forward through
// `$` parameters.
package lokec

// The orderings in the order `base:runtime.Memory_Order` declares them.
Memory_Order :: enum {
	Relaxed,
	Acquire,
	Release,
	Acquire_Release,
	Sequentially_Consistent,
}

// The width one operation runs at, in bits, or 0 for a type that is not atomic.
// A `bool` is one byte of storage. No floats: an atomic float would promise
// arithmetic it lacks.
atomic_width_bits :: proc(c: ^Compiler, type: Type_Id) -> int {
	#partial switch underlying_kind(c, type) {
	case .Bool:
		return 8
	case .Rune:
		return 32
	case .Pointer, .C_Pointer, .Raw_Pointer:
		return int(c.target.pointer_bits)
	case .Union:
		return atomic_option_of_pointer(c, type) ? int(c.target.pointer_bits) : 0
	case .Int, .Enum:
		bits := type_bits(c, type)
		switch bits {
		case 8, 16, 32, 64, 128:
			return bits
		}
	}
	return 0
}

// design.md "Concurrency and the memory model": a one-word `Option` of a
// pointer, whose `.none` is the null address.
@(private = "file")
atomic_option_of_pointer :: proc(c: ^Compiler, type: Type_Id) -> bool {
	some := union_niche_variant(c, type)
	return underlying_info(c, type).instance_of == c.option_symbol &&
	       some >= 0 && underlying_kind(c, union_variant_payload(c, type, some)) == .Pointer
}

// Read-modify-write arithmetic is integers only; an enum has no arithmetic.
@(private = "file")
atomic_operation_supported :: proc(c: ^Compiler, kind: Builtin_Kind, type: Type_Id) -> bool {
	#partial switch kind {
	case .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor:
		return underlying_kind(c, type) == .Int
	}
	return true
}

// A load (and a failed compare-exchange, which writes nothing) cannot release; a
// store cannot acquire; a relaxed fence orders nothing.
@(private = "file")
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

// Past the arity check, each operand and ordering reports its own error.
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
	if !builtin_argument_count_ok(k, v, ident.name, "L0661", wanted) {
		return
	}

	ok := builtin_arguments_ok(k, v)
	element := INVALID_TYPE
	bound := make([]Expr, operands, k.c.semantic_allocator)
	if operands > 0 {
		bound[0] = v.args[0].value
		element = check_atomic_place(k, v, ident, kind)
		ok = ok && element != INVALID_TYPE
	}
	for index in 1 ..< operands {
		bound[index] = v.args[index].value
		ok = check_value_expr(k, bound[index], element, "pass") && ok
	}

	order, order_ok := check_atomic_order(k, v.args[operands].value, order_type, kind, false)
	operation := Call_Atomic{type = element, order = order}
	ok = ok && order_ok
	if kind == .Atomic_Compare_Exchange {
		failure, failure_ok := check_atomic_order(k, v.args[operands + 1].value, order_type, kind, true)
		operation.failure_order = failure
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

// The address operand. A read-only `^` may write: atomic accesses do not conflict
// (design.md "Concurrency and the memory model"), which lets `Atomic(T)` work
// behind a `Shared(T)`.
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
	if atomic_width_bits(k.c, info.element) == 0 {
		errorf(
			k.c, expr_span(argument), "L0662",
			"`%s` is not an atomic type: the set is `bool`, the integer and rune types, an enum over one, any pointer, and an `Option` of a `^T`",
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
	if !is_const_expr(argument) {
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
