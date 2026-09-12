// Constants, places, expressions, and text operations.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

// -------------------------------------------------------------- constants --

// design.md "Zero values": a union constant is a payload written into the
// storage type's alignment-carrying head plus the variant's tag, serialized to
// the same little-endian byte image as packed/aligned records and split across
// the integer head and byte-array tail.
@(private = "file")
union_constant :: proc(e: ^Emitter, value: Const_Value, type: Type_Id, info: ^Type_Info) -> string {
	shape := union_layout(e.c, type)
	if value.kind != .Aggregate || value.aggregate == nil {
		return "zeroinitializer" // the designated zero variant, which is all-zero
	}
	index := value.aggregate.variant
	payload_type := union_variant_payload(e.c, type, index)
	head := "0"
	payload_bytes := make([]u8, int(shape.payload_size), context.temp_allocator)
	// A zero-sized payload — `Unit`, or any empty record — contributes no bits,
	// so the zeroed head already *is* the whole value.
	if payload_type != TYPE_VOID && type_size(e.c, payload_type) != 0 {
		payload_size := int(type_size(e.c, payload_type))
		if payload_size > len(payload_bytes) ||
		   !write_const_bytes(e, payload_bytes[:payload_size], value.aggregate.elements[0], payload_type) {
			backend_fail(e, fmt.aprintf("a union payload constant cannot be represented as bytes: %s in %s", type_name(e.c, payload_type), type_name(e.c, type)))
		}
		bits := bi_zero(e.c)
		for byte, byte_index in payload_bytes[:int(shape.align)] {
			part := bi_shl(e.c, bi_from_u64(e.c, u64(byte)), byte_index * 8)
			bits = bi_add(e.c, bits, part)
		}
		head = bi_text(e.c, bits)
	}

	b := strings.builder_make()
	strings.write_string(&b, "{ ")
	// An all-payloadless union stores its tag and nothing else.
	if shape.payload_size > 0 {
		fmt.sbprintf(&b, "i%d %s", shape.align * 8, head)
		if pad := shape.payload_size - shape.align; pad > 0 {
			strings.write_string(&b, ", ")
			write_byte_array_constant(&b, payload_bytes[int(shape.align):int(shape.payload_size)])
		}
		if gap := shape.tag_offset - shape.payload_size; gap > 0 {
			fmt.sbprintf(&b, ", [%d x i8] zeroinitializer", gap)
		}
		strings.write_string(&b, ", ")
	}
	fmt.sbprintf(&b, "i%d %d", shape.tag_bytes * 8, index)
	if tail := shape.size - shape.tag_offset - shape.tag_bytes; tail > 0 {
		fmt.sbprintf(&b, ", [%d x i8] zeroinitializer", tail)
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

@(private = "file")
write_byte_array_constant :: proc(b: ^strings.Builder, bytes: []u8) {
	fmt.sbprintf(b, "[%d x i8] c\"", len(bytes))
	for byte in bytes {
		fmt.sbprintf(b, "\\%02X", byte)
	}
	strings.write_string(b, "\"")
}

llvm_const :: proc(e: ^Emitter, value: Const_Value, type: Type_Id) -> string {
	under := type_underlying(e.c, default_type(e.c, type))
	info := type_of(e.c, under)
	if info == nil {
		return "0"
	}
	#partial switch info.kind {
	case .Typeid:
		// Symbolic during checking, numeric here: `freeze_typeids` has assigned a
		// deterministic value to every requested type before any body is emitted.
		id := typeid_value(e.c, value.type_value)
		if value.type_value != INVALID_TYPE && id == 0 {
			backend_fail(e, "a typeid constant was not registered before freezing")
		}
		return fmt.aprintf("%d", id)
	case .Bool:
		return value.boolean ? "true" : "false"
	case .Int, .Enum, .Rune:
		bits := type_bits(e.c, under)
		signed := type_signed(e.c, under)
		if info.kind == .Rune {
			bits, signed = 32, true
		}
		return bi_text(e.c, bi_wrap(e.c, value.integer, bits, signed))
	case .Float:
		return llvm_float(const_float_pattern(value, info.bits), info.bits)
	case .Pointer, .C_Pointer, .Raw_Pointer, .Proc, .Allocator:
		return "null"
	case .CString_View:
		// A string literal can initialize a `cstring_view` because its
		// zero-terminated bytes have static lifetime (design.md).
		return value.kind == .String ? text_literal_global(e, value.text) : "null"
	case .String, .String_View:
		return text_constant(e, value, info.kind == .String)
	case .Allocator_Error:
		// Nil is success, and success is zero.
		return value.kind == .Nil ? "0" : bi_text(e.c, value.integer)
	case .Union:
		return union_constant(e, value, under, info)
	case .Array, .Simd:
		// A vector constant is LLVM's `<...>` over the same lane values an array
		// constant writes between brackets; a `Simd(bool, N)` lane is `i8` in
		// memory, which `simd_lane_llvm_type` answers for both.
		vector := info.kind == .Simd
		lane := simd_lane_llvm_type(e, info)
		b := strings.builder_make()
		strings.write_string(&b, vector ? "<" : "[")
		for index in 0 ..< int(info.count) {
			if index > 0 {
				strings.write_string(&b, ",")
			}
			element := Const_Value{}
			if value.aggregate != nil && index < len(value.aggregate.elements) {
				element = value.aggregate.elements[index]
			}
			value := llvm_const(e, element, info.element)
			if vector && lane == "i8" {
				// A mask lane is a byte, so `true`/`false` — an `i1`'s spelling — is a
				// type mismatch in the constant rather than a narrowing.
				value = value == "true" ? "1" : "0"
			}
			fmt.sbprintf(&b, " %s %s", lane, value)
		}
		strings.write_string(&b, vector ? " >" : " ]")
		return strings.to_string(b)
	case .Struct, .Any_View, .Dyn, .Slice, .Dynamic_Array, .Map:
		if value.kind == .Nil {
			return "zeroinitializer"
		}
		// A slice constant is not a pair of fields to fill in: it points at
		// storage, and only the module can hold storage that outlives every frame.
		if info.kind == .Slice && value.aggregate != nil {
			return slice_literal_constant(e, value, info)
		}
		// A `@(packed)`/`@(align=N)` struct's constant must match the byte-exact
		// body `struct_body` emits.
		packed := info.kind == .Struct && info.packed
		over_aligned := info.kind == .Struct && info.align > record_natural_align(e.c, info)
		byte_array := packed && over_aligned
		b := strings.builder_make()
		strings.write_string(&b, byte_array ? "{" : (packed ? "<{" : "{"))
		for field, index in info.fields {
			symbol := symbol_of(e.c, field)
			if index > 0 {
				strings.write_string(&b, ",")
			}
			element := Const_Value{}
			if value.aggregate != nil && index < len(value.aggregate.elements) {
				element = value.aggregate.elements[index]
			}
			if byte_array {
				fmt.sbprintf(&b, " [%d x i8] %s", type_size(e.c, symbol.type), field_byte_const(e, element, symbol.type))
			} else {
				fmt.sbprintf(&b, " %s %s", llvm_type(e, symbol.type), llvm_const(e, element, symbol.type))
			}
		}
		if over_aligned {
			fmt.sbprintf(&b, ", [0 x i%d] zeroinitializer", info.align * 8)
		}
		strings.write_string(&b, byte_array ? " }" : (packed ? " }>" : " }"))
		return strings.to_string(b)
	}
	return "0"
}

// The `[size x i8]` constant of one field inside a combined `@(packed, align=N)`
// struct: byte arrays keep a non-packed LLVM record from re-padding or dropping
// the raised alignment. Serializes the complete little-endian value, including
// nested padding, rather than zeroing unsupported fields.
@(private = "file")
field_byte_const :: proc(e: ^Emitter, value: Const_Value, type: Type_Id) -> string {
	size := int(type_size(e.c, type))
	bytes := make([]u8, size, context.temp_allocator)
	if !write_const_bytes(e, bytes, value, type) {
		backend_fail(e, "a combined packed/aligned constant has a value that cannot be represented as bytes")
		return "zeroinitializer"
	}
	b := strings.builder_make()
	strings.write_string(&b, "c\"")
	for byte in bytes {
		fmt.sbprintf(&b, "\\%02X", byte)
	}
	strings.write_string(&b, "\"")
	return strings.to_string(b)
}

@(private = "file")
write_const_bytes :: proc(e: ^Emitter, out: []u8, value: Const_Value, type: Type_Id) -> bool {
	// Missing aggregate elements and nil values are their type's all-zero value;
	// `make` already initialized the destination accordingly.
	if value.kind == .Invalid || value.kind == .Nil {
		return true
	}
	under := type_underlying(e.c, type)
	info := type_of(e.c, under)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Int, .Enum, .Rune, .Allocator_Error:
		if value.kind != .Integer && value.kind != .Rune {
			return false
		}
		wrapped := bi_wrap(e.c, value.integer, len(out) * 8, false)
		for _, index in out {
			byte_value, ok := bi_to_u64(e.c, bi_wrap(e.c, bi_shr(e.c, wrapped, index * 8), 8, false))
			if !ok {
				return false
			}
			out[index] = u8(byte_value)
		}
		return true
	case .Bool:
		if value.kind != .Boolean || len(out) == 0 {
			return false
		}
		out[0] = value.boolean ? 1 : 0
		return true
	case .Float:
		if value.kind != .Float {
			return false
		}
		if info.bits != 16 && info.bits != 32 && info.bits != 64 {
			return false
		}
		raw := const_float_pattern(value, info.bits)
		for _, index in out {
			out[index] = u8(raw >> u64(index * 8))
		}
		return true
	case .Array, .Simd:
		stride := int(type_size(e.c, info.element))
		for index in 0 ..< int(info.count) {
			start, end := index * stride, (index + 1) * stride
			if end > len(out) {
				return false
			}
			element := Const_Value{}
			if value.aggregate != nil && index < len(value.aggregate.elements) {
				element = value.aggregate.elements[index]
			}
			if !write_const_bytes(e, out[start:end], element, info.element) {
				return false
			}
		}
		return true
	case .Struct:
		for field, index in info.fields {
			symbol := symbol_of(e.c, field)
			if symbol == nil || index >= len(info.offsets) {
				return false
			}
			start := int(info.offsets[index])
			end := start + int(type_size(e.c, symbol.type))
			if end > len(out) {
				return false
			}
			element := Const_Value{}
			if value.aggregate != nil && index < len(value.aggregate.elements) {
				element = value.aggregate.elements[index]
			}
			if !write_const_bytes(e, out[start:end], element, symbol.type) {
				return false
			}
		}
		return true
	case .Union:
		if value.kind != .Aggregate || value.aggregate == nil {
			return false
		}
		shape := union_layout(e.c, under)
		index := value.aggregate.variant
		if index < 0 || index >= len(info.variants) || int(shape.size) > len(out) {
			return false
		}
		payload := len(value.aggregate.elements) > 0 ? value.aggregate.elements[0] : Const_Value{}
		payload_type := info.variants[index]
		payload_size := int(type_size(e.c, payload_type))
		if payload_size > 0 && !write_const_bytes(e, out[:payload_size], payload, payload_type) {
			return false
		}
		for byte_index in 0 ..< int(shape.tag_bytes) {
			out[int(shape.tag_offset) + byte_index] = u8(u64(index) >> u64(byte_index * 8))
		}
		return true
	case .Typeid:
		id := typeid_value(e.c, value.type_value)
		if value.type_value != INVALID_TYPE && id == 0 {
			backend_fail(e, "a typeid constant was not registered before freezing")
			return false
		}
		for _, index in out {
			out[index] = u8(id >> u64(index * 8))
		}
		return true
	case .Pointer, .C_Pointer, .Raw_Pointer, .Proc, .CString_View:
		// Their only byte-serializable compile-time value is nil, handled above.
		return false
	}
	return false
}

