// Constants, places, expressions, and text operations.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

// -------------------------------------------------------------- constants --

// design.md "Zero values": a union constant is the payload's little-endian byte
// image, split across the integer head and byte-array tail, plus the tag.
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
	// A zero-sized payload contributes no bits.
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
is_zero_constant :: proc(value: string) -> bool {
	switch value {
	case "0", "false", "null", "zeroinitializer", "0xH0000", "0x0000000000000000":
		return true
	}
	return false
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
	// An invalid constant inside `@(initialized)` capacity is not a value, but
	// still has the inert all-zero representation.
	if value.kind == .Invalid {
		return "zeroinitializer"
	}
	#partial switch info.kind {
	case .Typeid:
		// `freeze_typeids` has numbered every requested type before emission.
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
		// A string literal's zero-terminated bytes have static lifetime.
		return value.kind == .String ? text_literal_global(e, value.text) : "null"
	case .String, .String_View:
		return text_constant(e, value, info.kind == .String)
	case .Allocator_Error:
		// Nil is success, and success is zero.
		return value.kind == .Nil ? "0" : bi_text(e.c, value.integer)
	case .Union:
		return union_constant(e, value, under, info)
	case .Array, .Simd:
		// A vector constant is `<...>`; a `Simd(bool, N)` lane is `i8` in memory.
		vector := info.kind == .Simd
		lane := simd_lane_llvm_type(e, info)
		mask := vector && type_kind(e.c, type_underlying(e.c, info.element)) == .Bool
		b := strings.builder_make()
		strings.write_string(&b, vector ? "<" : "[")
		zero := true
		for index in 0 ..< int(info.count) {
			if index > 0 {
				strings.write_string(&b, ",")
			}
			element := Const_Value{}
			if value.aggregate != nil && index < len(value.aggregate.elements) {
				element = value.aggregate.elements[index]
			}
			value := llvm_const(e, element, info.element)
			if mask {
				value = value == "true" ? "1" : "0"
			}
			fmt.sbprintf(&b, " %s %s", lane, value)
			zero &&= is_zero_constant(value)
		}
		// A zero value stays short, and `store` writes a large one with memset.
		if zero {
			return "zeroinitializer"
		}
		strings.write_string(&b, vector ? " >" : " ]")
		return strings.to_string(b)
	case .Struct, .Any_View, .Dyn, .Slice, .Dynamic_Array, .Map:
		if value.kind == .Nil {
			return "zeroinitializer"
		}
		// A slice constant points at storage only the module can hold.
		if info.kind == .Slice && value.aggregate != nil {
			return slice_literal_constant(e, value, info)
		}
		packed := info.kind == .Struct && info.packed
		over_aligned := info.kind == .Struct && info.align > record_natural_align(e.c, info)
		byte_array := packed && over_aligned
		b := strings.builder_make()
		strings.write_string(&b, byte_array ? "{" : (packed ? "<{" : "{"))
		zero := !byte_array
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
				strings.write_string(&b, " ")
				write_field_bytes(e, &b, element, symbol.type)
			} else {
				field_value := llvm_const(e, element, symbol.type)
				fmt.sbprintf(&b, " %s %s", llvm_type(e, symbol.type), field_value)
				zero &&= is_zero_constant(field_value)
			}
		}
		if zero {
			return "zeroinitializer"
		}
		if over_aligned {
			if len(info.fields) > 0 {
				strings.write_string(&b, ",")
			}
			fmt.sbprintf(&b, " [0 x i%d] zeroinitializer", info.align * 8)
		}
		strings.write_string(&b, byte_array ? " }" : (packed ? " }>" : " }"))
		return strings.to_string(b)
	}
	return "0"
}

// One field of a combined `@(packed, align=N)` struct, whose LLVM members are
// byte arrays: the field's complete little-endian image, padding included.
@(private = "file")
write_field_bytes :: proc(e: ^Emitter, b: ^strings.Builder, value: Const_Value, type: Type_Id) {
	bytes := make([]u8, int(type_size(e.c, type)), context.temp_allocator)
	if !write_const_bytes(e, bytes, value, type) {
		backend_fail(e, "a combined packed/aligned constant has a value that cannot be represented as bytes")
		fmt.sbprintf(b, "[%d x i8] zeroinitializer", len(bytes))
		return
	}
	write_byte_array_constant(b, bytes)
}

// Missing elements and nil values are all-zero, which `out` already is.
@(private = "file")
write_const_bytes :: proc(e: ^Emitter, out: []u8, value: Const_Value, type: Type_Id) -> bool {
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
		// Their only byte-serializable value is nil, handled above.
		return false
	}
	return false
}

// Every float constant is spelled as its bit pattern, since LLVM's decimal
// syntax only round-trips some values exactly.
llvm_float :: proc(pattern: u64, bits: u16) -> string {
	if bits == 16 {
		return fmt.aprintf("0xH%04X", u16(pattern))
	}
	if bits == 32 {
		// LLVM writes a `float` constant as the `double` pattern of the same value.
		// Widening the bits, not the value, keeps a signalling NaN's payload.
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
		// Zero or a subnormal: the hardware conversion is exact here.
		return transmute(u64)f64(transmute(f32)pattern)
	}
	return sign | (u64(exponent) - 127 + 1023) << 52 | mantissa
}

