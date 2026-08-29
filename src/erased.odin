// Erased views: `any_view` and `dyn Interface`.
//
// Both are two-word non-owning views, and both are compiler-owned struct types
// so they reuse the existing layout, parameter-passing, and emission paths:
//
//   any_view       { ptr data, typeid id }
//   dyn Interface  { ptr data, ptr witness }
//
// `any_view`'s position rules are enforced on the *resolved* type rather than on
// the written syntax, so an alias or a generic substitution cannot smuggle one
// into a field, a result, or a global.
//
// A witness is a mechanism, not a value: one immutable private global per
// `(Interface, Concrete, arguments)`, named from those parts, whose slot
// selection always uses inherent members plus extensions in the slot's declaring
// interface package. The key is compilation-global, so its lookup policy must be
// too — otherwise the same key could denote different behavior in two packages.
package lokec

import "core:fmt"
import "core:strings"

ANY_VIEW_DATA :: 0
ANY_VIEW_ID :: 1

DYN_DATA :: 0
DYN_WITNESS :: 1

// ----------------------------------------------------------- any_view --

// `any_view` is predeclared, so its two members are installed on first use
// rather than in the predeclared table, which runs before any symbol exists.
ensure_any_view_fields :: proc(c: ^Compiler) {
	info := type_of(c, TYPE_ANY_VIEW)
	if info == nil || len(info.fields) > 0 {
		return
	}
	fields := make([]Symbol_Id, 2, c.semantic_allocator)
	fields[ANY_VIEW_DATA] = new_field(c, "data", TYPE_RAWPTR, ANY_VIEW_DATA)
	fields[ANY_VIEW_ID] = new_field(c, "id", TYPE_TYPEID, ANY_VIEW_ID)
	info = type_of(c, TYPE_ANY_VIEW)
	info.fields = fields
	info.mangled = "any_view"
}

// design.md: `any_view` may be a local variable or parameter, but not a result
// type, global, struct or union field, container element, or captured value.
// Asking the resolved type is what makes an alias or a generic substitution
// unable to bypass the rule.
type_mentions_any_view :: proc(c: ^Compiler, id: Type_Id, allow_top := false) -> bool {
	if id == INVALID_TYPE {
		return false
	}
	if id == TYPE_ANY_VIEW {
		return !allow_top
	}
	return type_contains_any_view(c, id, 0)
}

@(private = "file")
type_contains_any_view :: proc(c: ^Compiler, id: Type_Id, depth: int) -> bool {
	if depth > 32 {
		return false
	}
	info := type_of(c, id)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Any_View:
		return true
	case .Pointer, .Multi_Pointer, .Slice, .Dynamic_Array, .Array, .Distinct:
		return type_contains_any_view(c, info.element, depth + 1)
	case .Map:
		return type_contains_any_view(c, info.key, depth + 1) ||
		       type_contains_any_view(c, info.element, depth + 1)
	case .Union:
		for variant in info.variants {
			if type_contains_any_view(c, variant, depth + 1) {
				return true
			}
		}
	case .Struct:
		for field in info.fields {
			sym := symbol_of(c, field)
			if sym != nil && type_contains_any_view(c, sym.type, depth + 1) {
				return true
			}
		}
	case .Proc:
		for parameter in info.parameters {
			if type_contains_any_view(c, parameter, depth + 1) {
				return true
			}
		}
		for result in info.results {
			if type_contains_any_view(c, result, depth + 1) {
				return true
			}
		}
	}
	return false
}

// One diagnostic per forbidden position, naming the position rather than the
// milestone.
reject_any_view_position :: proc(k: ^Checker, type: Type_Id, span: Span, what: string) -> bool {
	if !type_mentions_any_view(k.c, type) {
		return false
	}
	errorf(
		k.c,
		span,
		"L0462",
		"`any_view` is a borrowed view and cannot be %s; it may only be a local or a parameter",
		what,
	)
	return true
}

// design.md: conversion from a concrete value is implicit at an `any_view`
// destination and never allocates.
any_view_accepts :: proc(c: ^Compiler, from: Type_Id) -> bool {
	if from == INVALID_TYPE || from == TYPE_ANY_VIEW {
		return false
	}
	if type_is_untyped(c, from) && from != TYPE_UNTYPED_NIL {
		return true // through its default type
	}
	return type_is_supported(c, from) && !type_mentions_any_view(c, from)
}

// The concrete type an `any_view` is being made from, once untyped constants
// have taken their default type.
any_view_source_type :: proc(c: ^Compiler, from: Type_Id) -> Type_Id {
	return type_is_untyped(c, from) ? default_type(c, from) : from
}

// ---------------------------------------------------------------- dyn --