// LLVM's decimal float syntax only round-trips exactly for some values, so
// every float constant is spelled as its bit pattern: `half` uses the 16-bit
// form, `float` the double pattern (exact, since the value was already rounded
// to single precision).
llvm_float :: proc(pattern: u64, bits: u16) -> string {
	if bits == 16 {
		return fmt.aprintf("0xH%04X", u16(pattern))
	}
	if bits == 32 {
		// LLVM has no 32-bit hex float literal: a `float` constant is written as
		// the `double` pattern of the same value. The widening is done on the bits
		// rather than by a hardware conversion, so a signalling NaN's payload
		// survives — `f64(f32_snan)` would quiet it.
		return fmt.aprintf("0x%016X", f32_pattern_as_f64(u32(pattern)))
	}
	return fmt.aprintf("0x%016X", pattern)
}

@(private = "file")
f32_pattern_as_f64 :: proc(pattern: u32) -> u64 {
	sign := u64(pattern >> 31) << 63
	exponent := (pattern >> 23) & 0xff
	mantissa := u64(pattern & 0x7f_ffff) << 29
	switch exponent {
	case 0xff:
		return sign | 0x7ff0_0000_0000_0000 | mantissa // infinity, or a NaN payload
	case 0:
		// Zero, or an f32 subnormal, which is an ordinary normal f64: the
		// hardware conversion is exact and has no NaN to quiet.
		return transmute(u64)f64(transmute(f32)pattern)
	}
	return sign | (u64(exponent) - 127 + 1023) << 52 | mantissa
}

// ------------------------------------------------------------------ places --

// The read half of `store`, and the only load that can be under-aligned: it
// takes the `Type_Id` because that is what `align_suffix` needs. `load` remains
// the right call for a compiler-owned slot, whose alignment is natural by
// construction; this one is for a written place, which may be reached through a
// packed field.
@(private)
load_place :: proc(e: ^Emitter, type: Type_Id, address: string) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s%s", out, llvm_type(e, type), address, align_suffix(e, address, type))
	return out
}

@(private)
store :: proc(e: ^Emitter, type: Type_Id, value, address: string) {
	if address == "" || value == "" {
		return
	}
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s%s", llvm_type(e, type), value, address, align_suffix(e, address, type))
}

// The guaranteed alignment of a place, defaulting to the pointee's natural
// alignment when nothing lower was recorded.
@(private = "file")
place_align_of :: proc(e: ^Emitter, address: string, type: Type_Id) -> u64 {
	if a, ok := e.place_align[address]; ok {
		return a
	}
	return type_align(e.c, type)
}

// `, align N` when a place is known less aligned than its pointee wants — what
// reaching through a packed field produces. Empty otherwise, so ordinary access
// keeps its unchanged IR.
@(private = "file")
align_suffix :: proc(e: ^Emitter, address: string, type: Type_Id) -> string {
	if a, ok := e.place_align[address]; ok && a < type_align(e.c, type) {
		return fmt.aprintf(", align %d", a)
	}
	return ""
}

// Records the effective alignment of the address of `field` reached from a base
// place, lowering it to 1 through a packed struct so nested access stays
// unaligned.
@(private = "file")
record_field_align :: proc(e: ^Emitter, base_type: Type_Id, base_address, field_address: string, field_type: Type_Id) {
	base_info := underlying_info(e.c, base_type)
	base_align := place_align_of(e, base_address, base_type)
	field_align := base_info != nil && base_info.packed ? u64(1) : min(base_align, type_align(e.c, field_type))
	if field_align < type_align(e.c, field_type) {
		e.place_align[field_address] = field_align
	}
}

// The address of a place. Composite literals get temporary storage here, which
// is what makes `&Point{1, 2}` work.
@(private)
emit_address :: proc(e: ^Emitter, expr: Expr) -> string {
	if expression_converts_storage(expr) {
		type := expr_base(expr).type
		slot := alloca(e, llvm_type(e, type))
		store(e, type, emit_expr(e, expr), slot)
		register_temporary_place(e, type, slot)
		return slot
	}
	return emit_address_at(e, expr, expr_base(expr).type)
}

// The storage type can precede an implicit conversion on the same node.
@(private)
emit_address_at :: proc(e: ^Emitter, expr: Expr, as_type: Type_Id) -> string {
	// design.md "Materialization": every runtime use of one constant shares one
	// read-only object, so the address is the global the checker registered.
	if entry := materialization_of(e.c, expr); entry != nil {
		return entry.name
	}
	#partial switch v in expr {
	case ^Expr_Ident:
		if name, ok := e.names[v.symbol]; ok {
			return name
		}
		backend_fail(e, "a resolved place has no storage")
		return "null"

	case ^Expr_Postfix:
		pointer := emit_expr(e, v.operand)
		emit_nil_check(e, pointer)
		return pointer

	case ^Expr_Selector:
		// `pkg.name` naming another package's global is a whole symbol, not a field
		// of its operand — the operand is a package alias with no storage, so its
		// own name is the address.
		if v.resolution.kind == .Value {
			if name, ok := e.names[v.resolution.symbol]; ok {
				return name
			}
			backend_fail(e, "a resolved place has no storage")
			return "null"
		}
		symbol := symbol_of(e.c, v.resolution.symbol)
		base_type, base_address := emit_base_address(e, v.operand)
		out := gep_field(e, llvm_type(e, base_type), base_address, int(symbol.index))
		record_field_align(e, base_type, base_address, out, symbol.type)
		return out

	case ^Expr_Index:
		// design.md "Indexing and slicing": an `operator([])` returning `inout T`
		// hands back the address itself, and only that overload denotes a place. A
		// value-returning one produces a value, which needs temporary storage like
		// any other — asking for its address is what an immutable receiver does.
		if v.resolution.kind == .User_Operator {
			if sym := symbol_of(e.c, v.resolution.symbol); sym != nil && sym.result_inout {
				return emit_operator_call(e, v.resolution.symbol, v.bound)
			}
			slot := alloca(e, llvm_type(e, as_type))
			store(e, as_type, emit_operator_call(e, v.resolution.symbol, v.bound), slot)
			return slot
		}
		// A slice element lives in the root, reached through the data word, and its
		// bound is the runtime length rather than a static count.
		if type_is_slice(e.c, expr_base(v.operand).type) {
			return emit_slice_element_address(e, v)
		}
		// A dynamic array's element lives behind its data word, bounded by its
		// length word: the same two loads, read out of the container header.
		if type_is_dynamic_array(e.c, expr_base(v.operand).type) {
			return emit_dynamic_element_address(e, v)
		}
		if type_is_map(e.c, expr_base(v.operand).type) {
			// design.md "Maps": every index but the whole-element assignment names
			// an element that must already be there, and that one never asks for an
			// address — `src/emit_llvm_stmt.odin` commits its value into the slot.
			return emit_map_element_address(e, v)
		}
		// A C pointer indexes without bounds checking (design.md
		// "C pointers"). There is no length to check against, which is exactly
		// what the type says.
		if operand_info := underlying_info(e.c, expr_base(v.operand).type);
		   operand_info != nil && operand_info.kind == .C_Pointer {
			data := emit_expr(e, v.operand)
			index := widen_to_i64(e, emit_expr(e, v.indices[0]), expr_base(v.indices[0]).type)
			out := gep_at(e, llvm_type(e, operand_info.element), data, index)
			return out
		}
		base_type, base_address := emit_base_address(e, v.operand)
		info := underlying_info(e.c, base_type)
		index := emit_expr(e, v.indices[0])
		index = emit_bounds_check(e, index, expr_base(v.indices[0]).type, info.count)
		out := temp(e)
		fmt.sbprintfln(
			&e.b,
			"  %s = getelementptr inbounds %s, ptr %s, i64 0, i64 %s",
			out, llvm_type(e, base_type), base_address, index,
		)
		return out

	case ^Expr_Composite:
		slot := alloca(e, llvm_type(e, as_type))
		emit_composite_into(e, v, slot, as_type)
		return slot

	case ^Expr_Call:
		if expr_base(expr).value_category == .Place {
			// A single `inout` result is already the address of the returned place.
			return emit_call(e, v, as_type)
		}
		// An ordinary aggregate result selected immediately by a field still needs
		// addressable temporary storage for that selection.
		slot := alloca(e, llvm_type(e, as_type))
		store(e, as_type, emit_call(e, v, as_type), slot)
		hold_addressed_temporary(e, expr, as_type, slot)
		return slot
	}
	// Any other addressable expression is materialised into a temporary.
	slot := alloca(e, llvm_type(e, as_type))
	store(e, as_type, emit_expr_at(e, expr, as_type), slot)
	hold_addressed_temporary(e, expr, as_type, slot)
	return slot
}

