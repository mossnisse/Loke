// Leaf reads shared by replay. Source-form classification belongs to input
// construction; following the selected storage and its facts belongs to replay.
package lokec

Prov_Read_Input :: struct {
	// A non-place projection may forward its operand's carrier targets.
	fallback: Value_Id,
	unknown_alias: bool,
}

prov_input_read :: proc(graph: ^Flow_Graph, id: Value_Id) -> Prov_Read_Input {
	value := prov_value(graph, id)
	input := Prov_Read_Input{unknown_alias = value.unknown_alias}
	#partial switch form in value.form {
	case Prov_Form_Selector: input.fallback = form.operand
	case Prov_Form_Index: input.fallback = form.operand
	case Prov_Form_Postfix: input.fallback = form.operand
	case Prov_Form_Unary:
		if form.op == .Amp { input.fallback = form.operand }
	}
	return input
}

// design.md "Minimum provenance precision": what a load through a carrier
// reaches, from each of the carrier's `targets`, at `path` below it. Each
// possible source contributes known targets or, when `unknown` says the read
// may find storage no write named, an unresolved alternative, even beside
// another source's known targets.
@(private)
prov_load_aliases :: proc(graph: ^Flow_Graph, targets: []Written_Alias, path: []Proj_Step, unknown: bool) -> []Written_Alias {
	out := make([dynamic]Written_Alias, graph.alloc)
	for target in targets {
		if target.target == 0 {
			append(&out, target)
			continue
		}
		loaded := prov_written_aliases_of(graph, target.target, prov_concat_path(graph, target.at, path))
		if len(loaded) == 0 && unknown { append(&out, Written_Alias{})
		} else { append(&out, ..loaded) }
	}
	return out[:]
}

// The aliases a read through `id` reaches. Unlike a write's targets
// (`prov_written_aliases_at`), a read that finds nothing at all is also
// unresolved when it may find storage no write named.
prov_read_value_aliases :: proc(graph: ^Flow_Graph, id: Value_Id) -> []Written_Alias {
	value := graph.input.values[int(id)]
	input := prov_input_read(graph, id)
	aliases: []Written_Alias
	switch base in value.place.base {
	case Storage_Id:
		aliases = prov_written_aliases_of(graph, base, value.place.path)
	case Value_Id:
		aliases = prov_load_aliases(graph, prov_value_aliases(graph, base), value.place.path, input.unknown_alias)
	case:
		if input.fallback != 0 { aliases = prov_value_aliases(graph, input.fallback) }
	}
	if len(aliases) == 0 && input.unknown_alias {
		out := make([]Written_Alias, 1, graph.alloc)
		return out
	}
	return aliases
}
