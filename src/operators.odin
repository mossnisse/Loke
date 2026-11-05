// User operator declarations, lookup, and delegation, and which types compare.
// Ranking is shared with named overloads in overload.odin.
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

// design.md "Operator declarations".
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
	case ^Expr_Proc_Group:
		symbol.kind = .Proc_Group
		resolve_group_members(k, symbol_id, inner)
	}
	symbol = symbol_of(k.c, symbol_id)
	apply_proc_metadata(k, d, symbol_id)

	shape, overloadable := declared_operator_shape(k, value)
	if !overloadable {
		return
	}
	validate_operator_shape(k, value, shape, symbol_id)
	for member in symbol.members {
		validate_operator_shape(k, value, shape, member)
	}

	join_package_operators(k, value.symbol, symbol_id)
}

// The operator a generic template declares, recorded as
// `resolve_operator_declaration` records a concrete one, so lookup finds it
// before it is instantiated. Each instance's shape is checked when it is made.
mark_template_operator :: proc(k: ^Checker, d: ^Decl) {
	if d.kind != .Const || len(d.values) != 1 {
		return
	}
	value, is_operator := d.values[0].(^Expr_Operator)
	if !is_operator || value.hook != .None {
		return
	}
	literal, is_proc := value.value.(^Expr_Proc)
	if !is_proc {
		return
	}
	shape, overloadable := declared_operator_shape(k, value)
	if !overloadable {
		return
	}
	// The arity is in the syntax; the parameter types wait for an instance.
	if !check_operator_arity(k, value, shape, template_parameter_count(literal)) {
		return
	}
	for parameter in literal.signature.params {
		for entry in parameter.names {
			if entry.is_poly {
				errorf(
					k.c, entry.name.span, "L0416",
					"`operator(%s)` takes its operands at run time, so `$%s` cannot be one",
					value.symbol, entry.name.text,
				)
				return
			}
		}
	}
	if sym := symbol_of(k.c, d.symbols[0]); sym != nil {
		sym.operator = value.symbol
		join_package_operators(k, value.symbol, d.symbols[0])
	}
}

// What an instance of a generic operator must still answer: the template's
// syntax already settled the arity.
validate_operator_instance :: proc(k: ^Checker, d: ^Decl, symbol_id: Symbol_Id) {
	value := d.values[0].(^Expr_Operator)
	if shape, overloadable := operator_shape(value.symbol); overloadable {
		validate_operator_signature(k, value, shape, symbol_id)
	}
}

@(private = "file")
declared_operator_shape :: proc(k: ^Checker, value: ^Expr_Operator) -> (Operator_Shape, bool) {
	shape, overloadable := operator_shape(value.symbol)
	if !overloadable {
		errorf(k.c, value.symbol_span, "L0416", "`%s` is not an overloadable operator", value.symbol)
	}
	return shape, overloadable
}

// A parameter group counts each of its names; an unnamed parameter counts once.
@(private = "file")
template_parameter_count :: proc(literal: ^Expr_Proc) -> int {
	count := 0
	for parameter in literal.signature.params {
		count += max(len(parameter.names), 1)
	}
	return count
}

// Every operator declaration outside a procedure also joins its package's set,
// which is what an extension block and a file-scope declaration are found
// through. A local one is found through its scope.
@(private = "file")
join_package_operators :: proc(k: ^Checker, symbol: string, symbol_id: Symbol_Id) {
	if in_local_scope(k.scope) {
		k.scope.declares_operator = true
		return
	}
	pkg := package_of(k.c, k.pkg)
	set := pkg.operators[symbol]
	if set == nil {
		set = make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	}
	append_unique(&set, symbol_id)
	pkg.operators[symbol] = set
}

@(private = "file")
validate_operator_shape :: proc(k: ^Checker, value: ^Expr_Operator, shape: Operator_Shape, symbol_id: Symbol_Id) {
	sym := symbol_of(k.c, symbol_id)
	if sym != nil && sym.kind == .Proc && check_operator_arity(k, value, shape, len(sym.params)) {
		validate_operator_signature(k, value, shape, symbol_id)
	}
}

@(private = "file")
check_operator_arity :: proc(k: ^Checker, value: ^Expr_Operator, shape: Operator_Shape, count: int) -> bool {
	if count >= shape.min && (shape.max < 0 || count <= shape.max) {
		return true
	}
	errorf(k.c, value.symbol_span, "L0416", "`operator(%s)` takes %s, found %d", value.symbol, arity_text(shape), count)
	return false
}