// The two branches above are where an owned value becomes addressable storage,
// which is the one thing every borrowing form has in common: slicing, indexing,
// field selection, a conversion, an operator, and an immutable receiver all
// reach their operand through here. Registering the owner once, here, is what
// gives `takes(build()[:])` a boundary — the borrow is the caller's to keep
// alive, and the storage is nobody's to name.
//
// A place names storage someone else owns, and is not ours to destroy.
@(private)
hold_addressed_temporary :: proc(e: ^Emitter, expr: Expr, type: Type_Id, place: string) {
	if expression_is_borrowed_place(e.c, expr) {
		return
	}
	register_temporary_place(e, type, place)
}

// `xs[i]`: the element's address inside the container's current allocation,
// bounds-checked against the header's length word. Indexing and slicing produce
// views into the current allocation (design.md), so this address is exactly as
// long-lived as that allocation — enforced by the M5b invalidation events every
// relocating operation registers.
@(private = "file")
emit_dynamic_element_address :: proc(e: ^Emitter, v: ^Expr_Index) -> string {
	operand_type := expr_base(v.operand).type
	header := emit_address(e, v.operand)
	data := load(e, "ptr", header)
	length := temp(e)
	length_slot := gep_field(e, CONTAINER_TYPE, header, CONTAINER_LEN)
	fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", length, length_slot)

	index := widen_to_i64(e, emit_expr(e, v.indices[0]), expr_base(v.indices[0]).type)
	// Unsigned, so a negative index is caught by the same comparison as an
	// oversized one.
	out_of_range := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp uge i64 %s, %s", out_of_range, index, length)
	panic_if(e, out_of_range, "bounds", "index out of range")

	out := gep_at(e, llvm_type(e, container_element(e.c, operand_type)), data, index)
	return out
}

// `s[i]`: the element's address inside the slice's root, bounds-checked against
// the runtime length word.
@(private = "file")
emit_slice_element_address :: proc(e: ^Emitter, v: ^Expr_Index) -> string {
	operand_type := expr_base(v.operand).type
	slice := emit_expr(e, v.operand)
	llvm := llvm_type(e, operand_type)
	data := extract(e, llvm, slice, SLICE_DATA)
	length := extract(e, llvm, slice, SLICE_LEN)

	index := widen_to_i64(e, emit_expr(e, v.indices[0]), expr_base(v.indices[0]).type)
	// Unsigned, so a negative index is caught by the same comparison as an
	// oversized one.
	out_of_range := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp uge i64 %s, %s", out_of_range, index, length)
	panic_if(e, out_of_range, "bounds", "index out of range")

	out := gep_at(e, llvm_type(e, slice_element(e.c, operand_type)), data, index)
	return out
}

// `p.x` and `p[i]` accept one pointer hop, in which case the pointer value
// itself is the base address.
@(private = "file")
emit_base_address :: proc(e: ^Emitter, operand: Expr) -> (Type_Id, string) {
	type := expr_base(operand).type
	info := underlying_info(e.c, type)
	if info != nil && info.kind == .Pointer {
		pointer := emit_expr(e, operand)
		emit_nil_check(e, pointer)
		return info.element, pointer
	}
	return type, emit_address(e, operand)
}

@(private = "file")
emit_nil_check :: proc(e: ^Emitter, pointer: string) {
	is_nil := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", is_nil, pointer)
	panic_if(e, is_nil, "nil.deref", "nil pointer dereference")
}

// A built-in slice expression: `base[lo:hi]` over a fixed array or another
// slice. The base and both bounds are each evaluated once, in written order,
// then checked as `0 <= lo <= hi <= len` before any address is formed.
@(private = "file")
emit_builtin_slice :: proc(e: ^Emitter, v: ^Expr_Slice, as_type: Type_Id) -> string {
	operand_type := expr_base(v.operand).type
	info := underlying_info(e.c, operand_type)
	element := info.element

	data, length := "", ""
	#partial switch info.kind {
	case .String, .String_View:
		return emit_text_subrange(e, v)
	case .C_Pointer:
		return emit_c_pointer_slice(e, v, as_type)
	}
	if info.kind == .Slice {
		value := emit_expr(e, v.operand)
		llvm := llvm_type(e, operand_type)
		data, length = temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, llvm, value, SLICE_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, llvm, value, SLICE_LEN)
	} else if info.kind == .Dynamic_Array {
		// The view is over the *current* allocation and stops at `len`, never at
		// the capacity: the slots past the length hold no initialized element.
		value := emit_expr(e, v.operand)
		data, length = temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, CONTAINER_TYPE, value, CONTAINER_STORAGE)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, CONTAINER_TYPE, value, CONTAINER_LEN)
	} else {
		data = emit_address(e, v.operand)
		length = fmt.aprintf("%d", info.count)
	}

	low := "0"
	if v.lo != nil {
		low = widen_to_i64(e, emit_expr(e, v.lo), expr_base(v.lo).type)
	}
	high := length
	if v.hi != nil {
		high = widen_to_i64(e, emit_expr(e, v.hi), expr_base(v.hi).type)
	}

	// One trap seam for the whole range, so a reversed or oversized pair cannot
	// produce a slice with a negative or out-of-root length.
	reversed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", reversed, low, high)
	past_end := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", past_end, high, length)
	bad := temp(e)
	fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", bad, reversed, past_end)
	panic_if(e, bad, "slice.bounds", "slice bounds out of range")

	// The result's data pointer is the low bound's address in the root, so
	// reslicing composes without a second base.
	start := gep_at(e, llvm_type(e, element), data, low)
	count := temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, %s", count, high, low)

	return emit_slice_value(e, as_type, start, count)
}

// design.md "From string to X": `st[low:high]` is a subrange *view*. The bounds
// are byte offsets, and a range that split a code point would hand out a
// `string_view` that is not valid UTF-8 — so the encoding is checked with the
// range, not merely the length.
@(private = "file")
emit_text_subrange :: proc(e: ^Emitter, v: ^Expr_Slice) -> string {
	data, length := emit_text_parts(e, v.operand)
	low := "0"
	if v.lo != nil {
		low = widen_to_i64(e, emit_expr(e, v.lo), expr_base(v.lo).type)
	}
	high := length
	if v.hi != nil {
		high = widen_to_i64(e, emit_expr(e, v.hi), expr_base(v.hi).type)
	}
	reversed, past_end, bad := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", reversed, low, high)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", past_end, high, length)
	fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", bad, reversed, past_end)
	panic_if(e, bad, "slice.bounds", "string slice bounds out of range")

	start, count := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds i8, ptr %s, i64 %s", start, data, low)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, %s", count, high, low)
	valid, split := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = call i32 @loke_rt_v1_utf8_valid(ptr %s, i64 %s)", valid, start, count)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", split, valid)
	panic_if(e, split, "slice.utf8", "string slice bounds split a code point")

	return emit_ptr_len(e, STRING_VIEW_TYPE, start, count)
}

