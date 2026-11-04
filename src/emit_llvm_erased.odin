// Erased views: `dyn` values and slot calls, witness tables and their thunks,
// and the forwarding bodies of `dyn I` and `dyn proc`.
package lokec

import "core:fmt"
import "core:strings"

// `(dyn I)(&value)`: the data pointer plus the witness, or for a callable view
// the witness's one thunk.
@(private)
emit_dyn_value :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	storage := llvm_type(e, as_type)
	data := emit_expr(e, v.bound[0])
	witness := v.operation.(Call_Dyn_Conversion).witness
	second := e.witness_names[witness]
	if dyn_proc_signature(e.c, as_type) != INVALID_TYPE {
		second = witness_thunk_name(e, witness, 0)
	}
	return dyn_view_value(e, storage, data, second)
}

// A view's two words, built in fresh storage.
@(private)
dyn_view_value :: proc(e: ^Emitter, storage, data, second: string) -> string {
	first := insert(e, storage, "undef", "ptr", data, DYN_DATA)
	return insert(e, storage, first, "ptr", second, DYN_WITNESS)
}

// design.md "Variadic parameters": the view a `..dyn I` pack holds of a value,
// paired with the witness the checker requested for its type.
@(private)
emit_dyn_view_value :: proc(e: ^Emitter, address: string, from, as_type: Type_Id) -> string {
	dyn := underlying_info(e.c, as_type)
	witness := lookup_witness(e.c, dyn.dyn_interface, from, dyn.dyn_args)
	if witness == nil {
		backend_fail(e, "a value reached a `dyn` view with no witness")
		return "undef"
	}
	return dyn_view_value(e, llvm_type(e, as_type), address, e.witness_names[witness])
}

// design.md "Borrowed callable views": a procedure is the data word itself,
// called by its signature's adapter, so the view borrows nothing; a capture
// value is viewed where it is, or in a temporary, and called by its `call`.
@(private)
emit_dyn_proc_value :: proc(e: ^Emitter, expr: Expr, from, as_type: Type_Id) -> string {
	storage := llvm_type(e, as_type)
	data, code: string
	if underlying_kind(e.c, from) == .Proc {
		data = emit_expr_at(e, expr, from)
		code = symbol_name(e, e.c.dyn_proc_adapters[carrier_abi_type(e.c, as_type)])
	} else {
		data = spill_viewed_at(e, expr, from)
		dyn := underlying_info(e.c, as_type)
		witness := lookup_witness(e.c, dyn.dyn_interface, from, dyn.dyn_args)
		if witness == nil {
			backend_fail(e, "a capture literal reached a `dyn proc` view with no witness")
			return "undef"
		}
		code = witness_thunk_name(e, witness, 0)
	}
	return dyn_view_value(e, storage, data, code)
}

@(private)
emit_dyn_slot_call :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	view := emit_expr(e, v.bound[0])
	storage := llvm_type(e, expr_base(v.bound[0]).type)
	data := extract(e, storage, view, DYN_DATA)
	thunk := emit_witness_slot(e, extract(e, storage, view, DYN_WITNESS), v.operation.(Call_Dyn_Slot).index)
	signature := type_of(e.c, expr_base(v.callee).type)
	return emit_bound_call(e, INVALID_SYMBOL, thunk, signature, v.bound, v, receiver = data, receiver_type = "ptr")
}

@(private)
emit_witness_slot :: proc(e: ^Emitter, witness: string, index: int) -> string {
	return load(e, "ptr", gep_at(e, "ptr", witness, fmt.aprintf("%d", index)))
}

// One witness table per `(Interface, Concrete, arguments)`, holding a thunk per
// slot that re-types the erased receiver.
@(private)
emit_witnesses :: proc(e: ^Emitter) {
	for witness in e.c.witness_order {
		for slot, index in witness.slots {
			emit_witness_thunk(e, witness, slot, index)
		}
	}
	for witness in e.c.witness_order {
		fmt.sbprintf(&e.b, "%s = private unnamed_addr constant [%d x ptr] [", e.witness_names[witness], len(witness.slots))
		for _, index in witness.slots {
			if index > 0 {
				fmt.sbprint(&e.b, ",")
			}
			fmt.sbprintf(&e.b, " ptr %s", witness_thunk_name(e, witness, index))
		}
		fmt.sbprintln(&e.b, " ]")
	}
	fmt.sbprintln(&e.b, "")
}

