// Markers keep source tracking out of individual instruction-emission sites;
// they are resolved once the module is complete. See compiler-architecture.md
// "LLVM and toolchain". Natvis follows runtime map entries and erased values
// that LLVM metadata cannot describe.
package lokec

import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

@(private = "file")
PROC_MARKER :: ";dbg.proc "
@(private = "file")
LOCATION_MARKER :: ";dbg.loc "
@(private = "file")
VARIABLE_MARKER :: ";dbg.var "
@(private = "file")
OPEN_MARKER :: ";dbg.open"
@(private = "file")
CLOSE_MARKER :: ";dbg.close"

@(private)
debug_mark_proc :: proc(e: ^Emitter, symbol_id: Symbol_Id) {
	if e.c.debug_info {
		fmt.sbprintfln(&e.b, "%s%d", PROC_MARKER, u32(symbol_id))
	}
}

@(private)
debug_mark_location :: proc(e: ^Emitter, span: Span) {
	if e.c.debug_info && span.file != NO_FILE {
		fmt.sbprintfln(&e.b, "%s%d %d", LOCATION_MARKER, span.file, span.lo)
		e.debug_span = span
	}
}

// The code a statement or block runs as it ends, such as its scope's cleanup,
// at its closing `}`.
@(private)
debug_mark_end :: proc(e: ^Emitter, span: Span) {
	if span.hi > span.lo {
		debug_mark_location(e, Span{file = span.file, lo = span.hi - 1})
	}
}

@(private)
debug_mark_scope :: proc(e: ^Emitter, open: bool) {
	if e.c.debug_info {
		fmt.sbprintln(&e.b, open ? OPEN_MARKER : CLOSE_MARKER)
	}
}

@(private)
debug_mark_variable :: proc(e: ^Emitter, symbol_id: Symbol_Id, address: string) {
	if e.c.debug_info && symbol_id != INVALID_SYMBOL {
		fmt.sbprintfln(&e.b, "%s%d %s", VARIABLE_MARKER, u32(symbol_id), address)
	}
}

@(private = "file")
Debug_Info :: struct {
	c:         ^Compiler,
	meta:      strings.Builder,
	count:     int,
	files:     map[u32]int,
	types:     map[Type_Id]int,
	// By scope, line, and column.
	locations: map[[3]int]int,
	// Types only natvis names, kept by the compile unit.
	retained:  [dynamic]int,
	map_table: int,
	natvis:    strings.Builder,
	// Each witness table's global by its LLVM name, and the `witness$<n>`
	// variables their definitions carry.
	witnesses: map[string]int,
	globals:   [dynamic]int,
	dyns:      [dynamic]Type_Id,
}

// Metadata `!0` to `!3` are fixed: the unit, the two module flags, and the one
// subroutine type every procedure shares, since no debugger needs its
// parameter types to set a breakpoint or walk the stack.
@(private = "file")
UNIT :: 0
@(private = "file")
SUBROUTINE_TYPE :: 3

// The procedure being rewritten, while inside a marked one.
@(private = "file")
Debug_Proc :: struct {
	symbol:     ^Symbol,
	subprogram: int,
	location:   int,
	// The statement `location` names.
	span:       Span,
	// The open scopes, innermost last: each one's `DILexicalBlock`, or -1 until
	// a local is declared in it, so a scope without locals adds no block.
	blocks:     [dynamic]int,
}