// design.md "C pointers": `x[:]`/`x[i:]` stay C pointers and carry no
// bounds; `x[:n]`/`x[i:n]` produce a `[]T` and are checked, because only then is
// there a length to check against.
@(private = "file")
emit_c_pointer_slice :: proc(e: ^Emitter, v: ^Expr_Slice, as_type: Type_Id) -> string {
	element := underlying_info(e.c, expr_base(v.operand).type).element
	data := emit_expr(e, v.operand)
	low := "0"
	if v.lo != nil {
		low = widen_to_i64(e, emit_expr(e, v.lo), expr_base(v.lo).type)
	}
	start := gep_at(e, llvm_type(e, element), data, low)
	if v.hi == nil {
		return start
	}
	high := widen_to_i64(e, emit_expr(e, v.hi), expr_base(v.hi).type)
	reversed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", reversed, low, high)
	panic_if(e, reversed, "slice.bounds", "slice bounds out of range")
	count := temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, %s", count, high, low)
	return emit_slice_value(e, as_type, start, count)
}

@(private = "file")
emit_bounds_check :: proc(e: ^Emitter, index: string, index_type: Type_Id, count: u64) -> string {
	// An unsigned comparison catches a negative index and an oversized one at
	// once: a negative value becomes a very large unsigned one. Compare before
	// truncating a 128-bit index, then use the checked i64 value for the GEP.
	out_of_range := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp uge %s %s, %d", out_of_range, llvm_type(e, index_type), index, count)
	panic_if(e, out_of_range, "bounds", "index out of range")
	return widen_to_i64(e, index, index_type)
}

@(private)
widen_to_i64 :: proc(e: ^Emitter, value: string, type: Type_Id) -> string {
	bits := type_bits(e.c, type)
	if bits == 64 {
		return value
	}
	out := temp(e)
	op := type_signed(e.c, type) ? "sext" : "zext"
	if bits > 64 {
		op = "trunc"
	}
	fmt.sbprintfln(&e.b, "  %s = %s i%d %s to i64", out, op, bits, value)
	return out
}

// ------------------------------------------------------------ expressions --

// Returns an operand: a literal, or a `%name`.
@(private)
emit_expr :: proc(e: ^Emitter, expr: Expr) -> string {
	if expr == nil {
		return "0"
	}
	return emit_expr_at(e, expr, expr_base(expr).type)
}

// Emit the checked result type, or a source type recorded by an implicit
// conversion. Only this node uses the override: children keep their own checked
// types. Helpers receive it explicitly so checker annotations stay unchanged.
@(private)
emit_expr_at :: proc(e: ^Emitter, expr: Expr, as_type: Type_Id) -> string {
	base := expr_base(expr)
	// A concrete value becoming an `any_view`: its address plus the frozen
	// `typeid`. A non-addressable source gets compiler-owned temporary storage.
	if from := base.erased_from; from != INVALID_TYPE && as_type == TYPE_ANY_VIEW {
		address := spill_iterable_at(e, expr, from)
		return emit_any_view_value(e, address, from)
	}
	// design.md: a `string` borrowed as a `string_view` — the same pointer and
	// byte length, with the owning word dropped. Nothing is retained: the view
	// borrows the string and cannot outlive it, which `src/borrow.odin` checks.
	if from := base.view_from; from != INVALID_TYPE && underlying_kind(e.c, as_type) == .String_View {
		value := emit_expr_at(e, expr, from)
		data := extract(e, STRING_TYPE, value, STRING_DATA)
		length := extract(e, STRING_TYPE, value, STRING_LEN)
		return emit_ptr_len(e, STRING_VIEW_TYPE, data, length)
	}
	// design.md "SIMD vectors": a scalar widened to every lane.
	if from := base.splat_from; from != INVALID_TYPE && type_is_simd(e.c, as_type) {
		value := emit_expr_at(e, expr, from)
		return emit_simd_splat(e, value, as_type)
	}
	if base.is_const && base.const_value.kind != .Invalid {
		emit_const_len_receiver(e, expr)
		return llvm_const(e, base.const_value, as_type)
	}

	switch v in expr {
	case ^Expr_Error:
		return "0"

	case ^Expr_Literal:
		return llvm_const(e, v.const_value, as_type)

	case ^Expr_Ident:
		if name, ok := e.param_values[v.symbol]; ok {
			return name // a default argument reading a parameter to its left
		}
		symbol := symbol_of(e.c, v.symbol)
		if symbol != nil && symbol.kind == .Proc {
			return symbol_name(e, v.symbol)
		}
		out := temp(e)
		address, ok := e.names[v.symbol]
		if !ok {
			backend_fail(e, "a resolved value has no storage")
			return "0"
		}
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, as_type), address)
		return out

	case ^Expr_Slice:
		if v.resolution.kind == .User_Operator {
			return emit_operator_call(e, v.resolution.symbol, v.bound)
		}
		return emit_builtin_slice(e, v, as_type)

	case ^Expr_Postfix:
		if v.op == .Or_Return {
			results := emit_producer_value(e, expr, as_type)
			return len(results) == 0 ? "0" : results[0]
		}
		address := emit_address_at(e, expr, as_type)
		out := load(e, llvm_type(e, as_type), address)
		return out

	case ^Expr_Selector, ^Expr_Index:
		// A read does not insert and panics for a missing key (design.md "Maps").
		if index, is_index := expr.(^Expr_Index); is_index && !index.map_inserts &&
		   index.operand != nil && type_is_map(e.c, expr_base(index.operand).type) {
			return emit_map_lookup(e, index)
		}
		// A user `operator([])`. A value overload produces the element; an `inout`
		// overload produces its address, which is then read through.
		if index, is_index := expr.(^Expr_Index); is_index && base.resolution.kind == .User_Operator {
			result := emit_operator_call(e, index.resolution.symbol, index.bound)
			if base.value_category != .Place {
				return result
			}
			out := load(e, llvm_type(e, as_type), result)
			return out
		}
		// `pkg.f` as a value is the procedure itself, not storage holding one.
		if symbol := symbol_of(e.c, base.resolution.symbol); symbol != nil && symbol.kind == .Proc {
			return symbol_name(e, base.resolution.symbol)
		}
		address := emit_address_at(e, expr, as_type)
		return load_place(e, as_type, address)

	case ^Expr_Unary:
		return emit_unary(e, v, as_type)

	case ^Expr_Binary:
		return emit_binary(e, v, as_type)

	case ^Expr_Cond:
		return emit_cond(e, v, as_type)

	case ^Expr_Call:
		result := emit_call(e, v, as_type)
		if base.value_category != .Place {
			return result
		}
		out := load(e, llvm_type(e, as_type), result)
		return out

	case ^Expr_Checked_Extract, ^Expr_Or_Else:
		return emit_producer_value(e, expr, as_type)[0]

	case ^Expr_Composite:
		if v.backing != INVALID_TYPE {
			return emit_slice_literal(e, v, as_type)
		}
		slot := emit_address_at(e, expr, as_type)
		out := load(e, llvm_type(e, as_type), slot)
		return out

	case ^Expr_Proc:
		// Every literal a body can reach is hoisted and named before any body is
		// emitted. A `null` here would assemble and link, and only fail as a call
		// through a null pointer at run time.
		return symbol_name(e, v.symbol)

	case ^Expr_Range:
		return emit_range_value(e, v, as_type)

	case ^Expr_Move:
		return emit_move(e, v)

	case ^Expr_Proc_Group, ^Expr_Operator,
	     ^Type_Pointer, ^Type_C_Pointer, ^Type_Slice, ^Type_Dynamic_Array,
	     ^Type_Array, ^Type_Map, ^Type_Distinct, ^Type_Dyn, ^Type_Type,
	     ^Type_Poly, ^Type_Proc, ^Type_Record, ^Type_Anon_Record, ^Type_Enum, ^Type_Interface:
	}
	// Same gate as `emit_stmt`: returning `0` here would compile silently and
	// produce the wrong answer.
	backend_fail(e, "an unresolved expression reached emission")
	return "0"
}

// The backing array of a slice literal is a hidden fixed-array owner in the
// surrounding lexical scope, so the slice stays valid until that scope exits
// (design.md "Slice literals"). The hidden root is filled, then viewed whole.
@(private = "file")
emit_slice_literal :: proc(e: ^Emitter, v: ^Expr_Composite, as_type: Type_Id) -> string {
	backing := v.backing
	info := type_of(e.c, backing)
	root := alloca(e, llvm_type(e, backing))

	for element, index in v.elements {
		slot := temp(e)
		fmt.sbprintfln(
			&e.b,
			"  %s = getelementptr inbounds %s, ptr %s, i64 0, i64 %d",
			slot, llvm_type(e, backing), root, index,
		)
		store(e, info.element, emit_expr(e, element.value), slot)
	}

	// "An ordinary frame owner in the surrounding lexical scope" is the whole
	// claim, and a managed element makes the difference visible: without this the
	// hidden array is filled and then abandoned, so `[]mut T{...}` would leak
	// every element a named `[N]T` of the same elements drops.
	register_scope_place(e, backing, root)
	return emit_slice_value(e, as_type, root, fmt.aprintf("%d", len(v.elements)))
}