@(private = "file")
validate_operator_signature :: proc(k: ^Checker, value: ^Expr_Operator, shape: Operator_Shape, symbol_id: Symbol_Id) {
	sym := symbol_of(k.c, symbol_id)
	info := type_of(k.c, sym.proc_type)
	if variadic_parameter_index(info) >= 0 {
		errorf(k.c, value.symbol_span, "L0416", "`operator(%s)` cannot have a variadic parameter", value.symbol)
		return
	}
	if (sym.result == INVALID_TYPE ? 0 : 1) != shape.results {
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
	if shape.boolean && !type_is_boolean(k.c, sym.result) {
		errorf(k.c, value.symbol_span, "L0416", "`operator(%s)` produces `bool`", value.symbol)
		return
	}
	if shape.assign && proc_parameter_mode(k.c, sym.proc_type, 0) != .Inout {
		errorf(k.c, value.symbol_span, "L0416", "`operator(%s)` takes its destination as `inout`", value.symbol)
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
	settle_pending_operators(k)
	for operand in operands {
		settle_delegates(k, operand)
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
		if !scope.declares_operator {
			continue
		}
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
// question like "does it hand out a location?" must check the receiver alone. A
// template answers through its instance over the receiver, or stands for itself
// while an index type is still to be inferred.
operator_candidates_for_receiver :: proc(k: ^Checker, symbol: string, receiver: Type_Id) -> []Symbol_Id {
	all := operator_candidates(k, symbol, []Type_Id{receiver})
	out := make([dynamic]Symbol_Id, 0, len(all), k.c.semantic_allocator)
	for candidate in all {
		sym := symbol_of(k.c, candidate)
		if sym == nil {
			continue
		}
		if sym.generic {
			if overload := template_overload_for_receiver(k, candidate, receiver); overload != INVALID_SYMBOL {
				append(&out, overload)
			}
		} else if len(sym.params) > 0 && sym.params[0] == receiver {
			append(&out, candidate)
		}
	}
	return out[:]
}

@(private = "file")
template_overload_for_receiver :: proc(k: ^Checker, id: Symbol_Id, receiver: Type_Id) -> Symbol_Id {
	template := generic_template_for(k, id)
	inference := infer_generic_arguments(k, template, template_arguments(k, template, receiver, 0))
	if inference.unbound_wait {
		return id
	}
	if !inference.ok {
		return INVALID_SYMBOL
	}
	instance, made := instantiate_generic(k, template, inference.bindings, inference.scope, NO_SPAN, report = false)
	return made ? instance.symbol : id
}

// Arguments for inference over a template: `type` at `position`, or at every
// position when that is negative, and the rest waiting for what those bind.
@(private = "file")
template_arguments :: proc(k: ^Checker, template: ^Generic_Template, type: Type_Id, position: int) -> []Arg_Info {
	args := make([]Arg_Info, template_parameter_count(decl_proc_literal(template.decl)), k.c.semantic_allocator)
	for &arg, index in args {
		arg.name = INVALID_IDENTIFIER
		if position < 0 || index == position {
			arg.type = type
		} else {
			arg.waiting = true
		}
	}
	return args
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
			if sym == nil || sym.operator != symbol || member_is_visible(k, sym) {
				continue
			}
			if sym.kind != .Proc_Group {
				if overload_is_exactly(sym, operands) {
					return true
				}
				continue
			}
			for nested in sym.members {
				if inner := symbol_of(k.c, nested); inner != nil && overload_is_exactly(inner, operands) {
					return true
				}
			}
		}
	}
	return false
}

// A `delegate` forwards to the underlying type's operator, which is what the
// built-in table reaches for a `distinct` anyway. Nothing is being substituted,
// so nothing is worth reporting.
@(private = "file")
overload_is_exactly :: proc(sym: ^Symbol, operands: []Type_Id) -> bool {
	return !sym.bound_excluded && !sym.delegated && slice.equal(sym.params, operands)
}

@(private = "file")
append_unique :: proc(out: ^[dynamic]Symbol_Id, id: Symbol_Id) {
	if !slice.contains(out[:], id) {
		append(out, id)
	}
}

// The procedure a type's own `symbol_text` operator runs over two of its
// values, and the declaration naming it: that procedure, or the group it is a
// member of (design.md "Explicit procedure overloading"), which is what
// visibility asks about. A delegated operator is returned as itself.
inherent_self_operator :: proc(c: ^Compiler, type: Type_Id, symbol_text: string) -> (callable, declared: Symbol_Id) {
	info := type_of(c, type)
	if info == nil {
		return INVALID_SYMBOL, INVALID_SYMBOL
	}
	for member in info.members {
		sym := symbol_of(c, member)
		if sym == nil || sym.operator != symbol_text {
			continue
		}
		if sym.kind != .Proc_Group {
			if operator_on_self(sym, type) {
				return member, member
			}
			continue
		}
		for nested in sym.members {
			if inner := symbol_of(c, nested); inner != nil && operator_on_self(inner, type) {
				return nested, member
			}
		}
	}
	return INVALID_SYMBOL, INVALID_SYMBOL
}

// A binary operator over two values of `type`, the one a sort or a map key
// uses; `(a: T, b: int)` is a different operation.
@(private = "file")
operator_on_self :: proc(sym: ^Symbol, type: Type_Id) -> bool {
	return !sym.bound_excluded && len(sym.params) == 2 && sym.params[0] == type && sym.params[1] == type
}

// -------------------------------------------------- the built-in priority --

// A distinct type never participates in unshadowable built-in operations, and an
// enum may declare its own `==`. An anonymous record or union belongs to no
// package, so it is a built-in type for this rule (design.md "Operator lookup
// and overload resolution").
operand_is_builtin :: proc(k: ^Checker, type: Type_Id) -> bool {
	#partial switch type_kind(k.c, type) {
	case .Struct, .Union:
		info := type_of(k.c, type)
		return info != nil && (info.anonymous_record || info.anonymous_union)
	case .Distinct, .Enum, .Interface, .Dyn, .Invalid:
		return false
	}
	return true
}

builtin_binary_defined :: proc(k: ^Checker, op: Token_Kind, lhs, rhs: Type_Id) -> bool {
	if !operand_is_builtin(k, lhs) || !operand_is_builtin(k, rhs) {
		return false
	}
	if simd_operand(k.c, lhs) || simd_operand(k.c, rhs) {
		vector, other := lhs, rhs
		if !simd_operand(k.c, lhs) {
			vector, other = rhs, lhs
		}
		return simd_operand_is_builtin(k.c, vector, other) && simd_operator_applies(k.c, op, type_of(k.c, vector).element)
	}
	if op == .Shl || op == .Shr {
		if !builtin_operator_applies(k.c, op, lhs) {
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
	if simd_operand(k.c, operand) {
		return simd_unary_applies(k.c, op, type_of(k.c, operand).element)
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

// The built-in operator table, asked as a predicate so the unshadowable
// built-in rule can be decided before any user lookup.
builtin_operator_applies :: proc(c: ^Compiler, op: Token_Kind, type: Type_Id) -> bool {
	if type_kind(c, type) == .Distinct {
		return false
	}
	if simd_operand(c, type) {
		return simd_operator_applies(c, op, type_of(c, type).element)
	}
	#partial switch op {
	case .Plus:
		return type_is_numeric(c, type) || operator_concatenates(c, type)
	case .Minus, .Star, .Slash:
		return type_is_numeric(c, type)
	case .Plus_Wrap, .Minus_Wrap, .Star_Wrap:
		// design.md "Integer overflow": the wrapping operators are for integers.
		return type_is_integer(c, type)
	case .Percent, .Amp, .Pipe, .Tilde, .Amp_Tilde, .Shl, .Shr:
		return type_is_integer(c, type) || type_is_rune(c, type)
	}
	return false
}

// `a op= b`: the same table without concatenation.
compound_applies :: proc(c: ^Compiler, op: Token_Kind, type: Type_Id) -> bool {
	return !operator_concatenates(c, type) && builtin_operator_applies(c, op, type)
}

// design.md "Arithmetic operators": two `string`/`string_view` operands in either
// order produce an owning `string`.
@(private = "file")
operator_concatenates :: proc(c: ^Compiler, type: Type_Id) -> bool {
	#partial switch underlying_kind(c, type) {
	case .String, .String_View:
		return true
	}
	return type_kind(c, type) == .Untyped_String
}

// ------------------------------------------------------------- resolution --

// One operator's visible candidates, formed once against one argument list,
// so a fallback choice and the ranking after it share them.
Operator_Set :: struct {
	symbol:  string,
	members: []Symbol_Id,
	formed:  []Candidate,
}

form_operator_set :: proc(k: ^Checker, symbol: string, operands: []Type_Id, args: []Arg_Info) -> Operator_Set {
	members := operator_candidates(k, symbol, operands)
	return Operator_Set{symbol = symbol, members = members, formed = form_candidates(k, members, args)}
}

resolve_operator :: proc(k: ^Checker, span: Span, symbol: string, members: []Symbol_Id, args: []Arg_Info) -> (Symbol_Id, []Expr) {
	return resolve_operator_set(k, span, Operator_Set{symbol = symbol, members = members, formed = form_candidates(k, members, args)}, args)
}

resolve_operator_set :: proc(k: ^Checker, span: Span, set: Operator_Set, args: []Arg_Info) -> (Symbol_Id, []Expr) {
	description := fmt.tprintf("operator `%s`", set.symbol)
	cand, resolved := choose_candidate(k, span, description, set.members, set.formed, args)
	if !resolved {
		return INVALID_SYMBOL, nil
	}
	sym := symbol_of(k.c, cand.symbol)
	bound, ok := bind_candidate_slots(k, cand, sym, span)
	if !ok {
		return INVALID_SYMBOL, nil
	}
	warn_deprecated_use(k, sym, identifier_text(k.c, sym.name), span)
	promote_operator_instance(k, cand.symbol, span)
	return cand.symbol, bound
}

// A candidate chosen as a template is promoted by the ranking; an instance that
// stood in for one, or that a `delegate` forwards to, is not.
@(private = "file")
promote_operator_instance :: proc(k: ^Checker, operator: Symbol_Id, span: Span) {
	end, _ := operator_delegate_end(k.c, operator)
	if instance, found := k.c.procedure_instances[end]; found {
		promote_generic_instance(k, instance, span)
	}
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

// An operator is found by its symbol and operands, not by a name that could wait
// on its declaration, and both are known only once its signature is. So a package's
// operators resolve ahead of its other signatures, and of any lookup those make,
// wherever they are written. Nothing can load any more, so an `impl` subject that
// does not resolve now is an error.
//
// A signature or a block's subject can itself need an operator, as `[N]int` does where
// `N :: a + b`, so nothing is resolved until all of these are queued, and a lookup
// finishes what is still pending, wherever the operator it needs is written.
resolve_package_operators :: proc(k: ^Checker, pkg: ^Package) {
	saved := k.location
	defer k.location = saved
	for file in pkg.files {
		k.file, k.file_node, k.scope = file.file, file, pkg.scope
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				defer_if_operator(k, v)
			case ^Item_Impl:
				append(&k.c.pending_operator_blocks, Pending_Operator_Block{v, k.location})
			}
		}
	}
	settle_pending_operators(k)
}

// An operator whose signature has yet to resolve, and where it is written.
Pending_Operator :: struct {
	decl:     ^Decl,
	location: Checker_Location,
}

// A block yet to be declared, and where it is written.
Pending_Operator_Block :: struct {
	item:     ^Item_Impl,
	location: Checker_Location,
}

@(private = "file")
defer_if_operator :: proc(k: ^Checker, d: ^Decl) {
	if value, is_operator := decl_value(d).(^Expr_Operator); is_operator && value.hook == .None {
		append(&k.c.pending_operators, Pending_Operator{d, k.location})
	}
}

// Resolves what is pending, from wherever a lookup asked. A signature already being
// resolved below this call returns at once and finishes there. All of these are
// declared at file scope, so a probe that led here does not take them with it.
@(private = "file")
settle_pending_operators :: proc(k: ^Checker) {
	c := k.c
	if c.next_pending_operator_block == len(c.pending_operator_blocks) && c.next_pending_operator == len(c.pending_operators) {
		return
	}
	saved := k.location
	settling := begin_settling_file_scope(c)
	defer {
		end_settling(c, settling)
		k.location = saved
	}
	for c.next_pending_operator_block < len(c.pending_operator_blocks) {
		entry := c.pending_operator_blocks[c.next_pending_operator_block]
		c.next_pending_operator_block += 1
		k.location = entry.location
		declare_impl_block(k, entry.item, quiet = false)
		if entry.item.subject == INVALID_TYPE {
			continue
		}
		k.impl_type = entry.item.subject
		for member in entry.item.members {
			if d, is_decl := member.(^Decl); is_decl {
				defer_if_operator(k, d)
			}
		}
	}
	for c.next_pending_operator < len(c.pending_operators) {
		entry := c.pending_operators[c.next_pending_operator]
		c.next_pending_operator += 1
		k.location = entry.location
		resolve_declaration_signature(k, entry.decl)
	}
}

// ----------------------------------------------------------------- delegate --

// A declared block whose `delegate` items have yet to run, and where it is written.
Pending_Delegate :: struct {
	item:     ^Item_Impl,
	location: Checker_Location,
}

@(private)
defer_delegates :: proc(k: ^Checker, item: ^Item_Impl) {
	for member in item.members {
		if _, is_delegate := member.(^Item_Delegate); is_delegate {
			pending, found := &k.c.pending_delegates[item.subject]
			if !found {
				_, pending, _, _ = map_entry(&k.c.pending_delegates, item.subject)
				pending^ = make([dynamic]Pending_Delegate, 0, 1, k.c.semantic_allocator)
			}
			append(pending, Pending_Delegate{item, k.location})
			return
		}
	}
}

// design.md "Delegating operators": runs what `delegate` still owes `type`. A
// package's declarations are order-independent, so this waits for the operators
// it forwards (`resolve_package_operators`), and looking up an operator of the
// underlying type runs that type's own first, which settles a chain of distinct
// types from its end. A body-local block belongs to the check of its body, so a
// probe leaves one to the block; a probe that reaches a file-scope one settles it.
settle_delegates :: proc(k: ^Checker, type: Type_Id) {
	pending, found := k.c.pending_delegates[type]
	if !found {
		return
	}
	if !committing(k.c) {
		for entry in pending {
			if in_local_scope(entry.location.scope) {
				return
			}
		}
	}
	delete_key(&k.c.pending_delegates, type)
	saved := k.location
	settling := begin_settling_file_scope(k.c)
	defer {
		end_settling(k.c, settling)
		k.location = saved
	}
	for entry in pending {
		k.location = entry.location
		k.impl_type = type
		for member in entry.item.members {
			if delegate, is_delegate := member.(^Item_Delegate); is_delegate {
				check_delegate(k, delegate, type, entry.item.kind, k.pkg)
			}
		}
	}
}

// What an operator runs in the end: the first symbol of its delegate chain that
// does not itself delegate, or `builtin` when a delegate with no target forwards
// to the built-in operation. Neither for no operator at all.
operator_delegate_end :: proc(c: ^Compiler, operator: Symbol_Id) -> (end: Symbol_Id, builtin: bool) {
	current := operator
	for _ in 0 ..< len(c.symbols) + 1 {
		sym := symbol_of(c, current)
		if sym == nil {
			break
		}
		if !sym.delegated {
			return current, false
		}
		if sym.delegate_target == INVALID_SYMBOL {
			return INVALID_SYMBOL, true
		}
		current = sym.delegate_target
	}
	return INVALID_SYMBOL, false
}

// One symbol of a `delegate` item, and what every overload it generates shares.
@(private = "file")
Delegation :: struct {
	k:                   ^Checker,
	item:                ^Item_Delegate,
	kind:                Impl_Kind,
	in_pkg:              Package_Id,
	subject, underlying: Type_Id,
	symbol:              string,
}

// design.md "Delegating operators". The overloads go where the block's other
// members do, per `kind`; an extension's in `in_pkg`, whose lookup alone sees
// them (design.md "Methods and implementation blocks").
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
	for symbol in item.symbols {
		delegate_one(Delegation{k, item, kind, in_pkg, subject, info.element, symbol})
	}
}

@(private = "file")
delegate_one :: proc(d: Delegation) {
	k := d.k
	if _, overloadable := operator_shape(d.symbol); !overloadable {
		errorf(k.c, d.item.span, "L0416", "`%s` is not an overloadable operator", d.symbol)
		return
	}
	for candidate in delegation_neighbours(d) {
		sym := symbol_of(k.c, candidate)
		if sym.owner_type == d.subject || (len(sym.params) > 0 && sym.params[0] == d.subject) {
			errorf(k.c, d.item.span, "L0420", "`%s` is already declared for `%s`", d.symbol, type_name(k.c, d.subject))
			return
		}
	}
	delegated := delegate_builtin(d)
	// Each keeps its own signature, so `[]` forwards its index parameter unchanged.
	for target in operator_overloads_mentioning(d) {
		if !overload_is_shadowed(k, d.symbol, target) {
			delegate_overload(d, target)
			delegated = true
		}
	}
	if !delegated {
		errorf(k.c, d.item.span, "L0420", "`%s` is not defined for `%s`", d.symbol, type_name(k.c, d.underlying))
	}
}

// The concrete overloads lookup finds for the distinct type.
@(private = "file")
delegation_neighbours :: proc(d: Delegation) -> []Symbol_Id {
	out := make([dynamic]Symbol_Id, 0, 4, d.k.c.semantic_allocator)
	for candidate in operator_candidates(d.k, d.symbol, []Type_Id{d.subject}) {
		if sym := symbol_of(d.k.c, candidate); sym != nil && !sym.generic {
			append(&out, candidate)
		}
	}
	return out[:]
}

// The overloads of the symbol with the underlying type among their operands, in
// any position: `in` takes its container second, and `f64 * V` its vector second.
@(private = "file")
operator_overloads_mentioning :: proc(d: Delegation) -> []Symbol_Id {
	k := d.k
	out := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	for candidate in operator_candidates(k, d.symbol, []Type_Id{d.underlying}) {
		id := candidate
		sym := symbol_of(k.c, id)
		if sym != nil && sym.generic {
			id = template_instance_over(d, id)
			sym = symbol_of(k.c, id)
		}
		if sym != nil && slice.contains(sym.params, d.underlying) {
			append(&out, id)
		}
	}
	return out[:]
}

// A template's instance over the underlying type, with every parameter that type
// or else one parameter's pattern binding the rest. A bare `$T` takes anything,
// so it is no evidence: `proc(item: $T, bag: Bag($T))` is an operator on bags.
@(private = "file")
template_instance_over :: proc(d: Delegation, id: Symbol_Id) -> Symbol_Id {
	k := d.k
	template := generic_template_for(k, id)
	if instance := template_instance_at(d, template, -1); instance != INVALID_SYMBOL {
		return instance
	}
	position := 0
	for parameter in decl_proc_literal(template.decl).signature.params {
		_, bare := parameter.type.(^Type_Poly)
		for _ in 0 ..< max(len(parameter.names), 1) {
			if !bare {
				if instance := template_instance_at(d, template, position); instance != INVALID_SYMBOL {
					return instance
				}
			}
			position += 1
		}
	}
	return INVALID_SYMBOL
}

@(private = "file")
template_instance_at :: proc(d: Delegation, template: ^Generic_Template, position: int) -> Symbol_Id {
	k := d.k
	inference := infer_generic_arguments(k, template, template_arguments(k, template, d.underlying, position))
	if !inference.ok {
		return INVALID_SYMBOL
	}
	instance, made := instantiate_generic(k, template, inference.bindings, inference.scope, NO_SPAN, report = false)
	if !made || !slice.contains(symbol_of(k.c, instance.symbol).params, d.underlying) {
		return INVALID_SYMBOL
	}
	return instance.symbol
}

// Whether the built-in operation takes these operands, so this overload never runs.
@(private = "file")
overload_is_shadowed :: proc(k: ^Checker, symbol: string, target: Symbol_Id) -> bool {
	op := operator_token(symbol)
	params := symbol_of(k.c, target).params
	switch len(params) {
	case 1:
		return builtin_unary_defined(k, op, params[0])
	case 2:
		return builtin_binary_defined(k, op, params[0], params[1])
	}
	return false
}

// design.md "Delegating operators".
@(private = "file")
delegate_overload :: proc(d: Delegation, target: Symbol_Id) {
	source := symbol_of(d.k.c, target)
	shape := type_of(d.k.c, source.proc_type)
	promote_operator_instance(d.k, target, d.item.span)
	substitute :: proc(type, underlying, subject: Type_Id) -> Type_Id {
		return type == underlying ? subject : type
	}
	params := make([]Type_Id, len(source.params), d.k.c.semantic_allocator)
	for type, index in source.params {
		params[index] = substitute(type, d.underlying, d.subject)
	}
	// `Time + Duration` written by hand beside `Time + i64` stands for this one.
	for neighbour in delegation_neighbours(d) {
		written := symbol_of(d.k.c, neighbour)
		if !written.delegated && slice.equal(written.params, params) {
			return
		}
	}
	result := substitute(source.result, d.underlying, d.subject)
	install_delegated_operator(d, params, shape.param_modes, source.param_defaults, result, shape.result_inout, target)
}

// The built-in operation has no symbol to forward to: homogeneous overloads over
// the distinct type, one for each arity the underlying type defines the operator
// at. Reports whether it defines any.
@(private = "file")
delegate_builtin :: proc(d: Delegation) -> bool {
	k := d.k
	op := operator_token(d.symbol)
	unary := builtin_unary_defined(k, op, d.underlying)
	binary := builtin_binary_defined(k, op, d.underlying, d.underlying)
	if unary {
		install_builtin_arity(d, 1, d.subject)
	}
	if binary {
		install_builtin_arity(d, 2, builtin_delegation_result(d, op))
	}
	return unary || binary
}

// What the built-in binary operation produces, with the distinct type for the
// underlying one: a comparison's mask or `bool`, and a `string_view`
// concatenation's `string`, are of another type and pass through.
@(private = "file")
builtin_delegation_result :: proc(d: Delegation, op: Token_Kind) -> Type_Id {
	c := d.k.c
	#partial switch op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		if simd_operand(c, d.underlying) {
			return simd_of(c, TYPE_BOOL, type_of(c, d.underlying).count)
		}
		return TYPE_BOOL
	case .Plus:
		if underlying_kind(c, d.underlying) == .String_View {
			return TYPE_STRING
		}
	}
	return d.subject
}