// `dyn Interface(args...)`: the data pointer plus the coherent witness for the
// erased type. The subject argument is omitted because it is what is erased.
dyn_type :: proc(
	k: ^Checker,
	info: ^Interface_Info,
	args: []Generic_Arg,
	span: Span,
	mutable: bool,
	report: bool,
) -> Type_Id {
	if !dyn_compatible(k, info) {
		if report {
			errorf(
				k.c,
				span,
				"L0463",
				"`%s` is not dyn-compatible: %s",
				identifier_text(k.c, symbol_of(k.c, info.symbol).name),
				info.dyn_reason,
			)
		}
		return INVALID_TYPE
	}
	key := dyn_key(k.c, info.symbol, args, mutable)
	if existing, found := k.c.dyn_types[key]; found {
		return existing
	}
	// The read-only variant always exists, because it is the ABI type both
	// capabilities share (`dyn_abi_type`), exactly as `[]T` is for slices.
	if mutable {
		dyn_type(k, info, args, span, false, report)
	}
	name := intern_identifier(k.c, dyn_display_name(k.c, info, args, mutable))
	type := new_type(k.c, Type_Info {
		kind          = .Dyn,
		name          = name,
		mutable       = mutable,
		dyn_interface = info.symbol,
		dyn_args      = args,
	})
	fields := make([]Symbol_Id, 2, k.c.semantic_allocator)
	fields[DYN_DATA] = new_field(k.c, "data", TYPE_RAWPTR, DYN_DATA)
	fields[DYN_WITNESS] = new_field(k.c, "witness", TYPE_RAWPTR, DYN_WITNESS)
	if stored := type_of(k.c, type); stored != nil {
		stored.fields = fields
		stored.mangled = fmt.aprintf("dyn.%s", llvm_safe(identifier_text(k.c, name)), allocator = k.c.semantic_allocator)
	}
	k.c.dyn_types[key] = type
	install_dyn_forwarding_slots(k, info, args, type)
	return type
}

// `dyn I` satisfies `I` itself, through compiler-provided forwarding slots —
// the bridge between static and runtime polymorphism (design.md). Each
// forwarder is an ordinary method on the view whose body calls through the
// view's own witness, so `Drawable(dyn Drawable)` holds and generic code
// constrained by `I` accepts a `dyn I`.
@(private = "file")
install_dyn_forwarding_slots :: proc(k: ^Checker, info: ^Interface_Info, args: []Generic_Arg, dyn: Type_Id) {
	full := make([]Generic_Arg, len(info.params), k.c.semantic_allocator)
	full[0] = Generic_Arg{is_type = true, type = dyn}
	for index in 1 ..< len(full) {
		full[index] = index - 1 < len(args) ? args[index - 1] : Generic_Arg{}
	}
	flattened := make([dynamic]Interface_Slot, 0, 4, context.temp_allocator)
	interface_slots(k, info, full, &flattened)

	dyn_mutable := dyn_is_mutable(k.c, dyn)
	members := make([]Symbol_Id, len(flattened), k.c.semantic_allocator)
	saved_scope := k.scope
	for entry, index in flattened {
		owner := interface_info_for(k, entry.owner)
		scope := new_scope(k.c, owner.scope == nil ? build_universe(k.c) : owner.scope, .Local)
		for parameter, position in owner.params {
			if position < len(entry.args) {
				bind_generic_name(k, scope, Generic_Binding {
					name = parameter.name,
					span = parameter.span,
					arg  = entry.args[position],
				})
			}
		}
		k.scope = scope
		params, modes, results, result_inout, ok := slot_signature(k, entry.type, dyn)
		k.scope = saved_scope
		if !ok {
			continue
		}
		// A `dyn I` exposes only the slots an immutable `self` reaches. The
		// witness still carries every slot — what the view type decides is which
		// of them this capability may call, so the hole here is what makes the
		// mutable-slot call a capability error rather than a missing member.
		if !dyn_mutable && len(modes) > 0 && modes[0] == .Inout {
			continue
		}
		id := new_symbol(k.c, Symbol {
			name           = entry.name,
			span           = entry.span,
			kind           = .Proc,
			public         = true,
			owner_type     = dyn,
			params         = params,
			results        = results,
			param_symbols  = make([]Symbol_Id, len(params), k.c.semantic_allocator),
			param_defaults = make([]Expr, len(params), k.c.semantic_allocator),
			result_symbols = make([]Symbol_Id, len(results), k.c.semantic_allocator),
			proc_type      = intern_proc_type(k.c, params, modes, results, result_inout, ""),
			synth          = .Dyn_Forward,
			has_receiver   = true,
			receiver       = modes[0],
			index          = u32(index),
		})
		members[index] = id
		append(&k.c.synth_procs, id)
	}
	if stored := type_of(k.c, dyn); stored != nil {
		stored.members = members
	}
}

dyn_key :: proc(c: ^Compiler, interface_symbol: Symbol_Id, args: []Generic_Arg, mutable: bool) -> string {
	b := strings.builder_make(c.semantic_allocator)
	fmt.sbprintf(&b, "%d%s", u32(interface_symbol), mutable ? "m" : "")
	for arg in args {
		fmt.sbprintf(&b, "|%d", u32(arg.type))
	}
	return strings.to_string(b)
}

@(private = "file")
dyn_display_name :: proc(c: ^Compiler, info: ^Interface_Info, args: []Generic_Arg, mutable: bool) -> string {
	b := strings.builder_make(c.semantic_allocator)
	strings.write_string(&b, mutable ? "dyn mut " : "dyn ")
	strings.write_string(&b, identifier_text(c, symbol_of(c, info.symbol).name))
	if len(args) > 0 {
		strings.write_string(&b, "(")
		for arg, index in args {
			if index > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, type_name(c, arg.type))
		}
		strings.write_string(&b, ")")
	}
	return strings.to_string(b)
}