@(private = "file")
emit_composite_into :: proc(e: ^Emitter, v: ^Expr_Composite, address: string, as_type: Type_Id) {
	// Start from the zero value so an omitted field is not left undefined.
	zero, ok := zero_const(e.c, as_type)
	if ok {
		store(e, as_type, llvm_const(e, zero, as_type), address)
	}
	info := underlying_info(e.c, as_type)
	if info == nil {
		return
	}
	if info.kind == .Dynamic_Array {
		emit_dynamic_literal_into(e, v, address, info.element, as_type)
		return
	}
	if info.kind == .Map {
		emit_map_literal_into(e, v, address, info.key, info.element, as_type)
		return
	}
	for element, index in v.elements {
		slot := index
		element_type := info.element
		if info.kind == .Struct {
			if len(v.field_indices) != len(v.elements) ||
			   v.field_indices[index] < 0 || v.field_indices[index] >= len(info.fields) {
				backend_fail(e, "a struct literal element has no resolved field index")
				return
			}
			slot = v.field_indices[index]
			element_type = symbol_of(e.c, info.fields[slot]).type
		}
		value := emit_expr(e, element.value)
		if index < len(v.element_clones) && v.element_clones[index] {
			value = emit_clone_value(e, element_type, value)
		}
		field_address := gep_field(e, llvm_type(e, as_type), address, slot)
		record_field_align(e, as_type, address, field_address, element_type)
		store(e, element_type, value, field_address)
	}
}

@(private = "file")
emit_unary :: proc(e: ^Emitter, v: ^Expr_Unary, as_type: Type_Id) -> string {
	if v.op == .Amp {
		return emit_address(e, v.operand)
	}
	if v.resolution.kind == .User_Operator {
		operands := [1]Expr{v.operand}
		return emit_operator_call(e, v.resolution.symbol, operands[:])
	}
	if type_is_simd(e.c, as_type) {
		return emit_simd_unary(e, v, as_type)
	}
	operand := emit_expr(e, v.operand)
	type := as_type
	llvm := llvm_type(e, type)
	out := temp(e)
	#partial switch v.op {
	case .Plus:
		return operand
	case .Minus:
		if type_is_float(e.c, type) {
			fmt.sbprintfln(&e.b, "  %s = fneg %s %s", out, llvm, operand)
		} else {
			fmt.sbprintfln(&e.b, "  %s = sub %s 0, %s", out, llvm, operand)
		}
	case .Tilde:
		fmt.sbprintfln(&e.b, "  %s = xor %s %s, -1", out, llvm, operand)
	case .Not:
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", out, operand)
	}
	return out
}

@(private = "file")
emit_binary :: proc(e: ^Emitter, v: ^Expr_Binary, as_type: Type_Id) -> string {
	if v.resolution.kind == .User_Operator {
		operands := [2]Expr{v.lhs, v.rhs}
		result := emit_operator_call(e, v.resolution.symbol, operands[:])
		if !v.negated {
			return result
		}
		// The `!=` fallback: `!(a == b)`.
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", out, result)
		return out
	}
	// design.md "SIMD vectors": lane-wise, including the comparison whose result
	// is a mask rather than a `bool`, so it never reaches `emit_compare`.
	if type_is_simd(e.c, expr_base(v.lhs).type) || type_is_simd(e.c, expr_base(v.rhs).type) {
		return emit_simd_binary(e, v)
	}
	#partial switch v.op {
	case .And_And, .Or_Or:
		return emit_short_circuit(e, v)
	case .In:
		return emit_map_membership(e, v)
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		operand_type := expr_base(v.lhs).type
		lhs := emit_expr(e, v.lhs)
		rhs := emit_expr(e, v.rhs)
		return emit_compare(e, v.op, operand_type, lhs, rhs)
	}
	if v.op == .Plus && type_is_utf8_text(e.c, expr_base(v.lhs).type) {
		return emit_text_concat(e, v)
	}
	lhs := emit_expr(e, v.lhs)
	rhs := emit_expr(e, v.rhs)
	return emit_binary_op(e, v.op, as_type, expr_base(v.rhs).type, lhs, rhs)
}

// Concatenation allocates from `mem.default_allocator()` and follows its
// failure policy (design.md "Arithmetic operators"). Both operands are already
// valid UTF-8, so the result needs no validation.
@(private = "file")
emit_text_concat :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	left_data, left_len := emit_text_parts(e, v.lhs)
	right_data, right_len := emit_text_parts(e, v.rhs)
	return emit_text_allocating_call(
		e, "loke_rt_v1_string_concat",
		fmt.aprintf(
			"ptr %s, i64 %s, ptr %s, i64 %s, ptr %s",
			left_data, left_len, right_data, right_len, emit_default_allocator(e),
		),
		fail_is_panic = true,
	)
}

// The LLVM instruction each arithmetic operator lowers to. An empty column is a
// combination that never arrives: integer `/` and `%` route through
// `emit_divrem` before this is consulted, and a float has no bitwise operators.
@(private = "file")
Arith_Mnemonic :: struct {
	integer, float: string,
}

@(private = "file")
arith_mnemonic :: proc(op: Token_Kind) -> Arith_Mnemonic {
	#partial switch op {
	case .Plus:  return {"add", "fadd"}
	case .Minus: return {"sub", "fsub"}
	case .Star:  return {"mul", "fmul"}
	case .Slash: return {"",    "fdiv"}
	case .Amp:   return {"and", ""}
	case .Pipe:  return {"or",  ""}
	case .Tilde: return {"xor", ""}
	}
	return {}
}

@(private)
emit_binary_op :: proc(e: ^Emitter, op: Token_Kind, type: Type_Id, rhs_type: Type_Id, lhs, rhs: string) -> string {
	llvm := llvm_type(e, type)
	if type_is_float(e.c, type) {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", out, arith_mnemonic(op).float, llvm, lhs, rhs)
		return out
	}

	signed := type_signed(e.c, type) || type_is_rune(e.c, type)
	#partial switch op {
	case .Slash, .Percent:
		return emit_divrem(e, op, type, signed, lhs, rhs)
	case .Shl, .Shr:
		return emit_shift(e, op, type, signed, rhs_type, lhs, rhs)
	case .Amp_Tilde:
		complement := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor %s %s, -1", complement, llvm, rhs)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = and %s %s, %s", out, llvm, lhs, complement)
		return out
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", out, arith_mnemonic(op).integer, llvm, lhs, rhs)
	return out
}

// Division and remainder need two guards. Zero takes the explicit trap seam;
// `MIN / -1` has the wrapping result design.md requires and must not reach LLVM
// `sdiv`/`srem`, where it would be poison.
@(private = "file")
emit_divrem :: proc(e: ^Emitter, op: Token_Kind, type: Type_Id, signed: bool, lhs, rhs: string) -> string {
	llvm := llvm_type(e, type)
	bits := type_bits(e.c, type)

	is_zero := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, 0", is_zero, llvm, rhs)
	panic_if(e, is_zero, "div.zero", "integer division by zero")

	if !signed {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", out, op == .Slash ? "udiv" : "urem", llvm, lhs, rhs)
		return out
	}

	minimum := bi_text(e.c, bi_neg(e.c, bi_pow2(e.c, bits - 1)))
	special_label := new_label(e, "div.special")
	normal_label := new_label(e, "div.normal")
	done_label := new_label(e, "div.done")

	is_min := temp(e)
	is_neg_one := temp(e)
	is_overflow := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", is_min, llvm, lhs, minimum)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, -1", is_neg_one, llvm, rhs)
	fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", is_overflow, is_min, is_neg_one)
	branch_if(e, is_overflow, special_label, normal_label)

	place_label(e, special_label)
	branch(e, done_label)

	place_label(e, normal_label)
	normal_value := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", normal_value, op == .Slash ? "sdiv" : "srem", llvm, lhs, rhs)
	branch(e, done_label)

	place_label(e, done_label)
	out := temp(e)
	special_value := op == .Slash ? minimum : "0"
	fmt.sbprintfln(
		&e.b,
		"  %s = phi %s [ %s, %%%s ], [ %s, %%%s ]",
		out, llvm, special_value, special_label, normal_value, normal_label,
	)
	return out
}

// design.md: a shift count at or beyond the operand's width is defined — zero,
// or the replicated sign bit for an arithmetic right shift. No out-of-range
// count reaches an LLVM shift instruction, where it would be poison.
@(private = "file")
emit_shift :: proc(e: ^Emitter, op: Token_Kind, type: Type_Id, signed: bool, count_type: Type_Id, lhs, rhs: string) -> string {
	llvm := llvm_type(e, type)
	bits := type_bits(e.c, type)
	count_llvm := llvm_type(e, count_type)
	count_bits := type_bits(e.c, count_type)

	// The comparison happens in the count's own width, before any truncation
	// could hide how large it was.
	oversized := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp uge %s %s, %d", oversized, count_llvm, rhs, bits)

	count := rhs
	if count_bits != bits {
		converted := temp(e)
		operation := count_bits > bits ? "trunc" : "zext"
		fmt.sbprintfln(&e.b, "  %s = %s %s %s to %s", converted, operation, count_llvm, rhs, llvm)
		count = converted
	}

	if op == .Shr && signed {
		// Clamping to width-1 is the limit of the repeated one-bit shift.
		clamped := temp(e)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s %d, %s %s", clamped, oversized, llvm, bits - 1, llvm, count)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = ashr %s %s, %s", out, llvm, lhs, clamped)
		return out
	}

	safe := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s 0, %s %s", safe, oversized, llvm, llvm, count)
	raw := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", raw, op == .Shl ? "shl" : "lshr", llvm, lhs, safe)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s 0, %s %s", out, oversized, llvm, llvm, raw)
	return out
}

// The LLVM predicate each comparison lowers to, per operand class. The float
// column is ordered, so a NaN operand compares false — except `!=`, which is
// `une` and so is true whenever the operands are unordered.
Compare_Predicate :: struct {
	signed, unsigned, float: string,
}

