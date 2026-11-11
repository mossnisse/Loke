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
@(private = "file")
WITNESS_MARKER :: ";dbg.witness "

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

// The witness table written next is `witness_order[index]`.
@(private)
debug_mark_witness :: proc(e: ^Emitter, index: int) {
	if e.c.debug_info {
		fmt.sbprintfln(&e.b, "%s%d", WITNESS_MARKER, index)
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
	// The `witness$<n>` variables the witness tables' definitions carry.
	globals:   [dynamic]int,
	dyns:      [dynamic]Type_Id,
	// The type names taken.
	names:     map[string]bool,
}

// Metadata `!0` to `!3` are fixed: the unit, the two module flags, and the one
// subroutine type every procedure shares, since no debugger needs its
// parameter types to set a breakpoint or walk the stack.
@(private = "file")
UNIT :: 0
@(private = "file")
SUBROUTINE_TYPE :: 3

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
	d := Debug_Info{c = c, count = SUBROUTINE_TYPE + 1}
	strings.write_string(&d.natvis, NATVIS_HEADER)
	out: strings.Builder
	current: Maybe(Debug_Proc)
	// The witness whose table the next line defines, or -1.
	witness := -1
	rest := module
	for line in strings.split_lines_iterator(&rest) {
		p, inside := &current.?
		switch {
		case strings.has_prefix(line, PROC_MARKER):
			id, _ := strconv.parse_uint(line[len(PROC_MARKER):])
			symbol := symbol_of(c, Symbol_Id(id))
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
		case strings.has_prefix(line, WITNESS_MARKER):
			index, _ := strconv.parse_uint(line[len(WITNESS_MARKER):])
			witness = int(index)
		case inside && strings.has_prefix(line, "  "):
			write_with_dbg(&out, line, p.location)
		case witness >= 0:
			write_with_dbg(&out, line, debug_witness(&d, witness))
			witness = -1
		case:
			if line == "}" {
				current = nil
			}
			fmt.sbprintln(&out, line)
		}
	}

	debug_module_trailer(&d, &out)
	return strings.to_string(out)
}

// `line` with its `!dbg` attachment. Every instruction of a `-g` module passes
// through here, so this writes without `fmt`'s format parsing.
@(private = "file")
write_with_dbg :: proc(out: ^strings.Builder, line: string, metadata: int) {
	strings.write_string(out, line)
	strings.write_string(out, ", !dbg !")
	strings.write_int(out, metadata)
	strings.write_byte(out, '\n')
}

// What follows the module's code: the natvis rules, which the compiler keeps, the
// compile unit and its flags, and the metadata the code named.
@(private = "file")
debug_module_trailer :: proc(d: ^Debug_Info, out: ^strings.Builder) {
	c := d.c
	debug_dyn_natvis(d)
	strings.write_string(&d.natvis, "</AutoVisualizer>\n")
	c.natvis = strings.to_string(d.natvis)
	retained := debug_list_field(d, "retainedTypes", d.retained[:])
	globals := debug_list_field(d, "globals", d.globals[:])

	optimized := c.opt_mode != .None
	fmt.sbprintln(out, "declare void @llvm.dbg.declare(metadata, metadata, metadata)")
	fmt.sbprintln(out, "!llvm.dbg.cu = !{!0}")
	fmt.sbprintln(out, "!llvm.module.flags = !{!1, !2}")
	// Loke has no DWARF language code; C's describes its procedures well enough.
	// The producer is what `lokec -version` reports, so a PDB names the revision
	// that compiled it.
	fmt.sbprintfln(
		out,
		`!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !%d, producer: "lokec %s", isOptimized: %v, runtimeVersion: 0, emissionKind: FullDebug%s%s)`,
		debug_file(d, package_of(c, c.root_package).files[0].file), VERSION_WITH_REVISION, optimized, retained, globals,
	)
	fmt.sbprintln(out, `!1 = !{i32 2, !"Debug Info Version", i32 3}`)
	// Windows debuggers read CodeView, in a PDB the linker writes.
	fmt.sbprintln(out, `!2 = !{i32 2, !"CodeView", i32 1}`)
	fmt.sbprintln(out, "!3 = !DISubroutineType(types: !{})")
	strings.write_string(out, strings.to_string(d.meta))
}

