// Overload resolution.
//
// One engine, used by named procedure groups, methods, operators, `init`
// construction, and indexing. Operator overloads rank with the same algorithm
// as named ones (design.md) — two implementations would drift, and the
// error-quality bar (list every maximal candidate, its conversion vector, and
// the tie-breaker where selection failed) wants one place that can print it.
//
// The contract fixed here and not reopened by M4b: viability filters first,
// structure orders what survives, and constraints never rank.
package lokec

import "core:slice"
import "core:fmt"
import "core:strings"

// Conversion ranks (design.md "Operator lookup and overload resolution").
RANK_EXACT :: 0 // exact type and parameter-mode match
RANK_ADJUST :: 1 // a capability adjustment that does not create a value
RANK_CONST_KIND :: 2 // an untyped constant converted without changing its kind
RANK_BUILTIN :: 3 // any other built-in implicit conversion
RANK_NONE :: 4 // no conversion at all: the candidate is not viable

// One supplied argument, checked exactly once before any candidate sees it.
// Ranking is a pure predicate over these facts, so asking N candidates cannot
// re-check, re-report, or re-hoist the expression that produced them.
Arg_Info :: struct {
	expr:        Expr,
	span:        Span,
	name:        Identifier_Id, // INVALID_IDENTIFIER for a positional argument
	mode:        Argument_Mode,
	type:        Type_Id,
	is_const:    bool,
	const_value: Const_Value,
	// A receiver already adjusted by the call syntax that produced it, which is
	// what makes `v.method()` rank as an adjustment rather than a mismatch.
	is_receiver: bool,
}

Candidate :: struct {
	symbol: Symbol_Id,
	// One rank per argument that survives into this candidate's concrete runtime
	// signature. Never summed: the ranks form a vector and argument order does
	// not break ties.
	ranks:  []int,
	// Generic `$` arguments are absent from `args`/`ranks` — those arrays drive
	// runtime binding — but they're still written call arguments, so they
	// participate in overload ordering through this full vector.
	ordering_ranks: []int,
	// Which parameter each supplied argument fills.
	slots:  []int,
	filled: []bool,
	// The arguments this candidate actually ranked. A generic candidate ranks the
	// runtime subset: its `$` arguments were consumed at instantiation time.
	args:   []Arg_Info,

	omitted:    int,
	variadic:   bool,
	parametric: bool,
	// Tie-breaker 4: how much structure the written parameter patterns pin down.
	specificity: int,
	// Tie-breaker 5: how many arguments reached this candidate through a mode
	// their written form did not name — an owning argument into an ordinary value
	// parameter, or an unmarked temporary into a `move` one. Both transfer, so
	// neither is a mismatch; the written form decides which candidate gets to.
	mode_adjusted: int,
	// The instantiation this candidate stands for, promoted to a checked body
	// only if it is the one selected.
	instance:   ^Instance,
	// What a candidate rejected by its own bounds would have instantiated, so the
	// no-match diagnostic can re-run the bound and name the requirement that
	// failed instead of saying only that one did.
	template:   ^Generic_Template,
	bindings:   []Generic_Binding,
	scope:      ^Scope,
	viable:     bool,
	reason:     string,
}

@(private = "file")
candidate_ranks :: proc(cand: ^Candidate) -> []int {
	return cand.ordering_ranks != nil ? cand.ordering_ranks : cand.ranks
}

// -------------------------------------------------------------- groups --

