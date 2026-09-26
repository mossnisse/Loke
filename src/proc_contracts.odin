package lokec

import "core:slice"
import "core:strings"

Proc_Contract_Check :: struct { from, to: Type_Id, span: Span }

expression_converts_storage :: proc(value: Expr) -> bool {
	base := expr_base(value)
	return base != nil && (base.view_from != INVALID_TYPE || base.erased_from != INVALID_TYPE || base.splat_from != INVALID_TYPE)
}

check_borrow_argument :: proc(k: ^Checker, value: Expr) -> bool {
	if field, packed := packed_field_reached(k, value); packed {
		errorf(k.c, expr_span(value), "L0614", "cannot borrow `%s`: it is reached through a packed struct", field)
		return false
	}
	request_materialization(k, value)
	return true
}

result_needs_contract :: proc(c: ^Compiler, type: Type_Id, inout_result: bool) -> bool {
	if type == INVALID_TYPE { return false }
	if inout_result || type_is_carrier(c, type) { return true }
	// Hooks may still be resolving here. Asking lifecycle_of would cache an
	// incomplete lifecycle and silently lose later copy/drop hooks. Aggregate
	// results can carry ownership regions, so keep their contract conservatively.
	if info := underlying_info(c, type); info != nil {
		#partial switch info.kind {
		case .Allocator, .String, .Dynamic_Array, .Map, .Struct, .Union, .Array:
			return true
		}
	}
	return false
}

erase_proc_contract :: proc(c: ^Compiler, type: Type_Id) -> Type_Id {
	info := type_of(c, type)
	if info == nil || info.kind != .Proc || info.proc_contract == INVALID_SYMBOL { return type }
	return intern_proc_type(c, info.parameters, info.param_modes, info.result, info.result_inout,
		info.convention, info.param_resets, info.param_by_ptr, info.c_vararg, info.param_escapes)
}

record_proc_contract_check :: proc(c: ^Compiler, from, to: Type_Id, span: Span) {
	if from == to { return }
	a, b := underlying_info(c, from), underlying_info(c, to)
	if a == nil || b == nil || a.kind != .Proc || b.kind != .Proc || a.proc_contract == b.proc_contract { return }
	if b.proc_contract == INVALID_SYMBOL && discharged_escape(c, from, to) < 0 { return }
	if !proc_escape_weakens_to(c, type_underlying(c, from), type_underlying(c, to)) { return }
	for check in c.proc_contract_checks {
		if check.from == from && check.to == to && check.span == span { return }
	}
	append(&c.proc_contract_checks, Proc_Contract_Check{from, to, span})
}

// design.md "Escape levels": the first parameter a written `@(escape=none)`
// asks of an inferred contract that leaves it at `result`, or -1. The summary
// answers it once inference settles.
discharged_escape :: proc(c: ^Compiler, from, to: Type_Id, after := -1) -> int {
	a := underlying_info(c, from)
	if a == nil || a.kind != .Proc || a.proc_contract == INVALID_SYMBOL { return -1 }
	for index in after + 1 ..< len(a.parameters) {
		if proc_param_escape(c, from, index) == .Result && proc_param_escape(c, to, index) == .None { return index }
	}
	return -1
}

check_proc_contracts :: proc(k: ^Checker) {
	for check in k.c.proc_contract_checks {
		a, b := underlying_info(k.c, check.from), underlying_info(k.c, check.to)
		actual, have := result_summary(k.c, a.proc_contract)
		if b.proc_contract != INVALID_SYMBOL {
			bound, known := result_summary(k.c, b.proc_contract)
			if !have || !known || !result_contract_within(actual, bound) {
				errorf(k.c, check.span, "L0645", "procedure result provenance does not satisfy the inferred contract of `%s`",
					contract_name(k.c, b.proc_contract))
				if have && known {
					for index in 0 ..< len(actual.params) {
						if result_uses_param(actual, index) && !result_uses_param(bound, index) {
							add_notef(k.c, check.span, "the result of `%s` may borrow `%s`, which that contract excludes",
								contract_name(k.c, a.proc_contract), contract_param_name(k.c, a.proc_contract, index))
							break
						}
					}
				}
				add_contract_notes(k.c, b.proc_contract)
				add_precision_notes(k.c, check.span, actual.precision | bound.precision)
				continue
			}
		}
		if !have { continue }
		for index := discharged_escape(k.c, check.from, check.to); index >= 0; index = discharged_escape(k.c, check.from, check.to, index) {
			if result_uses_param(actual, index) {
				errorf(k.c, check.span, "L0645", "the result of `%s` may borrow `%s`, which `%s` marks `@(escape=none)`",
					contract_name(k.c, a.proc_contract), contract_param_name(k.c, a.proc_contract, index), type_name(k.c, check.to))
				add_contract_notes(k.c, a.proc_contract)
				add_precision_notes(k.c, check.span, actual.precision)
				break
			}
		}
	}
}

