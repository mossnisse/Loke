// Atomic intrinsics (design.md "Concurrency and the memory model").
//
// `Atomic(T)` is a `core:sync` wrapper over these, which is design.md's own
// split: the library owns the surface, and the compiler owns the one thing a
// library cannot express — an operation whose ordering is part of the
// instruction rather than an argument to it.
//
// So each intrinsic requires a *constant* ordering. A constant at the user's
// call site does not make an ordinary wrapper parameter constant inside the
// wrapper's body, which is why the public wrappers take their ordering through
// `$` parameters and forward it here unchanged.
package lokec

// The ordering enum, declared as ordinary source in `base:runtime` and found by
// name. Cached because the lookup walks the package list and every atomic
// argument is compared against it.
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
			k.c.memory_order_type = symbol_of(k.c, symbol_id).type
			return k.c.memory_order_type
		}
	}
	return INVALID_TYPE
}

// The five orderings, in strength order, matching `runtime.Memory_Order`.
Memory_Order :: enum {
	Relaxed,
	Acquire,
	Release,
	Acquire_Release,
	Sequentially_Consistent,
}

memory_order_name :: proc(order: Memory_Order) -> string {
	switch order {
	case .Relaxed:                 return "Relaxed"
	case .Acquire:                 return "Acquire"
	case .Release:                 return "Release"
	case .Acquire_Release:         return "Acquire_Release"
	case .Sequentially_Consistent: return "Sequentially_Consistent"
	}
	return "?"
}

// design.md permits a lock where the target has no lock-free operation, so the
// supported *type* set and the lowering are two separate questions. This is the
// first: `bool`, the integer and rune types, an enum over a supported integer,
// and every pointer.
//
// Floats are deliberately absent. An atomic float is a bit-pattern operation,
// and `Atomic(f64)` would promise arithmetic that is not provided.
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

// The width one operation runs at, in bits, or 0 for a type with no atomic
// width. A `bool` is one byte of storage whatever `i1` means in a register.
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
		return 64
	case .Int, .Enum:
		bits := type_bits(c, type_underlying(c, type))
		switch bits {
		case 8, 16, 32, 64, 128:
			return bits
		}
	}
	return 0
}

// Read-modify-write arithmetic is integers only. design.md: enum members are
// named constants, not numbers with a name, and arithmetic on them is not
// defined — so an enum gets load, store, exchange, and compare-exchange, and no
// `add`.
atomic_operation_supported :: proc(c: ^Compiler, kind: Builtin_Kind, type: Type_Id) -> bool {
	#partial switch kind {
	case .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor:
		info := underlying_info(c, type)
		return info != nil && info.kind == .Int
	}
	return true
}

// Which orderings each operation accepts. A load cannot release what it did not
// write, and a store cannot acquire what it did not read; both are rejected
// rather than silently strengthened.
atomic_order_permitted :: proc(kind: Builtin_Kind, order: Memory_Order, failure: bool) -> bool {
	if failure {
		// A compare-exchange that fails performs no write, so its ordering is a
		// load's.
		return order == .Relaxed || order == .Acquire || order == .Sequentially_Consistent
	}
	#partial switch kind {
	case .Atomic_Load:
		return order == .Relaxed || order == .Acquire || order == .Sequentially_Consistent
	case .Atomic_Store:
		return order == .Relaxed || order == .Release || order == .Sequentially_Consistent
	case .Atomic_Fence:
		// design.md: a fence orders the operations around it, and a relaxed one
		// orders nothing at all. It is a mistake rather than a no-op.
		return order != .Relaxed
	}
	return true
}

// --------------------------------------------------------------- checking --