type_is_dyn :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) == .Dyn
}

dyn_is_mutable :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := underlying_info(c, id)
	return info != nil && info.kind == .Dyn && info.mutable
}

// A mutable and a read-only dyn view share one runtime representation — the
// same data pointer and the same witness — so the backend gives both one LLVM
// type and weakening emits no cast and no copy.
dyn_abi_type :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	under := type_underlying(c, id)
	info := type_of(c, under)
	if info == nil || info.kind != .Dyn || !info.mutable {
		return under
	}
	readonly, found := c.dyn_types[dyn_key(c, info.dyn_interface, info.dyn_args, false)]
	return found ? readonly : under
}

// The same interface applied to the same arguments, whatever the capability:
// what `dyn mut I(T)` and `dyn I(T)` have in common and `dyn I(U)` does not.
dyn_same_application :: proc(a, b: ^Type_Info) -> bool {
	if a.dyn_interface != b.dyn_interface || len(a.dyn_args) != len(b.dyn_args) {
		return false
	}
	for arg, index in a.dyn_args {
		if arg.type != b.dyn_args[index].type || arg.is_type != b.dyn_args[index].is_type {
			return false
		}
	}
	return true
}

// --------------------------------------------------- dyn compatibility --

// design.md's five rules. They are properties of the declaration, not of the use
// site, so the answer and the rule that disqualified it are computed once.
dyn_compatible :: proc(k: ^Checker, info: ^Interface_Info) -> bool {
	if info.dyn_computed {
		return info.dyn_ok
	}
	info.dyn_computed = true
	info.dyn_ok = false

	if len(info.params) == 0 {
		info.dyn_reason = "it declares no subject parameter"
		return false
	}
	subject := info.params[0].name

	for requirement in info.node.requirements {
		if requirement.kind == .Slot {
			if reason, ok := dyn_slot_is_compatible(k, requirement, subject); !ok {
				info.dyn_reason = reason
				return false
			}
			continue
		}
		// Composition is the one free-form requirement a dyn interface may have,
		// and the composed interface must itself be dyn-compatible on the same
		// subject.
		composed := composed_interface_of(k, requirement)
		if composed == nil {
			info.dyn_reason = fmt.aprintf(
				"the requirement on line %d is a free expression; every runtime operation must be a named `slot`",
				requirement_line(k.c, requirement),
				allocator = k.c.semantic_allocator,
			)
			return false
		}
		call := requirement.expr.(^Expr_Call)
		first: ^Expr_Ident
		has_subject := false
		if len(call.args) > 0 {
			first, has_subject = call.args[0].value.(^Expr_Ident)
		}
		if !has_subject || first.name_id != subject {
			info.dyn_reason = fmt.aprintf(
				"the composed interface `%s` does not use this interface's subject as its first argument",
				identifier_text(k.c, symbol_of(k.c, composed.symbol).name),
				allocator = k.c.semantic_allocator,
			)
			return false
		}
		if !dyn_compatible(k, composed) {
			info.dyn_reason = fmt.aprintf(
				"the composed interface `%s` is not dyn-compatible: %s",
				identifier_text(k.c, symbol_of(k.c, composed.symbol).name),
				composed.dyn_reason,
				allocator = k.c.semantic_allocator,
			)
			return false
		}
	}
	info.dyn_ok = true
	return true
}

@(private = "file")
requirement_line :: proc(c: ^Compiler, requirement: Requirement) -> int {
	if requirement.span.file == NO_FILE || int(requirement.span.file) >= len(c.sources) {
		return 0
	}
	line, _ := line_col(&c.sources[requirement.span.file], requirement.span.lo)
	return line
}

@(private = "file")
composed_interface_of :: proc(k: ^Checker, requirement: Requirement) -> ^Interface_Info {
	if requirement.result != nil || len(requirement.bindings) > 0 {
		return nil
	}
	call, is_call := requirement.expr.(^Expr_Call)
	if !is_call {
		return nil
	}
	return interface_info_for(k, named_callee_symbol(k, call.callee))
}

