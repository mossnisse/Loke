// Compile-time result contracts on ordinary procedure values.
package lokec

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
	if root, id := constant_root_of(k.c, value); id != INVALID_SYMBOL { request_materialization(k, root) }
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
	if a == nil || b == nil || a.kind != .Proc || b.kind != .Proc ||
	   b.proc_contract == INVALID_SYMBOL || a.proc_contract == b.proc_contract { return }
	if !proc_escape_weakens_to(c, type_underlying(c, from), type_underlying(c, to)) { return }
	for check in c.proc_contract_checks {
		if check.from == from && check.to == to && check.span == span { return }
	}
	if c.proc_contract_checks.allocator.procedure == nil {
		c.proc_contract_checks = make([dynamic]Proc_Contract_Check, 0, 8, c.semantic_allocator)
	}
	append(&c.proc_contract_checks, Proc_Contract_Check{from, to, span})
}

check_proc_contracts :: proc(k: ^Checker) {
	for check in k.c.proc_contract_checks {
		a, b := underlying_info(k.c, check.from), underlying_info(k.c, check.to)
		actual, have := result_summary(k.c, a.proc_contract)
		bound, known := result_summary(k.c, b.proc_contract)
		if !have || !known || !result_contract_within(actual, bound) {
			errorf(k.c, check.span, "L0645", "procedure result provenance does not satisfy the inferred contract of `%s`",
				identifier_text(k.c, symbol_of(k.c, b.proc_contract).name))
			add_notef(k.c, symbol_of(k.c, b.proc_contract).span, "result contract inferred from this declaration")
			add_precision_notes(k.c, check.span, actual.precision | bound.precision)
		}
	}
}

@(private = "file")
dependency_contract_within :: proc(a, b: Result_Dependencies) -> bool {
	if (a.static && !b.static) || (a.thread && !b.thread) || (a.fresh && !b.fresh) ||
	   (a.local && !b.local) || (a.unknown && !b.unknown) { return false }
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

// Calls through contract-bearing values use precisely the same substitution
// and fixed-point dependency as a direct call. This does not devirtualize them.
call_contract_declaration :: proc(c: ^Compiler, call: ^Expr_Call) -> Symbol_Id {
	id := call.resolution.chosen_overload
	if id == INVALID_SYMBOL { id = call.resolution.symbol }
	if sym := symbol_of(c, id); sym != nil && sym.kind == .Proc { return id }
	if base := expr_base(call.callee); base != nil {
		if info := underlying_info(c, base.type); info != nil && info.kind == .Proc { return info.proc_contract }
	}
	return INVALID_SYMBOL
}