// design.md "Explicit procedure overloading": each member keeps its ordinary
// name and may be called directly; a call through the group uses the resolution
// rules above. Members are resolved after declaration collection, so a group may
// name a procedure declared later in its package.
resolve_group_members :: proc(k: ^Checker, group_id: Symbol_Id, value: ^Expr_Proc_Group) {
	members := make([dynamic]Symbol_Id, 0, len(value.names), k.c.semantic_allocator)
	for name in value.names {
		id := name.id
		if id == INVALID_IDENTIFIER {
			id = intern_identifier(k.c, name.text)
		}
		// A group inside an `impl`/`extend` block names that block's own members;
		// one at package scope names package declarations.
		member := INVALID_SYMBOL
		if owner := symbol_of(k.c, group_id); owner != nil && owner.owner_type != INVALID_TYPE {
			member = find_member(k, owner.owner_type, id)
		}
		if member == INVALID_SYMBOL {
			member = lookup_symbol(k.scope, id)
		}
		if member == INVALID_SYMBOL {
			// design.md "where clauses": a member whose bound does not hold is not part
			// of this instantiation, so a group that lists it simply loses it. This is
			// the same shrinking every other lookup does -- `Small_Array(T, N)` groups
			// its copying and consuming `append` under one name, and a move-only `T`
			// leaves the group with only the consuming member instead of failing the
			// moment such an instance exists.
			if holder := symbol_of(k.c, group_id); holder != nil && holder.owner_type != INVALID_TYPE {
				if excluded_member(k, holder.owner_type, id) != nil {
					continue
				}
			}
			errorf(k.c, name.span, "L0395", "unknown name `%s` in this procedure group", name.text)
			continue
		}
		// An operator declaration only becomes a procedure once its own signature
		// is resolved, which may not have happened yet.
		if sym := symbol_of(k.c, member); sym != nil && sym.decl != nil && sym.decl.sig_state == .Unchecked {
			resolve_declaration_signature(k, sym.decl)
		}
		sym := symbol_of(k.c, member)
		if sym == nil || sym.kind != .Proc {
			errorf(k.c, name.span, "L0393", "`%s` is not a procedure, so it cannot be a group member", name.text)
			continue
		}
		if slice.contains(members[:], member) {
			errorf(k.c, name.span, "L0394", "`%s` is already a member of this group", name.text)
			continue
		}
		append(&members, member)
	}
	if group := symbol_of(k.c, group_id); group != nil {
		group.members = members[:]
	}
}

// ------------------------------------------------------------------ arguments --

// Checks every written argument once, with no destination type. An untyped
// constant therefore stays untyped until a candidate is chosen, which is exactly
// what rank 2 needs to see.
collect_call_arguments :: proc(
	k: ^Checker,
	args: []Argument,
	candidates: []Symbol_Id = nil,
	offset := 0,
	live_group: Symbol_Id = INVALID_SYMBOL,
) -> ([]Arg_Info, bool) {
	out := make([]Arg_Info, len(args), k.c.semantic_allocator)
	ok := true
	for arg, index in args {
		info := Arg_Info {
			expr = arg.value,
			span = arg.span,
			mode = arg.mode,
		}
		if arg.name.text != "" {
			info.name = intern_identifier(k.c, arg.name.text)
		}
		k.place_position, k.insert_position = arg.mode == .Inout, false
		// A typeless aggregate and a contextual `.name` both need a destination
		// type before they can be checked at all. Supply it only when every
		// candidate agrees; scalar constants keep their untyped conversion ranks
		// and ambiguous overloads gain no preference.
		expected := INVALID_TYPE
		if argument_needs_context(arg.value) {
			context_candidates := candidates
			// A synthetic generic-extension group grows while earlier explicitly
			// typed arguments are checked. Later contextual arguments must see the
			// newly materialised member too.
			if live_group != INVALID_SYMBOL {
				if group := symbol_of(k.c, live_group); group != nil && group.kind == .Proc_Group {
					context_candidates = group.members
				}
			}
			expected = common_argument_type(k, context_candidates, info.name, index + offset)
		}
		info.type = check_single_expr(k, arg.value, expected)
		k.place_position, k.insert_position = false, false
		if info.type == INVALID_TYPE {
			ok = false
		} else if base := expr_base(arg.value); base != nil {
			info.is_const = base.is_const
			info.const_value = base.const_value
		}
		out[index] = info
	}
	return out, ok
}

// An argument whose meaning comes from its destination: a typeless aggregate
// literal, an implicit `.name` selector — an enum member, a record member, or a
// payloadless union variant — and `.name(payload)`, which is that selector in
// callee position.
argument_needs_context :: proc(e: Expr) -> bool {
	#partial switch v in e {
	case ^Expr_Composite:
		return v.type_expr == nil
	case ^Expr_Selector:
		return v.operand == nil
	case ^Expr_Call:
		sel, is_selector := v.callee.(^Expr_Selector)
		return is_selector && sel.operand == nil
	}
	return false
}