@(private = "file")
install_builtin_arity :: proc(d: Delegation, arity: int, result: Type_Id) {
	params := make([]Type_Id, arity, d.k.c.semantic_allocator)
	modes := make([]Param_Mode, arity, d.k.c.semantic_allocator)
	for &param in params {
		param = d.subject
	}
	install_delegated_operator(d, params, modes, nil, result, false, INVALID_SYMBOL)
}

// The generated overload is a compiler-owned symbol, not source: no body. The
// backend either applies the built-in operation to the unwrapped operands or
// calls the underlying type's own overload.
@(private = "file")
install_delegated_operator :: proc(
	d: Delegation, params: []Type_Id, modes: []Param_Mode, defaults: []Expr, result: Type_Id, inout: bool, target: Symbol_Id,
) {
	k := d.k
	id := new_symbol(k.c, Symbol {
		name       = intern_identifier(k.c, fmt.tprintf("delegate%s", d.symbol)),
		span       = d.item.span,
		kind       = .Proc,
		operator   = d.symbol,
		owner_type = d.subject,
		pkg        = k.pkg,
		lookup_pkg = k.pkg,
		public     = delegation_is_public(k),
		params     = params,
		param_defaults = defaults,
		result     = result,
		result_inout = inout,
		proc_type  = intern_proc_type(k.c, params, modes, result, inout, ""),
		delegated  = true,
		delegate_underlying = d.underlying,
		delegate_target = target,
	})
	install_impl_members(k, d.kind, d.subject, {id}, d.in_pkg)
}

