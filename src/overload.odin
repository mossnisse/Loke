// Overload resolution (m4a-plan step 1, decision "One candidate engine").
//
// One engine, used by named procedure groups, methods, operators, `init`
// construction, and indexing. design.md ranks operator overloads "using the same
// algorithm as named procedure overloads": two implementations would drift, and
// the error-quality requirement — list every maximal candidate, its conversion
// vector, and the tie-breaker where selection failed — wants one place that can
// print them.
//
// The contract fixed here and not reopened by M4b: viability filters first,
// structure orders what survives, and constraints never rank.
package lokec

import "core:fmt"
import "core:strings"

// Conversion ranks (design.md "Operator lookup and overload resolution").
RANK_EXACT :: 0 // exact type and parameter-mode match
RANK_ADJUST :: 1 // a capability adjustment that does not create a value
RANK_CONST_KIND :: 2 // an untyped constant converted without changing its kind
RANK_BUILTIN :: 3 // any other built-in implicit conversion
RANK_IMPLICIT :: 4 // a user `@(implicit)` conversion, reachable only from a constant
RANK_NONE :: 5 // no conversion at all: the candidate is not viable

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
	// One rank per supplied argument, in written order. Never summed: the ranks
	// form a vector and argument order does not break ties.
	ranks:  []int,
	// Which parameter each supplied argument fills.
	slots:  []int,
	filled: []bool,
	// The `@(implicit)` `init` overload a rank-4 argument goes through.
	via:    []Symbol_Id,

	omitted:    int,
	variadic:   bool,
	parametric: bool,
	viable:     bool,
	reason:     string,
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
		duplicate := false
		for existing in members {
			if existing == member {
				errorf(k.c, name.span, "L0394", "`%s` is already a member of this group", name.text)
				duplicate = true
				break
			}
		}
		if !duplicate {
			append(&members, member)
		}
	}
	if group := symbol_of(k.c, group_id); group != nil {
		group.members = members[:]
	}
}

// ------------------------------------------------------------------ arguments --

