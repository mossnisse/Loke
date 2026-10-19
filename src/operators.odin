// User operator declarations, lookup, and delegation. Ranking is shared with
// named overloads in overload.odin.
package lokec

import "core:slice"
import "core:fmt"

// ------------------------------------------------------------ declarations --

// Parameter and result counts for each overloadable symbol.
@(private = "file")
Operator_Shape :: struct {
	min, max: int,
	results:  int,
	boolean:  bool, // the single result must be `bool`
	assign:   bool, // a compound form: first parameter is `inout`, no results
}

@(private = "file")
operator_shape :: proc(symbol: string) -> (Operator_Shape, bool) {
	switch symbol {
	case "+", "-", "~":
		return Operator_Shape{min = 1, max = 2, results = 1}, true // unary or binary
	case "!":
		return Operator_Shape{min = 1, max = 1, results = 1}, true
	case "*", "+%", "-%", "*%", "/", "%", "|", "&", "&~", "<<", ">>":
		return Operator_Shape{min = 2, max = 2, results = 1}, true
	case "==", "!=", "<", "<=", ">", ">=", "in":
		return Operator_Shape{min = 2, max = 2, results = 1, boolean = true}, true
	case "+=", "-=", "*=", "+%=", "-%=", "*%=", "/=", "%=", "|=", "~=", "&=", "&~=", "<<=", ">>=":
		return Operator_Shape{min = 2, max = 2, results = 0, assign = true}, true
	case "[]":
		return Operator_Shape{min = 2, max = -1, results = 1}, true
	case "[]=":
		return Operator_Shape{min = 3, max = -1, results = 0}, true
	case "[:]":
		return Operator_Shape{min = 3, max = 3, results = 1}, true
	}
	return Operator_Shape{}, false
}

// design.md: assignment, declaration, member access, address-of, dereference,
// `move`, `drop`, `&&`, `||`, `or_else`, and the conditional expression are not
// overloadable.
resolve_operator_declaration :: proc(k: ^Checker, d: ^Decl, value: ^Expr_Operator) {
	symbol_id := d.symbols[0]
	symbol := symbol_of(k.c, symbol_id)
	if symbol == nil {
		return
	}
	symbol.operator = value.symbol
	#partial switch inner in value.value {
	case ^Expr_Proc:
		symbol.kind = .Proc
		resolve_proc_signature(k, inner, symbol_id)
		symbol = symbol_of(k.c, symbol_id)
		symbol.operator = value.symbol
	case ^Expr_Proc_Group:
		symbol.kind = .Proc_Group
		resolve_group_members(k, symbol_id, inner)
		symbol = symbol_of(k.c, symbol_id)
	case:
		return
	}

	shape, overloadable := operator_shape(value.symbol)
	if !overloadable {
		errorf(k.c, value.symbol_span, "L0416", "`%s` is not an overloadable operator", value.symbol)
		return
	}
	if symbol.kind == .Proc {
		validate_operator_shape(k, value, shape, symbol_id)
	} else {
		for member in symbol.members {
			validate_operator_shape(k, value, shape, member)
		}
	}

	// Every operator declaration outside a procedure also joins its package's
	// set, which is what an extension block and a file-scope declaration are
	// found through. A local one is found through its scope.
	if in_local_scope(k.scope) {
		return
	}
	pkg := package_of(k.c, k.pkg)
	set, found := pkg.operators[value.symbol]
	if !found {
		set = new([dynamic]Symbol_Id, k.c.semantic_allocator)
		set^ = make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
		pkg.operators[value.symbol] = set
	}
	append(set, symbol_id)
}