// ------------------------------------------------------------------ places --

// A load from a written place, which may be under-aligned through a packed
// field. `load` stays right for compiler-owned slots.
@(private)
load_place :: proc(e: ^Emitter, type: Type_Id, address: string) -> string {
	if is_large_value(e, type) {
		snapshot := temporary_slot(e, type)
		copy_bytes(e, snapshot, address, type_size(e.c, type))
		return snapshot
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s%s", out, llvm_type(e, type), address, align_suffix(e, address, type))
	return out
}

// clang crashes in instruction selection on a first-class value with 65536 or
// more scalars in it, so a value larger than this never becomes one. It is the
// address of storage nothing else writes, and crosses calls by pointer.
LARGE_VALUE_BYTES :: 4096

@(private)
is_large_value :: proc(e: ^Emitter, type: Type_Id) -> bool {
	return type != INVALID_TYPE && type_size(e.c, type) > LARGE_VALUE_BYTES
}

// Storage for one value of `type` within the current full expression. A large
// one is shared with other full expressions, since each would otherwise keep its
// whole size in the frame for the entire function.
@(private)
temporary_slot :: proc(e: ^Emitter, type: Type_Id) -> string {
	llvm := llvm_type(e, type)
	if !is_large_value(e, type) {
		return alloca(e, llvm)
	}
	slot := Large_Slot{type = llvm}
	for free, index in e.large_free {
		if free.type == llvm {
			slot = free
			unordered_remove(&e.large_free, index)
			break
		}
	}
	if slot.name == "" {
		slot.name = alloca(e, llvm)
	}
	append(&e.large_taken, slot)
	return slot.name
}

// The value in storage only this value's producer can write, which a large
// value can go on naming instead of copying.
@(private)
load_temporary :: proc(e: ^Emitter, type: Type_Id, slot: string) -> string {
	return is_large_value(e, type) ? slot : load_place(e, type, slot)
}

@(private)
copy_bytes :: proc(e: ^Emitter, to, from: string, size: u64) {
	fmt.sbprintfln(&e.b, "  call void @llvm.memcpy.p0.p0.i64(ptr %s, ptr %s, i64 %d, i1 false)", to, from, size)
}

@(private)
store :: proc(e: ^Emitter, type: Type_Id, value, address: string) {
	if address == "" || value == "" {
		return
	}
	// A large constant is written with memset or copied from a module constant.
	if is_large_value(e, type) {
		size := type_size(e.c, type)
		if value == "zeroinitializer" {
			fmt.sbprintfln(&e.b, "  call void @llvm.memset.p0.i64(ptr %s, i8 0, i64 %d, i1 false)", address, size)
			return
		}
		from := value
		if value[0] != '%' {
			from = fmt.aprintf("@.aggregate.%d", len(e.globals))
			append(&e.globals, fmt.aprintf("%s = private unnamed_addr constant %s %s\n", from, llvm_type(e, type), value))
		}
		copy_bytes(e, address, from, size)
		return
	}
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s%s", llvm_type(e, type), value, address, align_suffix(e, address, type))
}

@(private = "file")
place_align_of :: proc(e: ^Emitter, address: string, type: Type_Id) -> u64 {
	if a, ok := e.place_align[address]; ok {
		return a
	}
	return type_align(e.c, type)
}

// `, align N` for a place known to be less aligned than its pointee.
@(private = "file")
align_suffix :: proc(e: ^Emitter, address: string, type: Type_Id) -> string {
	if a, ok := e.place_align[address]; ok && a < type_align(e.c, type) {
		return fmt.aprintf(", align %d", a)
	}
	return ""
}

// Records a field address's effective alignment, which is 1 through a packed
// struct, so nested access stays unaligned.
@(private = "file")
record_field_align :: proc(e: ^Emitter, base_type: Type_Id, base_address, field_address: string, field_type: Type_Id) {
	base_info := underlying_info(e.c, base_type)
	base_align := place_align_of(e, base_address, base_type)
	field_align := base_info != nil && base_info.packed ? u64(1) : min(base_align, type_align(e.c, field_type))
	if field_align < type_align(e.c, field_type) {
		e.place_align[field_address] = field_align
	}
}

// The address of a place; a value gets temporary storage, so `&Point{1, 2}`
// works.
@(private)
emit_address :: proc(e: ^Emitter, expr: Expr) -> string {
	if expression_converts_storage(expr) {
		type := expr_base(expr).type
		slot := temporary_slot(e, type)
		store(e, type, emit_expr(e, expr), slot)
		register_temporary_place(e, type, slot)
		return slot
	}
	return emit_address_at(e, expr, expr_base(expr).type)
}

// The storage type can precede an implicit conversion on the same node.
@(private)
emit_address_at :: proc(e: ^Emitter, expr: Expr, as_type: Type_Id) -> string {
	// design.md "Materialization": every use of one constant shares one global.
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
		// `pkg.name` is another package's global, not a field of the alias.
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
		operand_type := expr_base(v.operand).type
		// An `inout` `operator([])` result is the address itself; a value result
		// is a temporary that needs storage like any other.
		if v.resolution.kind == .User_Operator {
			if sym := symbol_of(e.c, v.resolution.symbol); sym != nil && sym.result_inout {
				return emit_operator_call(e, v.resolution.symbol, v.bound)
			}
			slot := temporary_slot(e, as_type)
			store(e, as_type, emit_operator_call(e, v.resolution.symbol, v.bound), slot)
			hold_addressed_temporary(e, expr, as_type, slot)
			return slot
		}
		if type_is_slice(e.c, operand_type) {
			return emit_slice_element_address(e, v)
		}
		if type_is_dynamic_array(e.c, operand_type) {
			return emit_dynamic_element_address(e, v)
		}
		// Whole-element map assignment never asks for an address; every other
		// map index names an element that must already exist (design.md "Maps").
		if type_is_map(e.c, operand_type) {
			return emit_map_element_address(e, v)
		}
		// A C pointer indexes without bounds checking (design.md "C pointers").
		if operand_info := underlying_info(e.c, operand_type);
		   operand_info != nil && operand_info.kind == .C_Pointer {
			data := emit_expr(e, v.operand)
			index := widen_to_i64(e, emit_expr(e, v.indices[0]), expr_base(v.indices[0]).type)
			return gep_at(e, llvm_type(e, operand_info.element), data, index)
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
		slot := temporary_slot(e, as_type)
		emit_composite_into(e, v, slot, as_type)
		return slot

	case ^Expr_Call:
		// A single `inout` result is already the address of the returned place.
		if expr_base(expr).value_category == .Place {
			return emit_call(e, v, as_type)
		}
	}
	// Any other value is materialised into a temporary. A folded conversion like
	// `u8(3)` stores its constant, not its unconverted operand.
	slot := temporary_slot(e, as_type)
	store(e, as_type, emit_expr_at(e, expr, as_type), slot)
	hold_addressed_temporary(e, expr, as_type, slot)
	return slot
}

// Where an owned value becomes addressable storage for a borrow — slicing,
// indexing, a field, a conversion, an operator, an immutable receiver — the
// temporary is registered once, so `takes(build()[:])` has a boundary. A place
// is someone else's to destroy.
@(private)
hold_addressed_temporary :: proc(e: ^Emitter, expr: Expr, type: Type_Id, place: string) {
	if expression_is_borrowed_place(expr) {
		return
	}
	register_temporary_place(e, type, place)
}

// An operand read by value that its operation never owns, such as a comparison
// side or a text operation's receiver. An owned managed temporary lives until
// its full expression ends, so a view into it stays valid that long.
@(private = "file")
emit_borrowed_operand :: proc(e: ^Emitter, expr: Expr) -> string {
	value := emit_expr(e, expr)
	base := expr_base(expr)
	if base.is_const || !emit_lifecycle(e, base.type).managed || expression_is_borrowed_place(expr) {
		return value
	}
	slot := temporary_slot(e, base.type)
	store(e, base.type, value, slot)
	register_temporary_place(e, base.type, slot)
	return value
}

// The checked i64 index of `v`, which must be below the runtime `length`.
// Unsigned, so a negative index fails the same comparison as an oversized one.
@(private = "file")
emit_index_below :: proc(e: ^Emitter, v: ^Expr_Index, length: string) -> string {
	index := widen_to_i64(e, emit_expr(e, v.indices[0]), expr_base(v.indices[0]).type)
	out_of_range := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp uge i64 %s, %s", out_of_range, index, length)
	panic_if(e, out_of_range, "bounds", "index out of range")
	return index
}

// `xs[i]`: an address in the current allocation, valid only as long as it is
// (the M5b invalidation events enforce that).
@(private = "file")
emit_dynamic_element_address :: proc(e: ^Emitter, v: ^Expr_Index) -> string {
	operand_type := expr_base(v.operand).type
	header := emit_address(e, v.operand)
	data := load(e, "ptr", gep_field(e, CONTAINER_TYPE, header, CONTAINER_STORAGE))
	length := load(e, "i64", gep_field(e, CONTAINER_TYPE, header, CONTAINER_LEN))
	index := emit_index_below(e, v, length)
	return gep_at(e, llvm_type(e, container_element(e.c, operand_type)), data, index)
}

// `s[i]`: an address in the slice's root.
@(private = "file")
emit_slice_element_address :: proc(e: ^Emitter, v: ^Expr_Index) -> string {
	operand_type := expr_base(v.operand).type
	data, length := emit_byte_slice_parts(e, v.operand)
	index := emit_index_below(e, v, length)
	return gep_at(e, llvm_type(e, slice_element(e.c, operand_type)), data, index)
}

// `p.x` and `p[i]` accept one pointer hop, whose value is the base address.
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

// `lo` and `hi`, each evaluated once in order, checked as
// `0 <= lo <= hi <= length` in one trap seam before any address is formed.
@(private = "file")
emit_slice_bounds :: proc(e: ^Emitter, v: ^Expr_Slice, length, message: string) -> (low, high: string) {
	low = "0"
	if v.lo != nil {
		low = widen_to_i64(e, emit_expr(e, v.lo), expr_base(v.lo).type)
	}
	high = length
	if v.hi != nil {
		high = widen_to_i64(e, emit_expr(e, v.hi), expr_base(v.hi).type)
	}
	reversed, past_end, bad := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", reversed, low, high)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", past_end, high, length)
	fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", bad, reversed, past_end)
	panic_if(e, bad, "slice.bounds", message)
	return
}

