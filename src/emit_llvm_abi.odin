// LLVM type representation and foreign procedure ABI lowering.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

// The external symbol a foreign declaration binds: `@<link_name>`, with no
// package mangling, so the linker resolves it against the imported library.
@(private)
foreign_llvm_name :: proc(sym: ^Symbol) -> string {
	return fmt.aprintf("@%s", sym.link_name)
}

// One `declare` per foreign procedure and one `external global` per foreign
// variable, deduplicated by symbol name (m7-plan step 4). The classified
// signature matches the C library's definition under the Windows x64 ABI.
@(private)
emit_foreign_declarations :: proc(e: ^Emitter) {
	seen := make(map[string]bool)
	for id in package_order(e.c) {
		pkg := package_of(e.c, id)
		if pkg == nil {
			continue
		}
		for file in pkg.files {
			for item in file.active_items {
				block, ok := item.(^Item_Foreign_Block)
				if !ok {
					continue
				}
				for member in block.members {
					d, is_decl := member.(^Decl)
					if !is_decl {
						continue
					}
					for sid in d.symbols {
						sym := symbol_of(e.c, sid)
						if sym == nil || !sym.is_foreign {
							continue
						}
						name := foreign_llvm_name(sym)
						if seen[name] {
							continue
						}
						seen[name] = true
						emit_foreign_declare(e, sym)
					}
				}
			}
		}
	}
}

@(private = "file")
emit_foreign_declare :: proc(e: ^Emitter, sym: ^Symbol) {
	name := foreign_llvm_name(sym)
	if sym.kind != .Proc {
		fmt.sbprintfln(&e.b, "%s = external global %s", name, llvm_type(e, sym.type))
		return
	}
	ret := "void"
	sret_prefix := ""
	proc_info := type_of(e.c, sym.proc_type)
	if len(sym.results) == 1 {
		result := sym.results[0]
		if proc_result_is_inout(proc_info, 0) {
			ret = "ptr"
		} else {
			switch abi_pass(e.c, result) {
			case .Indirect:
				sret_prefix = fmt.aprintf("ptr sret(%s) align %d", llvm_type(e, result), type_align(e.c, result))
			case .Reg_Int:
				ret = fmt.aprintf("i%d", abi_reg_bits(e.c, result))
			case .Bool_I1:
				ret = "zeroext i1"
			case .Direct:
				ret = llvm_type(e, result)
			}
		}
	}
	fmt.sbprintf(&e.b, "declare %s %s(", ret, name)
	need_comma := false
	if sret_prefix != "" {
		fmt.sbprint(&e.b, sret_prefix)
		need_comma = true
	}
	for parameter, index in sym.params {
		if need_comma {
			fmt.sbprint(&e.b, ", ")
		}
		need_comma = true
		fmt.sbprint(&e.b, foreign_param_type(e, sym, parameter, index))
	}
	if proc_info != nil && proc_info.c_vararg {
		if need_comma {
			fmt.sbprint(&e.b, ", ")
		}
		fmt.sbprint(&e.b, "...")
	}
	fmt.sbprintln(&e.b, ")")
}

// ------------------------------------------------------------ LLVM types --

// Named struct definitions, in containment order. The checker has already
// rejected a by-value cycle, so a value edge cannot come back here.
@(private)
emit_struct_definitions :: proc(e: ^Emitter) {
	emitted := make(map[Type_Id]bool)
	defer delete(emitted)
	for index in 0 ..< len(e.c.types) {
		define_struct(e, Type_Id(index), &emitted)
	}
	fmt.sbprintln(&e.b, "")
}