@(private = "file")
validate_operator_shape :: proc(k: ^Checker, value: ^Expr_Operator, shape: Operator_Shape, symbol_id: Symbol_Id) {
	sym := symbol_of(k.c, symbol_id)
	if sym == nil || sym.kind != .Proc {
		return
	}
	count := len(sym.params)
	if count < shape.min || (shape.max >= 0 && count > shape.max) {
		errorf(
			k.c,
			value.symbol_span,
			"L0416",
			"`operator(%s)` takes %s, found %d",
			value.symbol,
			arity_text(shape),
			count,
		)
		return
	}
	info := type_of(k.c, sym.proc_type)
	if variadic_parameter_index(info) >= 0 {
		errorf(k.c, value.symbol_span, "L0416", "`operator(%s)` cannot have a variadic parameter", value.symbol)
		return
	}
	if shape.results >= 0 && (sym.result == INVALID_TYPE ? 0 : 1) != shape.results {
		errorf(
			k.c,
			value.symbol_span,
			"L0416",
			"`operator(%s)` produces %d result%s",
			value.symbol,
			shape.results,
			shape.results == 1 ? "" : "s",
		)
		return
	}
	if shape.boolean && (sym.result == INVALID_TYPE || !type_is_boolean(k.c, sym.result)) {
		errorf(k.c, value.symbol_span, "L0416", "`operator(%s)` produces `bool`", value.symbol)
		return
	}
	if shape.assign {
		if info == nil || len(info.param_modes) == 0 || info.param_modes[0] != .Inout {
			errorf(k.c, value.symbol_span, "L0416", "`operator(%s)` takes its destination as `inout`", value.symbol)
		}
	}
}

@(private = "file")
arity_text :: proc(shape: Operator_Shape) -> string {
	if shape.max < 0 {
		return fmt.tprintf("at least %d parameters", shape.min)
	}
	if shape.min == shape.max {
		return fmt.tprintf("%d parameter%s", shape.min, shape.min == 1 ? "" : "s")
	}
	return fmt.tprintf("%d or %d parameters", shape.min, shape.max)
}

// ------------------------------------------------------------------ lookup --

// Inherent operators plus file-scope and extension operators in this package.
operator_candidates :: proc(k: ^Checker, symbol: string, operands: []Type_Id) -> []Symbol_Id {
	out := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	for operand in operands {
		if info := type_of(k.c, operand); info != nil {
			add_operator_members(k, info.members, symbol, &out)
		}
	}
	if pkg := package_of(k.c, lookup_package(k)); pkg != nil {
		for operand in operands {
			if members, found := pkg.extensions[operand]; found {
				add_operator_members(k, members, symbol, &out)
			}
		}
		// design.md "Operator lookup and overload resolution": lexical scope comes
		// before ranking, so the innermost local scope declaring this operator
		// stands in for the package's set. Inherent and extension operators
		// belong to their types and stay candidates.
		if local := local_operator_set(k, symbol); len(local) > 0 {
			add_operator_members(k, local, symbol, &out)
		} else if set, found := pkg.operators[symbol]; found {
			add_operator_members(k, set[:], symbol, &out)
		}
	}
	return out[:]
}

@(private = "file")
in_local_scope :: proc(scope: ^Scope) -> bool {
	return scope != nil && (scope.kind == .Local || scope.kind == .Procedure)
}

// The operators named `symbol` declared in the innermost local scope that
// declares any, in declaration order.
@(private = "file")
local_operator_set :: proc(k: ^Checker, symbol: string) -> []Symbol_Id {
	out := make([dynamic]Symbol_Id, 0, 2, context.temp_allocator)
	for scope := k.scope; in_local_scope(scope); scope = scope.parent {
		for _, id in scope.names {
			if sym := symbol_of(k.c, id); sym != nil && sym.operator == symbol {
				append(&out, id)
			}
		}
		if len(out) > 0 {
			slice.sort(out[:])
			break
		}
	}
	return out[:]
}

@(private = "file")
add_operator_members :: proc(k: ^Checker, members: []Symbol_Id, symbol: string, out: ^[dynamic]Symbol_Id) {
	for member in members {
		sym := symbol_of(k.c, member)
		if sym == nil || sym.operator != symbol || !member_is_visible(k, sym) {
			continue
		}
		if sym.kind == .Proc_Group {
			for nested in sym.members {
				append_unique(out, nested)
			}
			continue
		}
		append_unique(out, member)
	}
}

// The overloads of a receiver-shaped operator (`[]`, `[]=`, `[:]`) that apply to
// this receiver: the package set holds every declaration of the symbol, so a
// question like "does it hand out a location?" must check the receiver alone.
operator_candidates_for_receiver :: proc(k: ^Checker, symbol: string, receiver: Type_Id) -> []Symbol_Id {
	all := operator_candidates(k, symbol, []Type_Id{receiver})
	out := make([dynamic]Symbol_Id, 0, len(all), k.c.semantic_allocator)
	for candidate in all {
		sym := symbol_of(k.c, candidate)
		if sym != nil && len(sym.params) > 0 && sym.params[0] == receiver {
			append(&out, candidate)
		}
	}
	return out[:]
}