@(private = "file")
common_argument_type :: proc(k: ^Checker, candidates: []Symbol_Id, name: Identifier_Id, position: int) -> Type_Id {
	common := INVALID_TYPE
	for candidate in candidates {
		sym := symbol_of(k.c, candidate)
		if sym == nil || sym.generic { return INVALID_TYPE }
		slot := position
		if name != INVALID_IDENTIFIER {
			slot = -1
			for binding, index in sym.param_symbols {
				if param := symbol_of(k.c, binding); param != nil && param.name == name {
					slot = index
					break
				}
			}
		}
		if slot < 0 { continue }
		// A variadic pack's parameter is `[]T`, but a written element wants `T` —
		// every argument from the pack's slot onward is one of them. A `..` spread
		// supplies the pack itself and needs no context, so it never reaches here.
		//
		// The modes live on the procedure type; a synthesized member leaves its
		// parameter symbols unnamed, so this is the reading that works for both.
		variadic := -1
		if signature := underlying_info(k.c, sym.proc_type); signature != nil {
			for mode, index in signature.param_modes {
				if mode == .Variadic {
					variadic = index
					break
				}
			}
		}
		if variadic >= 0 && slot > variadic { slot = variadic }
		if slot >= len(sym.params) { continue }
		type := sym.params[slot]
		if slot == variadic {
			pack := underlying_info(k.c, type)
			if pack == nil { return INVALID_TYPE }
			type = pack.element
		}
		if common != INVALID_TYPE && common != type { return INVALID_TYPE }
		common = type
	}
	return common
}

// An already-checked expression as one argument, for the operator and method
// paths that build their own argument lists.
arg_from_expr :: proc(k: ^Checker, e: Expr, mode := Argument_Mode.Value) -> Arg_Info {
	base := expr_base(e)
	if base == nil {
		return Arg_Info{expr = e, type = INVALID_TYPE}
	}
	return Arg_Info {
		expr        = e,
		span        = base.span,
		mode        = mode,
		type        = base.type,
		is_const    = base.is_const,
		const_value = base.const_value,
	}
}

// ------------------------------------------------------------------- ranking --

// The conversion rank of one argument against one parameter, or RANK_NONE when
// no conversion reaches it. Side-effect free: `materialize` runs only after a
// candidate has been chosen.
@(private = "file")
constant_conversion_preserves_kind :: proc(c: ^Compiler, from, to: Type_Id) -> bool {
	target := underlying_kind(c, to)
	#partial switch type_kind(c, from) {
	case .Untyped_Int:
		return target == .Int
	case .Untyped_Float:
		return target == .Float
	case .Untyped_Bool:
		return target == .Bool
	case .Untyped_Rune:
		return target == .Rune
	case .Untyped_String:
		return target == .String
	}
	return false
}