// The module with every marker replaced: a marked procedure's `define` and its
// instructions carry `!dbg`, its locals are declared where they get their
// addresses, and the metadata they name follows the module. An unmarked
// function, such as a thunk, gets none, and markers inside it vanish.
@(private)
attach_debug_info :: proc(e: ^Emitter, module: string) -> string {
	c := e.c
	d := Debug_Info {
		c         = c,
		meta      = strings.builder_make(),
		count     = SUBROUTINE_TYPE + 1,
		files     = make(map[u32]int),
		types     = make(map[Type_Id]int),
		locations = make(map[[3]int]int),
		natvis    = strings.builder_make(),
		witnesses = make(map[string]int),
	}
	for witness, index in c.witness_order {
		d.witnesses[e.witness_names[witness]] = index
	}
	strings.write_string(&d.natvis, NATVIS_HEADER)
	out := strings.builder_make()
	current: Maybe(Debug_Proc)
	rest := module
	for line in strings.split_lines_iterator(&rest) {
		p, inside := &current.?
		switch {
		case strings.has_prefix(line, PROC_MARKER):
			id, _ := strconv.parse_uint(line[len(PROC_MARKER):])
			symbol := symbol_of(c, Symbol_Id(id))
			if symbol == nil {
				continue
			}
			subprogram := debug_subprogram(&d, symbol, e.names[Symbol_Id(id)])
			current = Debug_Proc {
				symbol     = symbol,
				subprogram = subprogram,
				location   = debug_location(&d, subprogram, symbol.span),
				span       = symbol.span,
			}
			// The `define` line just written ends in ` {`.
			resize(&out.buf, len(out.buf) - len(" {\n"))
			fmt.sbprintfln(&out, " !dbg !%d {{", subprogram)
		case strings.has_prefix(line, LOCATION_MARKER):
			fields := strings.fields(line[len(LOCATION_MARKER):])
			file, _ := strconv.parse_uint(fields[0])
			lo, _ := strconv.parse_uint(fields[1])
			// A location's file is its subprogram's, so a statement written in
			// another file keeps the location before it.
			if inside && u32(file) == p.symbol.span.file {
				p.span = Span{file = u32(file), lo = u32(lo)}
				p.location = debug_location(&d, debug_scope(p), p.span)
			}
		case line == OPEN_MARKER:
			if inside {
				append(&p.blocks, -1)
			}
		case line == CLOSE_MARKER:
			// The code after a scope keeps its location's line, outside the scope.
			if inside && len(p.blocks) > 0 {
				pop(&p.blocks)
				p.location = debug_location(&d, debug_scope(p), p.span)
			}
		case strings.has_prefix(line, VARIABLE_MARKER):
			if inside {
				debug_declare(&d, &out, p, line[len(VARIABLE_MARKER):])
			}
		case inside && strings.has_prefix(line, "  "):
			fmt.sbprintfln(&out, "%s, !dbg !%d", line, p.location)
		case strings.has_prefix(line, "@loke.w."):
			name := line[:strings.index(line, " = ")]
			if index, found := d.witnesses[name]; found {
				fmt.sbprintfln(&out, "%s, !dbg !%d", line, debug_witness(&d, index))
			} else {
				fmt.sbprintln(&out, line)
			}
		case:
			if line == "}" {
				current = nil
			}
			fmt.sbprintln(&out, line)
		}
	}

	debug_any_view_natvis(&d)
	debug_dyn_natvis(&d)
	strings.write_string(&d.natvis, "</AutoVisualizer>\n")
	c.natvis = strings.to_string(d.natvis)
	retained := ""
	if len(d.retained) > 0 {
		nodes := strings.builder_make()
		for node, index in d.retained {
			fmt.sbprintf(&nodes, "%s!%d", index > 0 ? ", " : "", node)
		}
		retained = fmt.aprintf(", retainedTypes: !%d", debug_node(&d, "!{{%s}", strings.to_string(nodes)))
	}
	globals := ""
	if len(d.globals) > 0 {
		nodes := strings.builder_make()
		for node, index in d.globals {
			fmt.sbprintf(&nodes, "%s!%d", index > 0 ? ", " : "", node)
		}
		globals = fmt.aprintf(", globals: !%d", debug_node(&d, "!{{%s}", strings.to_string(nodes)))
	}

	optimized := c.opt_mode != .None
	fmt.sbprintln(&out, "declare void @llvm.dbg.declare(metadata, metadata, metadata)")
	fmt.sbprintln(&out, "!llvm.dbg.cu = !{!0}")
	fmt.sbprintln(&out, "!llvm.module.flags = !{!1, !2}")
	// Loke has no DWARF language code; C's describes its procedures well enough.
	fmt.sbprintfln(
		&out,
		`!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !%d, producer: "lokec %s", isOptimized: %v, runtimeVersion: 0, emissionKind: FullDebug%s%s)`,
		debug_file(&d, package_of(c, c.root_package).files[0].file), LOKE_VERSION_STRING, optimized, retained, globals,
	)
	fmt.sbprintln(&out, `!1 = !{i32 2, !"Debug Info Version", i32 3}`)
	// Windows debuggers read CodeView, in a PDB the linker writes.
	fmt.sbprintln(&out, `!2 = !{i32 2, !"CodeView", i32 1}`)
	fmt.sbprintln(&out, "!3 = !DISubroutineType(types: !{})")
	strings.write_string(&out, strings.to_string(d.meta))
	return strings.to_string(out)
}

