// Constants: LLVM constant spelling, byte images, and the private globals that
// hold constants, slice literals and large zeros.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:slice"
import "core:strings"

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

	// The members of `union_storage_definition`, each with its value.
	members := union_members(shape)
	parts := make([dynamic]string, 0, 4, context.temp_allocator)
	if members.head > 0 {
		head := strings.builder_make()
		write_union_head_constant(e, &head, payload_bytes[:members.head])
		append(&parts, strings.to_string(head))
	}
	if members.padding > 0 {
		padding := strings.builder_make()
		write_byte_array_constant(&padding, payload_bytes[members.head:shape.payload_size])
		append(&parts, strings.to_string(padding))
	}
	if members.aligner {
		append(&parts, fmt.aprintf("[0 x %s] zeroinitializer", union_head_type(shape.align)))
	}
	if members.tag {
		append(&parts, fmt.aprintf("%s %d", union_tag_llvm(shape), index))
	}
	if members.tail > 0 {
		append(&parts, fmt.aprintf("[%d x i8] zeroinitializer", members.tail))
	}
	return strings.concatenate({"{ ", strings.join(parts[:], ", ", context.temp_allocator), " }"})
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
	fmt.sbprintf(b, "[%d x i8] ", len(bytes))
	write_byte_string(b, bytes)
}

// `bytes` as an LLVM string constant, the value of an `[N x i8]`.
@(private = "file")
write_byte_string :: proc(b: ^strings.Builder, bytes: []u8) {
	strings.write_string(b, "c\"")
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
		// An array of bytes is one string of them, not a member per byte.
		if !vector && lane == "i8" {
			bytes := make([]u8, int(info.count), context.temp_allocator)
			if write_const_bytes(e, bytes, value, under) {
				if slice.all_of(bytes, 0) {
					return "zeroinitializer"
				}
				b := strings.builder_make()
				write_byte_string(&b, bytes)
				return strings.to_string(b)
			}
		}
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

// A global's value type and initializer, the alignment an image needs, and
// whether it is an image (`const_needs_image`).
global_initializer :: proc(e: ^Emitter, value: Const_Value, type: Type_Id) -> (string, string, string, bool) {
	if const_needs_image(e, value, type) {
		image_type, image := const_image(e, {value}, type)
		return image_type, image, fmt.aprintf(", align %d", type_align(e.c, type)), true
	}
	return llvm_type(e, type), llvm_const(e, value, type), "", false
}

// A constant operand in a body; an image is loaded from a private global. A large
// value is an address, so a large constant is the global's.
@(private)
const_operand :: proc(e: ^Emitter, value: Const_Value, type: Type_Id) -> string {
	large := is_large_value(e, type)
	image_type, image, align, imaged := global_initializer(e, value, type)
	if !large && !imaged {
		return image
	}
	if large && image == "zeroinitializer" {
		return large_zero(e, type)
	}
	name := private_constant(e, "@.image.", fmt.aprintf("%s %s%s", image_type, image, align))
	return large ? name : load(e, llvm_type(e, type), name)
}

// A new private global named by `prefix` and the count of globals so far, and
// `definition`, all that follows its `=`.
@(private = "file")
private_global :: proc(e: ^Emitter, prefix, definition: string) -> string {
	name := claim_name(e, fmt.aprintf("%s%d", prefix, len(e.globals)))
	append(&e.globals, fmt.aprintf("%s = %s\n", name, definition))
	return name
}

// A private constant global of `definition`, its type and initializer, which
// every use of the same one shares, as `text_literal_global` shares a text. The
// key holds the alignment, so a shared global is never less aligned than a use
// asks; the name keeps the prefix of the first use.
@(private)
private_constant :: proc(e: ^Emitter, prefix, definition: string) -> string {
	if name, found := e.constants[definition]; found {
		return name
	}
	name := private_global(e, prefix, fmt.aprintf("private unnamed_addr constant %s", definition))
	e.constants[definition] = name
	return name
}

// The address of a large zero, which takes no space in the file. `store` writes
// the zero itself rather than copying this, so most of these are never read.
LARGE_ZERO_PREFIX :: "@.zero."

@(private = "file")
large_zero :: proc(e: ^Emitter, type: Type_Id) -> string {
	if name, known := e.large_zeros[type]; known {
		return name
	}
	name := private_global(e, LARGE_ZERO_PREFIX, fmt.aprintf("private unnamed_addr global %s zeroinitializer", llvm_type(e, type)))
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

// The global backing array of a file-scope slice literal. A `[]mut T` literal's
// is never shared, since a write through one must not show up in another; a
// read-only one's is shared with every literal of the same elements.
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
	// Only a mutable literal's elements need storage of their own.
	if !info.mutable {
		return private_constant(e, "@.slice.", fmt.aprintf("%s%s", contents, align))
	}
	return private_global(e, "@.slice.", fmt.aprintf("private global %s%s", contents, align))
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