// `base[lo:hi]` over a fixed array, a slice, or a dynamic array's current
// allocation up to `len`.
@(private = "file")
emit_builtin_slice :: proc(e: ^Emitter, v: ^Expr_Slice, as_type: Type_Id) -> string {
	operand_type := expr_base(v.operand).type
	info := underlying_info(e.c, operand_type)

	data, length := "", ""
	#partial switch info.kind {
	case .String, .String_View:
		return emit_text_subrange(e, v)
	case .C_Pointer:
		return emit_c_pointer_slice(e, v, as_type)
	case .Slice:
		data, length = emit_byte_slice_parts(e, v.operand)
	case .Dynamic_Array:
		value := emit_expr(e, v.operand)
		data = extract(e, CONTAINER_TYPE, value, CONTAINER_STORAGE)
		length = extract(e, CONTAINER_TYPE, value, CONTAINER_LEN)
	case:
		data = emit_address(e, v.operand)
		length = fmt.aprintf("%d", info.count)
	}

	low, high := emit_slice_bounds(e, v, length, "slice bounds out of range")
	start := gep_at(e, llvm_type(e, info.element), data, low)
	count := temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, %s", count, high, low)
	return emit_slice_value(e, as_type, start, count)
}

// `st[low:high]` is a view over byte offsets, so a range that splits a code
// point is rejected along with an out-of-range one.
@(private = "file")
emit_text_subrange :: proc(e: ^Emitter, v: ^Expr_Slice) -> string {
	data, length := emit_text_parts(e, v.operand)
	low, high := emit_slice_bounds(e, v, length, "string slice bounds out of range")
	start, count := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds i8, ptr %s, i64 %s", start, data, low)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, %s", count, high, low)
	valid, split := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = call i32 @loke_rt_v1_utf8_valid(ptr %s, i64 %s)", valid, start, count)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", split, valid)
	panic_if(e, split, "slice.utf8", "string slice bounds split a code point")
	return emit_ptr_len(e, STRING_VIEW_TYPE, start, count)
}