// The innermost open scope with a block, or the procedure.
@(private = "file")
debug_scope :: proc(p: ^Debug_Proc) -> int {
	#reverse for block in p.blocks {
		if block >= 0 {
			return block
		}
	}
	return p.subprogram
}

// `<symbol> <address>` becomes the local's declaration, at its own line, in the
// innermost open scope, so two sibling scopes' locals of one name never appear
// side by side. That scope's block starts here: the code before a local's
// declaration does not see it.
@(private = "file")
debug_declare :: proc(d: ^Debug_Info, out: ^strings.Builder, p: ^Debug_Proc, marker: string) {
	space := strings.index_byte(marker, ' ')
	id, _ := strconv.parse_uint(marker[:space])
	symbol_id := Symbol_Id(id)
	symbol := symbol_of(d.c, symbol_id)
	if symbol == nil || symbol.span.file != p.symbol.span.file {
		return
	}
	if len(p.blocks) > 0 && p.blocks[len(p.blocks) - 1] < 0 {
		line, column := line_col(&d.c.sources[symbol.span.file], symbol.span.lo)
		p.blocks[len(p.blocks) - 1] = debug_node(
			d, "distinct !DILexicalBlock(scope: !%d, file: !%d, line: %d, column: %d)",
			debug_scope(p), debug_file(d, symbol.span.file), line, column,
		)
		p.location = debug_location(d, debug_scope(p), p.span)
	}
	scope := debug_scope(p)
	arg := ""
	for param, index in p.symbol.param_symbols {
		if param == symbol_id {
			arg = fmt.aprintf("arg: %d, ", index + 1)
		}
	}
	file := debug_file(d, symbol.span.file)
	line, _ := line_col(&d.c.sources[symbol.span.file], symbol.span.lo)
	variable := debug_node(
		d, `!DILocalVariable(name: "%s", %sscope: !%d, file: !%d, line: %d, type: !%d)`,
		llvm_escape(identifier_text(d.c, symbol.name)), arg, scope, file, line,
		debug_type(d, symbol.type),
	)
	fmt.sbprintfln(
		out,
		"  call void @llvm.dbg.declare(metadata ptr %s, metadata !%d, metadata !DIExpression()), !dbg !%d",
		marker[space + 1:], variable, debug_location(d, scope, symbol.span),
	)
}

@(private = "file")
debug_node :: proc(d: ^Debug_Info, format: string, args: ..any) -> int {
	id := d.count
	d.count += 1
	debug_node_at(d, id, format, ..args)
	return id
}

// A node whose number was taken before its operands were, so a type can refer
// to itself through a pointer.
@(private = "file")
debug_node_at :: proc(d: ^Debug_Info, id: int, format: string, args: ..any) {
	fmt.sbprintf(&d.meta, "!%d = ", id)
	fmt.sbprintfln(&d.meta, format, ..args)
}

@(private = "file")
debug_file :: proc(d: ^Debug_Info, file: u32) -> int {
	if id, found := d.files[file]; found {
		return id
	}
	path, _ := filepath.abs(d.c.sources[file].path)
	id := debug_node(
		d, `!DIFile(filename: "%s", directory: "%s")`,
		llvm_escape(filepath.base(path)), llvm_escape(path_dir(path)),
	)
	d.files[file] = id
	return id
}

@(private = "file")
debug_subprogram :: proc(d: ^Debug_Info, symbol: ^Symbol, llvm_name: string) -> int {
	file := debug_file(d, symbol.span.file)
	line, _ := line_col(&d.c.sources[symbol.span.file], symbol.span.lo)
	name := symbol.exported ? symbol.link_name : debug_proc_name(llvm_name)
	flags := d.c.opt_mode != .None ? "DISPFlagDefinition | DISPFlagOptimized" : "DISPFlagDefinition"
	return debug_node(
		d,
		`distinct !DISubprogram(name: "%s", scope: !%d, file: !%d, line: %d, type: !%d, scopeLine: %d, spFlags: %s, unit: !%d)`,
		llvm_escape(name), file, file, line, SUBROUTINE_TYPE, line, flags, UNIT,
	)
}