// `, field: !<n>` for a list that has nodes.
@(private = "file")
debug_list_field :: proc(d: ^Debug_Info, field: string, list: []int) -> string {
	if len(list) == 0 {
		return ""
	}
	nodes: strings.Builder
	for node, index in list {
		fmt.sbprintf(&nodes, "%s!%d", index > 0 ? ", " : "", node)
	}
	return fmt.aprintf(", %s: !%d", field, debug_node(d, "!{{%s}", strings.to_string(nodes)))
}

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
	if symbol.span.file != p.symbol.span.file {
		return
	}
	file := debug_file(d, symbol.span.file)
	line, column := line_col(&d.c.sources[symbol.span.file], symbol.span.lo)
	if len(p.blocks) > 0 && p.blocks[len(p.blocks) - 1] < 0 {
		p.blocks[len(p.blocks) - 1] = debug_node(
			d, "distinct !DILexicalBlock(scope: !%d, file: !%d, line: %d, column: %d)",
			debug_scope(p), file, line, column,
		)
		p.location = debug_location(d, debug_scope(p), p.span)
	}
	scope := debug_scope(p)
	// A debugger reads a parameter of any other size as a pointer to it, as it would
	// be on Win64, but Loke's slot holds the value.
	arg := ""
	switch type_size(d.c, symbol.type) {
	case 1, 2, 4, 8:
		for param, index in p.symbol.param_symbols {
			if param == symbol_id {
				arg = fmt.aprintf("arg: %d, ", index + 1)
			}
		}
	}
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

// The name a type goes by in the debug info. cdb resolves a by-name reference to one
// definition, so same-named types, from two packages or two bodies, would show each
// other's layout.
@(private = "file")
debug_type_name :: proc(d: ^Debug_Info, type: Type_Id) -> string {
	name := llvm_escape(type_name(d.c, type))
	if d.names[name] {
		return fmt.aprintf("%s$%d", name, u32(type))
	}
	d.names[name] = true
	return name
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
	name := debug_type_name(d, type)
	size := type_size(c, type) * 8
	// CodeView clamps wide enumerators; expose their exact stored bits.
	if (info.kind == .Int || info.kind == .Enum) && size == 128 {
		members: strings.Builder
		debug_member(d, &members, "low", TYPE_U64, 0)
		debug_member(d, &members, "high", TYPE_U64, 8)
		debug_composite(d, id, name, size, strings.to_string(members))
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
		debug_enum(d, id, type, name)
	case .Struct, .Dyn:
		debug_record(d, id, type, name)
	case .String, .String_View, .Slice, .Dynamic_Array:
		debug_sequence(d, id, type, name)
	case .Union:
		debug_union(d, id, type, name)
	case .Map:
		debug_map(d, id, type)
	case:
		debug_composite(d, id, name, size, "")
	}
	return id
}

@(private = "file")
debug_enum :: proc(d: ^Debug_Info, id: int, type: Type_Id, name: string) {
	c := d.c
	info := type_of(c, type)
	enumerators: strings.Builder
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
		name, debug_type(d, info.element), type_size(c, type) * 8, strings.to_string(enumerators),
	)
}

@(private = "file")
debug_record :: proc(d: ^Debug_Info, id: int, type: Type_Id, name: string) {
	c := d.c
	info := type_of(c, type)
	name := name
	if info.kind == .Dyn {
		name = fmt.aprintf("dyn$%d", u32(type))
		append(&d.dyns, type)
	}
	members: strings.Builder
	for field, index in info.fields {
		member := symbol_of(c, field)
		if field_is_padding(c, field) {
			continue
		}
		// A debugger's expression evaluator reads a positional field as
		// `__0`, as it does a Rust tuple's; `0` is no member name it parses.
		member_name := identifier_text(c, member.name)
		if field_is_positional(c, field) {
			member_name = fmt.aprintf("__%s", member_name)
		}
		debug_member(d, &members, member_name, member.type, type_field_offset(c, type, index))
	}
	debug_composite(d, id, name, type_size(c, type) * 8, strings.to_string(members))
}

// design.md "string type" and "Slices".
@(private = "file")
debug_sequence :: proc(d: ^Debug_Info, id: int, type: Type_Id, name: string) {
	c := d.c
	info := type_of(c, type)
	name := name
	element := info.kind == .String || info.kind == .String_View ? TYPE_U8 : info.element
	members: strings.Builder
	debug_pointer_member(d, &members, "data", debug_type(d, element), 0)
	debug_member(d, &members, "len", TYPE_INT, 8)
	if info.kind == .Dynamic_Array {
		debug_member(d, &members, "cap", TYPE_INT, 16)
	}
	// WinDbg shows a type named `string` its own way and ignores natvis for it.
	if type == TYPE_STRING {
		name = "string$"
	}
	debug_composite(d, id, name, type_size(c, type) * 8, strings.to_string(members))
}

@(private = "file")
debug_composite :: proc(d: ^Debug_Info, id: int, name: string, size: u64, members: string) {
	debug_node_at(
		d, id, `distinct !DICompositeType(tag: DW_TAG_structure_type, name: "%s", size: %d, elements: !{{%s})`,
		name, size, members,
	)
}

@(private = "file")
debug_member :: proc(d: ^Debug_Info, members: ^strings.Builder, name: string, type: Type_Id, offset: u64) {
	debug_member_node(d, members, name, debug_type(d, type), type_size(d.c, type) * 8, offset * 8)
}