compare_predicate :: proc(op: Token_Kind) -> Compare_Predicate {
	#partial switch op {
	case .Eq_Eq:  return {"eq",  "eq",  "oeq"}
	case .Not_Eq: return {"ne",  "ne",  "une"}
	case .Lt:     return {"slt", "ult", "olt"}
	case .Lt_Eq:  return {"sle", "ule", "ole"}
	case .Gt:     return {"sgt", "ugt", "ogt"}
	case .Gt_Eq:  return {"sge", "uge", "oge"}
	}
	return {}
}

emit_compare :: proc(e: ^Emitter, op: Token_Kind, type: Type_Id, lhs, rhs: string) -> string {
	// `string` and `string_view` values are comparable and ordered, lexically
	// byte-wise (design.md). One runtime call answers all six operators.
	if type_is_utf8_text(e.c, type) {
		storage := llvm_type(e, type_underlying(e.c, type))
		left_data := extract(e, storage, lhs, STRING_DATA)
		left_len := extract(e, storage, lhs, STRING_LEN)
		right_data := extract(e, storage, rhs, STRING_DATA)
		right_len := extract(e, storage, rhs, STRING_LEN)
		order := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_bytes_compare(ptr %s, i64 %s, ptr %s, i64 %s)",
			order, left_data, left_len, right_data, right_len,
		)
		// The runtime hands back a signed i32 ordering, so this is the signed column.
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp %s i32 %s, 0", out, compare_predicate(op).signed, order)
		return out
	}
	if type_is_aggregate(e.c, type) || type_is_union(e.c, type) || type_is_erased_view(e.c, type) {
		equal := emit_equal(e, type, lhs, rhs)
		if op == .Eq_Eq {
			return equal
		}
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", out, equal)
		return out
	}
	llvm := llvm_type(e, type)
	out := temp(e)
	if type_is_float(e.c, type) {
		fmt.sbprintfln(&e.b, "  %s = fcmp %s %s %s, %s", out, compare_predicate(op).float, llvm, lhs, rhs)
		return out
	}
	predicate := compare_predicate(op)
	signed := type_signed(e.c, type) || type_is_rune(e.c, type)
	name := signed ? predicate.signed : predicate.unsigned
	fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", out, name, llvm, lhs, rhs)
	return out
}

// LLVM has no aggregate `icmp`, so structural equality is generated: each
// operand is evaluated once, and the leaf comparisons are combined.
//
// ponytail: one flat `and` chain rather than short-circuiting blocks. Every leaf
// is a pure `extractvalue` plus `icmp`/`fcmp`, so skipping them is unobservable,
// and a chain of N blocks would be worse IR than N ands. Revisit if a measured
// comparison of a very large array shows up.
@(private)
emit_equal :: proc(e: ^Emitter, type: Type_Id, lhs, rhs: string) -> string {
	under := type_underlying(e.c, type)
	info := type_of(e.c, under)
	if info == nil {
		return "true"
	}
	#partial switch info.kind {
	case .Union:
		return emit_union_equal(e, under, lhs, rhs)
	case .Dyn, .Any_View:
		// design.md: dynamic interface values are comparable only with `nil`, and
		// nil is the zero view. Comparing the second word — the witness, or the
		// `typeid` — is what distinguishes a live view from the nil one.
		llvm := llvm_type(e, under)
		left := extract(e, llvm, lhs, 1)
		right := extract(e, llvm, rhs, 1)
		out := temp(e)
		operand := info.kind == .Dyn ? "ptr" : "i64"
		fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", out, operand, left, right)
		return out
	case .Slice:
		// The checker admits only `slice == nil`, and a nil slice is the one with a
		// null data pointer, so the first word decides it.
		llvm := llvm_type(e, under)
		left := extract(e, llvm, lhs, SLICE_DATA)
		right := extract(e, llvm, rhs, SLICE_DATA)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, %s", out, left, right)
		return out
	case .Array:
		result := "true"
		for index in 0 ..< int(info.count) {
			left := extract(e, llvm_type(e, under), lhs, index)
			right := extract(e, llvm_type(e, under), rhs, index)
			leaf := emit_equal(e, info.element, left, right)
			result = combine_and(e, result, leaf)
		}
		return result
	case .Struct:
		// A combined `@(packed, align=N)` record's LLVM members are byte arrays, so
		// `extractvalue` yields `[k x i8]` where the field's own type is wanted.
		// Reading each field through its address instead is the same GEP an ordinary
		// field access already uses.
		if record_uses_byte_members(e, under, info) {
			return emit_byte_member_struct_equal(e, under, info, lhs, rhs)
		}
		result := "true"
		for field, index in info.fields {
			symbol := symbol_of(e.c, field)
			left := extract(e, llvm_type(e, under), lhs, index)
			right := extract(e, llvm_type(e, under), rhs, index)
			leaf := emit_equal(e, symbol.type, left, right)
			result = combine_and(e, result, leaf)
		}
		return result
	}
	return emit_compare(e, .Eq_Eq, type, lhs, rhs)
}

// An erased view is an aggregate the ordinary struct path cannot compare, so it
// takes the same route a union does.
@(private = "file")
type_is_erased_view :: proc(c: ^Compiler, type: Type_Id) -> bool {
	#partial switch underlying_kind(c, type) {
	case .Dyn, .Any_View, .Slice:
		return true
	}
	return false
}

// Two unions are equal when their tags match and the active variant's payload
// matches (a payloadless variant is settled by the tag alone).
//
// Only the active variant's comparison runs. Computing every variant's and
// selecting afterward would be smaller IR, but a payload whose equality is a
// runtime call over a pointer and length — `string`, `string_view`, or any
// aggregate holding one — would then read arbitrary memory from another
// variant's bytes.
@(private = "file")
emit_union_equal :: proc(e: ^Emitter, union_type: Type_Id, lhs, rhs: string) -> string {
	info := type_of(e.c, union_type)
	shape := union_layout(e.c, union_type)
	tag_llvm := fmt.aprintf("i%d", shape.tag_bytes * 8)

	left_tag := emit_union_tag(e, union_type, lhs)
	right_tag := emit_union_tag(e, union_type, rhs)
	same_tag := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", same_tag, tag_llvm, left_tag, right_tag)

	left_slot := emit_union_spill(e, union_type, lhs)
	right_slot := emit_union_spill(e, union_type, rhs)

	// Differing tags settle it, and so does a matching payloadless variant. A
	// payload comparison below overrides this answer when its tag is the active
	// one.
	answer := alloca(e, "i1")
	fmt.sbprintfln(&e.b, "  store i1 %s, ptr %s", same_tag, answer)

	done, payloads := new_label(e, "unioneq.done"), new_label(e, "unioneq.payloads")
	branch_if(e, same_tag, payloads, done)
	place_label(e, payloads)

	for variant, index in info.variants {
		if variant == TYPE_VOID {
			continue
		}
		active := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %d", active, tag_llvm, left_tag, index)
		hit, next := new_label(e, "unioneq.hit"), new_label(e, "unioneq.next")
		branch_if(e, active, hit, next)

		place_label(e, hit)
		left := emit_union_payload(e, union_type, variant, left_slot)
		right := emit_union_payload(e, union_type, variant, right_slot)
		// The comparison may open blocks of its own, so the store belongs
		// wherever it left off rather than in `hit`.
		equal := emit_equal(e, variant, left, right)
		fmt.sbprintfln(&e.b, "  store i1 %s, ptr %s", equal, answer)
		branch(e, done)

		place_label(e, next)
	}
	place_label(e, done)
	return load(e, "i1", answer)
}

// Whether this record's LLVM members are byte arrays rather than the fields'
// own types — the combined `@(packed, align=N)` body from `struct_body`: tight
// packing needs a packed LLVM body, a raised alignment can't be spelled on one,
// and byte members satisfy both at once.
@(private = "file")
record_uses_byte_members :: proc(e: ^Emitter, type: Type_Id, info: ^Type_Info) -> bool {
	if !info.packed || len(info.fields) == 0 {
		return false
	}
	type_size(e.c, type)
	current := type_of(e.c, type)
	return current != nil && current.align > record_natural_align(e.c, current)
}

// Field-wise equality read through addresses. The value is spilled once and
// each field is loaded at its own type from the GEP the byte member occupies,
// so the comparison is the ordinary one and only the way the operands are
// reached differs.
@(private = "file")
emit_byte_member_struct_equal :: proc(e: ^Emitter, type: Type_Id, info: ^Type_Info, lhs, rhs: string) -> string {
	llvm := llvm_type(e, type)
	left_slot := alloca(e, llvm)
	right_slot := temp(e)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm, lhs, left_slot)
	alloca_named(e, right_slot, llvm)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm, rhs, right_slot)

	result := "true"
	for field, index in info.fields {
		symbol := symbol_of(e.c, field)
		field_llvm := llvm_type(e, symbol.type)
		left_ptr := gep_field(e, llvm, left_slot, index)
		right_ptr := gep_field(e, llvm, right_slot, index)
		left, right := temp(e), temp(e)
		// A packed field guarantees no more than byte alignment.
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s, align 1", left, field_llvm, left_ptr)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s, align 1", right, field_llvm, right_ptr)
		result = combine_and(e, result, emit_equal(e, symbol.type, left, right))
	}
	return result
}