@(private = "file")
debug_location :: proc(d: ^Debug_Info, scope: int, span: Span) -> int {
	line, column := line_col(&d.c.sources[span.file], span.lo)
	key := [3]int{scope, line, column}
	if id, found := d.locations[key]; found {
		return id
	}
	id := debug_node(d, "!DILocation(line: %d, column: %d, scope: !%d)", line, column, scope)
	d.locations[key] = id
	return id
}

// A type as a debugger shows it, laid out as the program stores it. A type
// with no closer description is a named block of its size.
@(private = "file")
debug_type :: proc(d: ^Debug_Info, type: Type_Id) -> int {
	if id, found := d.types[type]; found {
		return id
	}
	c := d.c
	id := d.count
	d.count += 1
	d.types[type] = id
	info := type_of(c, type)
	name := llvm_escape(type_name(c, type))
	size := type_size(c, type) * 8
	if info == nil {
		debug_composite(d, id, "DW_TAG_structure_type", name, size, "")
		return id
	}
	// CodeView clamps wide enumerators; expose their exact stored bits.
	if (info.kind == .Int || info.kind == .Enum) && size == 128 {
		members := strings.builder_make()
		debug_member(d, &members, "low", TYPE_U64, 0)
		debug_member(d, &members, "high", TYPE_U64, 8)
		debug_composite(d, id, "DW_TAG_structure_type", name, size, strings.to_string(members))
		return id
	}
	#partial switch info.kind {
	case .Bool:
		debug_node_at(d, id, `!DIBasicType(name: "%s", size: 8, encoding: DW_ATE_boolean)`, name)
	case .Int:
		encoding := info.signed ? "DW_ATE_signed" : "DW_ATE_unsigned"
		debug_node_at(d, id, `!DIBasicType(name: "%s", size: %d, encoding: %s)`, name, size, encoding)
	case .Float:
		debug_node_at(d, id, `!DIBasicType(name: "%s", size: %d, encoding: DW_ATE_float)`, name, size)
	case .Rune:
		debug_node_at(d, id, `!DIBasicType(name: "%s", size: 32, encoding: DW_ATE_UTF)`, name)
	case .Typeid:
		debug_node_at(d, id, `!DIBasicType(name: "%s", size: %d, encoding: DW_ATE_unsigned)`, name, size)
	case .Pointer, .C_Pointer:
		debug_node_at(d, id, "!DIDerivedType(tag: DW_TAG_pointer_type, baseType: !%d, size: 64)", debug_type(d, info.element))
	case .Raw_Pointer, .CString_View:
		debug_node_at(d, id, `!DIDerivedType(tag: DW_TAG_pointer_type, name: "%s", baseType: null, size: 64)`, name)
	case .Proc:
		debug_node_at(d, id, `!DIDerivedType(tag: DW_TAG_pointer_type, name: "%s", baseType: !%d, size: 64)`, name, SUBROUTINE_TYPE)
	case .Distinct:
		debug_node_at(
			d, id, `!DIDerivedType(tag: DW_TAG_typedef, name: "%s", baseType: !%d)`,
			name, debug_type(d, info.element),
		)
	case .Array:
		debug_node_at(
			d, id, "!DICompositeType(tag: DW_TAG_array_type, baseType: !%d, size: %d, elements: !{{!DISubrange(count: %d)}})",
			debug_type(d, info.element), size, info.count,
		)
	case .Enum:
		enumerators := strings.builder_make()
		for field, index in info.fields {
			member := symbol_of(c, field)
			fmt.sbprintf(
				&enumerators, "%s!DIEnumerator(name: \"%s\", value: %s%s)",
				index > 0 ? ", " : "", llvm_escape(identifier_text(c, member.name)),
				bi_text(c, member.const_value.integer), type_signed(c, type) ? "" : ", isUnsigned: true",
			)
		}
		debug_node_at(
			d, id, `!DICompositeType(tag: DW_TAG_enumeration_type, name: "%s", baseType: !%d, size: %d, elements: !{{%s})`,
			name, debug_type(d, info.element), size, strings.to_string(enumerators),
		)
	case .Struct, .Any_View, .Dyn:
		if info.kind == .Dyn {
			name = fmt.aprintf("dyn$%d", u32(type))
			append(&d.dyns, type)
		}
		members := strings.builder_make()
		for field, index in info.fields {
			member := symbol_of(c, field)
			if field_is_padding(c, field) {
				continue
			}
			debug_member(
				d, &members, identifier_text(c, member.name), member.type,
				type_field_offset(c, type, index),
			)
		}
		debug_composite(d, id, "DW_TAG_structure_type", name, size, strings.to_string(members))
	case .String, .String_View, .Slice, .Dynamic_Array:
		// design.md "string type" and "Slices": data first, then its length; a
		// dynamic array's header adds its capacity.
		element := info.kind == .String || info.kind == .String_View ? TYPE_U8 : info.element
		members := strings.builder_make()
		debug_pointer_member(d, &members, "data", debug_type(d, element), 0)
		debug_member(d, &members, "len", TYPE_INT, 8)
		if info.kind == .Dynamic_Array {
			debug_member(d, &members, "cap", TYPE_INT, 16)
		}
		// WinDbg shows a type named `string` its own way and ignores natvis for it.
		if type == TYPE_STRING {
			name = "string$"
		}
		debug_composite(d, id, "DW_TAG_structure_type", name, size, strings.to_string(members))
	case .Union:
		debug_union(d, id, type, name)
	case .Map:
		debug_map(d, id, type)
	case:
		debug_composite(d, id, "DW_TAG_structure_type", name, size, "")
	}
	return id
}