check_atomic_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	v.value_category = .Value
	order_type := memory_order_type(k)
	if order_type == INVALID_TYPE {
		errorf(k.c, v.span, "L0661", "`base:runtime` does not declare `Memory_Order`")
		v.type = INVALID_TYPE
		return
	}

	if kind == .Atomic_Fence {
		if !check_atomic_arity(k, v, ident, 1) {
			return
		}
		order, order_ok := check_atomic_order(k, v, 0, order_type, kind, false)
		if !order_ok {
			v.type = INVALID_TYPE
			return
		}
		v.atomic_order = int(order)
		v.bound = nil
		v.type = TYPE_VOID
		return
	}

	wanted := 3
	#partial switch kind {
	case .Atomic_Load:             wanted = 2
	case .Atomic_Compare_Exchange: wanted = 5
	}
	if !check_atomic_arity(k, v, ident, wanted) {
		return
	}

	// The operand is the address of the atomic place. A load may read through a
	// read-only pointer; every other operation writes.
	address := check_single_expr(k, v.args[0].value)
	if address == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	info := underlying_info(k.c, address)
	if info == nil || info.kind != .Pointer {
		errorf(
			k.c, expr_span(v.args[0].value), "L0661",
			"`%s` takes the address of the atomic place, found `%s`",
			ident.name, type_name(k.c, address),
		)
		v.type = INVALID_TYPE
		return
	}
	if kind != .Atomic_Load && !info.mutable {
		errorf(
			k.c, expr_span(v.args[0].value), "L0661",
			"`%s` writes through its operand, so it needs a `^mut` pointer, found `%s`",
			ident.name, type_name(k.c, address),
		)
		v.type = INVALID_TYPE
		return
	}
	element := info.element
	if !atomic_type_supported(k.c, element) {
		errorf(
			k.c, expr_span(v.args[0].value), "L0662",
			"`%s` is not an atomic type: the set is `bool`, the integer and rune types, an enum over one, and any pointer",
			type_name(k.c, element),
		)
		v.type = INVALID_TYPE
		return
	}
	if !atomic_operation_supported(k.c, kind, element) {
		errorf(
			k.c, v.span, "L0663",
			"`%s` is arithmetic, which `%s` does not have; it has load, store, exchange, and compare-exchange",
			ident.name, type_name(k.c, element),
		)
		v.type = INVALID_TYPE
		return
	}

	values := 1
	#partial switch kind {
	case .Atomic_Load:             values = 0
	case .Atomic_Compare_Exchange: values = 2
	}
	bound := make([]Expr, 1 + values, k.c.semantic_allocator)
	bound[0] = v.args[0].value
	for index in 0 ..< values {
		value, passed := check_argument_value(k, v.args[index + 1].value, element)
		bound[index + 1] = value
		if !passed {
			v.type = INVALID_TYPE
			return
		}
	}

	order, order_ok := check_atomic_order(k, v, 1 + values, order_type, kind, false)
	if !order_ok {
		v.type = INVALID_TYPE
		return
	}
	v.atomic_order = int(order)
	if kind == .Atomic_Compare_Exchange {
		failure, failure_ok := check_atomic_order(k, v, 2 + values, order_type, kind, true)
		if !failure_ok {
			v.type = INVALID_TYPE
			return
		}
		v.atomic_failure_order = int(failure)
	}

	v.bound = bound
	v.atomic_type = element
	#partial switch kind {
	case .Atomic_Store:
		v.type = TYPE_VOID
	case .Atomic_Compare_Exchange:
		// `.none` means the swap happened; `.some(observed)` is what was found
		// instead. One shape, and no path on which a caller can read an observed
		// value that does not exist.
		v.type = option_type(k, element)
	case:
		v.type = element
	}
}

@(private = "file")
check_atomic_arity :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, wanted: int) -> bool {
	if len(v.args) == wanted {
		return true
	}
	errorf(
		k.c, v.span, "L0661",
		"`%s` takes %d argument%s, found %d",
		ident.name, wanted, wanted == 1 ? "" : "s", len(v.args),
	)
	v.type = INVALID_TYPE
	return false
}

// One ordering argument: a constant of the ordering enum, and one this
// operation permits.
@(private = "file")
check_atomic_order :: proc(
	k: ^Checker,
	v: ^Expr_Call,
	index: int,
	order_type: Type_Id,
	kind: Builtin_Kind,
	failure: bool,
) -> (Memory_Order, bool) {
	argument := v.args[index].value
	if !check_value_expr(k, argument, order_type, "pass") {
		return .Relaxed, false
	}
	base := expr_base(argument)
	if !base.is_const {
		errorf(
			k.c, expr_span(argument), "L0666",
			"an atomic ordering must be a constant; a `$` parameter is what keeps one constant across a wrapper",
		)
		return .Relaxed, false
	}
	folded, evaluated := require_const(k, argument, "an atomic ordering", "L0666")
	if !evaluated || folded.kind != .Integer {
		return .Relaxed, false
	}
	raw, fits := bi_to_i64(k.c, folded.integer)
	if !fits || raw < 0 || raw > i64(max(Memory_Order)) {
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
			return order, false
		}
		errorf(
			k.c, expr_span(argument), "L0664",
			"%s does not permit the ordering `%s`",
			failure ? "the failure path of a compare-exchange" : "this operation",
			memory_order_name(order),
		)
		return order, false
	}
	return order, true
}