@(private = "file")
define_struct :: proc(e: ^Emitter, type: Type_Id, emitted: ^map[Type_Id]bool) {
	info := type_of(e.c, type)
	if info == nil || emitted[type] {
		return
	}
	// A generic record's own shell is a placeholder for its instances and has no
	// layout of its own.
	if sym := symbol_of(e.c, info.symbol); sym != nil && sym.generic {
		emitted[type] = true
		return
	}
	if info.kind == .Union {
		if !type_is_supported(e.c, type) {
			return
		}
		emitted[type] = true
		fmt.sbprintfln(&e.b, "%s = type %s", struct_name(e, type), union_storage_definition(e, type))
		return
	}
	if info.kind == .Slice {
		// Only the read-only variant is defined; `[]mut T` shares its name.
		if !type_is_supported(e.c, type) || slice_abi_type(e.c, type) != type {
			return
		}
		ensure_slice_fields(e.c, type)
		info = type_of(e.c, type)
	} else if info.kind == .Dyn {
		// The same for a dyn view: one struct per interface application, named by
		// the read-only variant, whatever capabilities the program spells.
		if dyn_abi_type(e.c, type) != type {
			return
		}
	} else if info.kind == .Any_View {
		// A program that imports `core:fmt` without formatting anything never asks
		// for an `any_view` value, so its two members are still uninstalled when
		// `core:fmt`'s own body — which does use them — is emitted.
		ensure_any_view_fields(e.c)
		info = type_of(e.c, type)
	} else if info.kind != .Struct && info.kind != .Dyn {
		return
	}
	emitted[type] = true
	for field in info.fields {
		symbol := symbol_of(e.c, field)
		if symbol == nil {
			continue
		}
		// A pointer edge stops here: `ptr` needs no definition of its pointee.
		define_struct(e, struct_dependency(e.c, symbol.type), emitted)
	}
	name := struct_name(e, type)
	// `{` is a format directive to core:fmt, so the brace is printed separately.
	fmt.sbprintf(&e.b, "%s = type", name)
	fmt.sbprintln(&e.b, strings.concatenate({" ", struct_body(e, type, info)}))
}

// The LLVM aggregate body of a struct. A natural record keeps its plain
// `{ ... }` spelling; a `@(packed)`/`@(align=N)` record is laid out byte-exact so
// LLVM's own size, alignment, and field offsets equal the checker's cached ones
// (m7-plan step 2, decision "Attributed LLVM layout"). Field GEP indices stay
// equal to the logical field index in every form, so field walks are unchanged.
@(private = "file")
struct_body :: proc(e: ^Emitter, type: Type_Id, info_in: ^Type_Info) -> string {
	// The cached alignment and size are read below, so the layout must be computed
	// first; computing a field's layout can grow the type store, so `info` is then
	// reacquired before its fields are read.
	natural := record_natural_align(e.c, info_in)
	type_size(e.c, type)
	info := type_of(e.c, type)
	packed := info.packed
	over_aligned := info.align > natural
	if !packed && !over_aligned {
		b := strings.builder_make()
		strings.write_string(&b, "{")
		for field, index in info.fields {
			symbol := symbol_of(e.c, field)
			if index > 0 {
				strings.write_string(&b, ",")
			}
			fmt.sbprintf(&b, " %s", llvm_type(e, symbol.type))
		}
		strings.write_string(&b, " }")
		return strings.to_string(b)
	}

	b := strings.builder_make()
	if packed && over_aligned {
		// Tight packing (needs an LLVM packed body) and a raised alignment (which a
		// packed body cannot report) at once: each field becomes a byte array so a
		// non-packed body neither re-pads nor drops the alignment, and a trailing
		// zero-length aligned member forces the record's alignment and size.
		// Byte members make whole-value `extractvalue` ill-typed, so equality reads
		// each field through its address instead (`emit_byte_member_struct_equal`,
		// m7-plan step 6); field GEP indices are unchanged, which is what lets
		// ordinary access, reflection, and formatting stay on their normal path.
		strings.write_string(&b, "{")
		for field, index in info.fields {
			symbol := symbol_of(e.c, field)
			if index > 0 {
				strings.write_string(&b, ",")
			}
			fmt.sbprintf(&b, " [%d x i8]", type_size(e.c, symbol.type))
		}
		fmt.sbprintf(&b, ", [0 x i%d] }", info.align * 8)
		return strings.to_string(b)
	}
	if packed {
		// Tight packing, natural alignment 1: an LLVM packed body matches exactly.
		strings.write_string(&b, "<{")
		for field, index in info.fields {
			symbol := symbol_of(e.c, field)
			if index > 0 {
				strings.write_string(&b, ",")
			}
			fmt.sbprintf(&b, " %s", llvm_type(e, symbol.type))
		}
		strings.write_string(&b, " }>")
		return strings.to_string(b)
	}
	// `@(align=N)` only: natural field offsets, so a plain body already agrees; a
	// trailing zero-length aligned member raises the alignment and tail padding.
	strings.write_string(&b, "{")
	for field, index in info.fields {
		symbol := symbol_of(e.c, field)
		if index > 0 {
			strings.write_string(&b, ",")
		}
		fmt.sbprintf(&b, " %s", llvm_type(e, symbol.type))
	}
	fmt.sbprintf(&b, ", [0 x i%d] }", info.align * 8)
	return strings.to_string(b)
}