@(private = "file")
combine_and :: proc(e: ^Emitter, a, b: string) -> string {
	if a == "true" {
		return b
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", out, a, b)
	return out
}

@(private = "file")
emit_short_circuit :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	lhs := emit_expr(e, v.lhs)
	rhs_label := new_label(e, "sc.rhs")
	done_label := new_label(e, "sc.done")
	entry_label := new_label(e, "sc.entry")

	// The incoming edge needs a name of its own for the phi, and the left
	// operand may itself have created blocks.
	branch(e, entry_label)
	place_label(e, entry_label)
	if v.op == .And_And {
		branch_if(e, lhs, rhs_label, done_label)
	} else {
		branch_if(e, lhs, done_label, rhs_label)
	}

	place_label(e, rhs_label)
	rhs := emit_expr(e, v.rhs)
	rhs_exit := new_label(e, "sc.rhs.exit")
	branch(e, rhs_exit)
	place_label(e, rhs_exit)
	branch(e, done_label)

	place_label(e, done_label)
	out := temp(e)
	short := v.op == .And_And ? "false" : "true"
	fmt.sbprintfln(
		&e.b,
		"  %s = phi i1 [ %s, %%%s ], [ %s, %%%s ]",
		out, short, entry_label, rhs, rhs_exit,
	)
	return out
}

@(private = "file")
emit_cond :: proc(e: ^Emitter, v: ^Expr_Cond, as_type: Type_Id) -> string {
	cond := emit_expr(e, v.cond)
	then_label := new_label(e, "cond.then")
	else_label := new_label(e, "cond.else")
	done_label := new_label(e, "cond.done")
	branch_if(e, cond, then_label, else_label)

	place_label(e, then_label)
	then_value := emit_expr(e, v.then)
	then_exit := new_label(e, "cond.then.exit")
	branch(e, then_exit)
	place_label(e, then_exit)
	branch(e, done_label)

	place_label(e, else_label)
	else_value := emit_expr(e, v.otherwise)
	else_exit := new_label(e, "cond.else.exit")
	branch(e, else_exit)
	place_label(e, else_exit)
	branch(e, done_label)

	place_label(e, done_label)
	out := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = phi %s [ %s, %%%s ], [ %s, %%%s ]",
		out, llvm_type(e, as_type), then_value, then_exit, else_value, else_exit,
	)
	return out
}

@(private)
emit_ptr_len :: proc(e: ^Emitter, storage, data, length: string) -> string {
	first := insert(e, storage, "undef", "ptr", data, SLICE_DATA)
	out := insert(e, storage, first, "i64", length, SLICE_LEN)
	return out
}

// `{ data, len }` for a slice type.
@(private)
emit_slice_value :: proc(e: ^Emitter, slice_type: Type_Id, data, length: string) -> string {
	return emit_ptr_len(e, llvm_type(e, slice_type), data, length)
}

// The data pointer and byte length of a `string` or `string_view` value, which
// is all every text operation needs: the two carriers differ only in whether a
// third word owns the storage.
@(private)
emit_text_parts :: proc(e: ^Emitter, operand: Expr) -> (data: string, length: string) {
	type := type_underlying(e.c, expr_base(operand).type)
	value := emit_expr(e, operand)
	if type_kind(e.c, type) == .CString_View {
		// design.md "C string views": terminated, not measured, so its length is a
		// scan rather than a field.
		length = temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i64 @loke_rt_v1_cstring_len(ptr %s)", length, value)
		return value, length
	}
	storage := llvm_type(e, type)
	data, length = temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, value, STRING_DATA)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, storage, value, STRING_LEN)
	return data, length
}

@(private)
emit_text_operation :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> []string {
	out := make([]string, 1)
	out[0] = "0"
	switch v.operation.(Call_Text).op {
	case .None:
		backend_fail(e, "a text call has no operation")

	case .Byte_Len:
		// `len(text)` is shorthand for `text.byte_len()` so that it stays a
		// constant-time operation (design.md).
		_, length := emit_text_parts(e, v.bound[0])
		out[0] = length

	case .Rune_Count:
		data, length := emit_text_parts(e, v.bound[0])
		out[0] = temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i64 @loke_rt_v1_rune_count(ptr %s, i64 %s)", out[0], data, length)

	case .Bytes:
		// A read-only `[]u8` over the same storage: the borrow costs nothing and
		// cannot be widened to `[]mut u8`.
		data, length := emit_text_parts(e, v.bound[0])
		out[0] = emit_slice_value(e, as_type, data, length)

	case .Runes:
		// design.md "String iteration": the rune traversal is the string's own, so
		// this is the same borrow `bytes()` takes, viewed as text rather than bytes.
		data, length := emit_text_parts(e, v.bound[0])
		out[0] = emit_ptr_len(e, STRING_VIEW_TYPE, data, length)

	case .Rune_Offsets:
		// The view holds the borrowed bytes and nothing else; the cursor belongs to
		// the iterator its `iter` makes.
		data, length := emit_text_parts(e, v.bound[0])
		view := emit_ptr_len(e, STRING_VIEW_TYPE, data, length)
		out[0] = insert(e, llvm_type(e, as_type), "undef", STRING_VIEW_TYPE, view, VIEW_SOURCE)

	case .Copy:
		data, length := emit_text_parts(e, v.bound[0])
		out[0] = emit_text_allocating_call(
			e, "loke_rt_v1_string_clone",
			fmt.aprintf("ptr %s, i64 %s, ptr %s", data, length, emit_default_allocator(e)),
			fail_is_panic = true,
		)

	case .To_C_View:
		// ponytail: every `string` buffer is allocated with room for a terminator
		// and a literal already carries one, so the "add a terminator only when
		// necessary" case of design.md's rule never arises and no call-scoped
		// temporary is created. A representation that could hand out an
		// unterminated `string` would need the allocating branch back.
		data, _ := emit_text_parts(e, v.bound[0])
		out[0] = data

	case .To_Runes:
		// An implicit allocation: design.md's "Allocation failure" gives it nowhere
		// to report, so failure follows the provider's policy. The helper releases
		// its partial buffer first, so the panic path leaks nothing.
		data, length := emit_text_parts(e, v.bound[0])
		ops := container_ops_global(e, as_type)
		slot := alloca(e, CONTAINER_TYPE)
		provider := emit_default_allocator(e)
		ok := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_string_to_runes(ptr %s, ptr %s, ptr %s, i64 %s, ptr %s)",
			ok, slot, ops, data, length, provider,
		)
		failed := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, ok)
		fail, done := new_label(e, "runes.failed"), new_label(e, "ok")
		branch_if(e, failed, fail, done)
		place_label(e, fail)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
		fmt.sbprintln(&e.b, "  unreachable")
		e.terminated = true
		place_label(e, done)
		value := load(e, CONTAINER_TYPE, slot)
		out[0] = value

	case .From_Runes:
		slice := emit_expr(e, v.bound[0])
		storage := llvm_type(e, expr_base(v.bound[0]).type)
		data := extract(e, storage, slice, SLICE_DATA)
		count := extract(e, storage, slice, SLICE_LEN)
		return emit_text_optional_ok(
			e, as_type, "loke_rt_v1_string_from_runes",
			fmt.aprintf("ptr %s, i64 %s, ptr %s", data, count, emit_default_allocator(e)),
		)
	}
	return out
}

// A runtime call that fills a `string` out-parameter and answers 1 on success.
// The out-pointer form keeps the ABI to pointers and integers, so the C and
// LLVM sides cannot disagree about how a 24-byte aggregate is returned.
@(private = "file")
emit_text_call_slot :: proc(e: ^Emitter, callee: string, arguments: string) -> (slot: string, ok: string) {
	slot = temp(e)
	alloca_named(e, slot, STRING_TYPE)
	ok = temp(e)
	fmt.sbprintfln(&e.b, "  %s = call i32 @%s(ptr %s, %s)", ok, callee, slot, arguments)
	return slot, ok
}

// design.md "Allocation failure": an implicit allocation — a clone, a
// concatenation — has nowhere to return an error, so failure follows the
// allocator's own policy.
@(private = "file")
emit_text_allocating_call :: proc(e: ^Emitter, callee, arguments: string, fail_is_panic: bool) -> string {
	slot, ok := emit_text_call_slot(e, callee, arguments)
	if fail_is_panic {
		failed := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, ok)
		fail, done := new_label(e, "text.failed"), new_label(e, "ok")
		branch_if(e, failed, fail, done)
		place_label(e, fail)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", emit_default_allocator(e))
		fmt.sbprintln(&e.b, "  unreachable")
		e.terminated = true
		place_label(e, done)
	}
	out := load(e, STRING_TYPE, slot)
	return out
}

// design.md "string type conversions": the value is the zero value on failure,
// which the runtime has already published into the slot.
@(private = "file")
emit_text_optional_ok :: proc(e: ^Emitter, option: Type_Id, callee, arguments: string) -> []string {
	slot, ok := emit_text_call_slot(e, callee, arguments)
	value, valid := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, STRING_TYPE, slot)
	fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", valid, ok)
	out := make([]string, 1)
	out[0] = emit_option_value(e, option, valid, value)
	return out
}