// ------------------------------------------- comparability and ordering --

// design.md "Comparison operators". Aggregates are comparable when every leaf
// is; that recursion is what the backend then generates.
type_is_comparable :: proc(c: ^Compiler, id: Type_Id) -> bool {
	seen: Type_Walk
	defer delete(seen)
	return type_is_comparable_walk(c, id, &seen)
}

@(private = "file")
type_is_comparable_walk :: proc(c: ^Compiler, id: Type_Id, seen: ^Type_Walk) -> bool {
	// design.md "Comparison operators": a type's own `==` makes it comparable,
	// whatever its fields are.
	if type_own_equality(c, id) != INVALID_SYMBOL {
		return true
	}
	under := type_underlying(c, id)
	info := type_of(c, under)
	if info == nil {
		return false
	}
	if !type_walk_enter(seen, under, info) {
		return true
	}
	#partial switch info.kind {
	case .Bool, .Int, .Float, .Rune, .Raw_Pointer, .Pointer, .C_Pointer, .Proc, .Enum,
	     .Untyped_Int, .Untyped_Float, .Untyped_Bool, .Untyped_Rune, .Untyped_Nil,
	     .Untyped_String:
		return true
	// A payloadless union variant carries `void`, and two of them are equal when
	// their tags are.
	case .Void:
		return true
	// `string` and `string_view` values are comparable and ordered, lexically
	// byte-wise (design.md). A `cstring_view` is not: it promises no encoding and
	// carries no length, so comparing two of them would compare addresses.
	case .String, .String_View:
		return true
	// design.md "Allocation failure": an error code compares with its zero, no
	// failure. An `Allocator` handle is comparable for the same reason a pointer
	// is.
	case .Allocator, .Allocator_Error:
		return true
	// design.md: two `type` values support `==` and `!=` during compilation, and
	// `typeid` is an ordinary runtime scalar. Neither has an ordering.
	case .Type, .Typeid:
		return true
	case .Array:
		return type_is_comparable_walk(c, info.element, seen)
	case .Struct:
		// design.md "Capture literals": a callable is called, not compared.
		if type_is_capture_record(c, under) {
			return false
		}
		for field in info.fields {
			symbol := symbol_of(c, field)
			if symbol == nil || !type_is_comparable_walk(c, symbol.type, seen) {
				return false
			}
		}
		return true
	case .Union:
		// Comparable against another value of the same union when every variant is
		// itself comparable.
		for variant in info.variants {
			if !type_is_comparable_walk(c, variant, seen) {
				return false
			}
		}
		return true
	}
	return false
}