// Finds an exact inherent overload hidden by package visibility.
hidden_inherent_operator :: proc(k: ^Checker, symbol: string, operands: []Type_Id) -> bool {
	for operand in operands {
		info := type_of(k.c, operand)
		if info == nil {
			continue
		}
		for member in info.members {
			sym := symbol_of(k.c, member)
			if sym == nil || sym.operator != symbol || sym.bound_excluded {
				continue
			}
			// A `delegate` forwards to the underlying type's operator, which is
			// what the built-in table reaches for a `distinct` anyway. Nothing is
			// being substituted, so nothing is worth reporting.
			if sym.delegated || member_is_visible(k, sym) || len(sym.params) != len(operands) {
				continue
			}
			applies := true
			for param, index in sym.params {
				if param != operands[index] {
					applies = false
					break
				}
			}
			if applies {
				return true
			}
		}
	}
	return false
}

@(private = "file")
append_unique :: proc(out: ^[dynamic]Symbol_Id, id: Symbol_Id) {
	if !slice.contains(out[:], id) {
		append(out, id)
	}
}

// -------------------------------------------------- the built-in priority --

// A distinct type never participates in unshadowable built-in operations. An
// anonymous record or union belongs to no package, so it is a built-in type
// for this rule (design.md "Operator lookup and overload resolution").
operand_is_builtin :: proc(k: ^Checker, type: Type_Id) -> bool {
	#partial switch type_kind(k.c, type) {
	case .Struct, .Union:
		info := type_of(k.c, type)
		return info != nil && (info.anonymous_record || info.anonymous_union)
	case .Distinct, .Interface, .Dyn, .Invalid:
		return false
	}
	return true
}

builtin_binary_defined :: proc(k: ^Checker, op: Token_Kind, lhs, rhs: Type_Id) -> bool {
	if !operand_is_builtin(k, lhs) || !operand_is_builtin(k, rhs) {
		return false
	}
	if op == .Shl || op == .Shr {
		if !type_is_integer(k.c, lhs) && !type_is_rune(k.c, lhs) {
			return false
		}
		if type_is_untyped(k.c, rhs) {
			return type_is_integer(k.c, rhs) || type_is_rune(k.c, rhs)
		}
		// design.md "Arithmetic operators": any integer count; a negative one panics.
		return type_is_integer(k.c, rhs)
	}
	unified, ok := join_operand_types(k, lhs, rhs)
	if !ok {
		return false
	}
	#partial switch op {
	case .Eq_Eq, .Not_Eq:
		return type_is_comparable(k.c, unified)
	case .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		return type_is_ordered(k.c, unified)
	}
	return builtin_operator_applies(k.c, op, unified)
}

builtin_unary_defined :: proc(k: ^Checker, op: Token_Kind, operand: Type_Id) -> bool {
	if !operand_is_builtin(k, operand) {
		return false
	}
	#partial switch op {
	case .Plus, .Minus:
		return type_is_numeric(k.c, operand)
	case .Tilde:
		return type_is_integer(k.c, operand) || type_is_rune(k.c, operand)
	case .Not:
		return type_is_boolean(k.c, operand)
	}
	return false
}

// ------------------------------------------------------------- resolution --

// One operator's visible candidates, formed once against one argument list,
// so a fallback choice and the ranking after it share them.
Operator_Set :: struct {
	symbol:  string,
	members: []Symbol_Id,
	formed:  []Candidate,
}

// `among` is the already-filtered set an index in place position built; every
// other caller forms the whole visible set.
form_operator_set :: proc(
	k: ^Checker, symbol: string, operands: []Type_Id, args: []Arg_Info, among: []Symbol_Id = nil,
) -> Operator_Set {
	members := among == nil ? operator_candidates(k, symbol, operands) : among
	return Operator_Set{symbol = symbol, members = members, formed = form_candidates(k, members, args)}
}

// An unrelated overload must not suppress a built-in fallback.
operator_viable :: proc(set: Operator_Set) -> bool {
	return candidates_viable(set.formed)
}

