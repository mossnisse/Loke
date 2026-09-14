package lokec

import "core:fmt"

emit_synth_adapter :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	result := llvm_type(e, symbol.result)
	source := symbol.params[0]
	info := type_of(e.c, source)
	open_function(e, "define %s%s %s(ptr %%arg0)", llvm_linkage(name), result, name)
	e.terminated = false
	#partial switch symbol.synth {
	case .Refs_View:
		view := type_of(e.c, symbol.result)
		slice_type := llvm_type(e, symbol_of(e.c, view.fields[0]).type)
		source_info := underlying_info(e.c, source)
		items: string
		if source_info.kind == .Array {
			items = emit_ptr_len(e, slice_type, "%arg0", fmt.aprintf("%d", source_info.count))
		} else {
			self := load(e, llvm_type(e, source), "%arg0")
			if source_info.kind == .Slice {
				items = self
			} else {
				data := extract(e, llvm_type(e, source), self, CONTAINER_STORAGE)
				length := extract(e, llvm_type(e, source), self, CONTAINER_LEN)
				items = emit_ptr_len(e, slice_type, data, length)
			}
		}
		value := insert(e, result, "undef", slice_type, items, 0)
		fmt.sbprintfln(&e.b, "  ret %s %s", result, value)
	case .Refs_Iter, .Refs_Iter_Reverse:
		slice_type := llvm_type(e, symbol_of(e.c, info.fields[0]).type)
		items := load(e, slice_type, gep_field(e, llvm_type(e, source), "%arg0", 0))
		reversed := symbol.synth == .Refs_Iter_Reverse
		index := reversed ? extract(e, slice_type, items, SLICE_LEN) : "0"
		value := insert(e, result, "undef", slice_type, items, ITER_ARRAY_DATA)
		value = insert(e, result, value, "i64", index, ITER_ARRAY_INDEX)
		value = insert(e, result, value, "i1", reversed ? "true" : "false", ITER_ARRAY_REVERSED)
		fmt.sbprintfln(&e.b, "  ret %s %s", result, value)
	case .Adapter_View:
		view := type_of(e.c, symbol.result)
		held_type, held := "ptr", "%arg0"
		if view.adapter_by_value {
			held_type, held = llvm_type(e, source), load(e, llvm_type(e, source), "%arg0")
		}
		value := insert(e, result, "undef", held_type, held, 0)
		fmt.sbprintfln(&e.b, "  ret %s %s", result, value)
	case .Adapter_Iter:
		address := gep_field(e, llvm_type(e, source), "%arg0", 0)
		if !info.adapter_by_value { address = load(e, "ptr", address) }
		target := symbol_of(e.c, symbol.iteration_target)
		iterator := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call %s %s(ptr %s)", iterator, llvm_type(e, target.result), symbol_name(e, symbol.iteration_target), address)
		value := iterator
		if info.adapter_kind == .Indexed {
			value = insert(e, result, "undef", llvm_type(e, target.result), iterator, 0)
			value = insert(e, result, value, "i64", "0", 1)
		}
		fmt.sbprintfln(&e.b, "  ret %s %s", result, value)
	case .Iterator_Copy:
		value := load(e, result, "%arg0")
		if emit_lifecycle(e, source).managed { value = emit_clone_value(e, source, value) }
		fmt.sbprintfln(&e.b, "  ret %s %s", result, value)
	case .Indexed_Next:
		target := symbol_of(e.c, symbol.iteration_target)
		inner_option := target.result
		inner_type := llvm_type(e, inner_option)
		iterator := gep_field(e, llvm_type(e, source), "%arg0", 0)
		produced := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call %s %s(ptr %s)", produced, inner_type, symbol_name(e, symbol.iteration_target), iterator)
		tag := emit_union_tag(e, inner_option, produced)
		ok := temp(e)
		shape := union_layout(e.c, inner_option)
		fmt.sbprintfln(&e.b, "  %s = icmp eq i%d %s, %d", ok, shape.tag_bytes * 8, tag, union_index_of(e.c, inner_option, "some"))
		yielded, stopped := new_label(e, "indexed.yield"), new_label(e, "indexed.stop")
		branch_if(e, ok, yielded, stopped)
		place_label(e, yielded)
		payload_type := option_payload(e.c, inner_option)
		payload := emit_union_payload(e, inner_option, payload_type, emit_union_spill(e, inner_option, produced))
		// A lending source hands back a pointer into its own storage; the pair
		// this builds is a new value, so the element is read out of that storage
		// and owned from here (design.md "Iteration adapters").
		wrapped := symbol_of(e.c, type_of(e.c, type_underlying(e.c, info.element)).fields[ELEMENT_FIRST]).type
		if payload_type != wrapped {
			payload = load(e, llvm_type(e, wrapped), payload)
			if emit_lifecycle(e, wrapped).managed {
				payload = emit_clone_value(e, wrapped, payload)
			}
			payload_type = wrapped
		}
		counter := gep_field(e, llvm_type(e, source), "%arg0", 1)
		index := load(e, "i64", counter)
		pair_type := llvm_type(e, info.element)
		pair := insert(e, pair_type, "undef", llvm_type(e, payload_type), payload, 0)
		pair = insert(e, pair_type, pair, "i64", index, 1)
		stepped := temp(e)
		fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", stepped, index)
		fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", stepped, counter)
		fmt.sbprintfln(&e.b, "  ret %s %s", result, emit_option_some(e, symbol.result, pair))
		place_label(e, stopped)
		fmt.sbprintfln(&e.b, "  ret %s zeroinitializer", result)
	}
	fmt.sbprintln(&e.b, "}")
}