// design.md: a slot is non-generic and non-variadic, uses the ordinary calling
// convention, has no defaults, and mentions the subject exactly once — as the
// receiver.
@(private = "file")
dyn_slot_is_compatible :: proc(k: ^Checker, requirement: Requirement, subject: Identifier_Id) -> (string, bool) {
	signature, is_proc := requirement.slot_type.(^Type_Proc)
	if !is_proc {
		return "a `slot` requirement needs a procedure type", false
	}
	name := requirement.name.text
	if signature.convention != "" {
		return fmt.aprintf("slot `%s` uses a foreign calling convention", name, allocator = k.c.semantic_allocator), false
	}
	for parameter, position in signature.params {
		if parameter.mode == .Variadic {
			return fmt.aprintf("slot `%s` is variadic", name, allocator = k.c.semantic_allocator), false
		}
		if parameter.default != nil {
			return fmt.aprintf("slot `%s` has a default argument", name, allocator = k.c.semantic_allocator), false
		}
		// `proc(self, canvas: inout Canvas)` is the receiver plus one typed
		// parameter, so the written type belongs to the parameter, not to `self`.
		split := position == 0 && parameter.type != nil && len(parameter.names) > 1 &&
			parameter.names[0].name.text == "self"
		if position == 0 && !split {
			// The receiver: immutable `self` (inferred or written) or
			// `self: inout Subject`. A consuming `move self` cannot be erased.
			if parameter.mode == .Move {
				return fmt.aprintf(
					"slot `%s` consumes its receiver, which a borrowed view cannot supply",
					name,
					allocator = k.c.semantic_allocator,
				), false
			}
			if parameter.type != nil && !type_syntax_names(parameter.type, subject) {
				return fmt.aprintf(
					"slot `%s`'s receiver is not the interface's subject",
					name,
					allocator = k.c.semantic_allocator,
				), false
			}
			continue
		}
		if !split && type_syntax_names(parameter.type, subject) {
			return fmt.aprintf(
				"slot `%s` mentions the subject outside its receiver, so its size is not erasable",
				name,
				allocator = k.c.semantic_allocator,
			), false
		}
	}
	for result in signature.results {
		if type_syntax_names(result.type, subject) {
			return fmt.aprintf(
				"slot `%s` returns the subject, whose size is not known behind the view",
				name,
				allocator = k.c.semantic_allocator,
			), false
		}
	}
	return "", true
}

// Does this written type mention `name` anywhere? Purely syntactic, because
// dyn compatibility is a property of the declaration and no arguments are bound.
@(private = "file")
type_syntax_names :: proc(e: Expr, name: Identifier_Id) -> bool {
	if e == nil {
		return false
	}
	#partial switch v in e {
	case ^Expr_Ident:
		return v.name_id == name
	case ^Type_Pointer:
		return type_syntax_names(v.elem, name)
	case ^Type_Multi_Pointer:
		return type_syntax_names(v.elem, name)
	case ^Type_Slice:
		return type_syntax_names(v.elem, name)
	case ^Type_Dynamic_Array:
		return type_syntax_names(v.elem, name)
	case ^Type_Distinct:
		return type_syntax_names(v.elem, name)
	case ^Type_Array:
		return type_syntax_names(v.length, name) || type_syntax_names(v.elem, name)
	case ^Type_Map:
		return type_syntax_names(v.key, name) || type_syntax_names(v.value, name)
	case ^Expr_Selector:
		return type_syntax_names(v.operand, name)
	case ^Expr_Call:
		for arg in v.args {
			if type_syntax_names(arg.value, name) {
				return true
			}
		}
		return type_syntax_names(v.callee, name)
	}
	return false
}

// ------------------------------------------------------------ witnesses --

// The evidence that one concrete type satisfies one interface application, as
// one immutable private global per key.
Witness :: struct {
	interface_symbol: Symbol_Id,
	concrete:         Type_Id,
	args:             []Generic_Arg,
	// One entry per slot, in the flattened declaration order the dyn type's
	// call sites index by.
	slots:            []Witness_Slot,
	name:             string,
}

Witness_Slot :: struct {
	name:   Identifier_Id,
	target: Symbol_Id,
	// The receiver mode the thunk has to re-type the erased pointer for.
	mode:   Param_Mode,
	params: []Type_Id,
	results: []Type_Id,
}

// The flattened slots of an interface application, composition included, each
// remembering the package that declares it.
interface_slots :: proc(k: ^Checker, info: ^Interface_Info, args: []Generic_Arg, out: ^[dynamic]Interface_Slot) {
	// Resolve composed applications in the declaring interface's lexical scope,
	// with this application's complete argument vector bound to its parameters.
	scope := new_scope(k.c, info.scope == nil ? build_universe(k.c) : info.scope, .Local)
	for parameter, index in info.params {
		if index < len(args) {
			bind_generic_name(k, scope, Generic_Binding{name = parameter.name, span = parameter.span, arg = args[index]})
		}
	}
	saved_scope, saved_pkg, saved_lookup := k.scope, k.pkg, k.lookup_pkg
	saved_file, saved_node := k.file, k.file_node
	k.scope, k.pkg, k.lookup_pkg = scope, info.pkg, info.pkg
	if info.file_node != nil {
		k.file, k.file_node = info.file, info.file_node
	}
	defer {
		k.scope, k.pkg, k.lookup_pkg = saved_scope, saved_pkg, saved_lookup
		k.file, k.file_node = saved_file, saved_node
	}

	for requirement in info.node.requirements {
		if requirement.kind == .Slot {
			signature, is_proc := requirement.slot_type.(^Type_Proc)
			if !is_proc {
				continue
			}
			name := requirement.name.id
			if name == INVALID_IDENTIFIER {
				name = intern_identifier(k.c, requirement.name.text)
			}
			append(out, Interface_Slot {
				name  = name,
				span  = requirement.span,
				type  = signature,
				owner = info.symbol,
				args  = args,
			})
			continue
		}
		composed := composed_interface_of(k, requirement)
		if composed == nil {
			continue
		}
		// Clone before annotating: one interface declaration can be flattened for
		// many applications with different arguments.
		one := make([]Requirement, 1, k.c.semantic_allocator)
		one[0] = requirement
		clone := clone_requirements(k.c, one)[0]
		call, is_call := clone.expr.(^Expr_Call)
		if !is_call || len(call.args) != len(composed.params) {
			continue
		}
		composed_args := make([]Generic_Arg, len(call.args), k.c.semantic_allocator)
		valid := true
		for arg, index in call.args {
			denoted := resolve_type_syntax(k, arg.value)
			if denoted == INVALID_TYPE {
				valid = false
				break
			}
			composed_args[index] = Generic_Arg{is_type = true, type = denoted}
		}
		if !valid {
			continue
		}
		interface_slots(k, composed, composed_args, out)
	}
}