// Resolves and binds one operator expression.
resolve_operator :: proc(
	k: ^Checker,
	span: Span,
	symbol: string,
	operands: []Type_Id,
	args: []Arg_Info,
	among: []Symbol_Id = nil,
) -> (Symbol_Id, []Expr) {
	return resolve_operator_set(k, span, form_operator_set(k, symbol, operands, args, among), args)
}

// Ranks a formed set and binds the chosen candidate's operands.
resolve_operator_set :: proc(k: ^Checker, span: Span, set: Operator_Set, args: []Arg_Info) -> (Symbol_Id, []Expr) {
	if len(set.members) == 0 {
		return INVALID_SYMBOL, nil
	}
	description := fmt.aprintf("operator `%s`", set.symbol, allocator = k.c.semantic_allocator)
	cand, resolved := choose_candidate(k, span, description, set.members, set.formed, args)
	if !resolved {
		return INVALID_SYMBOL, nil
	}
	bound, ok := bind_operator_operands(k, cand, args)
	if !ok || !check_operator_modes(k, cand.symbol, bound) {
		return INVALID_SYMBOL, nil
	}
	return cand.symbol, bound
}

// Whether a related candidate exists, used only to choose a diagnostic path.
operator_exists :: proc(k: ^Checker, members: []Symbol_Id, operands: []Type_Id) -> bool {
	for candidate in members {
		sym := symbol_of(k.c, candidate)
		if sym == nil {
			continue
		}
		if sym.generic {
			return true
		}
		for param in sym.params {
			if slice.contains(operands, param) {
				return true
			}
		}
	}
	return false
}

@(private = "file")
bind_operator_operands :: proc(k: ^Checker, cand: Candidate, args: []Arg_Info) -> ([]Expr, bool) {
	sym := symbol_of(k.c, cand.symbol)
	if sym == nil {
		return nil, false
	}
	bound := make([]Expr, len(sym.params), k.c.semantic_allocator)
	ok := true
	for arg, index in args {
		slot := cand.slots[index]
		value := arg.expr
		if !materialize_argument(k, value, sym.params[slot]) {
			ok = false
		}
		bound[slot] = value
	}
	for slot in 0 ..< len(bound) {
		if bound[slot] == nil {
			if slot < len(sym.param_defaults) && sym.param_defaults[slot] != nil {
				bound[slot] = sym.param_defaults[slot]
				continue
			}
			ok = false
		}
	}
	return bound, ok
}

// An `inout` parameter needs a mutable place, whichever operand fills it.
@(private = "file")
check_operator_modes :: proc(k: ^Checker, symbol_id: Symbol_Id, bound: []Expr) -> bool {
	sym := symbol_of(k.c, symbol_id)
	info := sym == nil ? nil : type_of(k.c, sym.proc_type)
	if info == nil {
		return false
	}
	ok := true
	for mode, index in info.param_modes {
		if index >= len(bound) || bound[index] == nil {
			continue
		}
		if !check_bound_argument_mode(k, bound[index], info.parameters[index], mode, "an `inout` operand") {
			ok = false
		}
	}
	return ok
}

// Does this overload hand back a place? `operator([])` returning `inout T` is
// what makes an indexed assignment an ordinary store.
operator_result_is_place :: proc(k: ^Checker, symbol_id: Symbol_Id) -> bool {
	sym := symbol_of(k.c, symbol_id)
	if sym == nil {
		return false
	}
	info := type_of(k.c, sym.proc_type)
	return info != nil && info.result_inout
}

// ----------------------------------------------------------------- delegate --

// design.md "Delegating operators": for each listed symbol, generate the
// overload found for the underlying type, with the distinct type substituted
// for it in every operand and result position — except a result of another
// type (a comparison's `bool`), which passes through unchanged. The overloads
// go where the block's other members do: the type's own for an inherent `impl`,
// `in_pkg`'s extensions of it for an extension, which only that package's
// lookup sees (design.md "Methods and implementation blocks").
check_delegate :: proc(k: ^Checker, item: ^Item_Delegate, subject: Type_Id, kind: Impl_Kind, in_pkg: Package_Id) {
	info := type_of(k.c, subject)
	if info == nil || info.kind != .Distinct {
		errorf(
			k.c,
			item.span,
			"L0420",
			"`delegate` needs a `distinct` type; `%s` has no underlying representation to forward to",
			type_name(k.c, subject),
		)
		return
	}
	underlying := info.element
	for symbol in item.symbols {
		delegate_one(k, item, kind, in_pkg, subject, underlying, symbol)
	}
}