// design.md "C pointers": `x[:]`/`x[i:]` stay unbounded C pointers; `x[:n]` and
// `x[i:n]` make a checked `[]T`.
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

// An unsigned comparison catches a negative index and an oversized one at once.
// It runs at i64, so a count wider than a narrow index type is not truncated;
// only a wider-than-64-bit index is compared before it is truncated.
@(private = "file")
emit_bounds_check :: proc(e: ^Emitter, index: string, index_type: Type_Id, count: u64) -> string {
	wide := type_bits(e.c, index_type) > 64
	compared := wide ? index : widen_to_i64(e, index, index_type)
	out_of_range := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = icmp uge %s %s, %d",
		out_of_range, wide ? llvm_type(e, index_type) : "i64", compared, count,
	)
	panic_if(e, out_of_range, "bounds", "index out of range")
	return wide ? widen_to_i64(e, index, index_type) : compared
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

// Emits `expr` at `as_type`: its checked type, or the source type an implicit
// conversion recorded on this node. Children keep their own checked types.
@(private)
emit_expr_at :: proc(e: ^Emitter, expr: Expr, as_type: Type_Id) -> string {
	base := expr_base(expr)
	// A value becoming an `any_view`: its address plus the frozen `typeid`.
	if from := base.erased_from; from != INVALID_TYPE && as_type == TYPE_ANY_VIEW {
		address := spill_iterable_at(e, expr, from)
		return emit_any_view_value(e, address, from)
	}
	// A `string` borrowed as a `string_view`: the owning word is dropped, and
	// addressing the source keeps an owned temporary alive.
	if from := base.view_from; from != INVALID_TYPE && underlying_kind(e.c, as_type) == .String_View {
		value := load(e, STRING_TYPE, emit_address_at(e, expr, from))
		data := extract(e, STRING_TYPE, value, STRING_DATA)
		length := extract(e, STRING_TYPE, value, STRING_LEN)
		return emit_ptr_len(e, STRING_VIEW_TYPE, data, length)
	}
	// A `[dynamic]T` read as a `[]T` of its live elements.
	if from := base.view_from; from != INVALID_TYPE && underlying_kind(e.c, as_type) == .Slice {
		value := load(e, CONTAINER_TYPE, emit_address_at(e, expr, from))
		data := extract(e, CONTAINER_TYPE, value, CONTAINER_STORAGE)
		length := extract(e, CONTAINER_TYPE, value, CONTAINER_LEN)
		return emit_slice_value(e, as_type, data, length)
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
		address, ok := e.names[v.symbol]
		if !ok {
			backend_fail(e, "a resolved value has no storage")
			return "0"
		}
		return load_place(e, as_type, address)

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
		return load_place(e, as_type, emit_address_at(e, expr, as_type))

	case ^Expr_Selector, ^Expr_Index:
		if index, is_index := expr.(^Expr_Index); is_index {
			// A read does not insert and panics for a missing key (design.md "Maps").
			if !index.map_inserts && index.operand != nil && type_is_map(e.c, expr_base(index.operand).type) {
				return emit_map_lookup(e, index)
			}
			// A value `operator([])` produces the element; an `inout` one its address.
			if base.resolution.kind == .User_Operator {
				result := emit_operator_call(e, index.resolution.symbol, index.bound)
				if base.value_category != .Place {
					return result
				}
				return load_place(e, as_type, result)
			}
		}
		// `pkg.f` as a value is the procedure itself, not storage holding one.
		if symbol := symbol_of(e.c, base.resolution.symbol); symbol != nil && symbol.kind == .Proc {
			return symbol_name(e, base.resolution.symbol)
		}
		return load_place(e, as_type, emit_address_at(e, expr, as_type))

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
		return load_place(e, as_type, result)

	case ^Expr_Checked_Extract, ^Expr_Or_Else:
		return emit_producer_value(e, expr, as_type)[0]

	case ^Expr_Composite:
		if v.backing != INVALID_TYPE {
			return emit_slice_literal(e, v, as_type)
		}
		return load_temporary(e, as_type, emit_address_at(e, expr, as_type))

	case ^Expr_Proc:
		// Every reachable literal is hoisted and named before any body is emitted.
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
	backend_fail(e, "an unresolved expression reached emission")
	return "0"
}

// A slice literal views a hidden fixed array owned by the enclosing scope
// (design.md "Slice literals"), which drops its elements like a named `[N]T`.
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
		value := emit_expr(e, element.value)
		if index < len(v.element_clones) && v.element_clones[index] {
			value = emit_clone_value(e, info.element, value)
		}
		store(e, info.element, value, slot)
	}
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
	// SIMD is lane-wise, and its comparisons produce a mask, not a `bool`.
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
		lhs := emit_borrowed_operand(e, v.lhs)
		rhs := emit_borrowed_operand(e, v.rhs)
		return emit_compare(e, v.op, operand_type, lhs, rhs)
	}
	if v.op == .Plus && type_is_utf8_text(e.c, expr_base(v.lhs).type) {
		return emit_text_concat(e, v)
	}
	lhs := emit_expr(e, v.lhs)
	rhs := emit_expr(e, v.rhs)
	return emit_binary_op(e, v.op, as_type, expr_base(v.rhs).type, lhs, rhs)
}