@(private = "file")
debug_composite :: proc(d: ^Debug_Info, id: int, tag, name: string, size: u64, members: string) {
	debug_node_at(
		d, id, `distinct !DICompositeType(tag: %s, name: "%s", size: %d, elements: !{{%s})`,
		tag, name, size, members,
	)
}

@(private = "file")
debug_member :: proc(d: ^Debug_Info, members: ^strings.Builder, name: string, type: Type_Id, offset: u64) {
	member := debug_node(
		d, `!DIDerivedType(tag: DW_TAG_member, name: "%s", baseType: !%d, size: %d, offset: %d)`,
		llvm_escape(name), debug_type(d, type), type_size(d.c, type) * 8, offset * 8,
	)
	fmt.sbprintf(members, "%s!%d", strings.builder_len(members^) > 0 ? ", " : "", member)
}

@(private = "file")
debug_pointer_member :: proc(d: ^Debug_Info, members: ^strings.Builder, name: string, pointee: int, offset: u64) {
	pointer := debug_node(d, "!DIDerivedType(tag: DW_TAG_pointer_type, baseType: !%d, size: 64)", pointee)
	member := debug_node(
		d, `!DIDerivedType(tag: DW_TAG_member, name: "%s", baseType: !%d, size: 64, offset: %d)`,
		name, pointer, offset * 8,
	)
	fmt.sbprintf(members, "%s!%d", strings.builder_len(members^) > 0 ? ", " : "", member)
}

// design.md "Unions": the payload overlaps at offset zero, one member per
// variant that carries one, and the tag, which is the variant's index, follows.
@(private = "file")
debug_union :: proc(d: ^Debug_Info, id: int, type: Type_Id, name: string) {
	c := d.c
	info := type_of(c, type)
	shape := union_layout(c, type)
	variants := strings.builder_make()
	for payload, index in info.variants {
		if payload != TYPE_VOID {
			debug_member(d, &variants, identifier_text(c, info.variant_names[index]), payload, 0)
		}
	}
	payload := debug_node(d, "distinct !DICompositeType(tag: DW_TAG_union_type, size: %d, elements: !{{%s})",
		shape.payload_size * 8, strings.to_string(variants))
	payload_member := debug_node(d, `!DIDerivedType(tag: DW_TAG_member, name: "payload", baseType: !%d, size: %d, offset: 0)`,
		payload, shape.payload_size * 8)
	// A niche union's null payload is its other variant; it has no tag member.
	if shape.niche {
		debug_composite(d, id, "DW_TAG_structure_type", name, shape.size * 8, fmt.aprintf("!%d", payload_member))
		return
	}
	tag := debug_node(d, `!DIBasicType(name: "tag", size: %d, encoding: DW_ATE_unsigned)`, shape.tag_bytes * 8)
	members := fmt.aprintf(
		"!%d, !%d",
		payload_member,
		debug_node(d, `!DIDerivedType(tag: DW_TAG_member, name: "tag", baseType: !%d, size: %d, offset: %d)`,
			tag, shape.tag_bytes * 8, shape.tag_offset * 8),
	)
	debug_composite(d, id, "DW_TAG_structure_type", name, shape.size * 8, members)
}

