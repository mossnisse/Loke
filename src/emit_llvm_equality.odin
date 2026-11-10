// Comparison, structural equality and ordering, and the key hashing that must
// stay coherent with `==` (design.md "Maps").
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

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
		left_data, left_len := string_parts(e, storage, lhs)
		right_data, right_len := string_parts(e, storage, rhs)
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
		return op == .Eq_Eq ? equal : not_i1(e, equal)
	}
	return emit_value(e, "%s %s %s, %s", compare_instruction(e, op, type), llvm_type(e, type), lhs, rhs)
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
	return value_address(e, type, lhs), value_address(e, type, rhs)
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

// An array bigger than either limit compares and hashes in a loop, since
// unrolling takes about four instructions per element.
@(private = "file")
UNROLLED_ARRAY_ELEMENTS :: 8
@(private = "file")
UNROLLED_ARRAY_BYTES :: 64

@(private)
array_walks_in_loop :: proc(e: ^Emitter, type: Type_Id, info: ^Type_Info) -> bool {
	return info.count > UNROLLED_ARRAY_ELEMENTS || type_size(e.c, type) > UNROLLED_ARRAY_BYTES
}

@(private = "file")
emit_array_equal :: proc(e: ^Emitter, type: Type_Id, info: ^Type_Info, lhs, rhs: string) -> string {
	if array_walks_in_loop(e, type, info) {
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
	tag_llvm := union_tag_llvm(union_layout(e.c, union_type))

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
	hits := variant_labels(e, info, "unioneq.hit", .Payload)
	emit_union_switch(e, union_type, left_tag, hits, done)

	for variant, index in info.variants {
		if hits[index] == "" {
			continue
		}
		place_label(e, hits[index])
		left := emit_union_payload(e, union_type, variant, left_slot)
		right := emit_union_payload(e, union_type, variant, right_slot)
		// The comparison may open blocks, so the store goes wherever it ends.
		equal := emit_equal(e, variant, left, right)
		fmt.sbprintfln(&e.b, "  store i1 %s, ptr %s", equal, answer)
		branch(e, done)
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

// ------------------------------------------------------------ key hashing --

emit_hash_value :: proc(e: ^Emitter, type: Type_Id, value, seed: string) -> string {
	// design.md "Maps": a part with its own `==` hashes by its own `hash`, which
	// is the coherent partner of the `==` structural equality calls for it.
	if own := part_own_hash(e.c, type); own != INVALID_SYMBOL {
		address := value_address(e, type, value)
		out := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i64 %s(%s, i64 %s)",
			out, callee_name(e, own), hook_argument(e, own, 0, type, address), seed,
		)
		return out
	}
	under := type_underlying(e.c, type)
	info := type_of(e.c, under)
	// A record mixes its fields in declaration order, as an array mixes its
	// elements; a large one is an address, read in place.
	if info != nil && info.kind == .Struct {
		current := seed
		for field, index in info.fields {
			symbol := symbol_of(e.c, field)
			current = emit_hash_value(e, symbol.type, record_part(e, under, value, index), current)
		}
		return current
	}
	// A union mixes its tag, then the active payload, so two variants with one
	// payload type hash apart.
	if info != nil && info.kind == .Union {
		tag := emit_union_tag(e, under, value)
		widened := temp(e)
		fmt.sbprintfln(&e.b, "  %s = zext %s %s to i64", widened, union_tag_llvm(union_layout(e.c, under)), tag)
		tagged := emit_hash_mix(e, seed, widened)
		slot := emit_union_spill(e, under, value)
		state := alloca(e, "i64")
		fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", tagged, state)
		done := new_label(e, "unionhash.done")
		hits := variant_labels(e, info, "unionhash.hit", .Payload)
		emit_union_switch(e, under, tag, hits, done)
		for variant, index in info.variants {
			if hits[index] == "" {
				continue
			}
			place_label(e, hits[index])
			payload := emit_union_payload(e, under, variant, slot)
			payload_hash := emit_hash_value(e, variant, payload, tagged)
			fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", payload_hash, state)
			branch(e, done)
		}
		place_label(e, done)
		return load(e, "i64", state)
	}
	if info != nil && info.kind == .Array {
		// Hashed in a loop where equality compares in one, element by element in
		// memory.
		if array_walks_in_loop(e, under, info) {
			address := value_address(e, under, value)
			element_llvm := llvm_type(e, info.element)
			state := alloca(e, "i64")
			fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", seed, state)
			loop := open_counted_loop(e, new_counter(e), "hash.array", fmt.aprintf("%d", info.count))
			element := load_temporary(e, info.element, gep_at(e, element_llvm, address, loop.index))
			next := emit_hash_value(e, info.element, element, load(e, "i64", state))
			fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next, state)
			close_counted_loop(e, loop)
			return load(e, "i64", state)
		}
		current := seed
		for index in 0 ..< int(info.count) {
			element := extract(e, llvm_type(e, under), value, index)
			current = emit_hash_value(e, info.element, element, current)
		}
		return current
	}
	// design.md: `string` and `string_view` hash byte-wise, which is the coherent
	// partner of the byte-wise `==` they already have.
	if type_is_utf8_text(e.c, under) {
		storage := llvm_type(e, under)
		data, length := string_parts(e, storage, value)
		out := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i64 @loke_rt_v1_hash_bytes(ptr %s, i64 %s, i64 %s)",
			out, data, length, seed,
		)
		return out
	}
	return emit_hash_mix(e, seed, emit_hash_bits(e, under, value))
}

// One hash step: `bits` folded into `seed`.
@(private = "file")
emit_hash_mix :: proc(e: ^Emitter, seed, bits: string) -> string {
	mixed, out := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = xor i64 %s, %s", mixed, seed, bits)
	fmt.sbprintfln(&e.b, "  %s = mul i64 %s, %d", out, mixed, HASH_MULTIPLIER)
	return out
}

// One scalar's 64-bit integer image.
@(private = "file")
emit_hash_bits :: proc(e: ^Emitter, under: Type_Id, value: string) -> string {
	#partial switch type_of(e.c, under).kind {
	case .Bool:
		return resize_int(e, value, 1, 64, signed = false)
	case .Raw_Pointer, .Pointer, .C_Pointer:
		return emit_value(e, "ptrtoint ptr %s to i64", value)
	}
	return widen_to_i64(e, value, under)
}