// The alignment a struct would have with no `@(align=N)`: the maximum field
// alignment, or 1 for a packed or empty record.
@(private)
record_natural_align :: proc(c: ^Compiler, info: ^Type_Info) -> u64 {
	if info.packed {
		return 1
	}
	natural := u64(1)
	for field in info.fields {
		if symbol := symbol_of(c, field); symbol != nil {
			natural = max(natural, type_align(c, symbol.type))
		}
	}
	return natural
}

// The struct a value-typed field depends on, looking through arrays and
// distinct wrappers but never through a pointer.
@(private = "file")
struct_dependency :: proc(c: ^Compiler, type: Type_Id) -> Type_Id {
	current := type_underlying(c, type)
	for i := 0; i < 32; i += 1 {
		info := type_of(c, current)
		if info == nil || info.kind != .Array {
			return current
		}
		current = type_underlying(c, info.element)
	}
	return current
}

@(private)
struct_name :: proc(e: ^Emitter, raw: Type_Id) -> string {
	// Both capabilities of a carrier share one backend type, so `[]mut T` and
	// `dyn mut I` weakening is the no-op the design says it is.
	type := carrier_abi_type(e.c, raw)
	if name, ok := e.struct_names[type]; ok {
		return name
	}
	info := type_of(e.c, type)
	prefix := info != nil && info.kind == .Union ? "union" : "struct"
	name := ""
	if info != nil && (info.mangled != "" || info.name != INVALID_IDENTIFIER) {
		// An instantiation carries its own backend spelling; a written name may
		// still mention punctuation LLVM would need quoting for.
		text := info.mangled
		if text == "" {
			text = identifier_text(e.c, info.name)
			if !llvm_plain_name(text) {
				text = llvm_safe(text)
			}
		}
		name = fmt.aprintf("%%%s.%s.%d", prefix, text, int(type))
	} else {
		name = fmt.aprintf("%%%s.anon.%d", prefix, int(type))
	}
	e.struct_names[type] = name
	return name
}

llvm_type :: proc(e: ^Emitter, type: Type_Id) -> string {
	// Nothing untyped should reach the backend, but taking its default type here
	// keeps a leak from silently becoming a zero of the wrong width.
	under := type_underlying(e.c, default_type(e.c, type))
	info := type_of(e.c, under)
	if info == nil {
		return "i64"
	}
	#partial switch info.kind {
	case .Void:
		return "void"
	case .Bool:
		// ponytail: `i1` everywhere, so a `bool` alloca is not one byte. Nothing
		// in M2 observes a bool's storage size; switch to i8-in-memory when the
		// foreign ABI lands in M7.
		return "i1"
	case .Int, .Enum, .Allocator_Error:
		return fmt.aprintf("i%d", type_bits(e.c, under))
	case .Typeid:
		// design.md: an ordinary runtime scalar holding one concrete type's unique
		// identifier. Zero is nil.
		return "i64"
	case .Rune:
		return "i32"
	case .Float:
		switch info.bits {
		case 16:
			return "half"
		case 32:
			return "float"
		}
		return "double"
	case .Pointer, .Multi_Pointer, .Raw_Pointer, .Proc, .Allocator, .CString_View:
		// An `Allocator` is a one-word handle on the provider record; a
		// `cstring_view` is one zero-terminated address; a multi-pointer is one
		// address with neither a length nor a capability.
		return "ptr"
	case .String:
		return STRING_TYPE
	case .String_View:
		return STRING_VIEW_TYPE
	case .Dynamic_Array, .Map:
		// Both headers are the same four words, so they share one backend type
		// exactly as the two slice capabilities do.
		return CONTAINER_TYPE
	case .Array:
		return fmt.aprintf("[%d x %s]", info.count, llvm_type(e, info.element))
	case .Struct, .Union, .Any_View, .Dyn, .Slice:
		// A two-word erased view or slice is an ordinary aggregate to the backend.
		return struct_name(e, under)
	}
	return "i64"
}

