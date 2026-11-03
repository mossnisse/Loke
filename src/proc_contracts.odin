package lokec

import "core:slice"
import "core:strings"

Proc_Contract_Check :: struct { from, to: Type_Id, span: Span }

// ------------------------------------------------------- contract-bearing types --

result_needs_contract :: proc(c: ^Compiler, type: Type_Id, inout_result: bool) -> bool {
	if type == INVALID_TYPE { return false }
	if inout_result || type_is_carrier(c, type) { return true }
	// Hooks may still be resolving here, so what lifecycle_of says now may not
	// hold for the finished record. Aggregate results can carry ownership regions,
	// so keep their contract conservatively.
	if info := underlying_info(c, type); info != nil {
		#partial switch info.kind {
		case .String, .Dynamic_Array, .Box, .Map, .Struct, .Union, .Array:
			return true
		}
	}
	return false
}

@(private = "file")
proc_type_with_contract :: proc(c: ^Compiler, info: ^Type_Info, contract: Symbol_Id) -> Type_Id {
	return intern_proc_type(c, info.parameters, info.param_modes, info.result, info.result_inout, info.convention,
		info.param_resets, info.param_by_ptr, info.c_vararg, info.param_escapes, contract, info.param_cross_thread)
}

erase_proc_contract :: proc(c: ^Compiler, type: Type_Id) -> Type_Id {
	info := type_of(c, type)
	if info == nil || info.kind != .Proc || info.proc_contract == INVALID_SYMBOL { return type }
	return proc_type_with_contract(c, info, INVALID_SYMBOL)
}