@(private = "file")
argument_rank :: proc(k: ^Checker, arg: Arg_Info, param: Type_Id, mode: Param_Mode) -> int {
	if param == INVALID_TYPE || arg.type == INVALID_TYPE {
		return RANK_NONE
	}
	// A parameter mode is part of the match, not a conversion. An argument's mode
	// decides viability here and ties in `tie_break`, so it never competes with a
	// conversion. A receiver's is different: its `inout` mode is implicit in
	// method-call syntax, and a borrowing receiver ranks behind a by-value one,
	// which is what picks between a `self` and a `self: inout` member of one group.
	// A consuming receiver follows the same rule a `move` parameter does: a place is
	// written `move(value).method()`, a temporary already owns its value.
	_, moved := arg.expr.(^Expr_Move)
	adjusted := false
	if arg.is_receiver {
		if mode == .Move {
			if !expression_is_owned_argument(arg.expr) {
				return RANK_NONE
			}
		} else if moved {
			return RANK_NONE
		}
		adjusted = mode != .Value
	} else {
		want_inout := mode == .Inout
		if want_inout != (arg.mode == .Inout) {
			return RANK_NONE
		}
		// design.md "Parameter semantics and ABI lowering": a `move` parameter is
		// written `move(expr)` at the call site too, unless the argument is a
		// temporary — it owns its value already and leaves no lexical owner dead, so
		// there is nothing for the marker to announce. Either form arrives owning
		// the argument, which is what the mode asks for.
		owned := expression_is_owned_argument(arg.expr)
		if mode == .Move && !owned {
			return RANK_NONE
		}
	}
	if arg.type == param {
		return adjusted ? RANK_ADJUST : RANK_EXACT
	}
	if type_is_untyped(k.c, arg.type) {
		if assignable(k.c, arg.type, param) {
			if arg.is_const {
				// An untyped constant reaches an `any_view` through its default type,
				// so that is the type representability has to be asked about: the
				// erased view itself has no constant but nil.
				wanted := param
				if param == TYPE_ANY_VIEW {
					wanted = any_view_source_type(k.c, arg.type)
				}
				if _, fits := convert_const(k.c, arg.const_value, wanted, false); !fits {
					return RANK_NONE
				}
			}
			if constant_conversion_preserves_kind(k.c, arg.type, param) {
				return RANK_CONST_KIND
			}
			return RANK_BUILTIN
		}
		return RANK_NONE
	}
	if assignable(k.c, arg.type, param) {
		// design.md rank 1: a mutable carrier weakening to a read-only one creates
		// no value, so it outranks every other built-in conversion.
		return carrier_weakens_to(k.c, arg.type, param) ? RANK_ADJUST : RANK_BUILTIN
	}
	return RANK_NONE
}

// ----------------------------------------------------------------- candidates --

// Reached from both sides of arity: too many supplied, and a parameter left
// with no argument and no default.
@(private = "file")
arity_reason :: proc(c: ^Compiler, count: int, supplied: int) -> string {
	return fmt.aprintf(
		"it takes %d argument%s, found %d",
		count,
		count == 1 ? "" : "s",
		supplied,
		allocator = c.semantic_allocator,
	)
}