// Materializes, or reuses, the witness for one key. Slot selection always uses
// inherent members plus extensions in each slot's declaring-interface package,
// never the conversion site's.
request_witness :: proc(k: ^Checker, info: ^Interface_Info, concrete: Type_Id, args: []Generic_Arg, span: Span) -> ^Witness {
	key := witness_key(k.c, info.symbol, concrete, args)
	if existing, found := k.c.witnesses[key]; found {
		return existing
	}

	// The subject is the first argument; the rest are the dyn type's own.
	full := make([]Generic_Arg, len(info.params), k.c.semantic_allocator)
	full[0] = Generic_Arg{is_type = true, type = concrete}
	for index in 1 ..< len(full) {
		full[index] = index - 1 < len(args) ? args[index - 1] : Generic_Arg{}
	}

	flattened := make([dynamic]Interface_Slot, 0, 4, context.temp_allocator)
	interface_slots(k, info, full, &flattened)

	witness := new(Witness, k.c.semantic_allocator)
	witness.interface_symbol = info.symbol
	witness.concrete = concrete
	witness.args = args
	witness.name = witness_llvm_name(k.c, info.symbol, concrete, args)

	slots := make([]Witness_Slot, len(flattened), k.c.semantic_allocator)
	saved_scope, saved_pkg, saved_lookup := k.scope, k.pkg, k.lookup_pkg
	for entry, index in flattened {
		owner := interface_info_for(k, entry.owner)
		// The coherent rule, applied per slot: the package that declares the slot
		// decides which extensions may supply it.
		k.pkg, k.lookup_pkg = owner.pkg, owner.pkg
		k.scope = owner.scope == nil ? build_universe(k.c) : owner.scope
		params, modes, results, _, shape_ok := slot_signature_for(k, owner, entry, concrete)
		target := INVALID_SYMBOL
		if shape_ok {
			target = find_witness_slot(k, concrete, entry.name, owner.pkg, params, modes, results)
		}
		slots[index] = Witness_Slot {
			name    = entry.name,
			target  = target,
			mode    = len(modes) > 0 ? modes[0] : Param_Mode.Value,
			params  = params,
			results = results,
		}
	}
	k.scope, k.pkg, k.lookup_pkg = saved_scope, saved_pkg, saved_lookup
	witness.slots = slots
	if k.c.speculation_depth == 0 {
		k.c.witnesses[key] = witness
		append(&k.c.witness_order, witness)
	}
	return witness
}

@(private = "file")
witness_key :: proc(c: ^Compiler, interface_symbol: Symbol_Id, concrete: Type_Id, args: []Generic_Arg) -> string {
	b := strings.builder_make(c.semantic_allocator)
	fmt.sbprintf(&b, "%d|%d", u32(interface_symbol), u32(concrete))
	for arg in args {
		if arg.is_type {
			fmt.sbprintf(&b, "|T%d", u32(arg.type))
		} else {
			fmt.sbprintf(&b, "|V%d:%s", u32(arg.value_type), const_key_text(c, arg.value))
		}
	}
	return strings.to_string(b)
}

// The backend spelling of a witness. Names rather than symbol and type ids: an
// id shifts whenever anything earlier in the universe or the type store grows,
// which made every emitted witness name — and the goldens that pin them — churn
// on unrelated changes. Uniqueness still comes from `witness_key`, which is what
// the witness map is keyed by; this only has to be stable and readable.
@(private = "file")
witness_llvm_name :: proc(c: ^Compiler, interface_symbol: Symbol_Id, concrete: Type_Id, args: []Generic_Arg) -> string {
	b := strings.builder_make(c.semantic_allocator)
	interface_name := "interface"
	if sym := symbol_of(c, interface_symbol); sym != nil {
		interface_name = identifier_text(c, sym.name)
	}
	fmt.sbprintf(&b, "@loke.w.%s.%s", llvm_safe(interface_name), llvm_safe(type_name(c, concrete)))
	for arg in args {
		if arg.is_type {
			fmt.sbprintf(&b, ".%s", llvm_safe(type_name(c, arg.type)))
		} else {
			fmt.sbprintf(&b, ".%s", llvm_safe(const_key_text(c, arg.value)))
		}
	}
	return strings.to_string(b)
}