// The union storage type, built so LLVM's own layout matches the checker's
// cached facts: an alignment-carrying payload head, explicit payload padding,
// the tag, and tail padding. A bare `[N x i8]` payload would be byte-aligned,
// which is wrong wherever a union is allocated directly, nested in a struct, or
// used as an array element.
@(private = "file")
union_storage_definition :: proc(e: ^Emitter, type: Type_Id) -> string {
	shape := union_layout(e.c, type)
	b := strings.builder_make()
	strings.write_string(&b, "{ ")
	// A union every variant of which is payloadless has no payload region at
	// all: its storage is the tag alone, and there is no head to carry an
	// alignment no payload asks for.
	if shape.payload_size > 0 {
		fmt.sbprintf(&b, "i%d", shape.align * 8)
		if pad := shape.payload_size - shape.align; pad > 0 {
			fmt.sbprintf(&b, ", [%d x i8]", pad)
		}
		if gap := shape.tag_offset - shape.payload_size; gap > 0 {
			fmt.sbprintf(&b, ", [%d x i8]", gap)
		}
		strings.write_string(&b, ", ")
	}
	fmt.sbprintf(&b, "i%d", shape.tag_bytes * 8)
	if tail := shape.size - shape.tag_offset - shape.tag_bytes; tail > 0 {
		fmt.sbprintf(&b, ", [%d x i8]", tail)
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

// Constructing a variant: zero the storage, write the payload through a typed
// pointer, then write the tag. `value` is empty for a payloadless variant,
// which is nothing but its tag.
@(private)
emit_union_value :: proc(e: ^Emitter, union_type: Type_Id, index: int, value: string) -> string {
	llvm := llvm_type(e, union_type)
	slot := alloca(e, llvm)
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", llvm, slot)
	if payload_type := union_variant_payload(e.c, union_type, index); payload_type != TYPE_VOID {
		payload := gep_field(e, llvm, slot, 0)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, payload_type), value, payload)
	}
	emit_union_store_tag(e, union_type, slot, index)
	out := load(e, llvm, slot)
	return out
}

// A two-variant union built from a runtime condition: each payload is written
// only on the branch where it is the active one, so an absent `Option` and a
// failed `Result` never publish uninitialized bytes.
//
// A payload string may be empty when that variant is payloadless. Both must
// already be computed: this branches, it does not evaluate.
@(private)
emit_union_either :: proc(
	e: ^Emitter,
	union_type: Type_Id,
	condition: string,
	true_index: int, true_payload: string,
	false_index: int, false_payload: string,
) -> string {
	llvm := llvm_type(e, union_type)
	slot := alloca(e, llvm)
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", llvm, slot)
	yes, no, done := new_label(e, "variant.yes"), new_label(e, "variant.no"), new_label(e, "variant.done")
	branch_if(e, condition, yes, no)

	arm :: proc(e: ^Emitter, union_type: Type_Id, llvm, slot: string, index: int, payload: string) {
		// An empty operand means the caller has nothing to write: the variant is
		// payloadless, or its payload is zero-sized and the zeroed slot is already
		// the whole value.
		if payload_type := union_variant_payload(e.c, union_type, index);
		   payload != "" && payload_type != TYPE_VOID {
			address := gep_field(e, llvm, slot, 0)
			fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, payload_type), payload, address)
		}
		emit_union_store_tag(e, union_type, slot, index)
	}

	place_label(e, yes)
	arm(e, union_type, llvm, slot, true_index, true_payload)
	branch(e, done)

	place_label(e, no)
	arm(e, union_type, llvm, slot, false_index, false_payload)
	branch(e, done)

	place_label(e, done)
	e.terminated = false
	out := load(e, llvm, slot)
	return out
}

@(private)
emit_union_choice :: proc(
	e: ^Emitter,
	union_type: Type_Id,
	present: string,
	present_index, absent_index: int,
	payload: string,
) -> string {
	return emit_union_either(e, union_type, present, present_index, payload, absent_index, "")
}

@(private = "file")
emit_union_store_tag :: proc(e: ^Emitter, union_type: Type_Id, slot: string, tag: int) {
	llvm := llvm_type(e, union_type)
	shape := union_layout(e.c, union_type)
	address := gep_field(e, llvm, slot, union_tag_member(e, union_type))
	fmt.sbprintfln(&e.b, "  store i%d %d, ptr %s", shape.tag_bytes * 8, tag, address)
}

// The tag of a union *value*, which is what every extraction and type switch
// tests.
@(private)
emit_union_tag :: proc(e: ^Emitter, union_type: Type_Id, value: string) -> string {
	out := extract(e, llvm_type(e, union_type), value, union_tag_member(e, union_type))
	return out
}