// Places every supplied argument, fills the rest from defaults, and ranks what
// remains. A candidate that cannot place an argument at all is not viable and
// carries the reason, which is what the no-match diagnostic prints.
@(private = "file")
build_candidate :: proc(k: ^Checker, symbol_id: Symbol_Id, args: []Arg_Info) -> Candidate {
	// A generic member is inferred and substituted before it can be ranked at
	// all: `$T` has no type to compare an argument against.
	if template := generic_template_for(k, symbol_id); template != nil && template.kind == .Procedure {
		return build_generic_candidate(k, template, args)
	}
	cand := Candidate {
		symbol = symbol_id,
		args   = args,
		ranks  = make([]int, len(args), k.c.semantic_allocator),
		slots  = make([]int, len(args), k.c.semantic_allocator),
	}
	sym := symbol_of(k.c, symbol_id)
	if sym == nil {
		cand.reason = "this name is not a procedure"
		return cand
	}
	// A signature the current phase has not reached yet is resolved on demand, so
	// a group may name a procedure declared later in the file.
	if sym.proc_type == INVALID_TYPE && sym.decl != nil {
		resolve_declaration_signature(k, sym.decl)
		sym = symbol_of(k.c, symbol_id)
	}
	info := type_of(k.c, sym.proc_type)
	if info == nil || info.kind != .Proc {
		cand.reason = "this name is not a procedure"
		return cand
	}

	count := len(sym.params)
	cand.filled = make([]bool, count, k.c.semantic_allocator)
	// design.md "Variadic parameters": every trailing argument fills the one pack
	// slot, so ranking places them there rather than running out of parameters.
	// An explicit argument ranks against the element type and a `..slice` spread
	// against the pack's own slice type.
	pack := variadic_parameter_index(info)
	element := INVALID_TYPE
	if pack >= 0 {
		cand.variadic = true
		element = slice_element(k.c, sym.params[pack])
	}
	named := false
	for arg, index in args {
		slot := index
		if arg.name != INVALID_IDENTIFIER {
			named = true
			slot = parameter_slot_named(k.c, sym, arg.name)
			if slot < 0 {
				cand.reason = fmt.aprintf(
					"it has no parameter named `%s`",
					identifier_text(k.c, arg.name),
					allocator = k.c.semantic_allocator,
				)
				return cand
			}
			if cand.filled[slot] {
				cand.reason = fmt.aprintf(
					"`%s` is given twice",
					identifier_text(k.c, arg.name),
					allocator = k.c.semantic_allocator,
				)
				return cand
			}
		} else if named {
			cand.reason = "a positional argument cannot follow a named one"
			return cand
		} else if pack >= 0 && slot >= pack {
			slot = pack
		} else if slot >= count {
			cand.reason = arity_reason(k.c, count, len(args))
			return cand
		}
		cand.filled[slot] = true
		cand.slots[index] = slot
		mode := slot < len(info.param_modes) ? info.param_modes[slot] : Param_Mode.Value
		want := sym.params[slot]
		if slot == pack {
			if arg.name != INVALID_IDENTIFIER {
				cand.reason = "a variadic argument cannot be named"
				return cand
			}
			// The pack itself is passed by value however the arguments arrived.
			mode = .Value
			want = arg.mode == .Spread ? sym.params[pack] : element
		} else if arg.mode == .Spread {
			cand.reason = "`..` spreads into a variadic parameter"
			return cand
		}
		rank := argument_rank(k, arg, want, mode)
		if rank == RANK_NONE {
			// A receiver form that does not match is not a type mismatch: the
			// ordinary sentence would name one type twice and explain nothing.
			if _, moved := arg.expr.(^Expr_Move); moved != (mode == .Move) {
				if arg.is_receiver {
					cand.reason = "it borrows its receiver, so `move(...)` gives away more than it takes"
					if mode == .Move {
						cand.reason = "it consumes its receiver, which is written `move(...)`"
					}
					return cand
				}
				if mode == .Move {
					cand.reason = fmt.aprintf(
						"it takes argument %d by `move`, which is written `move(...)`",
						index + 1,
						allocator = k.c.semantic_allocator,
					)
					return cand
				}
			}
			cand.reason = fmt.aprintf(
				"argument %d is `%s` where `%s` is wanted",
				index + 1,
				type_name(k.c, args[index].type),
				type_name(k.c, want),
				allocator = k.c.semantic_allocator,
			)
			return cand
		}
		cand.ranks[index] = rank
		// An unmarked temporary reaches a `move` parameter or a consuming receiver
		// without naming that mode, so the written form breaks the tie either way.
		if _, transferred := arg.expr.(^Expr_Move); transferred != (mode == .Move) {
			cand.mode_adjusted += 1
		}
	}

	for slot in 0 ..< count {
		if cand.filled[slot] {
			continue
		}
		// An empty pack is a legal call: the callee receives a zero-length slice.
		if slot == pack {
			continue
		}
		if slot >= len(sym.param_defaults) || sym.param_defaults[slot] == nil {
			cand.reason = arity_reason(k.c, count, len(args))
			return cand
		}
		cand.omitted += 1
	}
	cand.viable = true
	return cand
}

