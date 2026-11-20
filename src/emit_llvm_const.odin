// Constants: LLVM constant spelling, byte images, and the private globals that
// hold constants, slice literals and large zeros.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:slice"
import "core:strings"

// design.md "Zero values": a union constant is the payload's little-endian byte
// image, split across the head and byte-array tail, plus the tag. Only the
// active payload is written out; the storage past it is zero, and a member all
// of whose bytes are zero is `zeroinitializer`, however wide an inactive
// variant makes it.
@(private = "file")
union_constant :: proc(e: ^Emitter, value: Const_Value, type: Type_Id) -> string {
	shape := union_layout(e.c, type)
	if value.kind != .Aggregate || value.aggregate == nil {
		return "zeroinitializer" // a union with no zero: inert bits, no value
	}
	index := value.aggregate.variant
	payload_type := union_variant_payload(e.c, type, index)
	payload: []u8
	if payload_type != TYPE_VOID && type_size(e.c, payload_type) != 0 {
		payload = make([]u8, int(type_size(e.c, payload_type)), context.temp_allocator)
		if len(payload) > int(shape.payload_size) || !write_const_bytes(e, payload, value.aggregate.elements[0], payload_type) {
			backend_fail(e, fmt.aprintf("a union payload constant cannot be represented as bytes: %s in %s", type_name(e.c, payload_type), type_name(e.c, type)))
		}
	}
	if index == 0 && slice.all_of(payload, 0) {
		return "zeroinitializer"
	}

	// The members of `union_storage_definition`, each with its value: the
	// payload's bytes in `bytes[:size]`, zero past its end.
	storage_bytes :: proc(payload: []u8, start, size: u64) -> []u8 {
		bytes := make([]u8, int(size), context.temp_allocator)
		if start < u64(len(payload)) {
			copy(bytes, payload[start:])
		}
		return bytes
	}
	members := union_members(shape)
	parts := make([dynamic]string, 0, 4, context.temp_allocator)
	if members.head > 0 {
		head := strings.builder_make()
		write_union_head_constant(&head, storage_bytes(payload, 0, members.head))
		append(&parts, strings.to_string(head))
	}
	if members.padding > 0 {
		padding := strings.builder_make()
		if u64(len(payload)) > members.head {
			write_byte_array_constant(&padding, storage_bytes(payload, members.head, members.padding))
		} else {
			fmt.sbprintf(&padding, "[%d x i8] zeroinitializer", members.padding)
		}
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
write_union_head_constant :: proc(b: ^strings.Builder, head: []u8) {
	strings.write_string(b, union_head_type(u64(len(head))))
	if len(head) > UNION_INT_HEAD_BYTES {
		strings.write_string(b, " <")
		for byte, index in head {
			fmt.sbprintf(b, "%si8 %d", index > 0 ? ", " : "", byte)
		}
		strings.write_string(b, ">")
		return
	}
	bits: u128
	for byte, index in head {
		bits |= u128(byte) << uint(index * 8)
	}
	fmt.sbprintf(b, " %d", bits)
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
	write_byte_array_value(b, bytes)
}

// `bytes` as the value of an `[N x i8]`: an LLVM string constant, or
// `zeroinitializer` when all of them are zero.
@(private = "file")
write_byte_array_value :: proc(b: ^strings.Builder, bytes: []u8) {
	if slice.all_of(bytes, 0) {
		strings.write_string(b, "zeroinitializer")
		return
	}
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
	// The storage of an `Uninit(T)` is the constant that is no value
	// (`uninit_const`), and still has the inert all-zero representation.
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
	case .CString_View, .String, .String_View, .Slice:
		target, count, flags, _ := carrier_constant(e, value, info)
		switch {
		case target == "":
			return info.kind == .CString_View ? "null" : "zeroinitializer"
		case info.kind == .CString_View:
			return target
		case info.kind == .String:
			return fmt.aprintf("{{ ptr %s, i64 %d, i64 %d }}", target, count, flags)
		}
		return fmt.aprintf("{{ ptr %s, i64 %d }}", target, count)
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
				b := strings.builder_make()
				write_byte_array_value(&b, bytes)
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
	case .Int, .Enum, .Rune, .Allocator_Error, .Bool, .Float:
		pattern := scalar_const_pattern(value, info, len(out) * 8) or_return
		write_pattern_bytes(out, pattern)
		return true
	case .Array, .Simd, .Struct:
		count := info.kind == .Struct ? len(info.fields) : int(info.count)
		for index in 0 ..< count {
			member, start, end, ok := storage_member(e.c, under, info, index)
			if !ok || end > len(out) ||
			   !write_const_bytes(e, out[start:end], const_element(value, index), member, relocations, at + start) {
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
		write_pattern_bytes(out[tag:tag + int(shape.tag_bytes)], u128(index))
		return true
	case .Typeid:
		write_pattern_bytes(out, u128(emitted_typeid(e, value)))
		return true
	case .Dynamic_Array, .Map, .Dyn:
		// A constant of these is only the empty one, which is all-zero.
		return true
	case .String, .String_View, .CString_View, .Slice:
		target, count, flags := carrier_constant(e, value, info) or_return
		if target == "" {
			return true
		}
		// An image holds a relocation to the module storage.
		if relocations == nil {
			return false
		}
		append(relocations, Const_Relocation{at, target})
		// The pointer comes first, then the length and a string's owner flags.
		if info.kind != .CString_View {
			write_pattern_bytes(out[8:16], u128(count))
		}
		if info.kind == .String {
			write_pattern_bytes(out[16:24], u128(flags))
		}
		return true
	}
	return false
}

// design.md "Unions": a union payload, and a field of a combined packed/aligned
// record, is a byte image, which in its declared LLVM type cannot hold a pointer
// to module storage. A constant containing one is emitted whole as an image.
// `in_image` says the walk has entered such a byte image. A `thread_local`'s
// initializer is an image wherever it holds a slice literal, whose pointer may
// be one a thread installs (`Thread_Local_Pointer`).
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
		return (in_image || e.thread_local_initializer) && len(elements) > 0
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
// and pointers: its type, then its value. A pointer to a per-thread array is
// null, and left for `claim_thread_local_pointers` to give the image's global.
@(private = "file")
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
	image: Image_Writer
	cursor := 0
	for relocation in relocations {
		image_bytes(&image, bytes[cursor:relocation.offset])
		image_member(&image, "ptr")
		if strings.has_prefix(relocation.target, THREAD_LOCAL_SLICE_PREFIX) {
			strings.write_string(&image.parts, "null")
			append(&e.thread_local_pointers, Thread_Local_Pointer{offset = relocation.offset, target = relocation.target})
		} else {
			strings.write_string(&image.parts, relocation.target)
		}
		cursor = relocation.offset + 8
	}
	image_bytes(&image, bytes[cursor:])
	strings.write_string(&image.types, " }>")
	strings.write_string(&image.parts, " }>")
	return strings.to_string(image.types), strings.to_string(image.parts)
}

// An image's type and value, written member by member.
@(private = "file")
Image_Writer :: struct {
	types, parts: strings.Builder,
}

// Starts a member of LLVM type `type`, whose value the caller writes next.
@(private = "file")
image_member :: proc(image: ^Image_Writer, type: string) {
	separator := strings.builder_len(image.types) == 0 ? "<{ " : ", "
	fmt.sbprint(&image.types, separator, type, sep = "")
	fmt.sbprint(&image.parts, separator, type, " ", sep = "")
}

// A run of this many zero bytes is a member of its own, spelled
// `zeroinitializer`, since padding and inactive union variants make long ones.
@(private = "file")
IMAGE_ZERO_RUN :: 16

// `bytes` as image members: runs of bytes, each ending before a run of at least
// `IMAGE_ZERO_RUN` zeros, and those zeros.
@(private = "file")
image_bytes :: proc(image: ^Image_Writer, bytes: []u8) {
	for start := 0; start < len(bytes); {
		end, zeros := start, 0
		for end < len(bytes) && zeros < IMAGE_ZERO_RUN {
			zeros = bytes[end] == 0 ? zeros + 1 : 0
			end += 1
		}
		if zeros == IMAGE_ZERO_RUN {
			end -= zeros
		}
		if end == start {
			// At a long run of zeros: the member is all of it.
			for end < len(bytes) && bytes[end] == 0 {
				end += 1
			}
		}
		image_member(image, fmt.tprintf("[%d x i8]", end - start))
		write_byte_array_value(&image.parts, bytes[start:end])
		start = end
	}
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

// A text or slice literal's pointer, length, and owner flags. `target` is ""
// for one that is all zero, which an empty `cstring_view` is not: it is the
// address of a lone terminator. Not `ok` for a text value that is no literal.
@(private = "file")
carrier_constant :: proc(e: ^Emitter, value: Const_Value, info: ^Type_Info) -> (target: string, count, flags: int, ok: bool) {
	switch {
	case info.kind == .Slice:
		if value.aggregate == nil || len(value.aggregate.elements) == 0 {
			return "", 0, 0, true
		}
		return slice_literal_storage(e, value, info), len(value.aggregate.elements), 0, true
	case value.kind != .String:
		return "", 0, 0, false
	case value.text == "" && info.kind != .CString_View:
		return "", 0, 0, true
	}
	// A string literal's bytes have static lifetime, so a `string` owns nothing.
	return text_literal_global(e, value.text), len(value.text), info.kind == .String ? STRING_STATIC : 0, true
}

// The global backing array of a slice literal with at least one element. A
// `[]mut T` literal's is never shared, since a write through one must not show
// up in another; a read-only one's is shared with every literal of the same
// elements. In a `thread_local`'s initializer, a `[]mut T` literal's, and one
// whose elements point at such an array, is per thread.
@(private = "file")
slice_literal_storage :: proc(e: ^Emitter, value: Const_Value, info: ^Type_Info) -> string {
	count := len(value.aggregate.elements)
	imaged := false
	for slot in value.aggregate.elements {
		imaged ||= const_needs_image(e, slot, info.element)
	}
	unclaimed := len(e.thread_local_pointers)
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
	if e.thread_local_initializer && (info.mutable || len(e.thread_local_pointers) > unclaimed) {
		name := private_global(e, THREAD_LOCAL_SLICE_PREFIX, fmt.aprintf("private thread_local global %s%s", contents, align))
		claim_thread_local_pointers(e, name)
		return name
	}
	// Only a mutable literal's elements need storage of their own.
	if !info.mutable {
		return private_constant(e, "@.slice.", fmt.aprintf("%s%s", contents, align))
	}
	return private_global(e, "@.slice.", fmt.aprintf("private global %s%s", contents, align))
}

// design.md "Storage modifiers": each thread has its own instance of a
// `thread_local`, so a writable slice literal in its initializer has an array
// per thread. A thread's copy of the TLS template cannot hold that copy's own
// address, so the template holds null at `offset` in `global` and
// `loke_rt_v1_program_tls_init` stores the address of the thread's `target`
// there when the thread first attaches, before it runs Loke code.
@(private)
Thread_Local_Pointer :: struct {
	global, target: string,
	offset:         int,
}

// The name of each per-thread slice literal array.
@(private = "file")
THREAD_LOCAL_SLICE_PREFIX :: "@.slice.thread."

// Gives `global`, which holds the image just written, the pointers
// `const_image` left without one.
@(private)
claim_thread_local_pointers :: proc(e: ^Emitter, global: string) {
	#reverse for &pointer in e.thread_local_pointers {
		if pointer.global != "" {
			break
		}
		pointer.global = global
	}
}

// `text` as a literal `string_view`.
@(private)
text_view_constant :: proc(e: ^Emitter, text: string) -> string {
	return llvm_const(e, string_const(text), TYPE_STRING_VIEW)
}
