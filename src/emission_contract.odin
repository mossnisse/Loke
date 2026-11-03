// The checked-program boundary: validates that every registry the emitter reads
// was settled during checking. It never resolves, checks, or repairs anything.
package lokec

emission_contract_error :: proc(c: ^Compiler, message: string) -> bool {
	errorf(c, no_span(), "L0405", "internal backend contract violation: %s", message)
	return false
}

validate_emission_dependencies :: proc(c: ^Compiler) -> bool {
	if c.error_count != 0 { return false }
	if !committing(c) {
		return emission_contract_error(c, "emission was requested during speculative checking")
	}
	// A held error is out of `error_count` until it is released.
	if len(c.held_diagnostics) != 0 {
		return emission_contract_error(c, "diagnostics are still held aside from checking")
	}
	if !c.program_analyzed {
		return emission_contract_error(c, "the whole-program analyses have not completed")
	}
	if !c.formatters_ready {
		return emission_contract_error(c, "formatter discovery has not completed")
	}
	if !c.typeid_frozen {
		return emission_contract_error(c, "typeids must be frozen before emission")
	}
	if !c.lifecycle_operations_ready {
		return emission_contract_error(c, "lifecycle operations must be finalized before emission")
	}
	return validate_carrier_types(c) && validate_entry_procedures(c) && validate_typeids(c) &&
	       validate_generic_instances(c) && validate_operation_policies(c) && validate_lifecycle(c) &&
	       validate_witnesses(c) && validate_spawns(c) && validate_materialized(c)
}

// The emitter reads carrier fields and a map's key policy; it never installs them.
@(private = "file")
validate_carrier_types :: proc(c: ^Compiler) -> bool {
	for info in c.types {
		#partial switch info.kind {
		case .Slice, .Dynamic_Array, .Map:
			if len(info.fields) == 0 {
				return emission_contract_error(c, "a carrier type has no installed fields")
			}
		}
		// Synthesized map bodies need a settled key policy.
		if info.kind == .Map && .Container in info.contributed &&
		   c.map_key_policies[info.key].kind == .Unresolved {
			return emission_contract_error(c, "a map key operation was not resolved during checking")
		}
	}
	return true
}

@(private = "file")
validate_entry_procedures :: proc(c: ^Compiler) -> bool {
	if c.build_mode == .Exe && !emission_procedure_available(c, c.entry_point) {
		return emission_contract_error(c, "an executable has no validated entry procedure")
	}
	for test in c.tests {
		if !emission_procedure_available(c, test) {
			return emission_contract_error(c, "a test build has an unchecked test procedure")
		}
	}
	return true
}

@(private = "file")
validate_typeids :: proc(c: ^Compiler) -> bool {
	if len(c.typeid_values) != len(c.typeid_order) || len(c.typeid_requested) != len(c.typeid_order) {
		return emission_contract_error(c, "the frozen typeid registry is incomplete")
	}
	seen := make([]bool, len(c.typeid_order) + 1, context.temp_allocator)
	for type in c.typeid_order {
		id := typeid_value(c, type)
		if type_of(c, type) == nil || !c.typeid_requested[type] ||
		   id == 0 || id > u64(len(c.typeid_order)) || seen[id] {
			return emission_contract_error(c, "a requested type has no unique frozen typeid")
		}
		seen[id] = true
	}
	return true
}

// A committed generic body is checked and enrolled; signature-only ones are not.
@(private = "file")
validate_generic_instances :: proc(c: ^Compiler) -> bool {
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
	return true
}

@(private = "file")
validate_operation_policies :: proc(c: ^Compiler) -> bool {
	for _, policy in c.map_key_policies {
		if policy.kind == .Inherent &&
		   (!emission_procedure_available(c, policy.hash) || !emission_procedure_available(c, policy.equal)) {
			return emission_contract_error(c, "a resolved map key operation has no checked procedure")
		}
	}
	// A sort's `<`, already followed through any delegation.
	for _, policy in c.order_policies {
		if policy.kind == .Inherent && !emission_procedure_available(c, policy.less) {
			return emission_contract_error(c, "a resolved ordering operation has no checked procedure")
		}
	}
	// Erased formatting uses the same witness as an explicit interface view.
	for _, witness in c.formatters {
		if witness == nil || len(witness.slots) != 1 || !emission_procedure_available(c, witness.slots[0].target) {
			return emission_contract_error(c, "a discovered formatter has no checked procedure")
		}
	}
	return true
}

