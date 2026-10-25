// Leaf reads shared by replay. Source-form classification belongs to input
// construction; following the selected storage and its facts belongs to replay.
package lokec

Prov_Read_Input :: struct {
	// A non-place projection may forward its operand's carrier targets.
	fallback: Value_Id,
	unknown_alias: bool,
}

prov_input_read :: proc(graph: ^Flow_Graph, id: Value_Id) -> Prov_Read_Input {
	if input, found := graph.input.read_inputs[id]; found { return input }
	prov_writable_input(graph)
	value := prov_value(graph, id)
	input: Prov_Read_Input
	if value.origin == nil { return input }
	input.unknown_alias = prov_alias_source_is_unknown(graph.k.c, value.type, value.origin)
	#partial switch origin in value.origin {
	case ^Expr_Selector: input.fallback = prov_input_value(graph, origin.operand)
	case ^Expr_Index: input.fallback = prov_input_value(graph, origin.operand)
	case ^Expr_Postfix: input.fallback = prov_input_value(graph, origin.operand)
	case ^Expr_Unary:
		if origin.op == .Amp { input.fallback = prov_input_value(graph, origin.operand) }
	}
	graph.input.read_inputs[id] = input
	return input
}

// design.md "Minimum provenance precision": each possible indirect source
// contributes known targets or an unresolved alternative.
prov_read_value_aliases :: proc(graph: ^Flow_Graph, id: Value_Id) -> []Written_Alias {
	value := graph.input.values[int(id)]
	input := prov_input_read(graph, id)
	aliases: []Written_Alias
	switch base in value.place.base {
	case Storage_Id:
		aliases = prov_written_aliases_of(graph, base, value.place.path)
	case Value_Id:
		out := make([dynamic]Written_Alias, graph.alloc)
		for target in prov_value_aliases(graph, base) {
			if target.target == 0 {
				append(&out, target)
				continue
			}
			loaded := prov_written_aliases_of(graph, target.target, prov_concat_path(graph, target.at, value.place.path))
			if len(loaded) == 0 && input.unknown_alias { append(&out, Written_Alias{})
			} else { append(&out, ..loaded) }
		}
		aliases = out[:]
	case:
		if input.fallback != 0 { aliases = prov_value_aliases(graph, input.fallback) }
	}
	if len(aliases) == 0 && input.unknown_alias {
		out := make([]Written_Alias, 1, graph.alloc)
		return out
	}
	return aliases
}