// Spills a union value so its payload can be read at a variant's own type.
@(private)
emit_union_spill :: proc(e: ^Emitter, union_type: Type_Id, value: string) -> string {
	llvm := llvm_type(e, union_type)
	slot := alloca(e, llvm)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm, value, slot)
	return slot
}

@(private)
emit_union_payload :: proc(e: ^Emitter, union_type, payload_type: Type_Id, slot: string) -> string {
	payload := gep_field(e, llvm_type(e, union_type), slot, 0)
	out := load(e, llvm_type(e, payload_type), payload)
	return out
}

// Which member of that storage type holds the tag.
@(private = "file")
union_tag_member :: proc(e: ^Emitter, type: Type_Id) -> int {
	shape := union_layout(e.c, type)
	if shape.payload_size == 0 {
		return 0 // no payload region, so the tag is the whole storage
	}
	index := 1
	if shape.payload_size > shape.align {
		index += 1
	}
	if shape.tag_offset > shape.payload_size {
		index += 1
	}
	return index
}

// The internal convention for several results: one anonymous literal struct,
// used consistently by caller and callee. This is not the frozen Loke or C
// ABI; M7 replaces it.
@(private)
llvm_result_type :: proc(e: ^Emitter, results: []Type_Id, inout: []bool = nil) -> string {
	// An `inout` result is a place, so it travels as its address.
	slot :: proc(e: ^Emitter, results: []Type_Id, inout: []bool, index: int) -> string {
		if index < len(inout) && inout[index] {
			return "ptr"
		}
		return llvm_type(e, results[index])
	}
	switch len(results) {
	case 0:
		return "void"
	case 1:
		return slot(e, results, inout, 0)
	}
	b := strings.builder_make()
	strings.write_string(&b, "{ ")
	for _, index in results {
		if index > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, slot(e, results, inout, index))
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

@(private)
result_inout_of :: proc(e: ^Emitter, proc_type: Type_Id) -> []bool {
	info := type_of(e.c, proc_type)
	return info == nil ? nil : info.result_inout
}

@(private)
emit_result_is_inout :: proc(e: ^Emitter, index: int) -> bool {
	return index < len(e.result_inout) && e.result_inout[index]
}

@(private)
symbol_param_mode :: proc(c: ^Compiler, symbol: ^Symbol, index: int) -> Param_Mode {
	info := type_of(c, symbol.proc_type)
	if info == nil || index >= len(info.param_modes) {
		return .Value
	}
	return info.param_modes[index]
}

@(private)
proc_convention_of :: proc(e: ^Emitter, symbol: ^Symbol) -> string {
	info := type_of(e.c, symbol.proc_type)
	return info == nil ? "" : info.convention
}

// The `define` signature of a foreign-convention procedure under the Windows x64
// classification (m7-plan step 3). A result larger than one register becomes a
// hidden leading `sret` pointer and a `void` return; `e.abi_sret` records it.
@(private)
emit_foreign_signature :: proc(e: ^Emitter, symbol: ^Symbol, llvm_name: string) {
	ret := "void"
	sret_prefix := ""
	proc_info := type_of(e.c, symbol.proc_type)
	if len(symbol.results) == 1 {
		result := symbol.results[0]
		if proc_result_is_inout(proc_info, 0) {
			ret = "ptr"
		} else {
			switch abi_pass(e.c, result) {
			case .Indirect:
				e.abi_sret = "%arg.sret"
				sret_prefix = fmt.aprintf(
					"ptr sret(%s) align %d %s", llvm_type(e, result), type_align(e.c, result), e.abi_sret,
				)
			case .Reg_Int:
				ret = fmt.aprintf("i%d", abi_reg_bits(e.c, result))
			case .Bool_I1:
				ret = "zeroext i1"
			case .Direct:
				ret = llvm_type(e, result)
			}
		}
	}
	fmt.sbprintf(&e.b, "define %s %s(", ret, llvm_name)
	need_comma := false
	if sret_prefix != "" {
		fmt.sbprint(&e.b, sret_prefix)
		need_comma = true
	}
	for parameter, index in symbol.params {
		if need_comma {
			fmt.sbprint(&e.b, ", ")
		}
		need_comma = true
		fmt.sbprintf(&e.b, "%s %%arg%d", foreign_param_type(e, symbol, parameter, index), index)
	}
	fmt.sbprintln(&e.b, ") {")
}

// The LLVM type (with any ABI attribute) one foreign parameter occupies.
@(private = "file")
foreign_param_type :: proc(e: ^Emitter, symbol: ^Symbol, parameter: Type_Id, index: int) -> string {
	// design.md: `inout T` and `@(by_ptr) T` both cross as a pointer.
	proc_info := type_of(e.c, symbol.proc_type)
	if symbol_param_mode(e.c, symbol, index) == .Inout || param_is_by_ptr(proc_info, index) {
		return "ptr"
	}
	switch abi_pass(e.c, parameter) {
	case .Bool_I1:
		// A parameter attribute follows the type, unlike the return attribute.
		return "i1 zeroext"
	case .Reg_Int:
		return fmt.aprintf("i%d", abi_reg_bits(e.c, parameter))
	case .Indirect:
		return "ptr"
	case .Direct:
		return llvm_type(e, parameter)
	}
	return llvm_type(e, parameter)
}

// Materializes a foreign value parameter's addressable storage from its incoming
// register, and returns the slot the body binds to. A register-sized aggregate is
// stored byte-exact through an integer; a larger one is already a caller-owned
// pointer the immutable value parameter uses directly.
@(private)
emit_foreign_param_slot :: proc(e: ^Emitter, parameter: Type_Id, index: int) -> string {
	arg := fmt.aprintf("%%arg%d", index)
	switch abi_pass(e.c, parameter) {
	case .Indirect:
		return arg
	case .Reg_Int:
		slot := fmt.aprintf("%%p%d.%d", index, next_id(e))
		fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, parameter))
		fmt.sbprintfln(
			&e.b, "  store i%d %s, ptr %s, align %d",
			abi_reg_bits(e.c, parameter), arg, slot, type_align(e.c, parameter),
		)
		return slot
	case .Bool_I1, .Direct:
		slot := fmt.aprintf("%%p%d.%d", index, next_id(e))
		fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, parameter))
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, parameter), arg, slot)
		return slot
	}
	return arg
}

