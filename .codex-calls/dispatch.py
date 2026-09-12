from pathlib import Path
root = Path(__file__).resolve().parent.parent
files = {p.name: p.read_text(encoding='utf-8') for p in (root / 'src').glob('*.odin')}
def replace(name, old, new):
    assert old in files[name], (name, old)
    files[name] = files[name].replace(old, new)
def section(name, start, end, new):
    text = files[name]; a = text.index(start); b = text.index(end, a)
    files[name] = text[:a] + new + text[b:]

section('emit_llvm_calls.odin', '\tif v.operation != nil', '\tsymbol := symbol_of(e.c, v.resolution.symbol)', '''	switch operation in v.operation {
	case Call_Enum_From_Int:
		value := emit_expr(e, v.bound[0])
		present := "false"
		for member in underlying_info(e.c, operation.type).fields {
			sym := symbol_of(e.c, member)
			matches := temp(e)
			fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", matches,
				llvm_type(e, operation.type), value, bi_text(e.c, sym.const_value.integer))
			if present == "false" {
				present = matches
			} else {
				joined := temp(e)
				fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", joined, present, matches)
				present = joined
			}
		}
		return emit_option_value(e, as_type, present, value)
	case Call_Extract:
		return emit_any_view_extract(e, operation.node, operation.node.type)[0]
	case Call_Dyn_Slot:
		results := emit_dyn_slot_call(e, v)
		return len(results) == 0 ? "0" : results[0]
	case Call_Dyn_Conversion:
		return emit_dyn_value(e, v, as_type)
	case Call_Text_Conversion:
		return emit_text_conversion(e, v, as_type)[0]
	case Call_Conversion:
		return emit_conversion(e, v, as_type)
	case Call_Reflect:
		return emit_descriptor_operation(e, v)
	case Call_Union_Construct:
		return emit_union_operation(e, v, as_type)
	case Call_Text:
		return emit_text_operation(e, v, as_type)[0]
	case Call_Procedure:
		results := emit_direct_call(e, v)
		return len(results) == 0 ? "0" : results[0]
	case Call_Builtin, Call_Atomic, Call_Allocation, Call_Sort_By, Call_Simd_Reduce:
		// These intrinsic families retain their exact operation's symbol.
	case nil, Call_Compile_Time:
		backend_fail(e, "an unchecked or compile-time call reached emission")
		return "0"
	}
''')
replace('emit_llvm_calls.odin', '\tresults := emit_direct_call(e, v)\n\treturn len(results) == 0 ? "0" : results[0]\n}', '\tbackend_fail(e, "an intrinsic call has no builtin symbol")\n\treturn "0"\n}')
section('emit_llvm_calls.odin', '\t\t// `value.as(T)`: one extraction lowering', '\t\tif kind := call_builtin_kind(e, v); kind == .Unsafe_String_View', '''		#partial switch operation in v.operation {
		case Call_Extract:
			return emit_any_view_extract(e, operation.node, operation.node.type)
		case Call_Dyn_Slot:
			return emit_dyn_slot_call(e, v)
		case Call_Allocation:
			kind := call_builtin_kind(e, v)
			if kind == .Make { return emit_make_container(e, v, as_type) }
			return emit_allocation_pair(e, v, kind, as_type)
		case Call_Text:
			return emit_text_operation(e, v, as_type)
		case Call_Text_Conversion:
			return emit_text_conversion(e, v, as_type)
		}
''')
section('emit_llvm_calls.odin', '\tif v.operation in Call_Conversion ||', '\n}\n', '''	switch v.operation {
	case Call_Builtin, Call_Atomic, Call_Allocation, Call_Sort_By, Call_Simd_Reduce:
		sym := symbol_of(e.c, v.resolution.symbol)
		return sym != nil && sym.kind == .Builtin ? sym.builtin : Builtin_Kind.None
	case:
		return .None
	}''')