// Concatenation allocates from the default allocator and follows its failure
// policy. Both operands are valid UTF-8, so the result is too.
@(private = "file")
emit_text_concat :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	left_data, left_len := emit_text_parts(e, v.lhs)
	right_data, right_len := emit_text_parts(e, v.rhs)
	provider := emit_default_allocator(e)
	return emit_text_allocating_call(
		e, "loke_rt_v1_string_concat",
		fmt.aprintf(
			"ptr %s, i64 %s, ptr %s, i64 %s, ptr %s",
			left_data, left_len, right_data, right_len, provider,
		),
		provider,
	)
}

// The LLVM instruction each arithmetic operator lowers to. Integer `/` and `%`
// go through `emit_divrem`, and a float has no bitwise operators.
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

// Zero takes the trap seam; `MIN / -1` wraps (design.md) instead of reaching
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

// design.md: a shift count at or beyond the width is defined (zero, or the sign
// bit for an arithmetic right shift), so none reaches an LLVM shift as poison.
@(private = "file")
emit_shift :: proc(e: ^Emitter, op: Token_Kind, type: Type_Id, signed: bool, count_type: Type_Id, lhs, rhs: string) -> string {
	llvm := llvm_type(e, type)
	bits := type_bits(e.c, type)
	count_llvm := llvm_type(e, count_type)
	count_bits := type_bits(e.c, count_type)

	// Compared in the count's own width, before truncation could hide its size.
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

// The LLVM predicate per comparison and operand class. The float column is
// ordered, except `!=`, which is true for unordered operands.
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
	// Text is ordered byte-wise; one runtime call answers all six operators.
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

// Structural equality, since LLVM has no aggregate `icmp`.
//
// ponytail: one flat `and` chain rather than short-circuiting blocks; every
// leaf is a pure extract plus compare. Revisit if a very large array comparison
// shows up in a profile.
@(private)
emit_equal :: proc(e: ^Emitter, type: Type_Id, lhs, rhs: string) -> string {
	under := type_underlying(e.c, type)
	info := type_of(e.c, under)
	if info == nil {
		return "true"
	}
	if is_large_value(e, under) && (info.kind == .Array || info.kind == .Struct && !record_uses_byte_members(e, under, info)) {
		return emit_large_equal(e, under, info, lhs, rhs)
	}
	#partial switch info.kind {
	case .Union:
		return emit_union_equal(e, under, lhs, rhs)
	case .Dyn, .Any_View:
		// Comparable only with `nil`, the zero view, so the second word decides.
		llvm := llvm_type(e, under)
		left := extract(e, llvm, lhs, 1)
		right := extract(e, llvm, rhs, 1)
		out := temp(e)
		operand := info.kind == .Dyn ? "ptr" : "i64"
		fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", out, operand, left, right)
		return out
	case .Slice:
		// Only `slice == nil` is admitted, and nil has a null data pointer.
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
		if record_uses_byte_members(e, under, info) {
			return emit_byte_member_struct_equal(e, under, info, lhs, rhs)
		}
		result := "true"
		for field, index in info.fields {
			symbol := symbol_of(e.c, field)
			left := extract(e, llvm_type(e, under), lhs, index)
			right := extract(e, llvm_type(e, under), rhs, index)
			leaf := ""
			if counter := symbol_of(e.c, symbol.initialized_by); counter != nil {
				llvm := llvm_type(e, under)
				leaf = emit_prefix_equal(
					e, counter, symbol.type,
					extract(e, llvm, lhs, int(counter.index)), extract(e, llvm, rhs, int(counter.index)), left, right,
				)
			} else {
				leaf = emit_equal(e, symbol.type, left, right)
			}
			result = combine_and(e, result, leaf)
		}
		return result
	}
	return emit_compare(e, .Eq_Eq, type, lhs, rhs)
}