// design.md "Procedure result contracts": a conditional between two inferred
// callbacks keeps both contracts. The join is a bodiless contract whose members
// are the declarations, sorted so either branch order interns the same type.
join_callback_types :: proc(c: ^Compiler, a, b: Type_Id) -> (Type_Id, bool) {
	x, y := type_of(c, a), type_of(c, b)
	if a == b || x == nil || y == nil || x.kind != .Proc || y.kind != .Proc ||
	   x.proc_contract == INVALID_SYMBOL || y.proc_contract == INVALID_SYMBOL { return INVALID_TYPE, false }
	if erase_proc_contract(c, a) != erase_proc_contract(c, b) { return INVALID_TYPE, false }
	members, _ := slice.concatenate([][]Symbol_Id{contract_members(c, x.proc_contract), contract_members(c, y.proc_contract)}, context.temp_allocator)
	slice.sort(members)
	unique := slice.unique(members)
	join := INVALID_SYMBOL
	for existing in c.contract_joins {
		if slice.equal(symbol_of(c, existing).members, unique) { join = existing }
	}
	if join == INVALID_SYMBOL {
		names := make([]string, len(unique), context.temp_allocator)
		for member, index in unique { names[index] = identifier_text(c, symbol_of(c, member).name) }
		first := symbol_of(c, unique[0])
		stored, _ := slice.clone(unique, c.semantic_allocator)
		join = new_symbol(c, Symbol {
			kind    = .Proc,
			name    = intern_identifier(c, strings.join(names, " | ", context.temp_allocator)),
			span    = first.span,
			pkg     = first.pkg,
			members = stored,
		})
		append(&c.contract_joins, join)
	}
	return proc_type_with_contract(c, x, join), true
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

// design.md "Borrowed callable views": `contract` with a view added as
// parameter 0, for the `call` member of a view whose signature carries it.
receiver_contract :: proc(c: ^Compiler, contract: Symbol_Id) -> Symbol_Id {
	if contract == INVALID_SYMBOL { return INVALID_SYMBOL }
	if existing, found := c.receiver_contracts[contract]; found { return existing }
	original := symbol_of(c, contract)
	id := new_symbol(c, Symbol{kind = .Proc, name = original.name, span = original.span, pkg = original.pkg})
	c.receiver_contracts[contract] = id
	c.receiver_contract_of[id] = contract
	return id
}

// -------------------------------------------------------------------- recording --

@(private = "file")
add_contract_check :: proc(c: ^Compiler, from, to: Type_Id, span: Span) {
	for check in c.proc_contract_checks {
		if check.from == from && check.to == to && check.span == span { return }
	}
	append(&c.proc_contract_checks, Proc_Contract_Check{from, to, span})
}

record_proc_contract_check :: proc(c: ^Compiler, from, to: Type_Id, span: Span) {
	a, b := underlying_info(c, from), underlying_info(c, to)
	if a == nil || b == nil || a.kind != .Proc || b.kind != .Proc || a.proc_contract == b.proc_contract { return }
	if b.proc_contract == INVALID_SYMBOL && discharged_escape(c, from, to) < 0 { return }
	if !proc_type_weakens_to(c, type_underlying(c, from), type_underlying(c, to)) { return }
	add_contract_check(c, from, to, span)
}

// A `call` method behind a view meets the signature's inferred contract as a
// procedure converting to it would. Its receiver is the view's parameter 0, so
// the two types line up although no conversion joins them.
record_call_contract_check :: proc(c: ^Compiler, method, forward: Type_Id, span: Span) {
	if info := underlying_info(c, forward); info == nil || info.proc_contract == INVALID_SYMBOL { return }
	add_contract_check(c, method, forward, span)
}

// design.md "Escape levels": the first parameter a written `@(escape=none)`
// asks of an inferred contract that leaves it at `result`, or -1. The summary
// answers it once inference settles.
discharged_escape :: proc(c: ^Compiler, from, to: Type_Id, after := -1) -> int {
	a := underlying_info(c, from)
	if a.proc_contract == INVALID_SYMBOL { return -1 }
	for index in after + 1 ..< len(a.parameters) {
		if proc_param_escape(c, from, index) == .Result && proc_param_escape(c, to, index) == .None { return index }
	}
	return -1
}

// --------------------------------------------------------------------- checking --

check_proc_contracts :: proc(k: ^Checker) {
	for check in k.c.proc_contract_checks {
		a, b := underlying_info(k.c, check.from), underlying_info(k.c, check.to)
		actual, have := result_summary(k.c, a.proc_contract)
		if b.proc_contract != INVALID_SYMBOL && !check_contract_bound(k.c, check, a.proc_contract, b.proc_contract, actual, have) {
			continue
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

// Whether `from` keeps within the contract `to` it is converted to, reporting why not.
@(private = "file")
check_contract_bound :: proc(c: ^Compiler, check: Proc_Contract_Check, from, to: Symbol_Id, actual: Result_Provenance, have: bool) -> bool {
	bound, known := result_summary(c, to)
	written := written_contract_within(c, from, to)
	read, reads_within := callback_reads_within(c, from, to)
	if have && known && result_contract_within(actual, bound) && written < 0 && reads_within { return true }
	errorf(c, check.span, "L0645", "procedure result provenance does not satisfy the inferred contract of `%s`", contract_name(c, to))
	if !reads_within {
		add_notef(c, check.span, "the result of `%s` may hold what `%s` leaves in an argument, which that contract excludes",
			contract_name(c, from), contract_param_name(c, from, read.callback))
	} else if written >= 0 {
		add_notef(c, check.span, "`%s` may leave an owner in `%s` from a region that contract does not",
			contract_name(c, from), contract_param_name(c, from, written))
	} else if have && known {
		add_excluded_borrow_notes(c, check.span, from, actual, bound)
	}
	add_contract_notes(c, to)
	add_precision_notes(c, check.span, actual.precision | bound.precision)
	return false
}

// The first global, and the first parameter, the result may borrow past the bound.
@(private = "file")
add_excluded_borrow_notes :: proc(c: ^Compiler, span: Span, from: Symbol_Id, actual, bound: Result_Provenance) {
	for global in actual.globals {
		if !slice.contains(bound.globals, global) {
			add_notef(c, span, "the result of `%s` may borrow the global `%s`, which that contract excludes",
				contract_name(c, from), identifier_text(c, symbol_of(c, global).name))
			break
		}
	}
	for index in 0 ..< len(actual.params) {
		if result_uses_param(actual, index) && !result_uses_param(bound, index) {
			add_notef(c, span, "the result of `%s` may borrow `%s`, which that contract excludes",
				contract_name(c, from), contract_param_name(c, from, index))
			break
		}
	}
}

@(private = "file")
contract_param_name :: proc(c: ^Compiler, id: Symbol_Id, index: int) -> string {
	// Members share the signature, so the first one names the parameter.
	sym := symbol_of(c, contract_members(c, id)[0])
	// A capture literal's `call` takes the plain `self` its captures are read
	// through (design.md "Capture literals"), whatever the receiver is named.
	if index == 0 && sym.has_receiver && type_is_capture_record(c, sym.owner_type) { return "self" }
	if index < len(sym.param_symbols) { return identifier_text(c, symbol_of(c, sym.param_symbols[index]).name) }
	return "an argument"
}

@(private = "file")
add_contract_notes :: proc(c: ^Compiler, id: Symbol_Id) {
	for member in contract_members(c, id) {
		add_notef(c, symbol_of(c, member).span, "result contract inferred from this declaration")
	}
}

// An empty bound covers every path; otherwise each path used must be in it.
@(private = "file")
paths_within :: proc(a, b: []bool) -> bool {
	if len(b) == 0 { return true }
	if len(a) != len(b) { return false }
	for used, path in a {
		if used && !b[path] { return false }
	}
	return true
}

@(private = "file")
dependency_contract_within :: proc(a, b: Result_Dependencies) -> bool {
	if (a.static && !b.static) || (a.thread && !b.thread) ||
	   (a.local && !b.local) || (a.unknown && !b.unknown) { return false }
	// A named global is its own root (design.md "Global write effects"):
	// `static` covers only storage no symbol names.
	for global in a.globals {
		if !slice.contains(b.globals, global) { return false }
	}
	for depths, index in a.param_loads {
		if depths != 0 && (index >= len(b.param_loads) || depths & ~b.param_loads[index] != 0) { return false }
		for depth in 1 ..= 8 {
			if depths & (u8(1) << u8(depth - 1)) == 0 { continue }
			if !paths_within(result_load_paths(a, index, depth), result_load_paths(b, index, depth)) { return false }
		}
	}
	for wanted, index in a.params {
		if !wanted { continue }
		if index >= len(b.params) || !b.params[index] { return false }
		if !paths_within(a.param_paths[index], b.param_paths[index]) { return false }
	}
	return true
}

@(private = "file")
region_contract_within :: proc(a, b: Region_Set) -> bool {
	if region_has_local(a) || (a.default && !b.default) || (a.unknown && !b.unknown) { return false }
	return a.params & ~b.params == 0
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
				// Backing and payload facts are independent even at overlapping paths.
				if source.own == target.own && source.handle == target.handle && prov_same_path(source.path, target.path) &&
				   !region_contract_within(source.region, target.region) { return false }
			}
		}
	}
	return true
}

// design.md "Procedure result contracts": a call through the contract takes
// the regions it leaves in each writable argument from the contract's own
// declaration, so a substitute may leave no others. The first parameter where
// `from` leaves more, or -1.
@(private = "file")
written_contract_within :: proc(c: ^Compiler, from, to: Symbol_Id) -> int {
	actual, _ := written_region_summary(c, from)
	bound, _ := written_region_summary(c, to)
	for set, index in actual {
		if !region_is_empty(set) && (index >= len(bound) || !region_contract_within(set, bound[index])) { return index }
	}
	return -1
}

// design.md "Procedure result contracts": a call through a contract reads the
// callbacks its result may hold from the contract's own declaration, so a
// substitute may read no others. The first read of `from` that `to` lacks.
@(private = "file")
callback_reads_within :: proc(c: ^Compiler, from, to: Symbol_Id) -> (Callback_Read, bool) {
	for member in contract_members(c, from) {
		for read in c.callback_result_reads[member] {
			found := false
			for bound in contract_members(c, to) {
				found = found || slice.contains(c.callback_result_reads[bound], read)
			}
			if !found {
				return read, false
			}
		}
	}
	return {}, true
}

// ------------------------------------------------------------------------ calls --

// The declaration whose contract a call substitutes; an indirect call takes its
// callee type's contract.
call_contract_declaration :: proc(c: ^Compiler, call: ^Expr_Call) -> Symbol_Id {
	id := call.resolution.chosen_overload
	if id == INVALID_SYMBOL { id = call.resolution.symbol }
	if sym := symbol_of(c, id); sym != nil && sym.kind == .Proc {
		// A `dyn` forwarding member has no body; a callable view's carries the
		// signature's contract (design.md "Borrowed callable views").
		if sym.synth == .Dyn_Forward {
			info := underlying_info(c, sym.proc_type)
			return info == nil ? INVALID_SYMBOL : info.proc_contract
		}
		return id
	}
	if base := expr_base(call.callee); base != nil {
		if info := underlying_info(c, base.type); info != nil && info.kind == .Proc { return info.proc_contract }
	}
	return INVALID_SYMBOL
}