// A generic member: infer its arguments, create or reuse the instance, evaluate
// its bounds silently, and rank the written arguments against the *substituted*
// signature. The instance's body is not checked here — an overload that is never
// selected must not produce diagnostics from a body nothing calls.
@(private = "file")
build_generic_candidate :: proc(k: ^Checker, template: ^Generic_Template, args: []Arg_Info) -> Candidate {
	inference := infer_generic_arguments(k, template, args)
	if !inference.ok {
		return Candidate{symbol = template.symbol, args = args, reason = inference.reason}
	}
	// Bounds are a viability filter and never a preference: a failed one removes
	// the candidate with a captured reason, silently.
	instance, made := instantiate_generic(k, template, inference.bindings, inference.scope, no_span(), report = false)
	if !made {
		// A bound is the usual rejection, but not the only one: a substituted
		// signature that does not resolve was contained by the same probe, and
		// its own words say more than a guess about bounds would.
		reason := "its `where` bounds are not satisfied by these arguments"
		if instance != nil && instance.rejection.message != "" {
			reason = instance.rejection.message
		}
		return Candidate {
			symbol   = template.symbol,
			args     = args,
			reason   = reason,
			template = template,
			bindings = inference.bindings,
			scope    = inference.scope,
		}
	}
	cand := build_candidate(k, instance.symbol, inference.runtime_args)
	if cand.viable {
		ordering := make([]int, len(args), k.c.semantic_allocator)
		runtime_index := 0
		for arg, index in args {
			if inference.compile_time[index] {
				rank := argument_rank(k, arg, inference.compile_targets[index], .Value)
				if rank == RANK_NONE {
					cand.viable = false
					cand.reason = fmt.aprintf(
						"argument %d is `%s` where `%s` is wanted",
						index + 1,
						type_name(k.c, arg.type),
						type_name(k.c, inference.compile_targets[index]),
						allocator = k.c.semantic_allocator,
					)
					break
				}
				ordering[index] = rank
				continue
			}
			ordering[index] = cand.ranks[runtime_index]
			runtime_index += 1
		}
		cand.ordering_ranks = ordering
	}
	cand.parametric = true
	cand.specificity = template.specificity
	cand.instance = instance
	if !cand.viable && cand.reason == "" {
		cand.reason = "it does not apply to these arguments"
	}
	return cand
}

// ------------------------------------------------------------------ ordering --

// -1 when `a` is better, 1 when `b` is, 0 when the vectors are identical, and 2
// when they cross. A crossed pair such as (0, 2) and (2, 0) is intentionally
// ambiguous.
@(private = "file")
compare_vectors :: proc(a, b: []int) -> int {
	if len(a) != len(b) {
		return 2
	}
	a_better, b_better := false, false
	for value, index in a {
		if value < b[index] {
			a_better = true
		} else if value > b[index] {
			b_better = true
		}
	}
	switch {
	case a_better && b_better:
		return 2
	case a_better:
		return -1
	case b_better:
		return 1
	}
	return 0
}

// The five tie-breakers, in order, for candidates whose vectors are identical.
// Returns -1 when `a` wins, 1 when `b` does, and 0 when none of them decides.
@(private = "file")
tie_break :: proc(a, b: ^Candidate) -> int {
	if a.variadic != b.variadic {
		return a.variadic ? 1 : -1
	}
	if a.omitted != b.omitted {
		return a.omitted < b.omitted ? -1 : 1
	}
	if a.parametric != b.parametric {
		return a.parametric ? 1 : -1
	}
	// design.md tie-breaker 4: between parametric candidates a structural
	// specialization beats an unspecialized parameter. Neither more specialized
	// than the other stays ambiguous.
	if a.specificity != b.specificity {
		return a.specificity > b.specificity ? -1 : 1
	}
	// design.md tie-breaker 5: the written form selects. `values.append(move(f))`
	// picks the consuming member of a group, and `values.append(1)` the ordinary
	// one, where nothing structural tells the two apart.
	if a.mode_adjusted != b.mode_adjusted {
		return a.mode_adjusted < b.mode_adjusted ? -1 : 1
	}
	return 0
}

@(private = "file")
candidate_better :: proc(a, b: ^Candidate) -> bool {
	switch compare_vectors(candidate_ranks(a), candidate_ranks(b)) {
	case -1:
		return true
	case 1, 2:
		return false
	}
	return tie_break(a, b) == -1
}

// ------------------------------------------------------------------- entry --