// A large value is an address, so its parts are compared in place: a record
// field by field, an array in a loop rather than unrolled.
@(private = "file")
emit_large_equal :: proc(e: ^Emitter, type: Type_Id, info: ^Type_Info, lhs, rhs: string) -> string {
	part_value :: proc(e: ^Emitter, type: Type_Id, address: string) -> string {
		return is_large_value(e, type) ? address : load_place(e, type, address)
	}
	llvm := llvm_type(e, type)
	if info.kind == .Struct {
		result := "true"
		for field, index in info.fields {
			symbol := symbol_of(e.c, field)
			left := part_value(e, symbol.type, gep_field(e, llvm, lhs, index))
			right := part_value(e, symbol.type, gep_field(e, llvm, rhs, index))
			leaf := ""
			if counter := symbol_of(e.c, symbol.initialized_by); counter != nil {
				count_left := load_place(e, counter.type, gep_field(e, llvm, lhs, int(counter.index)))
				count_right := load_place(e, counter.type, gep_field(e, llvm, rhs, int(counter.index)))
				leaf = emit_prefix_equal(e, counter, symbol.type, count_left, count_right, left, right)
			} else {
				leaf = emit_equal(e, symbol.type, left, right)
			}
			result = combine_and(e, result, leaf)
		}
		return result
	}
	element_llvm := llvm_type(e, info.element)
	same, cursor := alloca(e, "i1"), alloca(e, "i64")
	fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", same)
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
	head := new_label(e, "large.equal.head")
	body, done := new_label(e, "large.equal.body"), new_label(e, "large.equal.done")
	branch(e, head)
	place_label(e, head)
	at := load(e, "i64", cursor)
	more := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %d", more, at, info.count)
	branch_if(e, more, body, done)
	place_label(e, body)
	left := part_value(e, info.element, gep_at(e, element_llvm, lhs, at))
	right := part_value(e, info.element, gep_at(e, element_llvm, rhs, at))
	leaf := emit_equal(e, info.element, left, right)
	fmt.sbprintfln(&e.b, "  store i1 %s, ptr %s", combine_and(e, load(e, "i1", same), leaf), same)
	step := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", step, at)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", step, cursor)
	branch(e, head)
	place_label(e, done)
	return load(e, "i1", same)
}

// design.md "Uninitialized capacity": only the live prefix is compared. Unequal
// counts already differ through the count field, and the loop stops at the
// shorter one, so neither side's capacity is ever read.
@(private = "file")
emit_prefix_equal :: proc(
	e: ^Emitter, counter: ^Symbol, array: Type_Id, raw_left, raw_right, left, right: string,
) -> string {
	element := underlying_info(e.c, array).element
	element_llvm := llvm_type(e, element)
	array_llvm := llvm_type(e, array)

	count_left := widen_to_i64(e, raw_left, counter.type)
	count_right := widen_to_i64(e, raw_right, counter.type)
	shorter, total := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %s", shorter, count_left, count_right)
	fmt.sbprintfln(
		&e.b, "  %s = select i1 %s, i64 %s, i64 %s", total, shorter, count_left, count_right,
	)

	// Both sides are spilled so the loop can index them.
	left_slot, right_slot := alloca(e, array_llvm), alloca(e, array_llvm)
	store(e, array, left, left_slot)
	store(e, array, right, right_slot)
	same, cursor := alloca(e, "i1"), alloca(e, "i64")
	fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", same)
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)

	head := new_label(e, "prefix.equal.head")
	body, done := new_label(e, "prefix.equal.body"), new_label(e, "prefix.equal.done")
	branch(e, head)
	place_label(e, head)
	at := load(e, "i64", cursor)
	more := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %s", more, at, total)
	branch_if(e, more, body, done)
	place_label(e, body)
	one := load_place(e, element, gep_at(e, element_llvm, left_slot, at))
	other := load_place(e, element, gep_at(e, element_llvm, right_slot, at))
	leaf := emit_equal(e, element, one, other)
	previous := load(e, "i1", same)
	next := temp(e)
	fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", next, previous, leaf)
	fmt.sbprintfln(&e.b, "  store i1 %s, ptr %s", next, same)
	step := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", step, at)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", step, cursor)
	branch(e, head)
	place_label(e, done)
	return load(e, "i1", same)
}

// An erased view takes the same comparison route a union does.
@(private = "file")
type_is_erased_view :: proc(c: ^Compiler, type: Type_Id) -> bool {
	#partial switch underlying_kind(c, type) {
	case .Dyn, .Any_View, .Slice:
		return true
	}
	return false
}