@(private = "file")
validate_lifecycle :: proc(c: ^Compiler) -> bool {
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
		for target in ([]Symbol_Id{operations.custom_drop, operations.custom_try_clone}) {
			if target == INVALID_SYMBOL { continue }
			if !emission_procedure_available(c, target) ||
			   type_underlying(c, symbol_of(c, target).owner_type) != type {
				return emission_contract_error(c, "a lifecycle hook has no checked procedure")
			}
		}
		for target, slot in ([]Symbol_Id{operations.clone, operations.try_clone}) {
			if target == INVALID_SYMBOL { continue }
			expected: Synth_Kind = slot == 0 ? .Clone : .Try_Clone
			if !emission_procedure_available(c, target) || !synthesized[target] ||
			   symbol_of(c, target).synth != expected || type_underlying(c, symbol_of(c, target).owner_type) != type {
				return emission_contract_error(c, "a lifecycle copy operation has no registered procedure")
			}
		}
	}
	// And every contributed clone must be the one its type records.
	for id in c.synth_procs {
		symbol := symbol_of(c, id)
		if symbol == nil || (symbol.synth != .Clone && symbol.synth != .Try_Clone) { continue }
		operations, _ := resolved_lifecycle_operations(c, symbol.owner_type)
		// A `distinct` name's own pair copies through its underlying `try_clone`.
		is_distinct := type_underlying(c, symbol.owner_type) != symbol.owner_type
		target := is_distinct || symbol.synth == .Try_Clone ? operations.try_clone : operations.clone
		if is_distinct ? target == INVALID_SYMBOL : target != id {
			return emission_contract_error(c, "a contributed lifecycle procedure has no recorded operation")
		}
	}
	return true
}

@(private = "file")
validate_witnesses :: proc(c: ^Compiler) -> bool {
	for witness in c.witness_order {
		if witness == nil || witness.concrete == INVALID_TYPE || type_of(c, witness.concrete) == nil {
			return emission_contract_error(c, "a witness has no concrete type")
		}
		for slot in witness.slots {
			if !emission_procedure_available(c, slot.target) {
				return emission_contract_error(c, "a witness slot has no checked procedure")
			}
		}
	}
	return true
}

// compiler-architecture.md "Lowering parallel blocks" gives the frame's layout.
@(private = "file")
validate_spawns :: proc(c: ^Compiler) -> bool {
	for task in c.spawn_tasks {
		frame := underlying_info(c, task.frame)
		if frame == nil || frame.kind != .Struct || len(frame.fields) != spawn_frame_field_count(task) {
			return emission_contract_error(c, "a spawn has no registered frame")
		}
		if !emission_procedure_available(c, task.run) || !emission_procedure_available(c, task.start) {
			return emission_contract_error(c, "a spawn has no checked run or start procedure")
		}
		scope, result := symbol_of(c, task.scope), symbol_of(c, task.result)
		if scope == nil || scope.kind != .Var || (task.result != INVALID_SYMBOL && (result == nil || result.kind != .Var)) {
			return emission_contract_error(c, "a spawn's scope or result is not a local")
		}
	}
	return true
}

@(private = "file")
validate_materialized :: proc(c: ^Compiler) -> bool {
	for entry in c.materialized_order {
		if entry == nil || entry.name == "" || entry.value.kind == .Invalid ||
		   type_of(c, entry.type) == nil || c.materialized[entry.key] != entry {
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

// How much the checked program holds: a new symbol (every field and member is
// one), type, or registry entry changes it.
Semantic_Extent :: struct {
	using registries: Emission_Registries,
	symbols, types, procedure_instances, formatters, lifecycle, map_keys, orders: int,
}

semantic_extent :: proc(c: ^Compiler) -> Semantic_Extent {
	return {
		registries = emission_registries(c),
		symbols = len(c.symbols), types = len(c.types), procedure_instances = len(c.procedure_instances),
		formatters = len(c.formatters), lifecycle = len(c.lifecycle_operations),
		map_keys = len(c.map_key_policies), orders = len(c.order_policies),
	}
}
