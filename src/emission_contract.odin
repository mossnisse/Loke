// The checked-program boundary: validates that every registry the emitter reads
// was settled during checking. It never resolves, checks, or repairs anything.
package lokec

emission_contract_error :: proc(c: ^Compiler, message: string) -> bool {
	errorf(c, no_span(), "L0405", "internal backend contract violation: %s", message)
	return false
}

validate_emission_dependencies :: proc(c: ^Compiler) -> bool {
	if c.error_count != 0 { return false }
	if c.speculation_depth != 0 {
		return emission_contract_error(c, "emission was requested during speculative checking")
	}
	if c.build_mode == .Exe && !emission_procedure_available(c, c.entry_point) {
		return emission_contract_error(c, "an executable has no validated entry procedure")
	}
	if !c.typeid_frozen {
		return emission_contract_error(c, "typeids must be frozen before emission")
	}
	if len(c.typeid_values) != len(c.typeid_order) || len(c.typeid_requested) != len(c.typeid_order) {
		return emission_contract_error(c, "the frozen typeid registry is incomplete")
	}
	ids := make(map[u64]bool, context.temp_allocator)
	for type in c.typeid_order {
		id := typeid_value(c, type)
		if type_of(c, type) == nil || !c.typeid_requested[type] ||
		   id == 0 || id > u64(len(c.typeid_order)) || ids[id] {
			return emission_contract_error(c, "a requested type has no unique frozen typeid")
		}
		ids[id] = true
	}

	// A committed generic body is checked and enrolled; signature-only ones are not.
	enrolled := make(map[Symbol_Id]bool, context.temp_allocator)
	for pkg in c.packages {
		for instance in pkg.instances {
			symbol := symbol_of(c, instance.symbol)
			if symbol == nil || instance.decl == nil {
				return emission_contract_error(c, "an emitted instance has no declaration")
			}
			if symbol.generic { continue }
			if instance.decl.check_state != .Checked || !emission_procedure_available(c, instance.symbol) {
				return emission_contract_error(c, "an emitted instance has not been checked")
			}
			enrolled[instance.symbol] = true
		}
	}
	for symbol, instance in c.procedure_instances {
		if instance == nil || (instance.body_checked && !enrolled[symbol]) {
			return emission_contract_error(c, "a committed generic body is missing from its package")
		}
	}

	// Synthesized map bodies need a settled key policy.
	for &info in c.types {
		if info.kind == .Map && .Container in info.contributed &&
		   c.map_key_policies[info.key].kind == .Unresolved {
			return emission_contract_error(c, "a map key operation was not resolved during checking")
		}
	}
	for _, policy in c.map_key_policies {
		if policy.kind == .Unresolved || (policy.kind == .Inherent &&
		   (!emission_procedure_available(c, policy.hash) || !emission_procedure_available(c, policy.equal))) {
			return emission_contract_error(c, "a resolved map key operation has no checked procedure")
		}
	}
	// A sort's `<`, already followed through any delegation.
	for _, policy in c.order_policies {
		if policy.kind == .Inherent && !emission_procedure_available(c, policy.less) {
			return emission_contract_error(c, "a resolved ordering operation has no checked procedure")
		}
	}
	// A discovered `format`; INVALID_SYMBOL means a generated formatter.
	for _, hook in c.formatters {
		if hook != INVALID_SYMBOL && !emission_procedure_available(c, hook) {
			return emission_contract_error(c, "a discovered formatter has no checked procedure")
		}
	}
	if !c.lifecycle_operations_ready {
		return emission_contract_error(c, "lifecycle operations must be finalized before emission")
	}
	synthesized := make(map[Symbol_Id]bool, context.temp_allocator)
	for id in c.synth_procs { synthesized[id] = true }
	for index in 1 ..< len(c.types) {
		// Records are keyed by underlying type, so each is validated once.
		type := Type_Id(index)
		if type_underlying(c, type) != type { continue }
		operations, resolved := resolved_lifecycle_operations(c, type)
		if !resolved {
			return emission_contract_error(c, "a type has no finalized lifecycle operations")
		}
		// Each hook and copy operation must be emittable and owned by this type.
		for target in ([]Symbol_Id{operations.custom_drop, operations.custom_try_clone}) {
			if target == INVALID_SYMBOL { continue }
			symbol := symbol_of(c, target)
			if symbol == nil || !emission_procedure_available(c, target) ||
			   type_underlying(c, symbol.owner_type) != type {
				return emission_contract_error(c, "a lifecycle hook has no checked procedure")
			}
		}
		for target, slot in ([]Symbol_Id{operations.clone, operations.try_clone}) {
			if target == INVALID_SYMBOL { continue }
			symbol := symbol_of(c, target)
			expected: Synth_Kind = slot == 0 ? .Clone : .Try_Clone
			if symbol == nil || !emission_procedure_available(c, target) || !synthesized[target] ||
			   symbol.synth != expected || type_underlying(c, symbol.owner_type) != type {
				return emission_contract_error(c, "a lifecycle copy operation has no registered procedure")
			}
		}
	}
	// And every contributed clone must be the one its type records.
	for id in c.synth_procs {
		symbol := symbol_of(c, id)
		if symbol == nil || (symbol.synth != .Clone && symbol.synth != .Try_Clone) { continue }
		operations, _ := resolved_lifecycle_operations(c, symbol.owner_type)
		target := symbol.synth == .Clone ? operations.clone : operations.try_clone
		if target != id {
			return emission_contract_error(c, "a contributed lifecycle procedure has no recorded operation")
		}
	}
	for witness in c.witness_order {
		if witness == nil || witness.name == "" || type_of(c, witness.concrete) == nil {
			return emission_contract_error(c, "a witness has no concrete type or global name")
		}
		for slot in witness.slots {
			if !emission_procedure_available(c, slot.target) {
				return emission_contract_error(c, "a witness slot has no checked procedure")
			}
		}
	}
	for entry in c.materialized_order {
		if entry == nil || entry.name == "" || entry.value.kind == .Invalid ||
		   type_of(c, entry.type) == nil || c.materialized[entry.symbol] != entry {
			return emission_contract_error(c, "a materialized constant has no registered definition")
		}
	}
	return true
}

@(private = "file")
emission_procedure_available :: proc(c: ^Compiler, id: Symbol_Id) -> bool {
	symbol := symbol_of(c, id)
	if symbol == nil || symbol.kind != .Proc || symbol.generic ||
	   symbol.signature_error || type_of(c, symbol.proc_type) == nil {
		return false
	}
	if symbol.is_foreign || symbol.synth != .None || symbol.delegated { return true }
	if instance, found := c.procedure_instances[id]; found {
		return instance.body_checked && instance.signature_ok
	}
	if symbol.decl != nil { return symbol.decl.check_state == .Checked }
	return symbol.proc_literal != nil
}