// Equal tags, then the active variant's payload. Only that variant's comparison
// runs: another variant's bytes read as a `string` would be arbitrary memory.
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

	// The tag comparison is the answer unless an active payload overrides it.
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
		// The comparison may open blocks, so the store goes wherever it ends.
		equal := emit_equal(e, variant, left, right)
		fmt.sbprintfln(&e.b, "  store i1 %s, ptr %s", equal, answer)
		branch(e, done)

		place_label(e, next)
	}
	place_label(e, done)
	return load(e, "i1", answer)
}

// Whether this record is the combined `@(packed, align=N)` body from
// `struct_body`, whose LLVM members are byte arrays.
@(private = "file")
record_uses_byte_members :: proc(e: ^Emitter, type: Type_Id, info: ^Type_Info) -> bool {
	if !info.packed || len(info.fields) == 0 {
		return false
	}
	type_size(e.c, type)
	current := type_of(e.c, type)
	return current != nil && current.align > record_natural_align(e.c, current)
}

// Field-wise equality with each field loaded at its own type through the GEP
// its byte member occupies.
@(private = "file")
emit_byte_member_struct_equal :: proc(e: ^Emitter, type: Type_Id, info: ^Type_Info, lhs, rhs: string) -> string {
	llvm := llvm_type(e, type)
	left_slot := alloca(e, llvm)
	right_slot := temp(e)
	store(e, type, lhs, left_slot)
	alloca_named(e, right_slot, llvm)
	store(e, type, rhs, right_slot)

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

	// The phi needs a named incoming edge, and the left operand may have opened
	// blocks of its own.
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
	// A large value cannot be a phi operand, so each arm writes one slot.
	joined := is_large_value(e, as_type) ? temporary_slot(e, as_type) : ""
	then_label := new_label(e, "cond.then")
	else_label := new_label(e, "cond.else")
	done_label := new_label(e, "cond.done")
	branch_if(e, cond, then_label, else_label)

	place_label(e, then_label)
	then_value := emit_expr(e, v.then)
	if joined != "" {
		store(e, as_type, then_value, joined)
	}
	then_exit := new_label(e, "cond.then.exit")
	branch(e, then_exit)
	place_label(e, then_exit)
	branch(e, done_label)

	place_label(e, else_label)
	else_value := emit_expr(e, v.otherwise)
	if joined != "" {
		store(e, as_type, else_value, joined)
	}
	else_exit := new_label(e, "cond.else.exit")
	branch(e, else_exit)
	place_label(e, else_exit)
	branch(e, done_label)

	place_label(e, done_label)
	if joined != "" {
		return joined
	}
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

// The data pointer and byte length of a text operand, which is all every text
// operation needs.
@(private)
emit_text_parts :: proc(e: ^Emitter, operand: Expr) -> (data: string, length: string) {
	type := type_underlying(e.c, expr_base(operand).type)
	value := emit_borrowed_operand(e, operand)
	if type_kind(e.c, type) == .CString_View {
		// A C string view is terminated, not measured.
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
		_, length := emit_text_parts(e, v.bound[0])
		out[0] = length

	case .Rune_Count:
		data, length := emit_text_parts(e, v.bound[0])
		out[0] = temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i64 @loke_rt_v1_rune_count(ptr %s, i64 %s)", out[0], data, length)

	case .Bytes:
		// A read-only `[]u8` over the same storage.
		data, length := emit_text_parts(e, v.bound[0])
		out[0] = emit_slice_value(e, as_type, data, length)

	case .Runes:
		// The same borrow as `bytes()`, viewed as text (design.md "String iteration").
		data, length := emit_text_parts(e, v.bound[0])
		out[0] = emit_ptr_len(e, STRING_VIEW_TYPE, data, length)

	case .Rune_Offsets:
		// The view holds the bytes; the cursor belongs to its iterator.
		data, length := emit_text_parts(e, v.bound[0])
		view := emit_ptr_len(e, STRING_VIEW_TYPE, data, length)
		out[0] = insert(e, llvm_type(e, as_type), "undef", STRING_VIEW_TYPE, view, VIEW_SOURCE)

	case .Copy:
		data, length := emit_text_parts(e, v.bound[0])
		provider := emit_default_allocator(e)
		out[0] = emit_text_allocating_call(
			e, "loke_rt_v1_string_clone",
			fmt.aprintf("ptr %s, i64 %s, ptr %s", data, length, provider),
			provider,
		)

	case .To_C_View:
		// ponytail: every `string` buffer and literal already carries a terminator,
		// so no terminated temporary is ever needed. A representation that could
		// hand out an unterminated `string` would need that branch back.
		data, _ := emit_text_parts(e, v.bound[0])
		out[0] = data

	case .To_Runes:
		// The helper releases its partial buffer before the policy applies.
		data, length := emit_text_parts(e, v.bound[0])
		ops := container_ops_global(e, as_type)
		slot := alloca(e, CONTAINER_TYPE)
		provider := emit_default_allocator(e)
		ok := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_string_to_runes(ptr %s, ptr %s, ptr %s, i64 %s, ptr %s)",
			ok, slot, ops, data, length, provider,
		)
		emit_alloc_check(e, ok, provider)
		out[0] = load(e, CONTAINER_TYPE, slot)

	case .From_Runes:
		data, count := emit_byte_slice_parts(e, v.bound[0])
		return emit_text_optional_ok(
			e, as_type, "loke_rt_v1_string_from_runes",
			fmt.aprintf("ptr %s, i64 %s, ptr %s", data, count, emit_default_allocator(e)),
		)
	}
	return out
}

