package lokec

import "core:fmt"

emit_synth_adapter :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	source := symbol.params[0]
	info := type_of(e.c, source)
	open_synth_receiver(e, name, symbol.result)
	#partial switch symbol.synth {
	case .Adapter_View:
		held := "%arg0"
		if type_of(e.c, symbol.result).adapter_by_value {
			held = load_place(e, source, "%arg0")
			if emit_lifecycle(e, source).managed { held = emit_clone_value(e, source, held) }
		}
		emit_ret(e, symbol.result, build_record(e, symbol.result, held))
	case .Adapter_Iter:
		address := gep_field(e, llvm_type(e, source), "%arg0", 0)
		if !info.adapter_by_value { address = load(e, "ptr", address) }
		target := symbol_of(e.c, symbol.iteration_target)
		// A value `self` takes the source itself.
		mode := symbol_param_mode(e.c, target, 0)
		source_arg := param_mode_is_pointer(mode) ? address : load_place(e, target.params[0], address)
		arguments := fmt.aprintf("%s %s", param_llvm(e, target.params[0], mode), source_arg)
		value := emit_call_result(e, target.result, symbol_name(e, symbol.iteration_target), arguments)
		#partial switch info.adapter_kind {
		case .Indexed: value = build_record(e, symbol.result, value, "0")
		case .Copied:  value = build_record(e, symbol.result, value)
		}
		emit_ret(e, symbol.result, value)
	case .Iterator_Copy:
		value := load_place(e, symbol.result, "%arg0")
		if emit_lifecycle(e, source).managed { value = emit_clone_value(e, source, value) }
		emit_ret(e, symbol.result, value)
	case .Indexed_Next, .Copied_Next:
		target := symbol_of(e.c, symbol.iteration_target)
		inner_option := target.result
		iterator := gep_field(e, llvm_type(e, source), "%arg0", 0)
		produced := emit_call_result(e, inner_option, symbol_name(e, symbol.iteration_target), fmt.aprintf("ptr %s", iterator))
		ok := emit_union_tag_is(e, inner_option, produced, union_index_of(e.c, inner_option, "some"))
		yielded, stopped := new_label(e, "adapter.yield"), new_label(e, "adapter.stop")
		branch_if(e, ok, yielded, stopped)
		place_label(e, yielded)
		handed := option_payload(e.c, inner_option)
		payload := emit_union_payload(e, inner_option, handed, emit_union_spill(e, inner_option, produced))
		item := option_payload(e.c, symbol.result)
		wrapped: string
		if symbol.synth == .Indexed_Next {
			counter := gep_field(e, llvm_type(e, source), "%arg0", 1)
			index := load(e, "i64", counter)
			step_counter(e, counter, "i64")
			wrapped = build_record(e, item, payload, index)
		} else {
			wrapped = own_yielded(e, payload, handed, item)
		}
		emit_ret(e, symbol.result, emit_option_some(e, symbol.result, wrapped))
		fmt.sbprintfln(&e.b, "%s:", stopped)
		emit_ret(e, symbol.result, "zeroinitializer")
	}
	fmt.sbprintln(&e.b, "}")
}

// Copy borrowed leaves and preserve already-owned ones.
@(private = "file")
own_yielded :: proc(e: ^Emitter, payload: string, handed, wanted: Type_Id) -> string {
	if handed == wanted {
		return payload
	}
	if type_is_pointer(e.c, handed) {
		value := load_place(e, wanted, payload)
		if emit_lifecycle(e, wanted).managed {
			return emit_clone_value(e, wanted, value)
		}
		return value
	}
	held := underlying_info(e.c, handed)
	target := underlying_info(e.c, wanted)
	parts := make([]string, len(target.fields))
	for id, index in target.fields {
		part := record_part(e, handed, payload, index)
		parts[index] = own_yielded(e, part, symbol_of(e.c, held.fields[index]).type, symbol_of(e.c, id).type)
	}
	return build_record(e, wanted, ..parts)
}