// The classified `ret` of a foreign-convention procedure (m7-plan step 3): a
// register-sized aggregate result is read back byte-exact as an integer, a
// larger one has already been written through `sret`.
@(private)
emit_foreign_return :: proc(e: ^Emitter) {
	if len(e.result_types) == 0 {
		fmt.sbprintln(&e.b, "  ret void")
		return
	}
	result := e.result_types[0]
	slot := e.result_slots[0]
	if emit_result_is_inout(e, 0) {
		v := load(e, "ptr", slot)
		fmt.sbprintfln(&e.b, "  ret ptr %s", v)
		return
	}
	switch abi_pass(e.c, result) {
	case .Indirect:
		fmt.sbprintln(&e.b, "  ret void")
	case .Reg_Int:
		bits := abi_reg_bits(e.c, result)
		v := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load i%d, ptr %s, align %d", v, bits, slot, type_align(e.c, result))
		fmt.sbprintfln(&e.b, "  ret i%d %s", bits, v)
	case .Bool_I1:
		v := load(e, "i1", slot)
		fmt.sbprintfln(&e.b, "  ret i1 %s", v)
	case .Direct:
		v := load(e, llvm_type(e, result), slot)
		fmt.sbprintfln(&e.b, "  ret %s %s", llvm_type(e, result), v)
	}
}