// The one resolution entry point. `description` names the construct for the
// diagnostic ("call to `to_string`", "operator `+`"). `expected` filters
// candidates by result type only when it would otherwise leave several.
resolve_overload :: proc(
	k: ^Checker,
	span: Span,
	description: string,
	members: []Symbol_Id,
	args: []Arg_Info,
	expected: Type_Id = INVALID_TYPE,
	report := true,
) -> (Candidate, bool) {
	if len(members) == 0 {
		if report {
			errorf(k.c, span, "L0392", "%s has no overloads", description)
		}
		return Candidate{}, false
	}
	all := make([]Candidate, len(members), context.temp_allocator)
	viable := make([dynamic]int, 0, len(members), context.temp_allocator)
	for member, index in members {
		all[index] = build_candidate(k, member, args)
		if all[index].viable {
			append(&viable, index)
		}
	}
	if len(viable) == 0 {
		if report {
			report_no_match(k, span, description, all[:])
		}
		return Candidate{}, false
	}

	// Return type may filter candidates against an already-known destination
	// type, but procedures cannot be overloaded by return type alone — so this
	// only ever narrows a set that is already plural.
	if expected != INVALID_TYPE && len(viable) > 1 {
		kept := make([dynamic]int, 0, len(viable), context.temp_allocator)
		for index in viable {
			if candidate_result_fits(k, all[index].symbol, expected) {
				append(&kept, index)
			}
		}
		if len(kept) > 0 {
			viable = kept
		}
	}

	maximal := make([dynamic]int, 0, len(viable), context.temp_allocator)
	for index in viable {
		dominated := false
		for other in viable {
			if other != index && candidate_better(&all[other], &all[index]) {
				dominated = true
				break
			}
		}
		if !dominated {
			append(&maximal, index)
		}
	}
	if len(maximal) == 1 {
		chosen := all[maximal[0]]
		// Only the selected instance is promoted to a checked, emitted body, and
		// this call is what selected it — so its body's diagnostics name it.
		promote_generic_instance(k, chosen.instance, span)
		return chosen, true
	}
	if report {
		report_ambiguity(k, span, description, all[:], maximal[:])
	}
	return Candidate{}, false
}

// Silent viability query used by syntax fallbacks. Ambiguity still counts as
// viable: the direct spelling must diagnose that ambiguity instead of silently
// selecting a fallback operation.
overload_has_viable :: proc(
	k: ^Checker,
	members: []Symbol_Id,
	args: []Arg_Info,
) -> bool {
	for member in members {
		cand := build_candidate(k, member, args)
		if cand.viable {
			return true
		}
	}
	return false
}

@(private = "file")
candidate_result_fits :: proc(k: ^Checker, symbol_id: Symbol_Id, expected: Type_Id) -> bool {
	sym := symbol_of(k.c, symbol_id)
	if sym == nil || sym.result == INVALID_TYPE {
		return false
	}
	return sym.result == expected || assignable(k.c, sym.result, expected)
}

// ---------------------------------------------------------------- diagnostics --

@(private = "file")
report_no_match :: proc(k: ^Checker, span: Span, description: string, all: []Candidate) {
	// design.md requires an interface bound to name the requirement that failed.
	// With one candidate there is no ambiguity about which bound to blame, so the
	// bound reports itself and stands alone; a plural set keeps the summary and
	// says which candidates their bounds rejected.
	if len(all) == 1 && all[0].template != nil {
		instantiate_generic(k, all[0].template, all[0].bindings, all[0].scope, span, report = true)
		return
	}
	errorf(k.c, span, "L0392", "no overload of %s applies to these arguments", description)
	for cand in all {
		sym := symbol_of(k.c, cand.symbol)
		if sym == nil {
			continue
		}
		add_notef(
			k.c,
			sym.span,
			"`%s` does not apply: %s",
			identifier_text(k.c, sym.name),
			cand.reason == "" ? "it is not viable here" : cand.reason,
		)
	}
}

// The ambiguity diagnostic must list every maximal candidate, its conversion
// vector, and the tie-breaker at which selection failed (design.md).
@(private = "file")
report_ambiguity :: proc(k: ^Checker, span: Span, description: string, all: []Candidate, maximal: []int) {
	errorf(k.c, span, "L0391", "%s is ambiguous here: %d candidates are equally good", description, len(maximal))
	for index in maximal {
		sym := symbol_of(k.c, all[index].symbol)
		if sym == nil {
			continue
		}
		add_notef(
			k.c,
			sym.span,
			"candidate `%s` with conversion vector %s",
			identifier_text(k.c, sym.name),
			vector_text(k.c, candidate_ranks(&all[index])),
		)
	}
	add_notef(k.c, no_span(), "selection failed at %s", failing_tie_breaker(all, maximal))
}