@(private = "file")
delegate_one :: proc(k: ^Checker, item: ^Item_Delegate, kind: Impl_Kind, in_pkg: Package_Id, subject, underlying: Type_Id, symbol: string) {
	if _, overloadable := operator_shape(symbol); !overloadable {
		errorf(k.c, item.span, "L0416", "`%s` is not an overloadable operator", symbol)
		return
	}
	// Delegating an operator already declared in the same block is a
	// redeclaration, diagnosed like any other.
	if len(operator_candidates_for_receiver(k, symbol, subject)) > 0 {
		errorf(k.c, item.span, "L0420", "`%s` is already declared for `%s`", symbol, type_name(k.c, subject))
		return
	}
	// The underlying operations are fixed here — a caller's later extension
	// cannot change what delegation means. Each keeps its own signature, so a
	// non-homogeneous operator like `[]` forwards its index parameter unchanged
	// rather than forcing the distinct type onto it.
	found := operator_candidates_for_receiver(k, symbol, underlying)
	if len(found) > 0 {
		for target in found {
			register_forwarded_operator(k, item, kind, in_pkg, subject, underlying, symbol, target)
		}
		return
	}
	if operand_is_builtin(k, underlying) && builtin_delegation_applies(k, symbol, underlying) {
		register_builtin_delegation(k, item, kind, in_pkg, subject, underlying, symbol)
		return
	}
	errorf(
		k.c,
		item.span,
		"L0420",
		"`%s` is not defined for `%s`",
		symbol,
		type_name(k.c, underlying),
	)
}

@(private = "file")
builtin_delegation_applies :: proc(k: ^Checker, symbol: string, underlying: Type_Id) -> bool {
	op := operator_token(symbol)
	if op == .EOF {
		return false
	}
	return builtin_unary_defined(k, op, underlying) || op != .Not && builtin_delegation_applies_binary(k, op, underlying)
}

// design.md: the overload found for the underlying type, with the distinct type
// substituted for it in every operand and result position. A result of another
// type (a comparison's `bool`, an element type) and a parameter that was never
// the underlying type both pass through unchanged.
@(private = "file")
register_forwarded_operator :: proc(
	k: ^Checker,
	item: ^Item_Delegate,
	kind: Impl_Kind,
	in_pkg: Package_Id,
	subject, underlying: Type_Id,
	symbol: string,
	target: Symbol_Id,
) {
	source := symbol_of(k.c, target)
	shape := source == nil ? nil : type_of(k.c, source.proc_type)
	if shape == nil {
		return
	}
	substitute :: proc(type, underlying, subject: Type_Id) -> Type_Id {
		return type == underlying ? subject : type
	}
	params := make([]Type_Id, len(source.params), k.c.semantic_allocator)
	for type, index in source.params {
		params[index] = substitute(type, underlying, subject)
	}
	result := source.result == INVALID_TYPE ? INVALID_TYPE : substitute(source.result, underlying, subject)
	modes := make([]Param_Mode, len(params), k.c.semantic_allocator)
	copy(modes, shape.param_modes)
	install_delegated_operator(k, item, kind, in_pkg, subject, underlying, symbol, params, modes, result, shape.result_inout, target)
}

// The built-in operation has no symbol to forward to: homogeneous overloads
// over the distinct type, one for each arity the underlying type defines the
// operator at. `-`, `+`, and `~` are both unary and binary on a number, so
// `delegate(-)` gives negation as well as subtraction; `!` is unary only.
@(private = "file")
register_builtin_delegation :: proc(
	k: ^Checker, item: ^Item_Delegate, kind: Impl_Kind, in_pkg: Package_Id, subject, underlying: Type_Id, symbol: string,
) {
	op := operator_token(symbol)
	if builtin_unary_defined(k, op, underlying) {
		register_builtin_arity(k, item, kind, in_pkg, subject, underlying, symbol, 1)
	}
	if op != .Not && builtin_delegation_applies_binary(k, op, underlying) {
		register_builtin_arity(k, item, kind, in_pkg, subject, underlying, symbol, 2)
	}
}