// An implicit allocation has nowhere to report failure, so a zero `status`
// applies the provider's own policy (design.md "Allocation failure").
@(private = "file")
emit_alloc_check :: proc(e: ^Emitter, status, provider: string) {
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, status)
	fail, done := new_label(e, "text.failed"), new_label(e, "ok")
	branch_if(e, failed, fail, done)
	place_label(e, fail)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
	fmt.sbprintln(&e.b, "  unreachable")
	e.terminated = true
	place_label(e, done)
}

// A runtime call that fills a `string` out-parameter and answers 1 on success.
// Pointers and integers only, so C and LLVM cannot disagree on returning a
// 24-byte aggregate.
@(private = "file")
emit_text_call_slot :: proc(e: ^Emitter, callee: string, arguments: string) -> (slot: string, ok: string) {
	slot = temp(e)
	alloca_named(e, slot, STRING_TYPE)
	ok = temp(e)
	fmt.sbprintfln(&e.b, "  %s = call i32 @%s(ptr %s, %s)", ok, callee, slot, arguments)
	return slot, ok
}

@(private = "file")
emit_text_allocating_call :: proc(e: ^Emitter, callee, arguments, provider: string) -> string {
	slot, ok := emit_text_call_slot(e, callee, arguments)
	emit_alloc_check(e, ok, provider)
	return load(e, STRING_TYPE, slot)
}

// On failure the runtime has already published the zero value into the slot.
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

// `Option(string_view)` over bytes that are borrowed, not copied: `.some` only
// when they are valid UTF-8.
@(private = "file")
emit_checked_view :: proc(e: ^Emitter, option: Type_Id, data, length: string) -> []string {
	valid, ok := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = call i32 @loke_rt_v1_utf8_valid(ptr %s, i64 %s)", valid, data, length)
	fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", ok, valid)
	kept_data, kept_len := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, ptr %s, ptr null", kept_data, ok, data)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 %s, i64 0", kept_len, ok, length)
	view := emit_ptr_len(e, STRING_VIEW_TYPE, kept_data, kept_len)
	out := make([]string, 1)
	out[0] = emit_option_value(e, option, ok, view)
	return out
}

// `strings.allocate_string(text, allocator)`: `.copy()` into the caller's
// allocator, reporting failure instead of applying its policy. The header
// records the allocator, so release returns the block to it.
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

// design.md "string type conversions": each validates and returns `Option(T)`.
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
		// A borrow of the slice's root, which `src/borrow.odin` keeps alive.
		data, length := emit_byte_slice_parts(e, v.bound[0])
		return emit_checked_view(e, as_type, data, length)

	case .String_From_C_View:
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

// The data pointer and length of a slice value.
@(private = "file")
emit_byte_slice_parts :: proc(e: ^Emitter, operand: Expr) -> (data: string, length: string) {
	storage := llvm_type(e, expr_base(operand).type)
	value := emit_expr(e, operand)
	data, length = temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, value, SLICE_DATA)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, storage, value, SLICE_LEN)
	return data, length
}

// `unsafe.transmute(T, value)`: the same bits read as a `T`. The checker has
// settled equal size and trivial lifecycles, so only the LLVM spelling is left:
// a register cast where one exists, a stack round trip otherwise.
@(private)
emit_transmute :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	source := expr_base(v.bound[0]).type
	value := emit_expr(e, v.bound[0])
	// A `bool` is `i1` in registers but a byte in memory, so it crosses as `i8`.
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
		// Bit 0 is the `bool`; a valid pattern is the caller's obligation.
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
		// An aggregate: through equally sized storage aligned for the stricter side.
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

// First-class, non-aggregate, non-pointer types, which `bitcast` accepts.
@(private = "file")
bitcastable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	#partial switch underlying_kind(c, type) {
	case .Bool, .Int, .Float, .Rune, .Enum, .Simd:
		return true
	}
	return false
}

// `unsafe.raw_data`, `unsafe.cstring_view` and `unsafe.string_view`; the last
// still validates, since `string_view` promises UTF-8.
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
			// The current allocation's first element; nothing keeps it current.
			out[0] = extract(e, CONTAINER_TYPE, emit_expr(e, v.bound[0]), CONTAINER_STORAGE)
		case:
			// A pointer to a fixed array, or a `cstring_view`, is already the address.
			out[0] = emit_expr(e, v.bound[0])
		}

	case .Unsafe_C_String_View:
		out[0] = emit_expr(e, v.bound[0])

	case .Unsafe_String_View:
		data := emit_expr(e, v.bound[0])
		length := widen_to_i64(e, emit_expr(e, v.bound[1]), expr_base(v.bound[1]).type)
		return emit_checked_view(e, as_type, data, length)
	}
	return out
}

// A fixed array's or vector's `len()` folds to a constant, but its receiver is
// still evaluated once (and a bare name has nothing to run).
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