// Natvis reads `{expr}` in display text and parses C++ type names in casts,
// so the rules below are templates filled by replacement rather than `fmt`.
@(private = "file")
NATVIS_HEADER :: `<?xml version="1.0" encoding="utf-8"?>
<AutoVisualizer xmlns="http://schemas.microsoft.com/vstudio/debugger/natvis/2010">
  <Type Name="string$">
    <DisplayString>{(char*)data,[len]s8}</DisplayString>
  </Type>
  <Type Name="string_view">
    <DisplayString>{(char*)data,[len]s8}</DisplayString>
  </Type>
`

@(private = "file")
NATVIS_MAP :: `  <Type Name="@MAP@">
    <DisplayString>{{ len={len} }}</DisplayString>
    <Expand>
      <Item Name="[len]">len</Item>
      <Item Name="[allocator]">allocator</Item>
      <CustomListItems Condition="table != 0">
        <Variable Name="slot" InitialValue="0"/>
        <Loop Condition="slot &lt; table->slot_count">
          <If Condition="*((unsigned char*)table + table->controls_offset + slot) == 2">
            <Item Name="[{*(@MAP@$key*)((char*)table + table->keys_offset + slot * @KEY_SIZE@)}]">*(@MAP@$value*)((char*)table + table->values_offset + slot * @VALUE_SIZE@)</Item>
          </If>
          <Exec>slot++</Exec>
        </Loop>
      </CustomListItems>
    </Expand>
  </Type>
`

// A typedef natvis can cast to: `[]u8` or `map[string]int` is no C++ name.
@(private = "file")
debug_natvis_type :: proc(d: ^Debug_Info, name: string, type: Type_Id) {
	append(&d.retained, debug_node(d, `!DIDerivedType(tag: DW_TAG_typedef, name: "%s", baseType: !%d)`, name, debug_type(d, type)))
}

// A map's header, named `map$<type>` for natvis to match, and a rule listing
// its occupied slots. The table is `loke_rt_map_table_v1` in
// runtime/loke_rt.h: a header, then control bytes, keys, and values, each at
// an offset the header stores.
@(private = "file")
debug_map :: proc(d: ^Debug_Info, id: int, type: Type_Id) {
	c := d.c
	info := type_of(c, type)
	if d.map_table == 0 {
		d.map_table = d.count
		d.count += 1
		header := strings.builder_make()
		for field, index in ([]string{"slot_count", "occupied", "tombstones"}) {
			debug_member(d, &header, field, TYPE_INT, u64(index) * 8)
		}
		for field, index in ([]string{"seed", "controls_offset", "keys_offset", "values_offset", "block_size", "block_align"}) {
			debug_member(d, &header, field, TYPE_U64, u64(index + 3) * 8)
		}
		debug_composite(d, d.map_table, "DW_TAG_structure_type", "loke_rt_map_table_v1", 9 * 64, strings.to_string(header))
	}
	name := fmt.aprintf("map$%d", u32(type))
	members := strings.builder_make()
	debug_pointer_member(d, &members, "table", d.map_table, 0)
	debug_member(d, &members, "len", TYPE_INT, 8)
	debug_member(d, &members, "cap", TYPE_INT, 16)
	debug_member(d, &members, "allocator", TYPE_ALLOCATOR, 24)
	debug_composite(d, id, "DW_TAG_structure_type", name, type_size(c, type) * 8, strings.to_string(members))

	debug_natvis_type(d, fmt.aprintf("%s$key", name), info.key)
	debug_natvis_type(d, fmt.aprintf("%s$value", name), info.element)
	rule, _ := strings.replace_all(NATVIS_MAP, "@MAP@", name)
	rule, _ = strings.replace_all(rule, "@KEY_SIZE@", fmt.aprint(type_size(c, info.key)))
	rule, _ = strings.replace_all(rule, "@VALUE_SIZE@", fmt.aprint(type_size(c, info.element)))
	strings.write_string(&d.natvis, rule)
}