// A tie-breaker that decides leaves its loser dominated, and a dominated
// candidate is not maximal — so a pair that reaches here was separated by none
// of them. That leaves two answers: crossed vectors, or the last tie-breaker.
@(private = "file")
failing_tie_breaker :: proc(all: []Candidate, maximal: []int) -> string {
	for index in maximal {
		for other in maximal {
			if other == index {
				continue
			}
			if compare_vectors(candidate_ranks(&all[index]), candidate_ranks(&all[other])) == 2 {
				return "crossed conversion vectors, which are ambiguous by design"
			}
		}
	}
	return "tie-breaker 5, where no candidate better matches the written parameter modes"
}

@(private = "file")
vector_text :: proc(c: ^Compiler, ranks: []int) -> string {
	b := strings.builder_make(c.semantic_allocator)
	strings.write_string(&b, "(")
	for rank, index in ranks {
		if index > 0 {
			strings.write_string(&b, ", ")
		}
		fmt.sbprintf(&b, "%d", rank)
	}
	strings.write_string(&b, ")")
	return strings.to_string(b)
}

// --------------------------------------------------------------- binding --

// Writes the chosen candidate onto the call node: the parameter-order argument
// list the backend evaluates, with every untyped constant materialised at its
// parameter's type.
bind_chosen_call :: proc(k: ^Checker, v: ^Expr_Call, cand: Candidate, written: []Arg_Info) -> bool {
	sym := symbol_of(k.c, cand.symbol)
	if sym == nil {
		return false
	}
	// A pack is settled by the one procedure that knows how to build it. Ranking
	// already checked every written argument, so it binds them without checking
	// them a second time.
	if info := type_of(k.c, sym.proc_type); variadic_parameter_index(info) >= 0 {
		// A method call's receiver is parameter 0 and is not one of the written
		// arguments, so the pack binder is told which expression fills it.
		receiver: Expr
		if len(cand.args) > 0 && cand.args[0].is_receiver {
			receiver = cand.args[0].expr
		}
		bound_ok := bind_variadic_arguments(k, v, info, cand.symbol, prechecked = true, receiver = receiver)
		require_argument_ownership(k, v, cand.symbol)
		return bound_ok
	}
	// A generic candidate ranked the runtime subset of the written arguments, so
	// binding follows what the candidate itself saw.
	args := cand.args
	if args == nil {
		args = written
	}
	count := len(sym.params)
	bound := make([]Expr, count, k.c.semantic_allocator)
	ok := true
	for arg, index in args {
		slot := cand.slots[index]
		value := arg.expr
		if !materialize_argument(k, value, sym.params[slot]) {
			ok = false
			continue
		}
		if arg.mode == .Inout {
			if base := expr_base(value); base != nil && !base.assignable {
				report_not_assignable(k, base, "an `inout` argument")
				ok = false
			}
		}
		bound[slot] = value
		if proc_parameter_mode(k.c, sym.proc_type, slot) == .Borrow && !check_borrow_argument(k, value) { ok = false }
	}
	for slot in 0 ..< count {
		if !cand.filled[slot] && slot < len(sym.param_defaults) {
			// design.md: `caller_location()` is evaluated at each call that omits
			// the argument, so an omitted default belongs to this call site and
			// not to the declaration — through a group exactly as directly.
			bound[slot] = substitute_caller_location(k, sym.param_defaults[slot], v.span)
		}
	}
	v.bound = bound
	require_argument_ownership(k, v, cand.symbol)
	return ok
}

// The assignability half of `check_value_expr`, for an argument the engine has
// already checked exactly once.
materialize_argument :: proc(k: ^Checker, e: Expr, target: Type_Id) -> bool {
	return materialize_value_expr(k, e, target, "pass")
}
