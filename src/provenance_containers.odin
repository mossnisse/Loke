// What a container operation stores, and the provenance of text operations
// (design.md "Values that contain borrows", "string type conversions").
package lokec

// Stored key/value borrows become the container's, checked like an indexed
// assignment. A fallible write joins, since its failure edge changes nothing.
@(private)
prov_container_content :: proc(graph: ^Flow_Graph, v: ^Expr_Call, op: Container_Op, actuals: [][]int) {
	effects := CONTAINER_OP_EFFECTS[op]
	if effects & {.Stores_Content, .Empties, .Permutes} == {} {
		return
	}
	if len(v.bound) == 0 || v.bound[0] == nil {
		return
	}
	c := graph.k.c
	receiver := v.bound[0]
	receiver_type := prov_type(graph, receiver)
	info := underlying_info(c, receiver_type)
	if info == nil {
		return
	}
	if .Permutes in effects {
		// A dynamic array's facts already stand for any element (`prov_region_path`).
		if type_is_carrier(c, receiver_type) && prov_type_has_region(c, info.element) {
			prov_store_permuted_region(graph, prov_input_value(graph, receiver))
		}
		return
	}
	// A spread's elements are copied in, keeping the regions they are in.
	if op == .Append && type_is_managed(c, info.element) {
		spreads := v.variadic_spreads
		if v.variadic_forwards {
			spreads = v.bound[v.variadic_slot:][:1]
		}
		for spread in spreads {
			prov_store_spread_region(graph, prov_input_value(graph, receiver), prov_input_value(graph, spread))
		}
	}
	stored_values: []Expr
	#partial switch op {
	case .Append:
		stored_values = v.is_variadic ? v.variadic_elements : v.bound[1:]
	case .Insert:
		stored_values = v.bound[min(2, len(v.bound)):]
	case .Map_Try_Insert, .Map_Find_Or_Insert:
		stored_values = v.bound[1:]
	}
	for value in stored_values {
		prov_store_region(graph, prov_input_value(graph, receiver), prov_input_value(graph, value), element = true)
	}
	if .Empties in effects {
		if root, path, ok := prov_place_of(graph, receiver); ok {
			if content := prov_content_at(graph, root, path); len(content) > 0 {
				prov_define_content(graph, content, nil, v.span, path, receiver_type)
			}
		}
		return
	}
	// What the operation keeps, and where in the entry or element it lands.
	Contained :: struct {
		actual: []int,
		type:   Type_Id,
		step:   Proj_Step,
	}
	map_op := op == .Map_Try_Insert || op == .Map_Find_Or_Insert
	parts: [2]Contained
	count := 0
	add :: proc(parts: ^[2]Contained, count: ^int, actuals: [][]int, index: int, type: Type_Id, step: Proj_Step) {
		if index < len(actuals) {
			parts[count^] = Contained{actuals[index], type, step}
			count^ += 1
		}
	}
	#partial switch op {
	case .Append:
		add(&parts, &count, actuals, 1, info.element, proj_wild())
	case .Insert:
		add(&parts, &count, actuals, 2, info.element, proj_wild())
	case .Map_Try_Insert, .Map_Find_Or_Insert:
		add(&parts, &count, actuals, 1, info.key, proj_field(PROJ_MAP_KEY))
		add(&parts, &count, actuals, 2, info.element, proj_field(PROJ_MAP_VALUE))
	}
	stored: []int
	for part in parts[:count] {
		if type_carries_borrow(c, part.type).any {
			stored = prov_join(graph, stored, part.actual)
		}
	}
	if len(stored) == 0 {
		return
	}
	// Also covers a receiver reached through a carrier.
	prov_retain_escape(graph, receiver, stored, v.span)
	root, path, ok := prov_place_of(graph, receiver)
	if !ok {
		through, _, _ := prov_read_through_carrier(graph, receiver, store = true)
		for part in parts[:count] {
			prov_publish_contained(graph, through, part.actual, part.type, v.span)
		}
		return
	}
	// One keyed entry, whose key and value replace what they held; any element.
	base := map_op ? prov_extend(graph, path, prov_map_call_step(graph, v)) : path
	for part in parts[:count] {
		if len(part.actual) == 0 { continue }
		written := prov_extend(graph, base, part.step)
		if content := prov_content_at(graph, root, written); len(content) > 0 {
			prov_define_content(graph, content, part.actual, v.span, written, part.type, map_op)
		}
	}
}

// design.md "Weakening and reborrows": a container operation on a receiver behind a
// carrier stores through it, as `d^.append(x)` stores `x` in an element of what `d`
// points to, which reads back as what it holds (`prov_use_stored`, `prov_link_landed`).
@(private = "file")
prov_publish_contained :: proc(graph: ^Flow_Graph, through, sources: []int, type: Type_Id, span: Span) {
	if len(through) == 0 || len(sources) == 0 || !type_carries_borrow(graph.k.c, type).any {
		return
	}
	prov_use_stored(graph, sources, type, span)
	graph.has_linked_store = true
	prov_emit(graph, Prov_Event {
		kind = .Publish, span = span, sources = sources, into = through,
		linked = prov_store_linked(graph.k.c, type), carried = type, links_copies = true,
	})
}

// design.md "string type conversions": a text operation either borrows its
// operand or returns a fresh owner with no loans. The checker binds its one
// operand: the text, or the bytes or runes a conversion reads.
@(private)
prov_text_call :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []int {
	if len(v.bound) != 1 || v.bound[0] == nil {
		return nil
	}
	operand := v.bound[0]
	source := walk_flow_expr(graph, operand)
	if text_reads_bytes(v) {
		prov_reach(graph, source, v.span)
	}
	if !text_result_borrows(graph, v) {
		return nil
	}
	// An owning `string` operand lends its own storage, which a temporary gives
	// up at the end of its statement.
	if len(source) == 0 {
		if root, path, ok := prov_place_of(graph, operand); ok {
			return prov_borrow(graph, root, path, false, v.span, "view")
		}
		if !type_is_carrier(graph.k.c, prov_type(graph, operand)) && prov_expr_is_temporary(operand) {
			return prov_borrow(graph, prov_temp_root(graph, expr_span(operand)), nil, false, v.span, "view")
		}
	}
	return source
}

// Whether a text operation reads the bytes its operand views. `byte_len` reads
// only the header, and `bytes`, `runes`, and `rune_offsets` only derive views,
// whose later reads, returns, and stores are recorded where they happen.
@(private = "file")
text_reads_bytes :: proc(v: ^Expr_Call) -> bool {
	if operation, is_text := v.operation.(Call_Text); is_text {
		#partial switch operation.op {
		case .Byte_Len, .Bytes, .Runes, .Rune_Offsets:
			return false
		}
	}
	return true
}

// design.md "string type conversions": these copy into the default allocator,
// where the others borrow their operand.
text_conversion_copies :: proc(op: Text_Conversion) -> bool {
	return op == .String_From_Bytes || op == .String_From_C_View || op == .String_From_Runes
}

@(private = "file")
text_result_borrows :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> bool {
	#partial switch operation in v.operation {
	case Call_Text:
		if operation.op == .Copy { return false }
	case Call_Text_Conversion:
		if text_conversion_copies(operation.op) { return false }
	}
	return prov_type_or_wrapped(graph.k.c, prov_type(graph, v), type_is_carrier)
}