// design.md "Comparison operators": the `==` a type declares for itself, or a
// distinct type's underlying type does. A value of the type compares by it
// wherever it is nested, as a map key does.
type_own_equality :: proc(c: ^Compiler, type: Type_Id) -> Symbol_Id {
	callable, _ := own_equality(c, type)
	return callable
}

// `declared` is the declaration the procedure belongs to, the group when it is in
// one: what `@(public)` is written on, so what visibility asks.
own_equality :: proc(c: ^Compiler, type: Type_Id) -> (callable, declared: Symbol_Id) {
	if callable, declared = inherent_equality(c, type); callable != INVALID_SYMBOL {
		return
	}
	return inherent_equality(c, type_underlying(c, type))
}

// Every type within `type`, itself included, that compares by its own `==`;
// structural comparison does not look inside one.
own_equalities_within :: proc(c: ^Compiler, type: Type_Id, out: ^[dynamic]Type_Id) {
	seen: Type_Walk
	defer delete(seen)
	own_equalities_walk(c, type, out, &seen, false)
}

// Those a comparison or hash of a value of `type` calls: a zero-length array has
// no element (design.md "Global write effects"), though comparing one still
// requires of its element what `own_equalities_within` says.
own_equalities_called :: proc(c: ^Compiler, type: Type_Id, out: ^[dynamic]Type_Id) {
	seen: Type_Walk
	defer delete(seen)
	own_equalities_walk(c, type, out, &seen, true)
}