@(private = "file")
builtin_delegation_applies_binary :: proc(k: ^Checker, op: Token_Kind, underlying: Type_Id) -> bool {
	#partial switch op {
	case .Eq_Eq, .Not_Eq:
		return type_is_comparable(k.c, underlying)
	case .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		return type_is_ordered(k.c, underlying)
	}
	return builtin_operator_applies(k.c, op, underlying)
}

@(private = "file")
register_builtin_arity :: proc(
	k: ^Checker, item: ^Item_Delegate, kind: Impl_Kind, in_pkg: Package_Id, subject, underlying: Type_Id, symbol: string, arity: int,
) {
	op := operator_token(symbol)
	params := make([]Type_Id, arity, k.c.semantic_allocator)
	modes := make([]Param_Mode, len(params), k.c.semantic_allocator)
	for index in 0 ..< len(params) {
		params[index] = subject
	}
	result := subject
	#partial switch op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		result = TYPE_BOOL
	}
	install_delegated_operator(k, item, kind, in_pkg, subject, underlying, symbol, params, modes, result, false, INVALID_SYMBOL)
}

// The generated overload is a compiler-owned symbol, not source — no body; the
// backend either applies the built-in operation to the unwrapped operands or
// calls the underlying type's own overload.
@(private = "file")
install_delegated_operator :: proc(
	k: ^Checker,
	item: ^Item_Delegate,
	kind: Impl_Kind,
	in_pkg: Package_Id,
	subject, underlying: Type_Id,
	symbol: string,
	params: []Type_Id,
	modes: []Param_Mode,
	result: Type_Id,
	inout: bool,
	target: Symbol_Id,
) {
	id := new_symbol(k.c, Symbol {
		name       = intern_identifier(k.c, fmt.aprintf("delegate%s", symbol, allocator = k.c.semantic_allocator)),
		span       = item.span,
		kind       = .Proc,
		operator   = symbol,
		owner_type = subject,
		pkg        = k.pkg,
		lookup_pkg = k.pkg,
		public     = delegation_is_public(k),
		params     = params,
		result     = result,
		result_inout = inout,
		proc_type  = intern_proc_type(k.c, params, modes, result, inout, ""),
		delegated  = true,
		delegate_underlying = underlying,
		delegate_target = target,
	})
	install_impl_members(k, kind, subject, {id}, in_pkg)
}

// The binary operator a compound assignment applies, or `.EOF` when the kind
// isn't one. The parser recognizes a compound assignment by this answer and the
// checker rejects non-compound statements with it, so the syntax and the
// lowering share one table, and by the time the evaluator or backend asks, the
// result is always one of the fourteen.
compound_operator :: proc(op: Token_Kind) -> Token_Kind {
	#partial switch op {
	case .Plus_Eq:         return .Plus
	case .Minus_Eq:        return .Minus
	case .Star_Eq:         return .Star
	case .Plus_Wrap_Eq:    return .Plus_Wrap
	case .Minus_Wrap_Eq:   return .Minus_Wrap
	case .Star_Wrap_Eq:    return .Star_Wrap
	case .Slash_Eq:        return .Slash
	case .Percent_Eq:      return .Percent
	case .Pipe_Eq:         return .Pipe
	case .Tilde_Eq:        return .Tilde
	case .Amp_Eq:          return .Amp
	case .Amp_Tilde_Eq:    return .Amp_Tilde
	case .Shl_Eq:          return .Shl
	case .Shr_Eq:          return .Shr
	}
	return .EOF
}

// The token a canonical operator symbol stands for, or `.EOF` for the index
// forms, which have no single token.
operator_token :: proc(symbol: string) -> Token_Kind {
	switch symbol {
	case "+":
		return .Plus
	case "-":
		return .Minus
	case "*":
		return .Star
	case "+%":
		return .Plus_Wrap
	case "-%":
		return .Minus_Wrap
	case "*%":
		return .Star_Wrap
	case "/":
		return .Slash
	case "%":
		return .Percent
	case "|":
		return .Pipe
	case "~":
		return .Tilde
	case "&":
		return .Amp
	case "&~":
		return .Amp_Tilde
	case "<<":
		return .Shl
	case ">>":
		return .Shr
	case "==":
		return .Eq_Eq
	case "!=":
		return .Not_Eq
	case "<":
		return .Lt
	case "<=":
		return .Lt_Eq
	case ">":
		return .Gt
	case ">=":
		return .Gt_Eq
	case "!":
		return .Not
	}
	return .EOF
}