replace('emit_llvm_calls.odin', '\tif v.operation in Call_Text_Conversion {\n\t\treturn emit_text_conversion(e, v, as_type)[0]\n\t}\n', '')
replace('emit_llvm_calls.odin', '\tif !(v.operation in Call_Union_Construct) || len(v.bound) != 1 {', '\toperation, construction := v.operation.(Call_Union_Construct)\n\tif !construction || len(v.bound) != 1 {')
replace('emit_llvm_calls.odin', 'if v.operation.(Call_Union_Construct).clone {', 'if operation.clone {')
replace('emit_llvm_calls.odin', 'return emit_union_value(e, as_type, v.operation.(Call_Union_Construct).index, payload)', 'return emit_union_value(e, as_type, operation.index, payload)')

section('cfg.odin', '\tif v.operation != nil', '\t// design.md "Variable declarations": an unevaluated operand', '''	#partial switch operation in v.operation {
	case Call_Enum_From_Int:
		walk_flow_expr(graph, v.bound[0])
		return nil // integer input and enum payload carry no borrows
	case Call_Extract:
		// The same extraction node as the postfix spelling.
		return walk_flow_expr(graph, operation.node)
	case Call_Union_Construct:
		loans: []int
		if len(v.bound) == 1 { loans = walk_flow_expr(graph, v.bound[0]) }
		if graph.mode == .Lifecycle { return nil }
		return prov_variant_content(graph, v, loans)
	}
''')

section('eval.odin', '\tif v.operation != nil', '\t// Standard built-in customization members likewise', '''	#partial switch operation in v.operation {
	case Call_Enum_From_Int:
		value, ok := eval_expr(ev, v.bound[0])
		if !ok { return Eval_Value{}, false }
		candidate := Const_Value{kind = .Integer, integer = value.integer}
		if enum_member_by_value(ev.k.c, operation.type, candidate) == INVALID_SYMBOL {
			return eval_named_union(ev, v.type, "none", Eval_Value{})
		}
		value.type = operation.type
		return eval_named_union(ev, v.type, "some", value)
	case Call_Conversion, Call_Dyn_Conversion:
		return eval_conversion(ev, v)
	case Call_Union_Construct:
		return eval_union_construct(ev, v)
	case Call_Extract:
		// The postfix spelling has no compile-time meaning either.
		eval_fail(ev, v.span, "L0341", "this expression has no compile-time meaning")
		return Eval_Value{}, false
	case Call_Text:
		return eval_text_op(ev, v)
	case Call_Builtin, Call_Atomic, Call_Allocation, Call_Sort_By, Call_Simd_Reduce:
		callee := symbol_of(ev.k.c, v.resolution.symbol)
		if callee != nil && callee.kind == .Builtin { return eval_builtin(ev, v, callee) }
	case nil:
		eval_fail(ev, v.span, "L0341", "an unchecked call has no compile-time meaning")
		return Eval_Value{}, false
	}
''')
replace('cfg_provenance.odin', 'if v.operation in Call_Union_Construct {', 'if _, construction := v.operation.(Call_Union_Construct); construction {')
replace('cfg_provenance.odin', 'if v.operation.(Call_Text_Conversion).op == .String_From_Bytes || v.operation.(Call_Text_Conversion).op == .String_From_C_View {', 'if operation, conversion := v.operation.(Call_Text_Conversion); conversion &&\n\t   (operation.op == .String_From_Bytes || operation.op == .String_From_C_View) {')
replace('cfg_provenance.odin', 'if v.operation in Call_Extract && type_is_managed(c, result_type) {', 'if _, extraction := v.operation.(Call_Extract); extraction && type_is_managed(c, result_type) {')
replace('cfg_provenance.odin', '\tif v.operation in Call_Text || v.operation in Call_Text_Conversion {\n\t\treturn prov_text_call(graph, v)\n\t}', '\t#partial switch v.operation {\n\tcase Call_Text, Call_Text_Conversion:\n\t\treturn prov_text_call(graph, v)\n\t}')
section('cfg_provenance.odin', '\tif v.text == .Copy', '\treturn prov_carries_borrow(c, v.type)', '''	#partial switch operation in v.operation {
	case Call_Text:
		if operation.op == .Copy || operation.op == .From_Runes { return false }
	case Call_Text_Conversion:
		if operation.op == .String_From_Bytes || operation.op == .String_From_C_View { return false }
	}
''')

for name, text in files.items():
    path = root / 'src' / name
    if text != path.read_text(encoding='utf-8'): path.write_text(text, encoding='utf-8', newline='\n')