@(private = "file")
own_equalities_walk :: proc(c: ^Compiler, type: Type_Id, out: ^[dynamic]Type_Id, seen: ^Type_Walk, called: bool) {
	if type_own_equality(c, type) != INVALID_SYMBOL {
		append(out, type)
		return
	}
	under := type_underlying(c, type)
	info := type_of(c, under)
	if info == nil || !type_walk_enter(seen, under, info) {
		return
	}
	#partial switch info.kind {
	case .Array:
		if !called || info.count > 0 {
			own_equalities_walk(c, info.element, out, seen, called)
		}
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil {
				own_equalities_walk(c, sym.type, out, seen, called)
			}
		}
	case .Union:
		for variant in info.variants {
			own_equalities_walk(c, variant, out, seen, called)
		}
	}
}

// A delegated `==` keeps the underlying type's policy, so it is not one of the
// type's own.
inherent_equality :: proc(c: ^Compiler, type: Type_Id) -> (callable, declared: Symbol_Id) {
	callable, declared = inherent_self_operator(c, type, "==")
	if sym := symbol_of(c, callable); sym == nil || sym.delegated {
		return INVALID_SYMBOL, INVALID_SYMBOL
	}
	return
}

type_is_ordered :: proc(c: ^Compiler, id: Type_Id) -> bool {
	#partial switch underlying_kind(c, id) {
	case .Int, .Float, .Rune, .Enum, .Untyped_Int, .Untyped_Float, .Untyped_Rune,
	     .Untyped_String, .String, .String_View:
		return true
	// Ordering compares the addresses as unsigned `uintptr` values, producing a
	// total order within one execution (design.md).
	case .Pointer, .C_Pointer, .Raw_Pointer:
		return true
	case .Struct:
		seen: Type_Walk
		defer delete(seen)
		return record_is_ordered_walk(c, id, &seen)
	}
	return false
}