@(private)
witness_thunk_name :: proc(e: ^Emitter, witness: ^Witness, index: int) -> string {
	return fmt.aprintf("%s.thunk.%d", e.witness_names[witness], index)
}

@(private = "file")
emit_witness_thunk :: proc(e: ^Emitter, witness: ^Witness, slot: Witness_Slot, index: int) {
	target := symbol_of(e.c, slot.target)
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	signature := type_of(e.c, target.proc_type)
	open_forwarding_function(e, "private ", witness_thunk_name(e, witness, index), target, signature, "ptr")

	// The receiver arrives as a pointer; a target taking its receiver by value
	// gets it loaded.
	receiver_type, receiver := "ptr", "%arg0"
	if !param_mode_is_pointer(symbol_param_mode(e.c, target, 0)) {
		receiver_type = param_llvm(e, target.params[0], .Value)
		receiver = load_place(e, target.params[0], "%arg0")
	}
	emit_forwarding_call(e, target, signature, symbol_name(e, slot.target), receiver_type, receiver)
	fmt.sbprintln(&e.b, "")
}

// `dyn I` satisfies `I` through slots that take the view and call its thunk with
// the data pointer.
@(private)
emit_dyn_forwarding_slot :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	signature := type_of(e.c, symbol.proc_type)
	view_type := llvm_type(e, symbol.params[0])
	receiver_by_ptr := param_mode_is_pointer(param_mode_at(signature, 0))
	open_forwarding_function(e, llvm_linkage(name), name, symbol, signature, receiver_by_ptr ? "ptr" : view_type)

	view := receiver_by_ptr ? load(e, view_type, "%arg0") : "%arg0"
	// A callable view holds its one slot's code directly.
	thunk := extract(e, view_type, view, DYN_WITNESS)
	if dyn_proc_signature(e.c, symbol.params[0]) == INVALID_TYPE {
		thunk = emit_witness_slot(e, thunk, int(symbol.index))
	}
	emit_forwarding_call(e, symbol, signature, thunk, "ptr", extract(e, view_type, view, DYN_DATA))
}

// design.md "Borrowed callable views": the code word of a view holding a
// procedure. The data word is the procedure, called with everything after it.
@(private)
emit_dyn_proc_adapter :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	signature := type_of(e.c, symbol.proc_type)
	open_forwarding_function(e, llvm_linkage(name), name, symbol, signature, "ptr")
	emit_forwarding_call(e, symbol, signature, "%arg0", "", "")
}

// The header of a function that forwards `symbol`'s parameters: the receiver at
// `%arg0`, after any `%sret`, and `%argN` for the rest.
@(private = "file")
open_forwarding_function :: proc(
	e: ^Emitter, linkage, name: string, symbol: ^Symbol, signature: ^Type_Info, receiver_type: string,
) {
	fmt.sbprintf(
		&e.b, "define %s%s %s(%s%s %%arg0", linkage, llvm_result_type(e, symbol.result, signature.result_inout), name,
		sret_param(e, symbol.result, signature.result_inout), receiver_type,
	)
	for position in 1 ..< len(symbol.params) {
		fmt.sbprintf(&e.b, ", %s %%arg%d", param_llvm(e, symbol.params[position], signature.param_modes[position]), position)
	}
	open_function(e, ")")
}

// Calls `callee` with the receiver, if any, and the forwarded parameters,
// returns its result, and closes the function.
@(private = "file")
emit_forwarding_call :: proc(
	e: ^Emitter, symbol: ^Symbol, signature: ^Type_Info, callee, receiver_type, receiver: string,
) {
	result_type := llvm_result_type(e, symbol.result, signature.result_inout)
	sret := returns_sret(e, symbol.result, signature.result_inout)
	args := make([dynamic]string, 0, len(symbol.params) + 1, context.temp_allocator)
	if sret {
		append(&args, "ptr %sret")
	}
	if receiver_type != "" {
		append(&args, fmt.tprintf("%s %s", receiver_type, receiver))
	}
	for position in 1 ..< len(symbol.params) {
		append(&args, fmt.tprintf("%s %%arg%d", param_llvm(e, symbol.params[position], signature.param_modes[position]), position))
	}
	joined := strings.join(args[:], ", ", context.temp_allocator)
	emit_forward_ret(e, "call", sret || symbol.result == INVALID_TYPE ? "void" : result_type, callee, joined)
	fmt.sbprintln(&e.b, "}")
}