// `strings.allocate_string(text, allocator)`: like `.copy()`, but into storage
// from the caller's allocator, reporting failure instead of following that
// allocator's policy. The `string_view` bytes are already valid UTF-8, so
// `loke_rt_v1_string_clone` copies without re-validating and records the
// allocator in the string header so release returns the block to the same
// provider.
@(private)
emit_strings_allocate :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> []string {
	data, length := emit_text_parts(e, v.bound[0])
	allocator := emit_expr(e, v.bound[1])
	slot, ok := emit_text_call_slot(
		e, "loke_rt_v1_string_clone", fmt.aprintf("ptr %s, i64 %s, ptr %s", data, length, allocator),
	)
	copied := load(e, STRING_TYPE, slot)
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, ok)
	out := make([]string, 1)
	out[0] = emit_alloc_result(e, as_type, failed, copied)
	return out
}

// design.md "string type conversions": each named constructor validates and
// returns Option(T), with .none for invalid input.
@(private)
emit_text_conversion :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> []string {
	switch v.operation.(Call_Text_Conversion).op {
	case .None:
		break

	case .String_From_Bytes:
		data, length := emit_byte_slice_parts(e, v.bound[0])
		return emit_text_optional_ok(
			e, as_type, "loke_rt_v1_string_from_bytes",
			fmt.aprintf("ptr %s, i64 %s, ptr %s", data, length, emit_default_allocator(e)),
		)

	case .View_From_Bytes:
		// This conversion validates and borrows (design.md "From []u8 to X"). No
		// allocation and no copy — the view points into the slice's own root, and `src/borrow.odin`
		// is what keeps it from outliving that root.
		data, length := emit_byte_slice_parts(e, v.bound[0])
		valid, ok := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i32 @loke_rt_v1_utf8_valid(ptr %s, i64 %s)", valid, data, length)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", ok, valid)
		kept_data, kept_len := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, ptr %s, ptr null", kept_data, ok, data)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 %s, i64 0", kept_len, ok, length)
		view := emit_ptr_len(e, STRING_VIEW_TYPE, kept_data, kept_len)
		out := make([]string, 1)
		out[0] = emit_option_value(e, as_type, ok, view)
		return out

	case .String_From_C_View:
		// Converting a C string view to `string` scans for the terminator,
		// validates UTF-8, and copies into owned storage (design.md "C string views").
		pointer := emit_expr(e, v.bound[0])
		length := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i64 @loke_rt_v1_cstring_len(ptr %s)", length, pointer)
		return emit_text_optional_ok(
			e, as_type, "loke_rt_v1_string_from_bytes",
			fmt.aprintf("ptr %s, i64 %s, ptr %s", pointer, length, emit_default_allocator(e)),
		)
	}
	backend_fail(e, "an unclassified text conversion reached emission")
	out := make([]string, 1)
	out[0] = "zeroinitializer"
	return out
}

@(private = "file")
emit_byte_slice_parts :: proc(e: ^Emitter, operand: Expr) -> (data: string, length: string) {
	storage := llvm_type(e, expr_base(operand).type)
	value := emit_expr(e, operand)
	data, length = temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, value, SLICE_DATA)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, storage, value, SLICE_LEN)
	return data, length
}

// A C pointer carries neither a length nor a read-only capability, and its
// lifetime is no longer checked after conversion (design.md "unsafe.raw_data
// procedure") — so each of these is just an address extraction, except
// `unsafe.transmute(T, value)`: the same bits, read as a `T`. The checker has
// already settled equal size and a trivial lifecycle on both sides, so the only
// question left is which LLVM spelling reinterprets these two representations —
// a register-level cast where one exists, and a stack round trip otherwise,
// which every optimization level above `none` folds away.
@(private)
emit_transmute :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	source := expr_base(v.bound[0]).type
	value := emit_expr(e, v.bound[0])
	// A `bool` is `i1` in the backend and one byte of storage, so it is the one
	// type whose register width is not the width its size promises. Widening to
	// `i8` at the edges keeps every other case a plain same-width operation, and
	// keeps the aggregate path storing whole bytes.
	from := llvm_type(e, source)
	if underlying_kind(e.c, source) == .Bool {
		widened := temp(e)
		fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i8", widened, value)
		value, from = widened, "i8"
	}
	to_bool := underlying_kind(e.c, as_type) == .Bool
	to := to_bool ? "i8" : llvm_type(e, as_type)
	result := reinterpret_bits(e, source, as_type, from, to, value)
	if to_bool {
		// Bit 0 is the `bool`, and producing a pattern that is one is the caller's
		// obligation — the checker has already rejected the constant case it can
		// see, and there is nothing to check at run time.
		narrowed := temp(e)
		fmt.sbprintfln(&e.b, "  %s = trunc i8 %s to i1", narrowed, result)
		return narrowed
	}
	return result
}

@(private = "file")
reinterpret_bits :: proc(e: ^Emitter, source, target: Type_Id, from, to, value: string) -> string {
	if from == to {
		return value
	}
	source_ptr := pointer_shaped(e.c, source)
	target_ptr := pointer_shaped(e.c, target)
	out := temp(e)
	switch {
	case source_ptr && target_ptr:
		return value // one opaque `ptr` under two Loke spellings
	case source_ptr:
		fmt.sbprintfln(&e.b, "  %s = ptrtoint %s %s to %s", out, from, value, to)
	case target_ptr:
		fmt.sbprintfln(&e.b, "  %s = inttoptr %s %s to %s", out, from, value, to)
	case bitcastable(e.c, source) && bitcastable(e.c, target):
		fmt.sbprintfln(&e.b, "  %s = bitcast %s %s to %s", out, from, value, to)
	case:
		// An aggregate on either side. `bitcast` does not accept one, so the bits
		// travel through equally sized storage — the pointer cast design.md names
		// as the operation this is akin to, written out. The slot takes whichever
		// type is more strictly aligned, since both are the same size and each
		// access wants its own natural alignment satisfied.
		slot := alloca(e, type_align(e.c, target) > type_align(e.c, source) ? to : from)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", from, value, slot)
		return load(e, to, slot)
	}
	return out
}

@(private = "file")
pointer_shaped :: proc(c: ^Compiler, type: Type_Id) -> bool {
	#partial switch underlying_kind(c, type) {
	case .Raw_Pointer, .C_Pointer, .Proc:
		return true
	}
	return false
}

// Which types LLVM's `bitcast` accepts: first-class, non-aggregate, and not a
// pointer (those have their own two instructions). A `bool` has already been
// widened to `i8` by the time this is asked, so its `i1` register width never
// reaches the instruction.
@(private = "file")
bitcastable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	#partial switch underlying_kind(c, type) {
	case .Bool, .Int, .Float, .Rune, .Enum, .Simd:
		return true
	}
	return false
}

// `unsafe.string_view`, which still validates since the type it produces
// promises valid UTF-8.
@(private)
emit_unsafe_builtin :: proc(e: ^Emitter, v: ^Expr_Call, kind: Builtin_Kind, as_type: Type_Id) -> []string {
	out := make([]string, 1)
	out[0] = "null"
	operand_kind := underlying_kind(e.c, expr_base(v.bound[0]).type)
	#partial switch kind {
	case .Unsafe_Raw_Data:
		#partial switch operand_kind {
		case .Slice:
			data, _ := emit_byte_slice_parts(e, v.bound[0])
			out[0] = data
		case .String, .String_View:
			data, _ := emit_text_parts(e, v.bound[0])
			out[0] = data
		case .Dynamic_Array:
			// The *current* allocation's first element. Nothing keeps it current.
			value, data := emit_expr(e, v.bound[0]), temp(e)
			fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, CONTAINER_TYPE, value, CONTAINER_STORAGE)
			out[0] = data
		case:
			// A pointer to a fixed array, or a `cstring_view`: the value is already
			// the address of the first element.
			out[0] = emit_expr(e, v.bound[0])
		}

	case .Unsafe_C_String_View:
		out[0] = emit_expr(e, v.bound[0])

	case .Unsafe_String_View:
		data := emit_expr(e, v.bound[0])
		length := widen_to_i64(e, emit_expr(e, v.bound[1]), expr_base(v.bound[1]).type)
		valid, ok := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i32 @loke_rt_v1_utf8_valid(ptr %s, i64 %s)", valid, data, length)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", ok, valid)
		kept_data, kept_len := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, ptr %s, ptr null", kept_data, ok, data)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 %s, i64 0", kept_len, ok, length)
		view := emit_ptr_len(e, STRING_VIEW_TYPE, kept_data, kept_len)
		single := make([]string, 1)
		single[0] = emit_option_value(e, as_type, ok, view)
		return single
	}
	return out
}

// design.md "Standard customization procedures": a fixed array's and a vector's
// length come from the type, so the call folds to a constant — but it is still
// an ordinary method call, so its receiver is evaluated exactly once. Only a
// bare name has nothing to run.
@(private = "file")
emit_const_len_receiver :: proc(e: ^Emitter, expr: Expr) {
	call, is_call := expr.(^Expr_Call)
	if !is_call || len(call.bound) == 0 || call.bound[0] == nil {
		return
	}
	if chosen := symbol_of(e.c, call.resolution.chosen_overload); chosen == nil || chosen.synth != .Standard_Len {
		return
	}
	receiver := call.bound[0]
	if _, is_name := receiver.(^Expr_Ident); is_name {
		return
	}
	emit_discarded_temporary(e, receiver, emit_expr(e, receiver))
}