// Resolves one slot's written signature with the owning interface's parameters
// bound to this application's arguments.
@(private = "file")
slot_signature_for :: proc(
	k: ^Checker,
	owner: ^Interface_Info,
	entry: Interface_Slot,
	concrete: Type_Id,
) -> ([]Type_Id, []Param_Mode, []Type_Id, []bool, bool) {
	scope := new_scope(k.c, k.scope, .Local)
	for parameter, index in owner.params {
		if index < len(entry.args) {
			bind_generic_name(k, scope, Generic_Binding{name = parameter.name, span = parameter.span, arg = entry.args[index]})
		}
	}
	saved := k.scope
	k.scope = scope
	defer k.scope = saved
	return slot_signature(k, entry.type, concrete)
}

@(private = "file")
find_witness_slot :: proc(
	k: ^Checker,
	concrete: Type_Id,
	name: Identifier_Id,
	owner_pkg: Package_Id,
	params: []Type_Id,
	modes: []Param_Mode,
	results: []Type_Id,
) -> Symbol_Id {
	result_inout := make([]bool, len(results), k.c.semantic_allocator)
	for candidate in slot_candidates_for_witness(k, concrete, name, owner_pkg) {
		sym := symbol_of(k.c, candidate)
		if sym == nil || sym.kind != .Proc || !sym.has_receiver {
			continue
		}
		if witness_slot_matches(k, sym, params, modes, results, result_inout) {
			return candidate
		}
	}
	return INVALID_SYMBOL
}

@(private = "file")
slot_candidates_for_witness :: proc(k: ^Checker, concrete: Type_Id, name: Identifier_Id, owner_pkg: Package_Id) -> []Symbol_Id {
	out := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	if info := underlying_info(k.c, concrete); info != nil {
		for member in info.members {
			if sym := symbol_of(k.c, member); sym != nil && sym.name == name {
				append(&out, member)
			}
		}
	}
	if pkg := package_of(k.c, owner_pkg); pkg != nil {
		for member in pkg.extensions[concrete] {
			if sym := symbol_of(k.c, member); sym != nil && sym.name == name {
				append(&out, member)
			}
		}
	}
	return out[:]
}

@(private = "file")
witness_slot_matches :: proc(
	k: ^Checker,
	sym: ^Symbol,
	params: []Type_Id,
	modes: []Param_Mode,
	results: []Type_Id,
	result_inout: []bool,
) -> bool {
	if len(sym.params) != len(params) || len(sym.results) != len(results) {
		return false
	}
	info := type_of(k.c, sym.proc_type)
	if info == nil || info.convention != "" {
		return false
	}
	for want, index in params {
		if sym.params[index] != want {
			return false
		}
		have := index < len(info.param_modes) ? info.param_modes[index] : Param_Mode.Value
		if have != modes[index] {
			return false
		}
	}
	for want, index in results {
		if sym.results[index] != want {
			return false
		}
	}
	return true
}

// The slot a `dyn` value's method call selects, and its index in the witness.
dyn_slot_index :: proc(k: ^Checker, dyn: Type_Id, name: Identifier_Id) -> (int, Interface_Slot, bool) {
	info := underlying_info(k.c, dyn)
	if info == nil || info.kind != .Dyn {
		return 0, Interface_Slot{}, false
	}
	owner := interface_info_for(k, info.dyn_interface)
	if owner == nil {
		return 0, Interface_Slot{}, false
	}
	full := make([]Generic_Arg, len(owner.params), k.c.semantic_allocator)
	if len(full) > 0 {
		full[0] = Generic_Arg{is_type = true, type = dyn}
	}
	for index in 1 ..< len(full) {
		full[index] = index - 1 < len(info.dyn_args) ? info.dyn_args[index - 1] : Generic_Arg{}
	}
	flattened := make([dynamic]Interface_Slot, 0, 4, k.c.semantic_allocator)
	interface_slots(k, owner, full, &flattened)
	for entry, index in flattened {
		if entry.name == name {
			return index, entry, true
		}
	}
	return 0, Interface_Slot{}, false
}

// ------------------------------------------------------- type resolution --

// `dyn Interface(args...)`. Forming the type validates the interface, its
// non-subject arguments, and dyn compatibility; it cannot evaluate satisfaction
// because the erased subject is absent.
resolve_dyn_type :: proc(k: ^Checker, v: ^Type_Dyn) -> Type_Id {
	callee := v.interface_expr
	args: []Argument
    if call, is_call := callee.(^Expr_Call); is_call {
		args = call.args
		callee = call.callee
	}
	info := interface_info_for(k, named_callee_symbol(k, callee))
	if info == nil {
		errorf(k.c, expr_span(v.interface_expr), "L0463", "`dyn` needs an interface")
		return INVALID_TYPE
	}
	// The subject is erased, so the application supplies every *other* parameter.
	if len(args) != len(info.params) - 1 {
		errorf(
			k.c,
			v.span,
			"L0463",
			"`dyn %s` takes %d argument%s beyond its erased subject, found %d",
			identifier_text(k.c, symbol_of(k.c, info.symbol).name),
			len(info.params) - 1,
			len(info.params) - 1 == 1 ? "" : "s",
			len(args),
		)
		return INVALID_TYPE
	}
	bound := make([]Generic_Arg, len(args), k.c.semantic_allocator)
	for arg, index in args {
		denoted := resolve_type_syntax(k, arg.value)
		if denoted == INVALID_TYPE {
			errorf(k.c, arg.span, "L0463", "a `dyn` interface argument must name a type")
			return INVALID_TYPE
		}
		bound[index] = Generic_Arg{is_type = true, type = denoted}
	}
	return dyn_type(k, info, bound, v.span, v.mutable, report = true)
}