// Sizes and offsets are in bits.
@(private = "file")
debug_member_node :: proc(d: ^Debug_Info, members: ^strings.Builder, name: string, base: int, size, offset: u64) {
	member := debug_node(
		d, `!DIDerivedType(tag: DW_TAG_member, name: "%s", baseType: !%d, size: %d, offset: %d)`,
		llvm_escape(name), base, size, offset,
	)
	fmt.sbprintf(members, "%s!%d", strings.builder_len(members^) > 0 ? ", " : "", member)
}

@(private = "file")
debug_pointer_member :: proc(d: ^Debug_Info, members: ^strings.Builder, name: string, pointee: int, offset: u64) {
	pointer := debug_node(d, "!DIDerivedType(tag: DW_TAG_pointer_type, baseType: !%d, size: 64)", pointee)
	debug_member_node(d, members, name, pointer, 64, offset * 8)
}

// compiler-architecture.md "Union layout": the payload overlaps at offset zero,
// one member per variant that carries one, and the tag, which is the variant's
// index, follows.
@(private = "file")
debug_union :: proc(d: ^Debug_Info, id: int, type: Type_Id, name: string) {
	c := d.c
	info := type_of(c, type)
	shape := union_layout(c, type)
	variants: strings.Builder
	for payload, index in info.variants {
		if payload != TYPE_VOID {
			debug_member(d, &variants, identifier_text(c, info.variant_names[index]), payload, 0)
		}
	}
	payload := debug_node(d, "distinct !DICompositeType(tag: DW_TAG_union_type, size: %d, elements: !{{%s})",
		shape.payload_size * 8, strings.to_string(variants))
	members: strings.Builder
	debug_member_node(d, &members, "payload", payload, u64(shape.payload_size) * 8, 0)
	// A niche union's null payload is its other variant; it has no tag member.
	if !shape.niche {
		tag := debug_node(d, `!DIBasicType(name: "tag", size: %d, encoding: DW_ATE_unsigned)`, shape.tag_bytes * 8)
		debug_member_node(d, &members, "tag", tag, u64(shape.tag_bytes) * 8, u64(shape.payload_size) * 8)
	}
	debug_composite(d, id, name, shape.size * 8, strings.to_string(members))
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
		header: strings.Builder
		for field, index in ([]string{"slot_count", "occupied", "tombstones"}) {
			debug_member(d, &header, field, TYPE_INT, u64(index) * 8)
		}
		for field, index in ([]string{"seed", "controls_offset", "keys_offset", "values_offset", "block_size", "block_align"}) {
			debug_member(d, &header, field, TYPE_U64, u64(index + 3) * 8)
		}
		debug_composite(d, d.map_table, "loke_rt_map_table_v1", 9 * 64, strings.to_string(header))
	}
	name := fmt.aprintf("map$%d", u32(type))
	members: strings.Builder
	debug_pointer_member(d, &members, "table", d.map_table, 0)
	debug_member(d, &members, "len", TYPE_INT, 8)
	debug_member(d, &members, "cap", TYPE_INT, 16)
	debug_member(d, &members, "allocator", TYPE_ALLOCATOR, 24)
	debug_composite(d, id, name, type_size(c, type) * 8, strings.to_string(members))

	debug_natvis_type(d, fmt.aprintf("%s$key", name), info.key)
	debug_natvis_type(d, fmt.aprintf("%s$value", name), info.element)
	rule, _ := strings.replace_all(NATVIS_MAP, "@MAP@", name)
	rule, _ = strings.replace_all(rule, "@KEY_SIZE@", fmt.aprint(type_size(c, info.key)))
	rule, _ = strings.replace_all(rule, "@VALUE_SIZE@", fmt.aprint(type_size(c, info.element)))
	strings.write_string(&d.natvis, rule)
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
		shown, expanded: strings.Builder
		for witness, index in d.c.witness_order {
			if witness.interface_symbol != info.dyn_interface || len(witness.slots) == 0 {
				continue
			}
			fmt.sbprintfln(&shown, `    <DisplayString Condition="witness == &amp;witness$%d">{{*(witness$%d$type*)data}}</DisplayString>`, index, index)
			fmt.sbprintfln(&expanded, `      <ExpandedItem Condition="witness == &amp;witness$%d">*(witness$%d$type*)data</ExpandedItem>`, index, index)
		}
		fmt.sbprintf(
			&d.natvis,
			"  <Type Name=\"dyn$%d\">\n    <DisplayString Condition=\"data == 0\">nil</DisplayString>\n%s    <DisplayString>{{{{ data={{data}} }}}}</DisplayString>\n    <Expand>\n%s    </Expand>\n  </Type>\n",
			u32(type), strings.to_string(shown), strings.to_string(expanded),
		)
	}
}

// The name a debugger shows, with `llvm_safe` undone: `@loke.p.core$3afmt.print`
// is `core:fmt.print`.
@(private = "file")
debug_proc_name :: proc(llvm_name: string) -> string {
	name := strings.trim_prefix(llvm_name, "@")
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