// design.md "any_view type": `data` points at a value of the type `id` names,
// so the rule shows that value, with a case for every type that has a typeid.
@(private = "file")
debug_any_view_natvis :: proc(d: ^Debug_Info) {
	if TYPE_ANY_VIEW not_in d.types {
		return
	}
	shown := strings.builder_make()
	expanded := strings.builder_make()
	for type in d.c.typeid_order {
		value := typeid_value(d.c, type)
		if value == 0 || type_size(d.c, type) == 0 {
			continue
		}
		name := fmt.aprintf("typeid$%d", value)
		debug_natvis_type(d, name, type)
		condition := fmt.aprintf(`Condition="id == %d"`, value)
		strings.write_string(&shown, strings.concatenate({"    <DisplayString ", condition, ">{*(", name, "*)data}</DisplayString>\n"}))
		strings.write_string(&expanded, strings.concatenate({"      <ExpandedItem ", condition, ">*(", name, "*)data</ExpandedItem>\n"}))
	}
	strings.write_string(&d.natvis, "  <Type Name=\"any_view\">\n")
	strings.write_string(&d.natvis, "    <DisplayString Condition=\"data == 0\">nil</DisplayString>\n")
	strings.write_string(&d.natvis, strings.to_string(shown))
	strings.write_string(&d.natvis, "    <DisplayString>{{ id={id} }}</DisplayString>\n    <Expand>\n")
	strings.write_string(&d.natvis, strings.to_string(expanded))
	strings.write_string(&d.natvis, "    </Expand>\n  </Type>\n")
}

// design.md "Borrowed dynamic interface values": a witness table's global, as
// `witness$<n>` for natvis to compare a view's `witness` with, and the type its
// views point at, as `witness$<n>$type`.
@(private = "file")
debug_witness :: proc(d: ^Debug_Info, index: int) -> int {
	witness := d.c.witness_order[index]
	debug_natvis_type(d, fmt.aprintf("witness$%d$type", index), witness.concrete)
	variable := debug_node(
		d, `distinct !DIGlobalVariable(name: "witness$%d", scope: !%d, type: !%d, isLocal: true, isDefinition: true)`,
		index, UNIT, debug_type(d, TYPE_RAWPTR),
	)
	expression := debug_node(d, "!DIGlobalVariableExpression(var: !%d, expr: !DIExpression())", variable)
	append(&d.globals, expression)
	return expression
}

// A `dyn` view shows the value its witness table's type says `data` points at.
// A table without slots may share its address with another, so it tells none.
@(private = "file")
debug_dyn_natvis :: proc(d: ^Debug_Info) {
	for type in d.dyns {
		info := type_of(d.c, type)
		shown := strings.builder_make()
		expanded := strings.builder_make()
		for witness, index in d.c.witness_order {
			if witness.interface_symbol != info.dyn_interface || len(witness.slots) == 0 {
				continue
			}
			name := fmt.aprintf("witness$%d", index)
			condition := strings.concatenate({`Condition="witness == &amp;`, name, `"`})
			strings.write_string(&shown, strings.concatenate({"    <DisplayString ", condition, ">{*(", name, "$type*)data}</DisplayString>\n"}))
			strings.write_string(&expanded, strings.concatenate({"      <ExpandedItem ", condition, ">*(", name, "$type*)data</ExpandedItem>\n"}))
		}
		fmt.sbprintfln(&d.natvis, `  <Type Name="dyn$%d">`, u32(type))
		strings.write_string(&d.natvis, "    <DisplayString Condition=\"data == 0\">nil</DisplayString>\n")
		strings.write_string(&d.natvis, strings.to_string(shown))
		strings.write_string(&d.natvis, "    <DisplayString>{{ data={data} }}</DisplayString>\n    <Expand>\n")
		strings.write_string(&d.natvis, strings.to_string(expanded))
		strings.write_string(&d.natvis, "    </Expand>\n  </Type>\n")
	}
}

// The name a debugger shows: `@loke.p.core$3afmt.print` is `core:fmt.print`.
@(private)
debug_proc_name :: proc(llvm_name: string) -> string {
	name := strings.trim_prefix(llvm_name, "@")
	name = strings.trim_prefix(strings.trim_suffix(name, `"`), `"`)
	name = strings.trim_prefix(name, "loke.p.")
	out := make([dynamic]u8, 0, len(name))
	for i := 0; i < len(name); i += 1 {
		if name[i] == '$' && i + 2 < len(name) {
			if value, ok := strconv.parse_uint(name[i + 1:i + 3], 16); ok {
				append(&out, u8(value))
				i += 2
				continue
			}
		}
		append(&out, name[i])
	}
	return string(out[:])
}