// design.md: conversion is an ordinary explicit conversion from a pointer to the
// concrete subject. It checks `Interface(Concrete, args...)` using the coherent
// dyn lookup rule and then requests the witness.
check_dyn_conversion :: proc(k: ^Checker, v: ^Expr_Call, target: Type_Id) {
	v.value_category = .Value
	v.type = target
	if len(v.args) != 1 {
		errorf(k.c, v.span, "L0464", "a `dyn` conversion takes one pointer to the concrete value")
		v.type = INVALID_TYPE
		return
	}
	source := check_single_expr(k, v.args[0].value)
	if source == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = v.args[0].value
	v.bound = bound
	v.resolution = Resolution{kind = .Conversion}

	// Converting a nil concrete pointer produces the nil dynamic view and does
	// not retain a witness for the absent value.
	if source == TYPE_UNTYPED_NIL {
		materialize(k, v.args[0].value, TYPE_RAWPTR)
		return
	}
	pointer := underlying_info(k.c, source)
	if pointer == nil || pointer.kind != .Pointer {
		errorf(
			k.c,
			expr_span(v.args[0].value),
			"L0464",
			"a `dyn` conversion takes `^Concrete`, found `%s`",
			type_name(k.c, source),
		)
		v.type = INVALID_TYPE
		return
	}
	// A mutable view may only be built from a mutable pointer: the view's
	// capability is the referent's, and the conversion is where it is claimed.
	// The other direction is ordinary weakening and needs nothing.
	if dyn_is_mutable(k.c, target) && !pointer.mutable {
		errorf(
			k.c,
			expr_span(v.args[0].value),
			"L0642",
			"`%s` needs `^mut Concrete`, found `%s`",
			type_name(k.c, target),
			type_name(k.c, source),
		)
		v.type = INVALID_TYPE
		return
	}
	concrete := pointer.element
	dyn := underlying_info(k.c, target)
	info := interface_info_for(k, dyn.dyn_interface)
	if info == nil {
		v.type = INVALID_TYPE
		return
	}

	full := make([]Generic_Arg, len(info.params), k.c.semantic_allocator)
	full[0] = Generic_Arg{is_type = true, type = concrete}
	for index in 1 ..< len(full) {
		full[index] = index - 1 < len(dyn.dyn_args) ? dyn.dyn_args[index - 1] : Generic_Arg{}
	}
	if !interface_satisfied(k, info, full, v.span, report = true) {
		v.type = INVALID_TYPE
		return
	}

	witness := request_witness(k, info, concrete, dyn.dyn_args, v.span)
	for slot in witness.slots {
		if slot.target == INVALID_SYMBOL {
			errorf(
				k.c,
				v.span,
				"L0464",
				"`%s` supplies no coherent `%s` for `%s`",
				type_name(k.c, concrete),
				identifier_text(k.c, slot.name),
				type_name(k.c, target),
			)
			v.type = INVALID_TYPE
			return
		}
	}
	v.dyn_witness = witness
}

// ---------------------------------------- any_view checked extractions --

// design.md: `any_view` supports runtime checked extractions and type switches,
// through the same two spellings a union has — trapping `.(T)` and optional
// `.as(T)` — on the same `Expr_Checked_Extract` node.
// design.md "Checked extractions": `value.as(T)` is the optional spelling. It
// is written with selector/call syntax but is not a call — it resolves to the
// same `Expr_Checked_Extract` `value.(T)` produces, so the flow graph, the
// evaluator, and the emitter keep one extraction path rather than two.
//
// `as` is a name users choose, so the receiver's *type* decides which meaning
// applies: an `any_view` takes the built-in, and every other type keeps its
// declared member. Resolving the receiver first is what makes that true for
// `f().as(T)`, `a.b.as(T)`, and `xs[0].as(T)` as well as for a plain name.
check_union_extract :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) -> bool {
	if sel.name.text != "as" {
		return false
	}
	// A package selector names a declaration, not a value receiver.
	if ident, ok := sel.operand.(^Expr_Ident); ok {
		if sym := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident))); sym != nil &&
		   sym.kind == .Package_Alias {
			return false
		}
	}
	if check_single_expr(k, sel.operand) != TYPE_ANY_VIEW {
		return false
	}

	v.value_category = .Value
	v.union_op = .Extract
	v.resolution = Resolution{kind = .Builtin_Operator}
	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = sel.operand
	v.bound = bound

	// Exactly one positional type argument, which is the extraction's target.
	if len(v.args) != 1 || v.args[0].name.text != "" || v.args[0].mode != .Value ||
	   v.args[0].value == nil {
		errorf(
			k.c, v.span, "L0425",
			"`as` names the requested type as its one positional argument, found %d argument%s",
			len(v.args), len(v.args) == 1 ? "" : "s",
		)
		v.type = INVALID_TYPE
		return true
	}

	extract := new(Expr_Checked_Extract, k.c.semantic_allocator)
	extract.span = v.span
	extract.operand = sel.operand
	extract.target = v.args[0].value
	extract.mode = .Optional
	v.extract = extract

	check_extract_of(k, extract, TYPE_ANY_VIEW)
	v.type = extract.type
	v.result_types = extract.result_types
	return true
}