// design.md "`@(c_vararg)`": the C default argument promotions. `f32` widens to
// `double`; `bool`, an enum, and an integer narrower than 32 bits widen to
// `i32`; an aggregate follows the ordinary by-value classification. Returns the
// promoted `<type> <value>` operand.
@(private = "file")
emit_c_vararg_promote :: proc(e: ^Emitter, type: Type_Id, operand: string) -> string {
	under := type_underlying(e.c, type)
	info := type_of(e.c, under)
	if info == nil {
		return fmt.aprintf("%s %s", llvm_type(e, type), operand)
	}
	#partial switch info.kind {
	case .Float:
		if info.bits == 32 {
			out := temp(e)
			fmt.sbprintfln(&e.b, "  %s = fpext float %s to double", out, operand)
			return fmt.aprintf("double %s", out)
		}
		return fmt.aprintf("%s %s", llvm_type(e, under), operand)
	case .Bool:
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i32", out, operand)
		return fmt.aprintf("i32 %s", out)
	case .Int, .Enum:
		bits := type_bits(e.c, under)
		if bits < 32 {
			out := temp(e)
			op := type_signed(e.c, under) ? "sext" : "zext"
			fmt.sbprintfln(&e.b, "  %s = %s i%d %s to i32", out, op, bits, operand)
			return fmt.aprintf("i32 %s", out)
		}
		return fmt.aprintf("i%d %s", bits, operand)
	case .Struct, .Array, .Union:
		#partial switch abi_pass(e.c, under) {
		case .Reg_Int:
			slot, loaded := temp(e), temp(e)
			bits, align := abi_reg_bits(e.c, under), type_align(e.c, under)
			fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, under))
			fmt.sbprintfln(&e.b, "  store %s %s, ptr %s, align %d", llvm_type(e, under), operand, slot, align)
			fmt.sbprintfln(&e.b, "  %s = load i%d, ptr %s, align %d", loaded, bits, slot, align)
			return fmt.aprintf("i%d %s", bits, loaded)
		case .Indirect:
			slot := alloca(e, llvm_type(e, under))
			fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, under), operand, slot)
			return fmt.aprintf("ptr %s", slot)
		}
	}
	return fmt.aprintf("%s %s", llvm_type(e, type), operand)
}

// The explicit LLVM function type a variadic call names: `<ret> (<fixed...>, ...)`,
// matching the `declare`'s parameter types without their call-site attributes.
@(private = "file")
foreign_call_type :: proc(e: ^Emitter, callee_type: ^Type_Info, has_sret: bool) -> string {
	ret := "void"
	if len(callee_type.results) == 1 {
		result := callee_type.results[0]
		if proc_result_is_inout(callee_type, 0) {
			ret = "ptr"
		} else {
			#partial switch abi_pass(e.c, result) {
			case .Reg_Int:
				ret = fmt.aprintf("i%d", abi_reg_bits(e.c, result))
			case .Bool_I1:
				ret = "i1"
			case .Direct:
				ret = llvm_type(e, result)
			}
		}
	}
	b := strings.builder_make()
	fmt.sbprintf(&b, "%s (", ret)
	need_comma := false
	if has_sret {
		fmt.sbprint(&b, "ptr")
		need_comma = true
	}
	for parameter, index in callee_type.parameters {
		if need_comma {
			fmt.sbprint(&b, ", ")
		}
		need_comma = true
		mode := index < len(callee_type.param_modes) ? callee_type.param_modes[index] : Param_Mode.Value
		if mode == .Inout || param_is_by_ptr(callee_type, index) {
			fmt.sbprint(&b, "ptr")
			continue
		}
		#partial switch abi_pass(e.c, parameter) {
		case .Bool_I1:
			fmt.sbprint(&b, "i1")
		case .Reg_Int:
			fmt.sbprintf(&b, "i%d", abi_reg_bits(e.c, parameter))
		case .Indirect:
			fmt.sbprint(&b, "ptr")
		case .Direct:
			fmt.sbprint(&b, llvm_type(e, parameter))
		}
	}
	if need_comma {
		fmt.sbprint(&b, ", ")
	}
	fmt.sbprint(&b, "...)")
	return strings.to_string(b)
}

