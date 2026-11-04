// Constants, places, expressions, comparisons, slices and text, and unsafe
// operations.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:slice"
import "core:strings"

// -------------------------------------------------------------- constants --

// design.md "Zero values": a union constant is the payload's little-endian byte
// image, split across the head and byte-array tail, plus the tag.
@(private = "file")
union_constant :: proc(e: ^Emitter, value: Const_Value, type: Type_Id) -> string {
	shape := union_layout(e.c, type)
	if value.kind != .Aggregate || value.aggregate == nil {
		return "zeroinitializer" // a union with no zero: inert bits, no value
	}
	index := value.aggregate.variant
	payload_type := union_variant_payload(e.c, type, index)
	payload_bytes := make([]u8, int(shape.payload_size), context.temp_allocator)
	if payload_type != TYPE_VOID && type_size(e.c, payload_type) != 0 {
		payload_size := int(type_size(e.c, payload_type))
		if payload_size > len(payload_bytes) ||
		   !write_const_bytes(e, payload_bytes[:payload_size], value.aggregate.elements[0], payload_type) {
			backend_fail(e, fmt.aprintf("a union payload constant cannot be represented as bytes: %s in %s", type_name(e.c, payload_type), type_name(e.c, type)))
		}
	}
	if index == 0 && slice.all_of(payload_bytes, 0) {
		return "zeroinitializer"
	}

	b := strings.builder_make()
	strings.write_string(&b, "{ ")
	// An all-payloadless union stores its tag and nothing else.
	if shape.payload_size > 0 {
		write_union_head_constant(e, &b, payload_bytes[:int(shape.align)])
		if pad := shape.payload_size - shape.align; pad > 0 {
			strings.write_string(&b, ", ")
			write_byte_array_constant(&b, payload_bytes[int(shape.align):int(shape.payload_size)])
		}
		if shape.niche {
			strings.write_string(&b, " }")
			return strings.to_string(b)
		}
		strings.write_string(&b, ", ")
	} else if shape.align > shape.tag_bytes {
		fmt.sbprintf(&b, "[0 x %s] zeroinitializer, ", union_head_type(shape.align))
	}
	fmt.sbprintf(&b, "i%d %d", shape.tag_bytes * 8, index)
	if tail := shape.size - shape.payload_size - shape.tag_bytes; tail > 0 {
		fmt.sbprintf(&b, ", [%d x i8] zeroinitializer", tail)
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

// The head member of `union_head_type`, typed, holding `head`'s bytes.
@(private = "file")
write_union_head_constant :: proc(e: ^Emitter, b: ^strings.Builder, head: []u8) {
	strings.write_string(b, union_head_type(u64(len(head))))
	if len(head) > UNION_INT_HEAD_BYTES {
		strings.write_string(b, " <")
		for byte, index in head {
			fmt.sbprintf(b, "%si8 %d", index > 0 ? ", " : "", byte)
		}
		strings.write_string(b, ">")
		return
	}
	bits := bi_zero(e.c)
	for byte, index in head {
		bits = bi_add(e.c, bits, bi_shl(e.c, bi_from_u64(e.c, u64(byte)), index * 8))
	}
	fmt.sbprintf(b, " %s", bi_text(e.c, bits))
}

// A type's zero value as an LLVM constant, when it has one. design.md "Zero
// values" makes every zero all-zero bits, so an aggregate's is written without
// building a constant per element.
llvm_zero :: proc(e: ^Emitter, type: Type_Id) -> (string, bool) {
	zero, ok := zero_const(e.c, type, build = false)
	if !ok {
		return "", false
	}
	if zero.kind == .Aggregate {
		return "zeroinitializer", true
	}
	return llvm_const(e, zero, type), true
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
		return fmt.aprintf("%d", emitted_typeid(e, value))
	case .Bool:
		return value.boolean ? "true" : "false"
	case .Int, .Enum, .Rune:
		return bi_text(e.c, bi_wrap(e.c, value.integer, type_bits(e.c, under), type_signed(e.c, under)))
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
		return union_constant(e, value, under)
	case .Array, .Simd:
		if value.aggregate == nil || len(value.aggregate.elements) == 0 {
			return "zeroinitializer"
		}
		// A vector constant is `<...>`; a `Simd(bool, N)` lane is `i8` in memory.
		vector := info.kind == .Simd
		lane := simd_lane_llvm_type(e, info)
		mask := vector && simd_is_mask(e, info)
		b := strings.builder_make()
		strings.write_string(&b, vector ? "<" : "[")
		zero := true
		for index in 0 ..< int(info.count) {
			if index > 0 {
				strings.write_string(&b, ",")
			}
			value := llvm_const(e, const_element(value, index), info.element)
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
	case .Dyn, .Dynamic_Array, .Map:
		return "zeroinitializer"
	case .Slice:
		// A slice constant points at storage only the module can hold.
		return value.aggregate != nil ? slice_literal_constant(e, value, info) : "zeroinitializer"
	case .Struct:
		if value.aggregate == nil || len(value.aggregate.elements) == 0 {
			return "zeroinitializer"
		}
		byte_array := record_uses_byte_members(e, under, info)
		angled := info.packed && !byte_array
		b := strings.builder_make()
		strings.write_string(&b, angled ? "<{" : "{")
		zero := !byte_array
		for field, index in info.fields {
			symbol := symbol_of(e.c, field)
			if index > 0 {
				strings.write_string(&b, ",")
			}
			element := const_element(value, index)
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
		if info.align > info.natural_align {
			fmt.sbprintf(&b, ", [0 x i%d] zeroinitializer", info.align * 8)
		}
		strings.write_string(&b, angled ? " }>" : " }")
		return strings.to_string(b)
	}
	return "0"
}

// An element of `value`; a missing one is the inert all-zero constant.
@(private = "file")
const_element :: proc(value: Const_Value, index: int) -> Const_Value {
	if value.aggregate != nil && index < len(value.aggregate.elements) {
		return value.aggregate.elements[index]
	}
	return {}
}

// `freeze_typeids` has numbered every requested type before emission; a bit-cast
// constant brought its own number.
@(private = "file")
emitted_typeid :: proc(e: ^Emitter, value: Const_Value) -> u64 {
	if id, known := typeid_const_number(e.c, value); known {
		return id
	}
	id := typeid_value(e.c, value.type_value)
	if id == 0 {
		backend_fail(e, "a typeid constant was not registered before freezing")
	}
	return id
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

// A pointer inside a constant's byte image, at `offset` from its start.
@(private = "file")
Const_Relocation :: struct {
	offset: int,
	target: string,
}

// Missing elements and nil values are all-zero, which `out` already is. With
// `relocations`, a pointer to module storage is recorded there instead of
// failing; `at` is `out`'s offset in the whole image.
@(private = "file")
write_const_bytes :: proc(
	e: ^Emitter, out: []u8, value: Const_Value, type: Type_Id,
	relocations: ^[dynamic]Const_Relocation = nil, at := 0,
) -> bool {
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
		write_u64_bytes(out, const_float_pattern(value, info.bits))
		return true
	case .Array, .Simd:
		stride := int(type_size(e.c, info.element))
		for index in 0 ..< int(info.count) {
			start, end := index * stride, (index + 1) * stride
			if end > len(out) {
				return false
			}
			if !write_const_bytes(e, out[start:end], const_element(value, index), info.element, relocations, at + start) {
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
			if !write_const_bytes(e, out[start:end], const_element(value, index), symbol.type, relocations, at + start) {
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
		payload_type := info.variants[index]
		payload_size := int(type_size(e.c, payload_type))
		if payload_size > 0 && !write_const_bytes(e, out[:payload_size], const_element(value, 0), payload_type, relocations, at) {
			return false
		}
		if shape.niche {
			return true
		}
		tag := int(shape.payload_size)
		write_u64_bytes(out[tag:tag + int(shape.tag_bytes)], u64(index))
		return true
	case .Typeid:
		write_u64_bytes(out, emitted_typeid(e, value))
		return true
	case .Dynamic_Array, .Map, .Dyn:
		// A constant of these is only the empty one, which is all-zero.
		return true
	case .String, .String_View, .CString_View, .Slice:
		target, count, flags := "", 0, 0
		switch {
		case info.kind == .Slice:
			if value.aggregate == nil || len(value.aggregate.elements) == 0 {
				return true
			}
		case value.kind != .String:
			return false
		case value.text == "" && info.kind != .CString_View:
			return true
		}
		// Literal text and a slice literal's backing array are module storage, so
		// an image holds a relocation to them.
		if relocations == nil {
			return false
		}
		if info.kind == .Slice {
			target, count = slice_literal_storage(e, value, info), len(value.aggregate.elements)
		} else {
			target, count = text_literal_global(e, value.text), len(value.text)
			flags = info.kind == .String ? STRING_STATIC : 0
		}
		append(relocations, Const_Relocation{at, target})
		// The pointer comes first, then the length and a string's owner flags.
		if info.kind != .CString_View {
			write_u64_bytes(out[8:16], u64(count))
		}
		if info.kind == .String {
			write_u64_bytes(out[16:24], u64(flags))
		}
		return true
	}
	return false
}

@(private = "file")
write_u64_bytes :: proc(out: []u8, value: u64) {
	for _, index in out {
		out[index] = u8(value >> u64(index * 8))
	}
}

// design.md "Unions": a union payload, and a field of a combined packed/aligned
// record, is a byte image, which in its declared LLVM type cannot hold a pointer
// to module storage. A constant containing one is emitted whole as an image.
// `in_image` says the walk has entered such a byte image.
const_needs_image :: proc(e: ^Emitter, value: Const_Value, type: Type_Id, in_image := false) -> bool {
	under := type_underlying(e.c, default_type(e.c, type))
	info := type_of(e.c, under)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .String, .String_View:
		return in_image && value.kind == .String && value.text != ""
	case .CString_View:
		return in_image && value.kind == .String
	}
	if value.kind != .Aggregate || value.aggregate == nil {
		return false
	}
	elements := value.aggregate.elements
	#partial switch info.kind {
	case .Slice:
		return in_image && len(elements) > 0
	case .Union:
		index := value.aggregate.variant
		return index >= 0 && index < len(info.variants) && len(elements) > 0 &&
			const_needs_image(e, elements[0], info.variants[index], true)
	case .Struct:
		nested := in_image || record_uses_byte_members(e, under, info)
		for field, index in info.fields {
			if index < len(elements) && const_needs_image(e, elements[index], symbol_of(e.c, field).type, nested) {
				return true
			}
		}
	case .Array, .Simd:
		for element in elements {
			if const_needs_image(e, element, info.element, in_image) {
				return true
			}
		}
	}
	return false
}

// `values` of `type`, one after another, as an LLVM packed struct of byte runs
// and pointers: its type, then its value.
const_image :: proc(e: ^Emitter, values: []Const_Value, type: Type_Id) -> (string, string) {
	stride := int(type_size(e.c, type))
	bytes := make([]u8, stride * len(values), context.temp_allocator)
	relocations := make([dynamic]Const_Relocation, context.temp_allocator)
	for value, index in values {
		start := index * stride
		if !write_const_bytes(e, bytes[start:start + stride], value, type, &relocations, start) {
			backend_fail(e, fmt.aprintf("a constant cannot be represented as an image: %s", type_name(e.c, type)))
		}
	}
	types, parts := strings.builder_make(), strings.builder_make()
	members := 0
	next := proc(types, parts: ^strings.Builder, members: ^int) {
		strings.write_string(types, members^ == 0 ? "<{ " : ", ")
		strings.write_string(parts, members^ == 0 ? "<{ " : ", ")
		members^ += 1
	}
	cursor := 0
	for relocation in relocations {
		if relocation.offset > cursor {
			next(&types, &parts, &members)
			fmt.sbprintf(&types, "[%d x i8]", relocation.offset - cursor)
			write_byte_array_constant(&parts, bytes[cursor:relocation.offset])
		}
		next(&types, &parts, &members)
		strings.write_string(&types, "ptr")
		fmt.sbprintf(&parts, "ptr %s", relocation.target)
		cursor = relocation.offset + 8
	}
	if cursor < len(bytes) {
		next(&types, &parts, &members)
		fmt.sbprintf(&types, "[%d x i8]", len(bytes) - cursor)
		write_byte_array_constant(&parts, bytes[cursor:])
	}
	strings.write_string(&types, " }>")
	strings.write_string(&parts, " }>")
	return strings.to_string(types), strings.to_string(parts)
}

// A global's value type and initializer, and the alignment an image needs.
global_initializer :: proc(e: ^Emitter, value: Const_Value, type: Type_Id) -> (string, string, string) {
	if const_needs_image(e, value, type) {
		image_type, image := const_image(e, {value}, type)
		return image_type, image, fmt.aprintf(", align %d", type_align(e.c, type))
	}
	return llvm_type(e, type), llvm_const(e, value, type), ""
}

// A constant operand in a body; an image is loaded from a private global. A large
// value is an address, so a large constant is the global's.
@(private = "file")
const_operand :: proc(e: ^Emitter, value: Const_Value, type: Type_Id) -> string {
	large := is_large_value(e, type)
	image_type, image, align := global_initializer(e, value, type)
	if large && image == "zeroinitializer" {
		return large_zero(e, type)
	}
	if !large && !const_needs_image(e, value, type) {
		return image
	}
	name := fmt.aprintf("@.image.%d", len(e.globals))
	append(&e.globals, fmt.aprintf("%s = private unnamed_addr constant %s %s%s\n", name, image_type, image, align))
	return large ? name : load(e, llvm_type(e, type), name)
}

// The address of a large zero, which takes no space in the file. `store` writes
// the zero itself rather than copying this, so most of these are never read.
LARGE_ZERO_PREFIX :: "@.zero."

@(private = "file")
large_zero :: proc(e: ^Emitter, type: Type_Id) -> string {
	if name, known := e.large_zeros[type]; known {
		return name
	}
	name := fmt.aprintf("%s%d", LARGE_ZERO_PREFIX, len(e.globals))
	append(&e.globals, fmt.aprintf("%s = private unnamed_addr global %s zeroinitializer\n", name, llvm_type(e, type)))
	e.large_zeros[type] = name
	return name
}

// Every float constant is spelled as its bit pattern, since LLVM's decimal
// syntax only round-trips some values exactly.
llvm_float :: proc(pattern: u64, bits: u16) -> string {
	if bits == 16 {
		return fmt.aprintf("0xH%04X", u16(pattern))
	}
	if bits == 32 {
		// LLVM writes a `float` constant as the `double` pattern of the same value.
		return fmt.aprintf("0x%016X", f32_pattern_as_f64(u32(pattern)))
	}
	return fmt.aprintf("0x%016X", pattern)
}

// Widening is exact, but a NaN's bits are widened by hand, since the hardware
// conversion would quiet a signalling one.
@(private = "file")
f32_pattern_as_f64 :: proc(pattern: u32) -> u64 {
	if pattern & 0x7f80_0000 == 0x7f80_0000 {
		sign := u64(pattern >> 31) << 63
		return sign | 0x7ff0_0000_0000_0000 | u64(pattern & 0x7f_ffff) << 29
	}
	return transmute(u64)f64(transmute(f32)pattern)
}

// The global backing array of a file-scope slice literal. Never shared: a
// write through one `[]mut T` literal must not show up in another.
@(private)
slice_literal_constant :: proc(e: ^Emitter, value: Const_Value, info: ^Type_Info) -> string {
	count := len(value.aggregate.elements)
	if count == 0 {
		return "zeroinitializer"
	}
	return slice_constant(slice_literal_storage(e, value, info), count)
}

// The global backing array of a slice literal with at least one element.
@(private)
slice_literal_storage :: proc(e: ^Emitter, value: Const_Value, info: ^Type_Info) -> string {
	count := len(value.aggregate.elements)
	imaged := false
	for slot in value.aggregate.elements {
		imaged ||= const_needs_image(e, slot, info.element)
	}
	contents, align := "", ""
	if imaged {
		image_type, image := const_image(e, value.aggregate.elements, info.element)
		contents = fmt.aprintf("%s %s", image_type, image)
		align = fmt.aprintf(", align %d", type_align(e.c, info.element))
	} else {
		element := llvm_type(e, info.element)
		b := strings.builder_make()
		fmt.sbprintf(&b, "[%d x %s] [", count, element)
		for slot, index in value.aggregate.elements {
			fmt.sbprintf(&b, "%s %s %s", index > 0 ? "," : "", element, llvm_const(e, slot, info.element))
		}
		strings.write_string(&b, " ]")
		contents = strings.to_string(b)
	}
	name := fmt.aprintf("@.slice.%d", len(e.globals))
	append(&e.globals, fmt.aprintf(
		"%s = private %s %s%s\n",
		name, info.mutable ? "global" : "unnamed_addr constant", contents, align,
	))
	return name
}

@(private)
slice_constant :: proc(name: string, count: int) -> string {
	return fmt.aprintf("{{ ptr %s, i64 %d }}", name, count)
}

// A literal `string` or `string_view`: static owner flags, no allocation.
@(private)
text_constant :: proc(e: ^Emitter, value: Const_Value, owning: bool) -> string {
	if value.kind != .String || value.text == "" {
		return "zeroinitializer"
	}
	b := strings.builder_make()
	strings.write_string(&b, "{ ptr ")
	strings.write_string(&b, text_literal_global(e, value.text))
	fmt.sbprintf(&b, ", i64 %d", len(value.text))
	if owning {
		fmt.sbprintf(&b, ", i64 %d", STRING_STATIC)
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

// `text` as a literal `string_view`.
@(private)
text_view_constant :: proc(e: ^Emitter, text: string) -> string {
	return text_constant(e, string_const(text), false)
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

// One field of a record value. A large record is an address, read in place, and
// a large field stays one.
@(private)
record_part :: proc(e: ^Emitter, record: Type_Id, value: string, index: int) -> string {
	if !is_large_value(e, record) {
		return extract(e, llvm_type(e, record), value, index)
	}
	address := element_address(e, record, value, index)
	field := symbol_of(e.c, underlying_info(e.c, record).fields[index]).type
	return is_large_value(e, field) ? address : load_place(e, field, address)
}

// A record of `parts`, in field order. A large one is built in storage, and a
// large part is the address of its value.
@(private)
build_record :: proc(e: ^Emitter, record: Type_Id, parts: ..string) -> string {
	fields := underlying_info(e.c, record).fields
	if is_large_value(e, record) {
		slot := temporary_slot(e, record)
		for part, index in parts {
			store(e, symbol_of(e.c, fields[index]).type, part, element_address(e, record, slot, index))
		}
		return slot
	}
	llvm := llvm_type(e, record)
	built := "undef"
	for part, index in parts {
		built = insert(e, llvm, built, llvm_type(e, symbol_of(e.c, fields[index]).type), part, index)
	}
	return built
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
		if value == "zeroinitializer" || strings.has_prefix(value, LARGE_ZERO_PREFIX) {
			fmt.sbprintfln(&e.b, "  call void @llvm.memset.p0.i64(ptr %s, i8 0, i64 %d, i1 false)", address, size)
			return
		}
		from := value
		if value[0] != '%' && value[0] != '@' {
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
@(private)
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
emit_address :: proc(e: ^Emitter, expr: Expr, lending := false) -> string {
	type := expr_base(expr).type
	if expression_converts_storage(expr) {
		return hold_in_temporary(e, expr, type, emit_expr(e, expr))
	}
	return emit_address_at(e, expr, type, lending)
}

// The address of `expr` for a borrow, such as `&`, slicing, or a view
// conversion: a temporary literal under it is dropped when the borrow's
// temporaries are, rather than handed on as an owned value.
@(private)
emit_lent_address :: proc(e: ^Emitter, expr: Expr, as_type: Type_Id) -> string {
	return emit_address_at(e, expr, as_type, lending = true)
}

// A field or element read out of a literal whose type has a lifecycle: the
// literal is still a temporary that is built and dropped (design.md "Evaluation
// order"), so its read does not fold to the constant it would select.
@(private = "file")
projects_managed_literal :: proc(e: ^Emitter, expr: Expr) -> bool {
	node := expr
	for {
		#partial switch v in node {
		case ^Expr_Selector:
			if v.resolution.kind != .Field {
				return false
			}
			node = v.operand
		case ^Expr_Index:
			node = v.operand
		case ^Expr_Composite:
			return node != expr && emit_lifecycle(e, v.type).managed
		case:
			return false
		}
	}
}

// Storage for the temporary `expr` makes. A large one is shared between full
// expressions, so one a local's value extends past its own gets storage of its
// own instead.
@(private = "file")
temporary_slot_for :: proc(e: ^Emitter, expr: Expr, type: Type_Id) -> string {
	if expr_base(expr).extended {
		return alloca(e, llvm_type(e, type))
	}
	return temporary_slot(e, type)
}

// The storage of `symbol`, which a resolved place has.
@(private = "file")
symbol_place :: proc(e: ^Emitter, symbol: Symbol_Id) -> string {
	if name, ok := e.names[symbol]; ok {
		return name
	}
	backend_fail(e, "a resolved place has no storage")
	return "null"
}

// `value` in storage of its own, as the temporary `expr` makes.
@(private = "file")
hold_in_temporary :: proc(e: ^Emitter, expr: Expr, type: Type_Id, value: string) -> string {
	slot := temporary_slot_for(e, expr, type)
	store(e, type, value, slot)
	hold_addressed_temporary(e, expr, type, slot)
	return slot
}

// The storage type can precede an implicit conversion on the same node. Only
// the address asked for is `lending`; a projection lends its own operand.
@(private)
emit_address_at :: proc(e: ^Emitter, expr: Expr, as_type: Type_Id, lending := false) -> string {
	// design.md "Materialization": every use of one constant shares one global.
	if entry := materialization_of(e.c, expr); entry != nil {
		return entry.name
	}
	#partial switch v in expr {
	case ^Expr_Ident:
		// A default argument selecting from a parameter to its left.
		if bound, ok := e.param_values[v.symbol]; ok {
			if bound.by_address {
				return bound.operand
			}
			slot := temporary_slot(e, as_type)
			store(e, as_type, bound.operand, slot)
			return slot
		}
		return symbol_place(e, v.symbol)

	case ^Expr_Postfix:
		// `x or_return` is a value, materialised below like any other.
		if v.boxed {
			// A temporary box drops at the end of its full expression.
			return emit_box_payload_address(e, expr_base(v.operand).type, emit_borrowed_operand(e, v.operand))
		}
		// design.md "Pointers": a checked pointer is never null, so there is
		// nothing to test.
		if v.op == .Caret {
			return emit_expr(e, v.operand)
		}

	case ^Expr_Selector:
		// `pkg.name` is another package's global, not a field of the alias.
		if v.resolution.kind == .Value {
			return symbol_place(e, v.resolution.symbol)
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
			return hold_in_temporary(e, expr, as_type, emit_operator_call(e, v.resolution.symbol, v.bound))
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
		index := emit_index_below(e, v, fmt.tprintf("%d", info.count))
		out := temp(e)
		fmt.sbprintfln(
			&e.b,
			"  %s = getelementptr inbounds %s, ptr %s, i64 0, i64 %s",
			out, llvm_type(e, base_type), base_address, index,
		)
		record_field_align(e, base_type, base_address, out, info.element)
		return out

	case ^Expr_Composite:
		slot := temporary_slot_for(e, expr, as_type)
		emit_composite_into(e, v, slot, as_type)
		if lending {
			hold_addressed_temporary(e, expr, as_type, slot)
		}
		return slot

	case ^Expr_Call:
		// A single `inout` result is already the address of the returned place.
		if expr_base(expr).value_category == .Place {
			return emit_call(e, v, as_type)
		}
	}
	// Any other value is materialised into a temporary. A folded conversion like
	// `u8(3)` stores its constant, not its unconverted operand.
	return hold_in_temporary(e, expr, as_type, emit_expr_at(e, expr, as_type))
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
	// A local's value may extend it to the end of the block (design.md
	// "Temporaries and procedure boundaries").
	if expr_base(expr).extended {
		register_scope_place(e, type, place)
		return
	}
	register_temporary_place(e, type, place)
}

// An operand read by value that its operation never owns, such as a comparison
// side or a text operation's receiver. An owned managed temporary lives until
// its full expression ends, so a view into it stays valid that long.
@(private)
emit_borrowed_operand :: proc(e: ^Emitter, expr: Expr) -> string {
	value := emit_expr(e, expr)
	base := expr_base(expr)
	if base_is_const(base) || !emit_lifecycle(e, base.type).managed || expression_is_borrowed_place(expr) {
		return value
	}
	hold_in_temporary(e, expr, base.type, value)
	return value
}

// The checked i64 index of `v`, which must be below the runtime `length`.
// Unsigned, so a negative index fails the same comparison as an oversized one.
@(private = "file")
emit_index_below :: proc(e: ^Emitter, v: ^Expr_Index, length: string) -> string {
	index := checked_index_to_i64(e, emit_expr(e, v.indices[0]), expr_base(v.indices[0]).type)
	out_of_range := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp uge i64 %s, %s", out_of_range, index, length)
	panic_if(e, out_of_range, "bounds", "index out of range")
	return index
}

// `xs[i]`: an address in the current allocation, valid only as long as it is.
@(private = "file")
emit_dynamic_element_address :: proc(e: ^Emitter, v: ^Expr_Index) -> string {
	operand_type := expr_base(v.operand).type
	header := emit_address(e, v.operand, lending = true)
	data := load(e, "ptr", gep_field(e, CONTAINER_TYPE, header, CONTAINER_STORAGE))
	length := load(e, "i64", gep_field(e, CONTAINER_TYPE, header, CONTAINER_LEN))
	index := emit_index_below(e, v, length)
	return gep_at(e, llvm_type(e, container_element(e.c, operand_type)), data, index)
}

// `s[i]`: an address in the slice's root.
@(private = "file")
emit_slice_element_address :: proc(e: ^Emitter, v: ^Expr_Index) -> string {
	operand_type := expr_base(v.operand).type
	data, length := emit_slice_parts(e, v.operand)
	index := emit_index_below(e, v, length)
	return gep_at(e, llvm_type(e, slice_element(e.c, operand_type)), data, index)
}

// `p.x` and `p[i]` accept one pointer hop, whose value is the base address.
// Otherwise the operand is lent: a field or element of a temporary is a place
// in it, read by borrowing or copying, so the temporary is dropped whole.
@(private = "file")
emit_base_address :: proc(e: ^Emitter, operand: Expr) -> (Type_Id, string) {
	type := expr_base(operand).type
	info := underlying_info(e.c, type)
	if info != nil && info.kind == .Pointer {
		return info.element, emit_expr(e, operand)
	}
	return type, emit_address(e, operand, lending = true)
}

// `lo` and `hi`, each evaluated once in order, checked as
// `0 <= lo <= hi <= length` in one trap seam before any address is formed.
@(private = "file")
emit_slice_bounds :: proc(e: ^Emitter, v: ^Expr_Slice, length, message: string) -> (low, high: string) {
	low = "0"
	if v.lo != nil {
		low = checked_index_to_i64(e, emit_expr(e, v.lo), expr_base(v.lo).type)
	}
	high = length
	if v.hi != nil {
		high = checked_index_to_i64(e, emit_expr(e, v.hi), expr_base(v.hi).type)
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
		data, length = emit_slice_parts(e, v.operand)
	case .Dynamic_Array:
		value := emit_borrowed_operand(e, v.operand)
		data = extract(e, CONTAINER_TYPE, value, CONTAINER_STORAGE)
		length = extract(e, CONTAINER_TYPE, value, CONTAINER_LEN)
	case:
		data = emit_lent_address(e, v.operand, operand_type)
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
	if v.lo != nil {
		emit_code_point_bound_check(e, data, low, length)
	}
	if v.hi != nil {
		emit_code_point_bound_check(e, data, high, length)
	}
	start := gep_at(e, "i8", data, low)
	count := temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, %s", count, high, low)
	return emit_ptr_len(e, STRING_VIEW_TYPE, start, count)
}

// design.md "String views": a slice bound starts a sequence or is the end of the
// text. The text is already valid UTF-8, so the byte at the bound decides.
@(private = "file")
emit_code_point_bound_check :: proc(e: ^Emitter, data, bound, length: string) {
	inside := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ult i64 %s, %s", inside, bound, length)
	lead_label, checked_label := new_label(e, "slice.lead"), new_label(e, "slice.checked")
	branch_if(e, inside, lead_label, checked_label)
	place_label(e, lead_label)
	lead, masked, continuation := load(e, "i8", gep_at(e, "i8", data, bound)), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = and i8 %s, -64", masked, lead)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i8 %s, -128", continuation, masked)
	panic_if(e, continuation, "slice.utf8", "string slice bounds split a code point")
	branch(e, checked_label)
	place_label(e, checked_label)
}

// design.md "C pointers": `x[:]`/`x[i:]` stay unbounded C pointers; `x[:n]` and
// `x[i:n]` make a checked `[]T`, and a negative length panics (design.md "string
// type conversions").
@(private = "file")
emit_c_pointer_slice :: proc(e: ^Emitter, v: ^Expr_Slice, as_type: Type_Id) -> string {
	element := underlying_info(e.c, expr_base(v.operand).type).element
	data := emit_expr(e, v.operand)
	low := "0"
	if v.lo != nil {
		low = checked_index_to_i64(e, emit_expr(e, v.lo), expr_base(v.lo).type)
	}
	start := gep_at(e, llvm_type(e, element), data, low)
	if v.hi == nil {
		return start
	}
	high := checked_index_to_i64(e, emit_expr(e, v.hi), expr_base(v.hi).type)
	reversed, negative, bad := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", reversed, low, high)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, 0", negative, high)
	fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", bad, reversed, negative)
	panic_if(e, bad, "slice.bounds", "slice bounds out of range")
	count := temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, %s", count, high, low)
	return emit_slice_value(e, as_type, start, count)
}

// An index, slice bound or length about to be bounds-checked. A value wider than
// 64 bits that does not fit saturates to all ones, negative as an `i64` and past
// any length unsigned, instead of truncating into range (design.md "Slices").
@(private = "file")
checked_index_to_i64 :: proc(e: ^Emitter, value: string, type: Type_Id) -> string {
	bits := type_bits(e.c, type)
	if bits <= 64 {
		return widen_to_i64(e, value, type)
	}
	oversized, truncated, out := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i%d %s, 18446744073709551615", oversized, bits, value)
	fmt.sbprintfln(&e.b, "  %s = trunc i%d %s to i64", truncated, bits, value)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 -1, i64 %s", out, oversized, truncated)
	return out
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

// An operand: a literal, a `%name`, or a large value's address.
@(private)
emit_expr :: proc(e: ^Emitter, expr: Expr) -> string {
	if expr == nil {
		return "0"
	}
	return emit_expr_at(e, expr, expr_base(expr).type)
}

// `expr` at `type`, cloned when its copy site `clones`: through `allocator`,
// or through the allocator of the variable `destination` initializes, which is
// evaluated after the value. A widened union is cloned at its own type and the
// copy remapped (design.md "Widening by label"), since the wider union may
// have a move-only alternative that the smaller one lacks.
@(private)
emit_copied_expr :: proc(
	e: ^Emitter, expr: Expr, type: Type_Id, clones: bool, allocator := "", destination := INVALID_SYMBOL,
) -> string {
	if !clones {
		return emit_expr(e, expr)
	}
	from := copied_type(expr, type)
	value := from == type ? emit_expr(e, expr) : emit_expr_at(e, expr, from)
	provider := allocator
	if destination != INVALID_SYMBOL {
		provider = emit_destination_allocator(e, destination)
	}
	if emit_lifecycle(e, from).managed {
		value = emit_clone_value(e, from, value, provider)
	}
	return from == type ? value : emit_union_widen(e, value, from, type)
}

@(private = "file")
emit_move :: proc(e: ^Emitter, v: ^Expr_Move) -> string {
	value := emit_expr(e, v.value)
	if ident, is_ident := v.value.(^Expr_Ident); is_ident {
		kill_place(e, ident.symbol)
	}
	return value
}

// Addressable storage for `expr` at `as_type`. A non-addressable value gets a
// slot, and an owned temporary is dropped when its full expression ends.
@(private)
spill_viewed_at :: proc(e: ^Emitter, expr: Expr, as_type: Type_Id) -> string {
	base := expr_base(expr)
	if base.addressable {
		return emit_lent_address(e, expr, as_type)
	}
	value := emit_expr_at(e, expr, as_type)
	slot := alloca(e, llvm_type(e, as_type))
	store(e, as_type, value, slot)
	if !base_is_const(base) {
		hold_addressed_temporary(e, expr, as_type, slot)
	}
	return slot
}

// The address an erased view of `expr` holds: the place itself, or a temporary
// holding the value. A view reads its target at the type's alignment, which a
// packed place may not have (design.md "@(packed)"), so it views an aligned copy.
@(private)
emit_viewed_address :: proc(e: ^Emitter, expr: Expr, from: Type_Id) -> string {
	address := spill_viewed_at(e, expr, from)
	if align, known := e.place_align[address]; known && align < type_align(e.c, from) {
		aligned := temporary_slot(e, from)
		copy_bytes(e, aligned, address, type_size(e.c, from))
		address = aligned
	}
	return address
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

// The implicit conversion the checker recorded on `expr`'s node, when one applies
// at `as_type`.
@(private = "file")
emit_implicit_conversion :: proc(e: ^Emitter, expr: Expr, as_type: Type_Id) -> (string, bool) {
	base := expr_base(expr)
	// design.md "Widening by label": the smaller union remapped into the wider.
	if from := base.widened_from; from != INVALID_TYPE && union_widens_to(e.c, from, as_type) {
		return emit_union_widen(e, emit_expr_at(e, expr, from), from, as_type), true
	}
	// design.md "Borrowed callable views": a procedure or capture value becoming
	// a `dyn proc` view.
	if from := base.erased_from; from != INVALID_TYPE && type_is_dyn(e.c, as_type) &&
	   dyn_proc_signature(e.c, base.type) != INVALID_TYPE {
		return emit_dyn_proc_value(e, expr, from, as_type), true
	}
	// design.md "Variadic parameters": a value a `..dyn I` pack views, with the
	// witness of its type. A `dyn` value passed as it is keeps its own type and
	// is not viewed again.
	if from := base.erased_from; from != INVALID_TYPE && as_type == base.type && type_is_dyn(e.c, as_type) {
		return emit_dyn_view_value(e, emit_viewed_address(e, expr, from), from, as_type), true
	}
	if from := base.view_from; from != INVALID_TYPE {
		#partial switch underlying_kind(e.c, as_type) {
		case .String_View:
			// A `string` borrowed as a `string_view`: the owning word is dropped, and
			// addressing the source keeps an owned temporary alive. A packed field's
			// header may be byte-aligned (design.md "@(packed)").
			value := load_place(e, from, emit_lent_address(e, expr, from))
			data := extract(e, STRING_TYPE, value, STRING_DATA)
			length := extract(e, STRING_TYPE, value, STRING_LEN)
			return emit_ptr_len(e, STRING_VIEW_TYPE, data, length), true
		case .Pointer:
			// A `Box(T)` lent as the `^T` of its payload.
			if underlying_kind(e.c, from) == .Box {
				return emit_box_payload_address(e, from, load_place(e, from, emit_lent_address(e, expr, from))), true
			}
		case .Slice:
			// A `[N]T` read as a `[]T` of all its elements.
			if underlying_kind(e.c, from) == .Array {
				address := emit_lent_address(e, expr, from)
				length := fmt.tprintf("%d", underlying_info(e.c, from).count)
				return emit_slice_value(e, as_type, address, length), true
			}
			// A `[dynamic]T` read as a `[]T` of its live elements.
			value := load_place(e, from, emit_lent_address(e, expr, from))
			data := extract(e, CONTAINER_TYPE, value, CONTAINER_STORAGE)
			length := extract(e, CONTAINER_TYPE, value, CONTAINER_LEN)
			return emit_slice_value(e, as_type, data, length), true
		}
	}
	// design.md "SIMD vectors": a scalar widened to every lane.
	if from := base.splat_from; from != INVALID_TYPE && type_is_simd(e.c, as_type) {
		return emit_simd_splat(e, emit_expr_at(e, expr, from), as_type), true
	}
	return "", false
}

// Emits `expr` at `as_type`: its checked type, or the source type an implicit
// conversion recorded on this node. Children keep their own checked types.
@(private)
emit_expr_at :: proc(e: ^Emitter, expr: Expr, as_type: Type_Id) -> string {
	if converted, is_converted := emit_implicit_conversion(e, expr, as_type); is_converted {
		return converted
	}
	base := expr_base(expr)
	if base_is_const(base) && !projects_managed_literal(e, expr) {
		emit_const_len_receiver(e, expr)
		return const_operand(e, base.const_value, as_type)
	}

	switch v in expr {
	case ^Expr_Error:
		return "0"

	case ^Expr_Literal:
		return const_operand(e, v.const_value, as_type)

	case ^Expr_Ident:
		// A default argument reading a parameter to its left.
		if bound, ok := e.param_values[v.symbol]; ok {
			return bound.by_address ? load_place(e, as_type, bound.operand) : bound.operand
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
			return emit_or_return(e, v)
		}
		return load_place(e, as_type, emit_address_at(e, expr, as_type))

	case ^Expr_Propagated_Error:
		if error, ok := e.propagated_errors[v.owner]; ok {
			// The mapper's argument takes it over from here.
			finish_temporary_drop(e, error.hold)
			return error.value
		}
		backend_fail(e, "an `or_return` mapper's error has no value")
		return "0"

	case ^Expr_Selector, ^Expr_Index:
		if index, is_index := expr.(^Expr_Index); is_index {
			// A read does not insert and panics for a missing key (design.md "Maps").
			if !index.map_inserts && type_is_map(e.c, expr_base(index.operand).type) {
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

	case ^Expr_Or_Else:
		return emit_or_else(e, v)

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
	     ^Type_Poly, ^Type_Proc, ^Type_Record, ^Type_Anon_Record, ^Type_Anon_Union, ^Type_Enum, ^Type_Interface:
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

	// Each element is the unwind's to drop until the scope owns the array.
	guards := make([]Deferred, len(v.elements))
	for element, index in v.elements {
		slot := element_address(e, backing, root, index)
		value := emit_copied_expr(e, element.value, info.element, index < len(v.element_clones) && v.element_clones[index])
		store(e, info.element, value, slot)
		guards[index] = guard_built_element(e, info.element, slot)
	}
	for guard in guards {
		finish_temporary_drop(e, guard)
	}
	register_scope_place(e, backing, root)
	return emit_slice_value(e, as_type, root, fmt.aprintf("%d", len(v.elements)))
}

@(private = "file")
emit_composite_into :: proc(e: ^Emitter, v: ^Expr_Composite, address: string, as_type: Type_Id) {
	// Start from the zero value so an omitted field is not left undefined.
	zero, ok := llvm_zero(e, as_type)
	if ok {
		store(e, as_type, zero, address)
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
		emit_map_literal_into(e, v, address, info.element, as_type)
		return
	}
	// design.md "What the unwind runs, and what it does not": a part is the
	// unwind's to drop from when it is stored until the literal is complete, so
	// a later element that panics releases exactly the parts already built.
	guards := make([dynamic]Deferred)
	defer delete(guards)
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
		value := emit_copied_expr(e, element.value, element_type, index < len(v.element_clones) && v.element_clones[index])
		// A designated index range stores one evaluation in every slot; each
		// slot after the first owns a copy.
		end := slot + 1
		if info.kind == .Array {
			slot, end = composite_element_slots(v, index)
		}
		for target in slot ..< end {
			stored := value
			if target > slot && emit_lifecycle(e, element_type).managed {
				stored = emit_clone_value(e, element_type, value)
			}
			field_address := gep_field(e, llvm_type(e, as_type), address, target)
			record_field_align(e, as_type, address, field_address, element_type)
			store(e, element_type, stored, field_address)
			if info.kind == .Struct {
				append(&guards, guard_record_part(e, as_type, address, target))
			} else {
				append(&guards, guard_built_element(e, element_type, field_address))
			}
		}
	}
	for guard in guards {
		finish_temporary_drop(e, guard)
	}
}

@(private = "file")
emit_unary :: proc(e: ^Emitter, v: ^Expr_Unary, as_type: Type_Id) -> string {
	if v.op == .Amp {
		if expression_converts_storage(v.operand) {
			return emit_address(e, v.operand)
		}
		return emit_lent_address(e, v.operand, expr_base(v.operand).type)
	}
	if v.resolution.kind == .User_Operator {
		operands := [1]Expr{v.operand}
		return emit_operator_call(e, v.resolution.symbol, operands[:])
	}
	return emit_unary_op(e, v.op, as_type, emit_expr(e, v.operand))
}

// A unary operation on an evaluated operand of `type`, lane-wise on a vector; a
// delegated operator applies it to the unwrapped value too.
emit_unary_op :: proc(e: ^Emitter, op: Token_Kind, type: Type_Id, operand: string) -> string {
	llvm := llvm_type(e, type)
	info := underlying_info(e.c, type)
	vector := info.kind == .Simd
	out := temp(e)
	#partial switch op {
	case .Plus:
		return operand
	case .Minus:
		if type_is_float(e.c, vector ? info.element : type) {
			fmt.sbprintfln(&e.b, "  %s = fneg %s %s", out, llvm, operand)
		} else if vector {
			return emit_simd_checked(e, .Minus, info, llvm, "zeroinitializer", operand)
		} else {
			return emit_checked_integer(e, .Minus, type_signed(e.c, type), llvm, "0", operand)
		}
	case .Tilde:
		fmt.sbprintfln(&e.b, "  %s = xor %s %s, %s", out, llvm, operand, vector ? simd_all_ones(e, info) : "-1")
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
		if info := type_of(e.c, expr_base(v.rhs).type); info != nil && info.is_range {
			return emit_range_membership(e, v)
		}
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
	return emit_text_concat_parts(e, left_data, left_len, right_data, right_len)
}

// Two evaluated operands of one text `type`, as a delegated `+` has them.
@(private)
emit_text_concat_values :: proc(e: ^Emitter, type: Type_Id, lhs, rhs: string) -> string {
	storage := llvm_type(e, type)
	return emit_text_concat_parts(
		e,
		extract(e, storage, lhs, STRING_DATA), extract(e, storage, lhs, STRING_LEN),
		extract(e, storage, rhs, STRING_DATA), extract(e, storage, rhs, STRING_LEN),
	)
}

@(private = "file")
emit_text_concat_parts :: proc(e: ^Emitter, left_data, left_len, right_data, right_len: string) -> string {
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

// A checked integer `+`, `-`, or `*` and an integer `/` or `%` have lowerings of
// their own, and a float has no bitwise operators.
Arith_Mnemonic :: struct {
	integer, float: string,
}

arith_mnemonic :: proc(op: Token_Kind) -> Arith_Mnemonic {
	#partial switch op {
	case .Plus:       return {"",    "fadd"}
	case .Minus:      return {"",    "fsub"}
	case .Star:       return {"",    "fmul"}
	case .Slash:      return {"",    "fdiv"}
	case .Plus_Wrap:  return {"add", ""}
	case .Minus_Wrap: return {"sub", ""}
	case .Star_Wrap:  return {"mul", ""}
	case .Amp:        return {"and", ""}
	case .Pipe:       return {"or",  ""}
	case .Tilde:      return {"xor", ""}
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

	signed := type_signed(e.c, type)
	#partial switch op {
	case .Plus, .Minus, .Star:
		return emit_checked_integer(e, op, signed, llvm, lhs, rhs)
	case .Slash, .Percent:
		return emit_divrem(e, op, scalar_int_form(e, type), lhs, rhs)
	case .Shl, .Shr:
		return emit_shift(e, op, scalar_int_form(e, type), scalar_int_form(e, rhs_type), lhs, rhs)
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

// design.md "Integer overflow": a `+`, `-`, or `*` result that does not fit its
// integer type panics.
emit_checked_integer :: proc(e: ^Emitter, op: Token_Kind, signed: bool, llvm, lhs, rhs: string) -> string {
	wrapped, overflowed := emit_overflow_call(e, checked_intrinsic(op, signed, llvm), llvm, "i1", lhs, rhs)
	panic_if(e, overflowed, "int.overflow", overflow_message(signed))
	return wrapped
}

// A `*.with.overflow` intrinsic answers the wrapped value and whether it wrapped,
// the latter in a `flag` of `i1` or `<N x i1>`.
emit_overflow_call :: proc(e: ^Emitter, key, llvm, flag, lhs, rhs: string) -> (wrapped, overflowed: string) {
	pair_type := strings.concatenate({"{ ", llvm, ", ", flag, " }"})
	pair := temp(e)
	fmt.sbprintfln(&e.b, "  %s = call %s @%s(%s %s, %s %s)", pair, pair_type, key, llvm, lhs, llvm, rhs)
	return extract(e, pair_type, pair, 0), extract(e, pair_type, pair, 1)
}

// The intrinsic's name, with `suffix` the mangling of its operand type.
checked_intrinsic :: proc(op: Token_Kind, signed: bool, suffix: string) -> string {
	operation := signed ? "smul" : "umul"
	#partial switch op {
	case .Plus:  operation = signed ? "sadd" : "uadd"
	case .Minus: operation = signed ? "ssub" : "usub"
	}
	return strings.concatenate({"llvm.", operation, ".with.overflow.", suffix})
}

overflow_message :: proc(signed: bool) -> string {
	return signed ? "signed integer overflow" : "unsigned integer overflow"
}

// What `emit_divrem` and `emit_shift` lower over: one integer, or a vector's lanes,
// where `mask` is the comparison type and `lanes` the vector's type. Over lanes, a
// failing lane panics the whole operation (design.md "Lane-wise operators").
@(private)
Int_Form :: struct {
	llvm, mask: string,
	bits:       int,
	signed:     bool,
	lanes:      ^Type_Info,
}

@(private = "file")
scalar_int_form :: proc(e: ^Emitter, type: Type_Id) -> Int_Form {
	return Int_Form {
		llvm = llvm_type(e, type),
		mask = "i1",
		bits = type_bits(e.c, type),
		signed = type_signed(e.c, type),
	}
}

@(private = "file")
form_const :: proc(e: ^Emitter, form: Int_Form, value: string) -> string {
	return form.lanes == nil ? value : simd_repeated(e, form.lanes, value)
}

@(private = "file")
form_zero :: proc(form: Int_Form) -> string {
	return form.lanes == nil ? "0" : "zeroinitializer"
}

// The `i1` a `panic_if` tests: whether any lane of `mask` is set.
@(private = "file")
form_any :: proc(e: ^Emitter, form: Int_Form, mask: string) -> string {
	return form.lanes == nil ? mask : simd_any_lane(e, form.lanes, mask)
}

@(private = "file")
form_select :: proc(e: ^Emitter, form: Int_Form, condition, if_true, if_false: string) -> string {
	out := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = select %s %s, %s %s, %s %s", out, form.mask, condition, form.llvm, if_true, form.llvm, if_false,
	)
	return out
}

// Zero takes the trap seam. `MIN / -1` does not fit, so it panics as any signed
// overflow does, and `MIN % -1` is 0 (design.md "Integer operators"); neither
// reaches `sdiv`/`srem`, where it would be poison.
@(private)
emit_divrem :: proc(e: ^Emitter, op: Token_Kind, form: Int_Form, lhs, rhs: string) -> string {
	llvm := form.llvm

	is_zero := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", is_zero, llvm, rhs, form_zero(form))
	panic_if(e, form_any(e, form, is_zero), "div.zero", "integer division by zero")

	if !form.signed {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", out, op == .Slash ? "udiv" : "urem", llvm, lhs, rhs)
		return out
	}

	minimum := form_const(e, form, bi_text(e.c, bi_neg(e.c, bi_pow2(e.c, form.bits - 1))))
	is_min := temp(e)
	is_neg_one := temp(e)
	is_overflow := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", is_min, llvm, lhs, minimum)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", is_neg_one, llvm, rhs, form_const(e, form, "-1"))
	fmt.sbprintfln(&e.b, "  %s = and %s %s, %s", is_overflow, form.mask, is_min, is_neg_one)
	if op == .Slash {
		panic_if(e, form_any(e, form, is_overflow), "int.overflow", "signed integer overflow")
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = sdiv %s %s, %s", out, llvm, lhs, rhs)
		return out
	}
	// `MIN % -1` is 0, and so is `MIN % 1`, which `srem` defines.
	divisor := form_select(e, form, is_overflow, form_const(e, form, "1"), rhs)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = srem %s %s, %s", out, llvm, lhs, divisor)
	return out
}

// design.md "Arithmetic operators": a negative count panics, and a count at or
// beyond the width is defined (zero, or the sign bit for an arithmetic right
// shift), so none reaches an LLVM shift as poison. A vector's count has its form.
@(private)
emit_shift :: proc(e: ^Emitter, op: Token_Kind, form, count_form: Int_Form, lhs, rhs: string) -> string {
	llvm := form.llvm
	count_llvm := count_form.llvm

	if count_form.signed {
		negative := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp slt %s %s, %s", negative, count_llvm, rhs, form_zero(count_form))
		panic_if(e, form_any(e, count_form, negative), "shift.negative", "negative shift count")
	}

	// Compared in the count's own width, before truncation could hide its size.
	oversized := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = icmp uge %s %s, %s", oversized, count_llvm, rhs,
		form_const(e, count_form, fmt.aprintf("%d", form.bits)),
	)

	count := rhs
	if count_form.bits != form.bits {
		converted := temp(e)
		operation := count_form.bits > form.bits ? "trunc" : "zext"
		fmt.sbprintfln(&e.b, "  %s = %s %s %s to %s", converted, operation, count_llvm, rhs, llvm)
		count = converted
	}

	if op == .Shr && form.signed {
		clamped := form_select(e, form, oversized, form_const(e, form, fmt.aprintf("%d", form.bits - 1)), count)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = ashr %s %s, %s", out, llvm, lhs, clamped)
		return out
	}

	safe := form_select(e, form, oversized, form_zero(form), count)
	raw := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", raw, op == .Shl ? "shl" : "lshr", llvm, lhs, safe)
	return form_select(e, form, oversized, form_zero(form), raw)
}

// ------------------------------------------------- comparison and equality --

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

// The instruction and predicate that compare values of scalar `type`, such as
// `icmp slt`.
compare_instruction :: proc(e: ^Emitter, op: Token_Kind, type: Type_Id) -> string {
	predicate := compare_predicate(op)
	if type_is_float(e.c, type) {
		return strings.concatenate({"fcmp ", predicate.float})
	}
	return strings.concatenate({"icmp ", type_signed(e.c, type) ? predicate.signed : predicate.unsigned})
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
	if op != .Eq_Eq && op != .Not_Eq && underlying_kind(e.c, type) == .Struct {
		return emit_record_order(e, op, type, lhs, rhs)
	}
	if type_is_aggregate(e.c, type) || type_is_union(e.c, type) {
		equal := emit_equal(e, type, lhs, rhs)
		if op == .Eq_Eq {
			return equal
		}
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", out, equal)
		return out
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", out, compare_instruction(e, op, type), llvm_type(e, type), lhs, rhs)
	return out
}

// design.md "Comparison operators": an anonymous record orders by its first
// unequal field, under that field's `<` with the operands swapped for `>` and
// `>=`; equal records answer `<=` and `>=`. Built from the last field back, so
// each field's answer selects between its own `<` and the fields after it.
//
// ponytail: every field is compared, as `emit_equal` does, rather than
// branching at the first difference.
@(private = "file")
emit_record_order :: proc(e: ^Emitter, op: Token_Kind, type: Type_Id, lhs, rhs: string) -> string {
	under := type_underlying(e.c, type)
	info := type_of(e.c, under)
	swapped := op == .Gt || op == .Gt_Eq
	result := op == .Lt_Eq || op == .Gt_Eq ? "true" : "false"
	for index := len(info.fields) - 1; index >= 0; index -= 1 {
		field := symbol_of(e.c, info.fields[index]).type
		left := record_part(e, under, lhs, index)
		right := record_part(e, under, rhs, index)
		if swapped {
			left, right = right, left
		}
		equal := emit_equal(e, field, left, right)
		less := emit_compare(e, .Lt, field, left, right)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 %s, i1 %s", out, equal, result, less)
		result = out
	}
	return result
}

// Structural equality, since LLVM has no aggregate `icmp`.
//
// ponytail: one flat `and` chain rather than short-circuiting blocks; every
// leaf is a pure extract plus compare.
@(private)
emit_equal :: proc(e: ^Emitter, type: Type_Id, lhs, rhs: string) -> string {
	if equal := type_own_equality(e.c, type); equal != INVALID_SYMBOL {
		return emit_own_equal(e, equal, type, lhs, rhs)
	}
	under := type_underlying(e.c, type)
	info := type_of(e.c, under)
	if info == nil {
		return "true"
	}
	#partial switch info.kind {
	case .Union:
		return emit_union_equal(e, under, lhs, rhs)
	case .Array:
		return emit_array_equal(e, under, info, lhs, rhs)
	case .Struct:
		if record_uses_byte_members(e, under, info) {
			return emit_byte_member_struct_equal(e, under, info, lhs, rhs)
		}
		return emit_fields_equal(e, under, info, lhs, rhs, record_part)
	}
	return emit_compare(e, .Eq_Eq, type, lhs, rhs)
}

// Both operands in memory: a large value is already an address, and a small one
// is spilled.
@(private = "file")
spill_equal_operands :: proc(e: ^Emitter, type: Type_Id, lhs, rhs: string) -> (left, right: string) {
	if is_large_value(e, type) {
		return lhs, rhs
	}
	left, right = alloca(e, llvm_type(e, type)), alloca(e, llvm_type(e, type))
	store(e, type, lhs, left)
	store(e, type, rhs, right)
	return left, right
}

// design.md "Comparison operators": a part with its own `==` is compared by it.
@(private = "file")
emit_own_equal :: proc(e: ^Emitter, equal: Symbol_Id, type: Type_Id, lhs, rhs: string) -> string {
	left, right := spill_equal_operands(e, type, lhs, rhs)
	out := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i1 %s(%s, %s)", out, callee_name(e, equal),
		hook_argument(e, equal, 0, type, left), hook_argument(e, equal, 1, type, right),
	)
	return out
}

// An array bigger than either limit compares in a loop, since unrolling takes
// about four instructions per element.
@(private = "file")
UNROLLED_EQUAL_ELEMENTS :: 8
@(private = "file")
UNROLLED_EQUAL_BYTES :: 64

@(private = "file")
emit_array_equal :: proc(e: ^Emitter, type: Type_Id, info: ^Type_Info, lhs, rhs: string) -> string {
	if info.count > UNROLLED_EQUAL_ELEMENTS || type_size(e.c, type) > UNROLLED_EQUAL_BYTES {
		left, right := spill_equal_operands(e, type, lhs, rhs)
		return emit_elements_equal(e, info.element, left, right, fmt.tprintf("%d", info.count))
	}
	llvm := llvm_type(e, type)
	result := "true"
	for index in 0 ..< int(info.count) {
		left := extract(e, llvm, lhs, index)
		right := extract(e, llvm, rhs, index)
		result = combine_and(e, result, emit_equal(e, info.element, left, right))
	}
	return result
}

// Whether the `count` elements at `left` and `right` are equal. Every element is
// compared, as `emit_equal` compares every field.
@(private = "file")
emit_elements_equal :: proc(e: ^Emitter, element: Type_Id, left, right, count: string) -> string {
	element_llvm := llvm_type(e, element)
	same := alloca(e, "i1")
	fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", same)
	loop := open_counted_loop(e, new_counter(e), "equal", count)
	one := load_temporary(e, element, gep_at(e, element_llvm, left, loop.index))
	other := load_temporary(e, element, gep_at(e, element_llvm, right, loop.index))
	leaf := emit_equal(e, element, one, other)
	fmt.sbprintfln(&e.b, "  store i1 %s, ptr %s", combine_and(e, load(e, "i1", same), leaf), same)
	close_counted_loop(e, loop)
	return load(e, "i1", same)
}

// design.md "Uninitialized capacity": only the live prefix is compared. Unequal
// counts already differ through the count field, and the loop stops at the
// shorter one, so neither side's capacity is ever read.
@(private = "file")
emit_prefix_equal :: proc(
	e: ^Emitter, counter: ^Symbol, array: Type_Id, raw_left, raw_right, left, right: string,
) -> string {
	count_left := widen_to_i64(e, raw_left, counter.type)
	count_right := widen_to_i64(e, raw_right, counter.type)
	emit_prefix_count_check(e, count_left, array)
	emit_prefix_count_check(e, count_right, array)
	shorter, total := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %s", shorter, count_left, count_right)
	fmt.sbprintfln(
		&e.b, "  %s = select i1 %s, i64 %s, i64 %s", total, shorter, count_left, count_right,
	)
	left_slot, right_slot := spill_equal_operands(e, array, left, right)
	return emit_elements_equal(e, underlying_info(e.c, array).element, left_slot, right_slot, total)
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

// Field-wise equality, with each field read by `read`. An `@(initialized)` array
// compares only its live prefix.
@(private = "file")
emit_fields_equal :: proc(
	e: ^Emitter, record: Type_Id, info: ^Type_Info, lhs, rhs: string,
	read: proc(e: ^Emitter, record: Type_Id, value: string, index: int) -> string,
) -> string {
	result := "true"
	for field, index in info.fields {
		symbol := symbol_of(e.c, field)
		left := read(e, record, lhs, index)
		right := read(e, record, rhs, index)
		leaf := ""
		if counter := symbol_of(e.c, symbol.initialized_by); counter != nil {
			count := int(counter.index)
			leaf = emit_prefix_equal(e, counter, symbol.type, read(e, record, lhs, count), read(e, record, rhs, count), left, right)
		} else {
			leaf = emit_equal(e, symbol.type, left, right)
		}
		result = combine_and(e, result, leaf)
	}
	return result
}

// A field of a byte-member record in storage, loaded at its own type through the
// GEP its byte member occupies, at the alignment that member guarantees.
@(private = "file")
byte_member_part :: proc(e: ^Emitter, record: Type_Id, slot: string, index: int) -> string {
	address := element_address(e, record, slot, index)
	return load_place(e, symbol_of(e.c, underlying_info(e.c, record).fields[index]).type, address)
}

@(private = "file")
emit_byte_member_struct_equal :: proc(e: ^Emitter, type: Type_Id, info: ^Type_Info, lhs, rhs: string) -> string {
	left, right := spill_equal_operands(e, type, lhs, rhs)
	return emit_fields_equal(e, type, info, left, right, byte_member_part)
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

// ---------------------------------------------------- branching expressions --

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
	begin_conditional(e)
	rhs := emit_expr(e, v.rhs)
	end_conditional(e)
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

// One arm of a conditional, ending in a block of its own for the phi to name.
@(private = "file")
emit_cond_arm :: proc(
	e: ^Emitter, label, exit_prefix: string, arm: Expr, as_type: Type_Id, clones: bool, joined, done: string,
) -> (value, exit: string) {
	place_label(e, label)
	begin_conditional(e)
	value = emit_copied_expr(e, arm, as_type, clones)
	end_conditional(e)
	if joined != "" {
		store(e, as_type, value, joined)
	}
	exit = new_label(e, exit_prefix)
	branch(e, exit)
	place_label(e, exit)
	branch(e, done)
	return value, exit
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

	then_value, then_exit := emit_cond_arm(e, then_label, "cond.then.exit", v.then, as_type, v.then_clone, joined, done_label)
	else_value, else_exit := emit_cond_arm(e, else_label, "cond.else.exit", v.otherwise, as_type, v.else_clone, joined, done_label)

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
emit_union_failed :: proc(e: ^Emitter, union_type: Type_Id, value: string) -> string {
	shape, _ := fallible_of(e.c, union_type)
	return emit_union_tag_is(e, union_type, value, shape.failure)
}

@(private = "file")
emit_failure_conversion :: proc(e: ^Emitter, value: string, from, into: Type_Id) -> string {
	if from == into {
		return value
	}
	if underlying_kind(e.c, from) == .String && underlying_kind(e.c, into) == .String_View {
		data := extract(e, STRING_TYPE, value, STRING_DATA)
		length := extract(e, STRING_TYPE, value, STRING_LEN)
		return emit_ptr_len(e, STRING_VIEW_TYPE, data, length)
	}
	// design.md "Widening by label": a smaller error set propagates into a
	// larger one.
	if union_widens_to(e.c, from, into) {
		return emit_union_widen(e, value, from, into)
	}
	// Carrier weakening, procedure escape weakening, checked/C-pointer
	// interchange, and pointer-to-rawptr all share one backend representation.
	return value
}

// A failure path's exit statement, whose temporaries are made only on this path.
@(private = "file")
emit_conditional_exit :: proc(e: ^Emitter, exit: Stmt) {
	begin_conditional(e)
	emit_stmt(e, exit)
	end_conditional(e)
	if !e.terminated {
		fmt.sbprintln(&e.b, "  unreachable")
		e.terminated = true
	}
}

// The fallback is evaluated only for the failure variant.
@(private = "file")
emit_or_else :: proc(e: ^Emitter, v: ^Expr_Or_Else) -> string {
	operand_type := type_underlying(e.c, expr_base(v.value).type)
	shape, _ := fallible_of(e.c, operand_type)
	// A success that carries nothing yields `Unit`.
	unit := shape.success_type == TYPE_VOID
	payload_type := payload_value_type(e.c, shape.success_type)

	value := emit_expr(e, v.value)
	slot := emit_union_spill(e, operand_type, value)
	failed := emit_union_failed(e, operand_type, value)
	joined := temporary_slot(e, payload_type)
	success_label := new_label(e, "orelse.success")
	fallback_label := new_label(e, "orelse.fallback")
	done := new_label(e, "orelse.done")
	branch_if(e, failed, fallback_label, success_label)

	place_label(e, success_label)
	taken := "zeroinitializer"
	if !unit {
		taken = emit_union_payload(e, operand_type, payload_type, slot)
	}
	if v.borrows && emit_lifecycle(e, payload_type).managed {
		taken = emit_clone_value(e, payload_type, taken)
	}
	store(e, payload_type, taken, joined)
	branch(e, done)

	place_label(e, fallback_label)
	// design.md: `or_else` never copies the error, so a managed failure payload of
	// a *temporary* is dropped here, before the fallback runs, since the operand's
	// value is discarded on this path. A place still owns its own.
	if !v.borrows && emit_lifecycle(e, shape.failure_type).managed {
		emit_drop_place(e, shape.failure_type, gep_field(e, llvm_type(e, operand_type), slot, 0))
	}
	// design.md "or_else expression": an exit leaves here, and only the success
	// arm reaches the rest of the expression.
	if v.exit != nil {
		emit_conditional_exit(e, v.exit)
	} else {
		begin_conditional(e)
		fallback := emit_copied_expr(e, v.fallback, payload_type, v.fallback_clone)
		end_conditional(e)
		store(e, payload_type, fallback, joined)
		branch(e, done)
	}

	place_label(e, done)
	return load_temporary(e, payload_type, joined)
}

// Rewraps a failure and exits through the ordinary epilogue.
@(private = "file")
emit_or_return :: proc(e: ^Emitter, v: ^Expr_Postfix) -> string {
	operand_type := type_underlying(e.c, expr_base(v.operand).type)
	shape, _ := fallible_of(e.c, operand_type)
	operand_address := ""
	value := ""
	if v.borrows {
		// A place is evaluated once and retained as an address.
		operand_address = emit_address(e, v.operand)
		value = load_place(e, operand_type, operand_address)
	} else {
		value = emit_expr(e, v.operand)
	}
	slot := emit_union_spill(e, operand_type, value)
	failed := emit_union_failed(e, operand_type, value)

	fail_label := new_label(e, "orreturn.fail")
	ok_label := new_label(e, "orreturn.ok")
	branch_if(e, failed, fail_label, ok_label)

	place_label(e, fail_label)
	if v.failure_exit != nil {
		// design.md "or_return operator": the failure operand runs only here. A
		// mapper takes the error, copied out of a place; a replacement leaves a
		// place's error where it is and drops a temporary's first, as `or_else`
		// does.
		failure_type := shape.failure_type
		if v.failure_maps {
			error := emit_union_payload(e, operand_type, failure_type, slot)
			if v.borrows && emit_lifecycle(e, failure_type).managed {
				error = emit_clone_value(e, failure_type, error)
			}
			// Held until the mapper takes it, so an exit or a panic while the
			// mapper is selected still drops it.
			e.propagated_errors[v] = {error, hold_temporary_value(e, failure_type, error)}
		} else if !v.borrows && failure_type != TYPE_VOID && emit_lifecycle(e, failure_type).managed {
			emit_drop_place(e, failure_type, gep_field(e, llvm_type(e, operand_type), slot, 0))
		}
		emit_conditional_exit(e, v.failure_exit)
	} else {
		target, _ := fallible_of(e.c, e.result_type)
		error := ""
		if failure_type := shape.failure_type; failure_type != TYPE_VOID {
			error = emit_union_payload(e, operand_type, failure_type, slot)
			failure_into := target.failure_type
			if v.borrows && emit_lifecycle(e, failure_type).managed &&
			   !failure_assignment_borrows(e.c, failure_type, failure_into) {
				error = emit_clone_value(e, failure_type, error)
			}
			error = emit_failure_conversion(e, error, failure_type, failure_into)
		}
		wrapped := emit_union_value(e, e.result_type, target.failure, error)
		store(e, e.result_type, wrapped, e.result_slot)
		emit_epilogue(e)
	}

	place_label(e, ok_label)
	if shape.success_type == TYPE_VOID {
		return "zeroinitializer"
	}
	out := emit_union_payload(e, operand_type, shape.success_type, slot)
	if v.borrows && emit_lifecycle(e, shape.success_type).managed {
		out = emit_clone_value(e, shape.success_type, out)
	}
	return out
}

// -------------------------------------------------------- slices and text --

@(private)
emit_ptr_len :: proc(e: ^Emitter, storage, data, length: string) -> string {
	first := insert(e, storage, "undef", "ptr", data, SLICE_DATA)
	out := insert(e, storage, first, "i64", length, SLICE_LEN)
	return out
}

@(private)
ptr_len_parts :: proc(e: ^Emitter, storage, value: string) -> (data: string, length: string) {
	return extract(e, storage, value, SLICE_DATA), extract(e, storage, value, SLICE_LEN)
}

@(private)
emit_slice_value :: proc(e: ^Emitter, slice_type: Type_Id, data, length: string) -> string {
	return emit_ptr_len(e, llvm_type(e, slice_type), data, length)
}

@(private = "file")
emit_slice_parts :: proc(e: ^Emitter, operand: Expr) -> (data: string, length: string) {
	storage := llvm_type(e, expr_base(operand).type)
	value := emit_expr(e, operand)
	return ptr_len_parts(e, storage, value)
}

// The data pointer and byte length of a text operand.
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
	return extract(e, storage, value, STRING_DATA), extract(e, storage, value, STRING_LEN)
}

@(private)
emit_text_operation :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	out := "0"
	switch v.operation.(Call_Text).op {
	case .None:
		backend_fail(e, "a text call has no operation")

	case .Byte_Len:
		_, length := emit_text_parts(e, v.bound[0])
		out = length

	case .Rune_Count:
		data, length := emit_text_parts(e, v.bound[0])
		out = temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i64 @loke_rt_v1_rune_count(ptr %s, i64 %s)", out, data, length)

	case .Bytes:
		// A read-only `[]u8` over the same storage.
		data, length := emit_text_parts(e, v.bound[0])
		out = emit_slice_value(e, as_type, data, length)

	case .Runes:
		// The same borrow as `bytes()`, viewed as text (design.md "String iteration").
		data, length := emit_text_parts(e, v.bound[0])
		out = emit_ptr_len(e, STRING_VIEW_TYPE, data, length)

	case .Rune_Offsets:
		// The view holds the bytes; the cursor belongs to its iterator.
		data, length := emit_text_parts(e, v.bound[0])
		view := emit_ptr_len(e, STRING_VIEW_TYPE, data, length)
		out = insert(e, llvm_type(e, as_type), "undef", STRING_VIEW_TYPE, view, VIEW_SOURCE)

	case .Copy:
		data, length := emit_text_parts(e, v.bound[0])
		provider := emit_default_allocator(e)
		out = emit_text_allocating_call(
			e, "loke_rt_v1_string_clone",
			fmt.aprintf("ptr %s, i64 %s, ptr %s", data, length, provider),
			provider,
		)

	case .To_C_View:
		// design.md "C string views": every `string` buffer and literal carries a
		// terminator, so the view is the string's own data, borrowed like `bytes()`.
		// The empty string has no buffer, and C needs a pointer to read.
		data, _ := emit_text_parts(e, v.bound[0])
		missing := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", missing, data)
		out = temp(e)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, ptr %s, ptr %s", out, missing, text_literal_global(e, ""), data)

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
		out = load(e, CONTAINER_TYPE, slot)

	}
	return out
}

// An implicit allocation has nowhere to report failure, so a zero `status`
// applies the provider's own policy (design.md "Allocation failure").
@(private = "file")
emit_alloc_check :: proc(e: ^Emitter, status, provider: string) {
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, status)
	alloc_failed_if(e, failed, provider, "text.failed")
}

// A runtime call that fills a `string` out-parameter and answers 1 on success.
// Pointers and integers only, so C and LLVM cannot disagree on returning a
// 24-byte aggregate.
@(private = "file")
emit_text_call_slot :: proc(e: ^Emitter, callee: string, arguments: string) -> (slot: string, ok: string) {
	slot = alloca(e, STRING_TYPE)
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
emit_text_optional_ok :: proc(e: ^Emitter, option: Type_Id, callee, arguments: string) -> string {
	slot, ok := emit_text_call_slot(e, callee, arguments)
	value, valid := load(e, STRING_TYPE, slot), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", valid, ok)
	return emit_option_value(e, option, valid, value)
}

// `Option(string_view)` over bytes that are borrowed, not copied: `.some` only
// when they are valid UTF-8.
@(private = "file")
emit_checked_view :: proc(e: ^Emitter, option: Type_Id, data, length: string) -> string {
	valid, ok := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = call i32 @loke_rt_v1_utf8_valid(ptr %s, i64 %s)", valid, data, length)
	fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", ok, valid)
	kept_data, kept_len := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, ptr %s, ptr null", kept_data, ok, data)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 %s, i64 0", kept_len, ok, length)
	view := emit_ptr_len(e, STRING_VIEW_TYPE, kept_data, kept_len)
	return emit_option_value(e, option, ok, view)
}

// `strings.allocate_string(text, allocator)`: `.copy()` into the caller's
// allocator, reporting failure instead of applying its policy. The header
// records the allocator, so release returns the block to it.
@(private)
emit_strings_allocate :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	data, length := emit_text_parts(e, v.bound[0])
	allocator := emit_expr(e, v.bound[1])
	slot, ok := emit_text_call_slot(
		e, "loke_rt_v1_string_clone", fmt.aprintf("ptr %s, i64 %s, ptr %s", data, length, allocator),
	)
	copied := load(e, STRING_TYPE, slot)
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, ok)
	return emit_alloc_result(e, as_type, failed, copied)
}

@(private = "file")
emit_string_from_bytes :: proc(e: ^Emitter, option: Type_Id, data, length: string) -> string {
	return emit_text_optional_ok(
		e, option, "loke_rt_v1_string_from_bytes",
		fmt.aprintf("ptr %s, i64 %s, ptr %s", data, length, emit_default_allocator(e)),
	)
}

// design.md "string type conversions": each validates and returns `Option(T)`.
@(private)
emit_text_conversion :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	switch v.operation.(Call_Text_Conversion).op {
	case .String_From_Bytes:
		data, length := emit_slice_parts(e, v.bound[0])
		return emit_string_from_bytes(e, as_type, data, length)

	case .View_From_Bytes:
		// A borrow of the slice's root, which `src/borrow.odin` keeps alive.
		data, length := emit_slice_parts(e, v.bound[0])
		return emit_checked_view(e, as_type, data, length)

	case .C_View_From_Bytes:
		// Also a borrow of the slice's root. C reads to the first zero, so a
		// zero last byte keeps every read inside the slice.
		data, length := emit_slice_parts(e, v.bound[0])
		terminated := alloca(e, "i1")
		fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", terminated)
		nonempty := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp sgt i64 %s, 0", nonempty, length)
		check, done := new_label(e, "cview.check"), new_label(e, "cview.done")
		branch_if(e, nonempty, check, done)
		place_label(e, check)
		last := temp(e)
		fmt.sbprintfln(&e.b, "  %s = sub i64 %s, 1", last, length)
		zero := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq i8 %s, 0", zero, load(e, "i8", gep_at(e, "i8", data, last)))
		fmt.sbprintfln(&e.b, "  store i1 %s, ptr %s", zero, terminated)
		branch(e, done)
		place_label(e, done)
		ok, kept := load(e, "i1", terminated), temp(e)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, ptr %s, ptr null", kept, ok, data)
		return emit_option_value(e, as_type, ok, kept)

	case .String_From_C_View:
		data, length := emit_text_parts(e, v.bound[0])
		return emit_string_from_bytes(e, as_type, data, length)

	case .String_From_Runes:
		data, count := emit_slice_parts(e, v.bound[0])
		return emit_text_optional_ok(
			e, as_type, "loke_rt_v1_string_from_runes",
			fmt.aprintf("ptr %s, i64 %s, ptr %s", data, count, emit_default_allocator(e)),
		)
	}
	backend_fail(e, "an unclassified text conversion reached emission")
	return "zeroinitializer"
}

// ------------------------------------------------------ unsafe operations --

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
		// Bit 0 is the `bool`; a valid pattern is the caller's obligation
		// (design.md "Invalid representations").
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
	out := temp(e)
	switch {
	case pointer_shaped(e.c, source) && to[0] == 'i':
		fmt.sbprintfln(&e.b, "  %s = ptrtoint %s %s to %s", out, from, value, to)
	case pointer_shaped(e.c, target) && from[0] == 'i':
		fmt.sbprintfln(&e.b, "  %s = inttoptr %s %s to %s", out, from, value, to)
	case is_large_value(e, target):
		// Both sides are addresses; the copy is aligned for `target`.
		slot := temporary_slot(e, target)
		copy_bytes(e, slot, value, type_size(e.c, target))
		return slot
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
emit_unsafe_builtin :: proc(e: ^Emitter, v: ^Expr_Call, kind: Builtin_Kind, as_type: Type_Id) -> string {
	out := "null"
	operand_kind := underlying_kind(e.c, expr_base(v.bound[0]).type)
	#partial switch kind {
	case .Unsafe_Raw_Data:
		#partial switch operand_kind {
		case .Slice:
			data, _ := emit_slice_parts(e, v.bound[0])
			out = data
		case .String, .String_View:
			data, _ := emit_text_parts(e, v.bound[0])
			out = data
		case .Dynamic_Array:
			// The current allocation's first element; nothing keeps it current.
			out = extract(e, CONTAINER_TYPE, emit_borrowed_operand(e, v.bound[0]), CONTAINER_STORAGE)
		case:
			// A pointer to a fixed array, or a `cstring_view`, is already the address.
			out = emit_expr(e, v.bound[0])
		}

	case .Unsafe_C_String_View:
		out = emit_expr(e, v.bound[0])
		guard_null_reference(e, out, expr_base(v.bound[0]).type, TYPE_CSTRING_VIEW)

	case .Unsafe_String_View:
		// design.md "string type conversions": a negative length is a bounds
		// error, as in `pointer[0:length]`, not input to report.
		data := emit_expr(e, v.bound[0])
		length := checked_index_to_i64(e, emit_expr(e, v.bound[1]), expr_base(v.bound[1]).type)
		negative := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, 0", negative, length)
		panic_if(e, negative, "slice.bounds", "slice bounds out of range")
		return emit_checked_view(e, as_type, data, length)
	}
	return out
}