// `.as(T)` produces `Option(T)`; `.(T)` produces `T` and traps on a mismatch.
@(private = "file")
set_extract_results :: proc(k: ^Checker, v: ^Expr_Checked_Extract, target: Type_Id) {
	if v.mode != .Optional {
		return
	}
	v.type = option_type(k, target, v.span)
}

check_any_view_extract :: proc(k: ^Checker, v: ^Expr_Checked_Extract) {
	target := resolve_type_syntax(k, v.target)
	if target == INVALID_TYPE {
		errorf(k.c, expr_span(v.target), "L0465", "a checked extraction names the requested type")
		v.type = INVALID_TYPE
		return
	}
	if !any_view_accepts(k.c, target) {
		errorf(
			k.c,
			expr_span(v.target),
			"L0465",
			"`%s` is not a concrete type an `any_view` can hold",
			type_name(k.c, target),
		)
		v.type = INVALID_TYPE
		return
	}
	v.type = target
	v.payload = target
	set_extract_results(k, v, target)
	if type_clone_disabled(k.c, target) {
		errorf(k.c, v.span, "L0503", "`%s` is move-only, so a checked extraction cannot copy it from an `any_view`", type_name(k.c, target))
		return
	}
	contribute_lifecycle_members(k, target)
	request_typeid(k.c, target)
}

// --------------------------------------------------------- slot calls --

// `view.draw(inout canvas)`: an indirect call through the witness, with a
// nil-witness trap. The slot was selected by name at check time.
check_dyn_slot_call :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector, dyn: Type_Id) -> bool {
	name := intern_identifier(k.c, sel.name.text)
	index, entry, found := dyn_slot_index(k, dyn, name)
	if !found {
		return false
	}
	owner := interface_info_for(k, entry.owner)
	scope := new_scope(k.c, owner.scope == nil ? build_universe(k.c) : owner.scope, .Local)
	saved := k.scope
	k.scope = scope
	for parameter, position in owner.params {
		if position < len(entry.args) && entry.args[position].is_type {
			bind_generic_name(k, scope, Generic_Binding {
				name = parameter.name,
				span = parameter.span,
				arg  = entry.args[position],
			})
		}
	}
	// The receiver's own type is the erased view, and every other parameter is
	// resolved from the interface application.
	params, modes, results, _, ok := slot_signature(k, entry.type, dyn)
	k.scope = saved
	if !ok {
		errorf(k.c, v.span, "L0467", "`%s`'s signature does not resolve here", sel.name.text)
		v.type = INVALID_TYPE
		return true
	}
	// The slot exists on the witness whatever the view's capability, so calling a
	// mutating one through a read-only view is a capability error and must not be
	// reported as a missing member (design.md).
	if !dyn_is_mutable(k.c, dyn) && len(modes) > 0 && modes[0] == .Inout {
		errorf(
			k.c,
			v.span,
			"L0643",
			"slot `%s` mutates its subject, so it needs `dyn mut %s`",
			sel.name.text,
			identifier_text(k.c, symbol_of(k.c, owner.symbol).name),
		)
		v.type = INVALID_TYPE
		return true
	}

	v.value_category = .Value
	if len(v.args) != len(params) - 1 {
		errorf(
			k.c,
			v.span,
			"L0467",
			"slot `%s` takes %d argument%s, found %d",
			sel.name.text,
			len(params) - 1,
			len(params) - 1 == 1 ? "" : "s",
			len(v.args),
		)
		v.type = INVALID_TYPE
		return true
	}
	bound := make([]Expr, len(params), k.c.semantic_allocator)
	bound[0] = sel.operand
	for arg, position in v.args {
		want := params[position + 1]
		k.place_position, k.insert_position = modes[position + 1] == .Inout, modes[position + 1] == .Inout
		checked := check_single_expr(k, arg.value, want)
		k.place_position = false
		if checked == INVALID_TYPE || !materialize_argument(k, arg.value, want) {
			v.type = INVALID_TYPE
			return true
		}
		if modes[position + 1] == .Inout {
			if base := expr_base(arg.value); base != nil && !base.assignable {
				report_not_assignable(k, base, "an `inout` argument")
				v.type = INVALID_TYPE
				return true
			}
		}
		bound[position + 1] = arg.value
	}
	v.bound = bound
	v.is_dyn_call = true
	v.dyn_slot = index
	sel.type = intern_proc_type(k.c, params, modes, results, make([]bool, len(results), k.c.semantic_allocator), "")
	switch len(results) {
	case 0:
		v.type = TYPE_VOID
	case 1:
		v.type = results[0]
	case:
		v.type = results[0]
		v.result_types = results
	}
	return true
}