// Checks every written argument once, with no destination type. An untyped
// constant therefore stays untyped until a candidate is chosen, which is exactly
// what rank 2 needs to see.
collect_call_arguments :: proc(k: ^Checker, args: []Argument) -> ([]Arg_Info, bool) {
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
		if arg.mode == .Spread {
			unsupported_construct(k, arg.span)
			ok = false
		}
		k.place_position = arg.mode == .Inout
		info.type = check_single_expr(k, arg.value)
		k.place_position = false
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
	target := type_kind(c, type_underlying(c, to))
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
argument_rank :: proc(k: ^Checker, arg: Arg_Info, param: Type_Id, mode: Param_Mode) -> (int, Symbol_Id) {
	if param == INVALID_TYPE || arg.type == INVALID_TYPE {
		return RANK_NONE, INVALID_SYMBOL
	}
	// A parameter mode is part of the match, not a conversion. A receiver carries
	// its mode implicitly, so the call syntax has already supplied it.
	if !arg.is_receiver {
		want_inout := mode == .Inout
		if want_inout != (arg.mode == .Inout) {
			return RANK_NONE, INVALID_SYMBOL
		}
	}
	if arg.type == param {
		return arg.is_receiver && mode != .Value ? RANK_ADJUST : RANK_EXACT, INVALID_SYMBOL
	}
	if type_is_untyped(k.c, arg.type) {
		if assignable(k.c, arg.type, param) {
			if arg.is_const {
				if _, fits := convert_const(k.c, arg.const_value, param, false); !fits {
					return RANK_NONE, INVALID_SYMBOL
				}
			}
			if constant_conversion_preserves_kind(k.c, arg.type, param) {
				return RANK_CONST_KIND, INVALID_SYMBOL
			}
			return RANK_BUILTIN, INVALID_SYMBOL
		}
		// Rank 4 sits below every built-in conversion, so a constant always
		// prefers a compatible built-in destination.
		if arg.is_const {
			overload, applicable := implicit_init_overload(k, arg, param)
			if applicable {
				return RANK_IMPLICIT, overload
			}
		}
		return RANK_NONE, INVALID_SYMBOL
	}
	if assignable(k.c, arg.type, param) {
		return RANK_BUILTIN, INVALID_SYMBOL
	}
	return RANK_NONE, INVALID_SYMBOL
}

// ----------------------------------------------------------------- candidates --

// Places every supplied argument, fills the rest from defaults, and ranks what
// remains. A candidate that cannot place an argument at all is not viable and
// carries the reason, which is what the no-match diagnostic prints.
@(private = "file")
build_candidate :: proc(k: ^Checker, symbol_id: Symbol_Id, args: []Arg_Info) -> Candidate {
	cand := Candidate {
		symbol = symbol_id,
		ranks  = make([]int, len(args), k.c.semantic_allocator),
		slots  = make([]int, len(args), k.c.semantic_allocator),
		via    = make([]Symbol_Id, len(args), k.c.semantic_allocator),
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
	named := false
	for arg, index in args {
		slot := index
		if arg.name != INVALID_IDENTIFIER {
			named = true
			slot = -1
			for binding, position in sym.param_symbols {
				if symbol := symbol_of(k.c, binding); symbol != nil && symbol.name == arg.name {
					slot = position
					break
				}
			}
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
		} else if slot >= count {
			cand.reason = fmt.aprintf(
				"it takes %d argument%s, found %d",
				count,
				count == 1 ? "" : "s",
				len(args),
				allocator = k.c.semantic_allocator,
			)
			return cand
		}
		cand.filled[slot] = true
		cand.slots[index] = slot
		mode := slot < len(info.param_modes) ? info.param_modes[slot] : Param_Mode.Value
		rank, via := argument_rank(k, arg, sym.params[slot], mode)
		if rank == RANK_NONE {
			cand.reason = fmt.aprintf(
				"argument %d is `%s` where `%s` is wanted",
				index + 1,
				type_name(k.c, args[index].type),
				type_name(k.c, sym.params[slot]),
				allocator = k.c.semantic_allocator,
			)
			return cand
		}
		cand.ranks[index] = rank
		cand.via[index] = via
	}

	for slot in 0 ..< count {
		if cand.filled[slot] {
			continue
		}
		if slot >= len(sym.param_defaults) || sym.param_defaults[slot] == nil {
			cand.reason = fmt.aprintf(
				"it takes %d argument%s, found %d",
				count,
				count == 1 ? "" : "s",
				len(args),
				allocator = k.c.semantic_allocator,
			)
			return cand
		}
		cand.omitted += 1
	}
	cand.viable = true
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

TIE_BREAKERS :: [4]string {
	"a fixed-arity candidate beats a variadic one",
	"a candidate requiring fewer omitted default arguments wins",
	"a non-parametric candidate beats a parametric one",
	"a structural specialization beats an unspecialized parameter",
}

// The four tie-breakers, in order, for candidates whose vectors are identical.
// Returns -1/1 for a decision and 0 for none, plus how many tie-breakers were
// consulted without deciding.
@(private = "file")
tie_break :: proc(a, b: ^Candidate) -> (int, int) {
	if a.variadic != b.variadic {
		return a.variadic ? 1 : -1, 0
	}
	if a.omitted != b.omitted {
		return a.omitted < b.omitted ? -1 : 1, 1
	}
	if a.parametric != b.parametric {
		return a.parametric ? 1 : -1, 2
	}
	// Tie-breaker 4 needs structural specialization, which arrives with M4b's
	// instantiated declarations. Until then no two candidates differ here.
	return 0, 4
}

@(private = "file")
candidate_better :: proc(a, b: ^Candidate) -> bool {
	switch compare_vectors(a.ranks, b.ranks) {
	case -1:
		return true
	case 1, 2:
		return false
	}
	decision, _ := tie_break(a, b)
	return decision == -1
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
		return all[maximal[0]], true
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
	if sym == nil || len(sym.results) != 1 {
		return false
	}
	return sym.results[0] == expected || assignable(k.c, sym.results[0], expected)
}

// ---------------------------------------------------------------- diagnostics --

@(private = "file")
report_no_match :: proc(k: ^Checker, span: Span, description: string, all: []Candidate) {
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

// design.md: "The compiler diagnostic must list every maximal candidate, its
// conversion vector, and the tie-breaker at which selection failed."
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
			vector_text(k.c, all[index].ranks),
		)
	}
	add_notef(k.c, no_span(), "selection failed at %s", failing_tie_breaker(all, maximal))
}

@(private = "file")
failing_tie_breaker :: proc(all: []Candidate, maximal: []int) -> string {
	breakers := TIE_BREAKERS
	worst := -1
	for index in maximal {
		for other in maximal {
			if other == index {
				continue
			}
			if compare_vectors(all[index].ranks, all[other].ranks) == 2 {
				return "crossed conversion vectors, which are ambiguous by design"
			}
			_, consulted := tie_break(&all[index], &all[other])
			worst = max(worst, consulted)
		}
	}
	if worst < 0 || worst >= len(breakers) {
		return "tie-breaker 4, where no candidate is more structurally specialized"
	}
	return breakers[worst]
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

// ------------------------------------------------- implicit conversions --
// Filled in by `src/impl.odin` once `init` groups exist; declared here so the
// ranking function has one seam rather than a conditional.

// --------------------------------------------------------------- binding --

// Writes the chosen candidate onto the call node: the parameter-order argument
// list the backend evaluates, with every untyped constant materialised at its
// parameter's type and every rank-4 argument wrapped in its conversion.
bind_chosen_call :: proc(k: ^Checker, v: ^Expr_Call, cand: Candidate, args: []Arg_Info) -> bool {
	sym := symbol_of(k.c, cand.symbol)
	if sym == nil {
		return false
	}
	count := len(sym.params)
	bound := make([]Expr, count, k.c.semantic_allocator)
	ok := true
	for arg, index in args {
		slot := cand.slots[index]
		value := arg.expr
		if cand.ranks[index] == RANK_IMPLICIT && cand.via[index] == INVALID_SYMBOL {
			implicit_init_overload(k, arg, sym.params[slot], report = true)
			ok = false
			continue
		} else if cand.via[index] != INVALID_SYMBOL {
			value = wrap_implicit_conversion(k, value, cand.via[index])
		} else if !materialize_argument(k, value, sym.params[slot]) {
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
	}
	for slot in 0 ..< count {
		if !cand.filled[slot] && slot < len(sym.param_defaults) {
			bound[slot] = sym.param_defaults[slot]
		}
	}
	v.bound = bound
	return ok
}

// The assignability half of `check_value_expr`, for an argument the engine has
// already checked exactly once.
materialize_argument :: proc(k: ^Checker, e: Expr, target: Type_Id) -> bool {
	if target == INVALID_TYPE {
		return false
	}
	if !materialize(k, e, target) {
		return false
	}
	final := expr_base(e).type
	if !assignable(k.c, final, target) {
		errorf(
			k.c,
			expr_span(e),
			"L0310",
			"cannot pass `%s` with `%s`",
			type_name(k.c, target),
			type_name(k.c, final),
		)
		return false
	}
	return true
}
