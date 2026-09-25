package lokec

import "core:fmt"

emit_synth_adapter :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	result := llvm_type(e, symbol.result)
	source := symbol.params[0]
	info := type_of(e.c, source)
	open_function(e, "define %s%s %s(%sptr %%arg0)", llvm_linkage(name), llvm_result_type(e, symbol.result), name, sret_param(e, symbol.result))
	e.terminated = false
	#partial switch symbol.synth {
	case .Adapter_View:
		view := type_of(e.c, symbol.result)
		held_type, held := "ptr", "%arg0"
		if view.adapter_by_value {
			held_type, held = llvm_type(e, source), load_place(e, source, "%arg0")
		}
		value := insert(e, result, "undef", held_type, held, 0)
		emit_ret(e, symbol.result, value)
	case .Adapter_Iter:
		address := gep_field(e, llvm_type(e, source), "%arg0", 0)
		if !info.adapter_by_value { address = load(e, "ptr", address) }
		target := symbol_of(e.c, symbol.iteration_target)
		// A value `self` takes the source itself.
		source_type, source_arg := "ptr", address
		if !param_mode_is_pointer(symbol_param_mode(e.c, target, 0)) {
			source_type = llvm_type(e, target.params[0])
			source_arg = load_place(e, target.params[0], address)
		}
		iterator := emit_call_result(e, target.result, symbol_name(e, symbol.iteration_target), fmt.aprintf("%s %s", source_type, source_arg))
		value := iterator
		if info.adapter_kind == .Indexed {
			value = insert(e, result, "undef", llvm_type(e, target.result), iterator, 0)
			value = insert(e, result, value, "i64", "0", 1)
		} else if info.adapter_kind == .Copied {
			value = insert(e, result, "undef", llvm_type(e, target.result), iterator, 0)
		}
		emit_ret(e, symbol.result, value)
	case .Iterator_Copy:
		value := load_place(e, symbol.result, "%arg0")
		if emit_lifecycle(e, source).managed { value = emit_clone_value(e, source, value) }
		emit_ret(e, symbol.result, value)
	case .Indexed_Next:
		target := symbol_of(e.c, symbol.iteration_target)
		inner_option := target.result
		iterator := gep_field(e, llvm_type(e, source), "%arg0", 0)
		produced := emit_call_result(e, inner_option, symbol_name(e, symbol.iteration_target), fmt.aprintf("ptr %s", iterator))
		tag := emit_union_tag(e, inner_option, produced)
		ok := temp(e)
		shape := union_layout(e.c, inner_option)
		fmt.sbprintfln(&e.b, "  %s = icmp eq i%d %s, %d", ok, shape.tag_bytes * 8, tag, union_index_of(e.c, inner_option, "some"))
		yielded, stopped := new_label(e, "indexed.yield"), new_label(e, "indexed.stop")
		branch_if(e, ok, yielded, stopped)
		place_label(e, yielded)
		payload_type := option_payload(e.c, inner_option)
		payload := emit_union_payload(e, inner_option, payload_type, emit_union_spill(e, inner_option, produced))
		// Preserve the source iterator's ownership inside the indexed pair.
		pair_id := option_payload(e.c, symbol.result)
		wrapped := symbol_of(e.c, type_of(e.c, type_underlying(e.c, pair_id)).fields[ELEMENT_FIRST]).type
		payload = own_yielded(e, payload, payload_type, wrapped)
		counter := gep_field(e, llvm_type(e, source), "%arg0", 1)
		index := load(e, "i64", counter)
		pair_type := llvm_type(e, pair_id)
		pair := insert(e, pair_type, "undef", llvm_type(e, wrapped), payload, 0)
		pair = insert(e, pair_type, pair, "i64", index, 1)
		stepped := temp(e)
		fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", stepped, index)
		fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", stepped, counter)
		emit_ret(e, symbol.result, emit_option_some(e, symbol.result, pair))
		fmt.sbprintfln(&e.b, "%s:", stopped)
		emit_ret(e, symbol.result, "zeroinitializer")
	case .Copied_Next:
		target := symbol_of(e.c, symbol.iteration_target)
		inner_option := target.result
		iterator := gep_field(e, llvm_type(e, source), "%arg0", 0)
		produced := emit_call_result(e, inner_option, symbol_name(e, symbol.iteration_target), fmt.aprintf("ptr %s", iterator))
		tag := emit_union_tag(e, inner_option, produced)
		ok := temp(e)
		shape := union_layout(e.c, inner_option)
		fmt.sbprintfln(&e.b, "  %s = icmp eq i%d %s, %d", ok, shape.tag_bytes * 8, tag, union_index_of(e.c, inner_option, "some"))
		yielded, stopped := new_label(e, "copied.yield"), new_label(e, "copied.stop")
		branch_if(e, ok, yielded, stopped)
		place_label(e, yielded)
		handed := option_payload(e.c, inner_option)
		payload := emit_union_payload(e, inner_option, handed, emit_union_spill(e, inner_option, produced))
		owned := own_yielded(e, payload, handed, option_payload(e.c, symbol.result))
		emit_ret(e, symbol.result, emit_option_some(e, symbol.result, owned))
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
	held := type_of(e.c, type_underlying(e.c, handed))
	target := type_of(e.c, type_underlying(e.c, wanted))
	llvm, out := llvm_type(e, handed), llvm_type(e, wanted)
	built := "undef"
	for id, index in target.fields {
		field := symbol_of(e.c, id)
		part := own_yielded(
			e, extract(e, llvm, payload, index), symbol_of(e.c, held.fields[index]).type, field.type,
		)
		built = insert(e, out, built, llvm_type(e, field.type), part, index)
	}
	return built
}