@(private)
emit_foreign_call :: proc(
	e: ^Emitter, callee: string, callee_type: ^Type_Info, operands: []string,
	symbol: ^Symbol, bound: []Expr,
) -> []string {
	ret := "void"
	sret := ""
	result_type := INVALID_TYPE
	if len(callee_type.results) == 1 {
		result_type = callee_type.results[0]
		if proc_result_is_inout(callee_type, 0) {
			ret = "ptr"
		} else {
			switch abi_pass(e.c, result_type) {
			case .Indirect:
				sret = temp(e)
				fmt.sbprintfln(&e.b, "  %s = alloca %s", sret, llvm_type(e, result_type))
			case .Reg_Int:
				ret = fmt.aprintf("i%d", abi_reg_bits(e.c, result_type))
			case .Bool_I1:
				ret = "zeroext i1"
			case .Direct:
				ret = llvm_type(e, result_type)
			}
		}
	}

	// design.md "`@(c_vararg)`": arguments past the fixed parameters are concrete
	// C variadics with the default promotions applied here.
	fixed := len(callee_type.parameters)
	c_vararg := callee_type.c_vararg

	args := make([dynamic]string, 0, len(operands) + 1)
	if sret != "" {
		append(&args, fmt.aprintf(
			"ptr sret(%s) align %d %s", llvm_type(e, result_type), type_align(e.c, result_type), sret,
		))
	}
	for operand, index in operands {
		if c_vararg && index >= fixed {
			append(&args, emit_c_vararg_promote(e, expr_base(bound[index]).type, operand))
			continue
		}
		parameter := callee_type.parameters[index]
		mode := index < len(callee_type.param_modes) ? callee_type.param_modes[index] : Param_Mode.Value
		// An `inout` or `@(by_ptr)` parameter both cross as a pointer to storage.
		if mode == .Inout {
			append(&args, fmt.aprintf("ptr %s", operand))
			continue
		}
		if param_is_by_ptr(callee_type, index) {
			slot := alloca(e, llvm_type(e, parameter))
			fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, parameter), operand, slot)
			append(&args, fmt.aprintf("ptr %s", slot))
			continue
		}
		switch abi_pass(e.c, parameter) {
		case .Bool_I1:
			append(&args, fmt.aprintf("i1 zeroext %s", operand))
		case .Reg_Int:
			slot, loaded := temp(e), temp(e)
			bits, align := abi_reg_bits(e.c, parameter), type_align(e.c, parameter)
			fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, parameter))
			fmt.sbprintfln(&e.b, "  store %s %s, ptr %s, align %d", llvm_type(e, parameter), operand, slot, align)
			fmt.sbprintfln(&e.b, "  %s = load i%d, ptr %s, align %d", loaded, bits, slot, align)
			append(&args, fmt.aprintf("i%d %s", bits, loaded))
		case .Indirect:
			slot := alloca(e, llvm_type(e, parameter))
			fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, parameter), operand, slot)
			append(&args, fmt.aprintf("ptr %s", slot))
		case .Direct:
			append(&args, fmt.aprintf("%s %s", llvm_type(e, parameter), operand))
		}
	}

	// A variadic call names the explicit function type in place of the plain
	// return type; a fixed call names only the return type.
	head := ret
	if c_vararg {
		head = foreign_call_type(e, callee_type, sret != "")
	}
	call := ""
	if ret == "void" {
		fmt.sbprintf(&e.b, "  call %s %s(", head, callee)
	} else {
		call = temp(e)
		fmt.sbprintf(&e.b, "  %s = call %s %s(", call, head, callee)
	}
	for arg, index in args {
		if index > 0 {
			fmt.sbprint(&e.b, ", ")
		}
		fmt.sbprint(&e.b, arg)
	}
	fmt.sbprintln(&e.b, ")")

	if len(callee_type.results) == 0 {
		return nil
	}
	single := make([]string, 1)
	if proc_result_is_inout(callee_type, 0) {
		single[0] = call
		return single
	}
	switch abi_pass(e.c, result_type) {
	case .Indirect:
		v := load(e, llvm_type(e, result_type), sret)
		single[0] = v
	case .Reg_Int:
		slot, v := temp(e), temp(e)
		align := type_align(e.c, result_type)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, result_type))
		fmt.sbprintfln(&e.b, "  store i%d %s, ptr %s, align %d", abi_reg_bits(e.c, result_type), call, slot, align)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s, align %d", v, llvm_type(e, result_type), slot, align)
		single[0] = v
	case .Bool_I1, .Direct:
		single[0] = call
	}
	return single
}

// `Option(T)` from a runtime presence flag. The payload is written only on the
// present branch, so an absent option never publishes uninitialized bytes.
@(private)
emit_option_value :: proc(e: ^Emitter, option_type: Type_Id, present, payload: string) -> string {
	return emit_union_choice(
		e, option_type, present,
		union_index_of(e.c, option_type, "some"), union_index_of(e.c, option_type, "none"),
		payload,
	)
}

// `Result(T, Allocator_Error)` from a runtime failure flag. The error payload is
// the one non-zero `Allocator_Error` code the seed runtime reports; `value` is
// the success payload, empty when success carries `Unit`.
@(private)
emit_alloc_result :: proc(e: ^Emitter, result: Type_Id, failed: string, value := "") -> string {
	return emit_union_either(
		e, result, failed,
		union_index_of(e.c, result, "err"), "1",
		union_index_of(e.c, result, "ok"), value,
	)
}