// design.md "Comparison operators": an anonymous record is ordered when every
// field is, by the built-in operators. Answers what stops it, as a diagnostic
// note, or "" when nothing does.
record_order_blocker :: proc(c: ^Compiler, id: Type_Id) -> string {
	under := type_underlying(c, id)
	info := type_of(c, under)
	if info == nil || info.kind != .Struct || !info.anonymous_record {
		return ""
	}
	seen: Type_Walk
	defer delete(seen)
	type_walk_enter(&seen, under, info)
	for field, index in info.fields {
		symbol := symbol_of(c, field)
		why := ""
		if type_declares_comparison(c, symbol.type) {
			why = "declares a comparison operator of its own"
		} else if !field_is_ordered(c, symbol.type, &seen) {
			why = "is not ordered"
		} else {
			continue
		}
		which := fmt.tprintf("field `%s`", identifier_text(c, symbol.name))
		if field_is_positional(c, field) {
			position := index + 1
			suffix := "th"
			if position % 100 < 11 || position % 100 > 13 {
				switch position % 10 {
				case 1: suffix = "st"
				case 2: suffix = "nd"
				case 3: suffix = "rd"
				}
			}
			which = fmt.tprintf("%d%s field", position, suffix)
		}
		return fmt.tprintf("its %s is `%s`, which %s", which, type_name(c, symbol.type), why)
	}
	return ""
}