// design.md "Procedure result contracts": a conditional between two inferred
// callbacks keeps both contracts. The join is a bodiless contract whose members
// are the declarations, sorted so either branch order interns the same type.
join_callback_types :: proc(c: ^Compiler, a, b: Type_Id) -> (Type_Id, bool) {
	x, y := type_of(c, a), type_of(c, b)
	if a == b || x == nil || y == nil || x.kind != .Proc || y.kind != .Proc ||
	   x.proc_contract == INVALID_SYMBOL || y.proc_contract == INVALID_SYMBOL { return INVALID_TYPE, false }
	plain := erase_proc_contract(c, a)
	if plain != erase_proc_contract(c, b) { return INVALID_TYPE, false }
	members := make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
	append(&members, ..contract_members(c, x.proc_contract))
	append(&members, ..contract_members(c, y.proc_contract))
	slice.sort(members[:])
	unique := slice.unique(members[:])
	join := INVALID_SYMBOL
	for existing in c.contract_joins {
		if slice.equal(symbol_of(c, existing).members, unique) { join = existing }
	}
	if join == INVALID_SYMBOL {
		stored := make([]Symbol_Id, len(unique), c.semantic_allocator)
		copy(stored, unique)
		names := make([]string, len(unique), context.temp_allocator)
		for member, index in unique { names[index] = identifier_text(c, symbol_of(c, member).name) }
		first := symbol_of(c, unique[0])
		join = new_symbol(c, Symbol {
			kind    = .Proc,
			name    = intern_identifier(c, strings.join(names, " | ", context.temp_allocator)),
			span    = first.span,
			pkg     = first.pkg,
			members = stored,
		})
		append(&c.contract_joins, join)
	}
	p := type_of(c, plain)
	return intern_proc_type(c, p.parameters, p.param_modes, p.result, p.result_inout, p.convention,
		p.param_resets, p.param_by_ptr, p.c_vararg, p.param_escapes, join), true
}

is_contract_join :: proc(c: ^Compiler, id: Symbol_Id) -> bool {
	sym := symbol_of(c, id)
	return sym != nil && sym.kind == .Proc && len(sym.members) > 0
}

// The declarations a contract stands for: itself, or a join's members.
contract_members :: proc(c: ^Compiler, id: Symbol_Id) -> []Symbol_Id {
	if is_contract_join(c, id) { return symbol_of(c, id).members }
	single := make([]Symbol_Id, 1, context.temp_allocator)
	single[0] = id
	return single
}

contract_name :: proc(c: ^Compiler, id: Symbol_Id) -> string {
	return identifier_text(c, symbol_of(c, id).name)
}

// Members share the signature, so the first one names the parameter.
@(private = "file")
contract_param_name :: proc(c: ^Compiler, id: Symbol_Id, index: int) -> string {
	sym := symbol_of(c, contract_members(c, id)[0])
	if index < len(sym.param_symbols) { return identifier_text(c, symbol_of(c, sym.param_symbols[index]).name) }
	return "an argument"
}

@(private = "file")
add_contract_notes :: proc(c: ^Compiler, id: Symbol_Id) {
	for member in contract_members(c, id) {
		add_notef(c, symbol_of(c, member).span, "result contract inferred from this declaration")
	}
}

@(private = "file")
dependency_contract_within :: proc(a, b: Result_Dependencies) -> bool {
	if (a.static && !b.static) || (a.thread && !b.thread) || (a.fresh && !b.fresh) ||
	   (a.local && !b.local) || (a.unknown && !b.unknown) { return false }
	if a.fresh && !region_contract_within(a.fresh_region, b.fresh_region) { return false }
	for loaded, index in a.param_loads {
		if loaded && (index >= len(b.param_loads) || !b.param_loads[index]) { return false }
	}
	for wanted, index in a.params {
		if !wanted { continue }
		if index >= len(b.params) || !b.params[index] { return false }
		bp := index < len(b.param_paths) ? b.param_paths[index] : nil
		if len(bp) == 0 { continue }
		ap := index < len(a.param_paths) ? a.param_paths[index] : nil
		if len(ap) != len(bp) { return false }
		for used, path in ap { if used && !bp[path] { return false } }
	}
	return true
}

@(private = "file")
region_contract_within :: proc(a, b: Region_Set) -> bool {
	if region_has_local(a) || (a.default && !b.default) || (a.unknown && !b.unknown) { return false }
	for wanted, index in a.params {
		if wanted && (index >= len(b.params) || !b.params[index]) { return false }
	}
	return true
}

@(private = "file")
result_contract_within :: proc(a, b: Result_Provenance) -> bool {
	if !dependency_contract_within(a.dependencies, b.dependencies) || !region_contract_within(a.region, b.region) { return false }
	for target in b.content {
		if len(a.content) == 0 {
			if !dependency_contract_within(a.dependencies, target.dependencies) { return false }
		} else {
			for source in a.content {
				if paths_overlap(source.path.steps, target.path.steps) &&
				   !dependency_contract_within(source.dependencies, target.dependencies) { return false }
			}
		}
	}
	for target in b.region_content {
		if len(a.region_content) == 0 {
			if !region_contract_within(a.region, target.region) { return false }
		} else {
			for source in a.region_content {
				if paths_overlap(source.path, target.path) && !region_contract_within(source.region, target.region) { return false }
			}
		}
	}
	return true
}

// Contract-bearing indirect calls use direct-call substitution.
call_contract_declaration :: proc(c: ^Compiler, call: ^Expr_Call) -> Symbol_Id {
	id := call.resolution.chosen_overload
	if id == INVALID_SYMBOL { id = call.resolution.symbol }
	if sym := symbol_of(c, id); sym != nil && sym.kind == .Proc { return id }
	if base := expr_base(call.callee); base != nil {
		if info := underlying_info(c, base.type); info != nil && info.kind == .Proc { return info.proc_contract }
	}
	return INVALID_SYMBOL
}