// `seen` holds the records being walked, so one met again is a cycle: a record
// that holds itself by value through a `distinct` type is diagnosed, but still
// reaches body checking. A record met twice side by side is no cycle.
@(private = "file")
record_is_ordered_walk :: proc(c: ^Compiler, id: Type_Id, seen: ^Type_Walk) -> bool {
	under := type_underlying(c, id)
	info := type_of(c, under)
	if info == nil || info.kind != .Struct || !info.anonymous_record || !type_walk_enter(seen, under, info) {
		return false
	}
	defer delete_key(seen, under)
	for field in info.fields {
		type := symbol_of(c, field).type
		if type_declares_comparison(c, type) || !field_is_ordered(c, type, seen) {
			return false
		}
	}
	return true
}

@(private = "file")
field_is_ordered :: proc(c: ^Compiler, type: Type_Id, seen: ^Type_Walk) -> bool {
	if underlying_kind(c, type) == .Struct {
		return record_is_ordered_walk(c, type, seen)
	}
	return type_is_ordered(c, type)
}

// Whether the type declares a comparison operator of its own over two of its
// values. A group declares one when a member does, and a `delegate` does when
// it forwards, however indirectly, to a user operator rather than the built-in
// one (design.md "Delegating operators"). A `distinct` type that delegates
// nothing compares by its underlying built-in operators.
@(private = "file")
type_declares_comparison :: proc(c: ^Compiler, id: Type_Id) -> bool {
	for text in ([6]string{"==", "!=", "<", "<=", ">", ">="}) {
		callable, _ := inherent_self_operator(c, id, text)
		if _, builtin := operator_delegate_end(c, callable); callable != INVALID_SYMBOL && !builtin {
			return true
		}
	}
	return false
}
