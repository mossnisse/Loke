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
	// Text is ordered byte-wise; one runtime call answers the four orderings.
	if type_is_utf8_text(e.c, type) {
		storage := llvm_type(e, type_underlying(e.c, type))
		left_data, left_len := string_parts(e, storage, lhs)
		right_data, right_len := string_parts(e, storage, rhs)
		if op == .Eq_Eq || op == .Not_Eq {
			equal := emit_text_equal(e, left_data, left_len, right_data, right_len)
			return op == .Eq_Eq ? equal : not_i1(e, equal)
		}
		order := emit_value(
			e, "call i32 @loke_rt_v1_bytes_compare(ptr %s, i64 %s, ptr %s, i64 %s)",
			left_data, left_len, right_data, right_len,
		)
		return emit_value(e, "icmp %s i32 %s, 0", compare_predicate(op).signed, order)
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

// Equal texts have equal lengths, so only those reach `memcmp`, which LLVM
// knows: against a literal it becomes a few loads.
@(private = "file")
emit_text_equal :: proc(e: ^Emitter, left_data, left_len, right_data, right_len: string) -> string {
	declare_intrinsic(e, "memcmp", "i32", "ptr, ptr, i64")
	same_len := emit_value(e, "icmp eq i64 %s, %s", left_len, right_len)
	entry_label := current_block(e, "teq.entry")
	bytes_label := new_label(e, "teq.bytes")
	done_label := new_label(e, "teq.done")
	branch_if(e, same_len, bytes_label, done_label)
	place_label(e, bytes_label)
	order := emit_value(e, "call i32 @memcmp(ptr %s, ptr %s, i64 %s)", left_data, right_data, left_len)
	same_bytes := emit_value(e, "icmp eq i32 %s, 0", order)
	branch(e, done_label)
	place_label(e, done_label)
	return emit_value(e, "phi i1 [ false, %%%s ], [ %s, %%%s ]", entry_label, same_bytes, bytes_label)
}

// design.md "Comparison operators": an anonymous record orders by its first
// unequal field, under that field's `<` with the operands swapped for `>` and
// `>=`; equal records answer `<=` and `>=`. Built from the last field back, so
// each field's answer selects between its own `<` and the fields after it.
//
// ponytail: every field is compared rather than branching at the first
// difference; an ordered record's fields declare no `==`, so comparing one
// has no effect to skip.
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
		out := emit_value(e, "select i1 %s, i1 %s, i1 %s", equal, result, less)
		result = out
	}
	return result
}

// Structural equality, since LLVM has no aggregate `icmp`.
@(private)
emit_equal :: proc(e: ^Emitter, type: Type_Id, lhs, rhs: string) -> string {
	// design.md "Comparison operators": a part with its own `==` is compared by
	// it, with both operands in memory.
	if equal := type_own_equality(e.c, type); equal != INVALID_SYMBOL {
		return emit_equal_hook_call(e, equal, type, value_address(e, type, lhs), value_address(e, type, rhs))
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
		// A byte-member record's fields are read in memory, which takes one copy
		// of each operand rather than one per field (`record_part`).
		if record_uses_byte_members(e, under, info) {
			left, right := value_address(e, under, lhs), value_address(e, under, rhs)
			return emit_fields_equal(e, under, info, left, right, record_field_at)
		}
		return emit_fields_equal(e, under, info, lhs, rhs, record_part)
	}
	return emit_compare(e, .Eq_Eq, type, lhs, rhs)
}

// A direct call of the inherent `==` `equal` on two `type` values in memory.
@(private)
emit_equal_hook_call :: proc(e: ^Emitter, equal: Symbol_Id, type: Type_Id, left, right: string) -> string {
	return emit_value(
		e, "call i1 %s(%s, %s)", callee_name(e, equal),
		hook_argument(e, equal, 0, type, left), hook_argument(e, equal, 1, type, right),
	)
}

// A direct call of the inherent `hash` `hash` on a `type` value in memory.
@(private)
emit_hash_hook_call :: proc(e: ^Emitter, hash: Symbol_Id, type: Type_Id, address, seed: string) -> string {
	return emit_value(e, "call i64 %s(%s, i64 %s)", callee_name(e, hash), hook_argument(e, hash, 0, type, address), seed)
}

// design.md "Comparison operators": parts compare in order, and the first
// unequal one ends the comparison. A part whose comparison may run an inherent
// `==` is reached by a branch on the parts before it; comparing any other part
// has no effect to skip, so those fold into one `and` chain.
@(private = "file")
Part_Chain :: struct {
	// The parts since the last branch, folded; `true` before any.
	result:       string,
	// The `i1` slot a branch leaves the answer in and the label it goes to,
	// both empty until a part needs a branch.
	answer, done: string,
}

@(private = "file")
chain_part :: proc(e: ^Emitter, chain: ^Part_Chain, type: Type_Id, left, right: string) {
	if chain.result != "true" && comparison_runs_own_equality(e.c, type) {
		if chain.answer == "" {
			chain.answer, chain.done = alloca(e, "i1"), new_label(e, "equal.done")
		}
		store_scalar(e, "i1", chain.result, chain.answer)
		next := new_label(e, "equal.next")
		branch_if(e, chain.result, next, chain.done)
		place_label(e, next)
		chain.result = "true"
	}
	chain.result = combine_and(e, chain.result, emit_equal(e, type, left, right))
}

@(private = "file")
chain_answer :: proc(e: ^Emitter, chain: Part_Chain) -> string {
	if chain.answer == "" {
		return chain.result
	}
	store_scalar(e, "i1", chain.result, chain.answer)
	place_label(e, chain.done)
	return load(e, "i1", chain.answer)
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
		left, right := value_address(e, type, lhs), value_address(e, type, rhs)
		return emit_elements_equal(e, info.element, left, right, fmt.tprintf("%d", info.count))
	}
	llvm := llvm_type(e, type)
	chain := Part_Chain{result = "true"}
	for index in 0 ..< int(info.count) {
		chain_part(e, &chain, info.element, extract(e, llvm, lhs, index), extract(e, llvm, rhs, index))
	}
	return chain_answer(e, chain)
}

// Whether the `count` elements at `left` and `right` are equal. As `Part_Chain`
// does, the first unequal element ends the loop where a later one's comparison
// could run an inherent `==`; otherwise every element is compared.
@(private = "file")
emit_elements_equal :: proc(e: ^Emitter, element: Type_Id, left, right, count: string) -> string {
	element_llvm := llvm_type(e, element)
	same := alloca(e, "i1")
	store_scalar(e, "i1", "true", same)
	loop := open_counted_loop(e, new_counter(e), "equal", count)
	one := load_temporary(e, element, gep_at(e, element_llvm, left, loop.index))
	other := load_temporary(e, element, gep_at(e, element_llvm, right, loop.index))
	leaf := emit_equal(e, element, one, other)
	if comparison_runs_own_equality(e.c, element) {
		store_scalar(e, "i1", leaf, same)
		next := new_label(e, "equal.next")
		branch_if(e, leaf, next, loop.done)
		place_label(e, next)
	} else {
		store_scalar(e, "i1", combine_and(e, load(e, "i1", same), leaf), same)
	}
	close_counted_loop(e, loop)
	return load(e, "i1", same)
}

// Equal tags, then the active variant's payload. Only that variant's comparison
// runs: another variant's bytes read as a `string` would be arbitrary memory.
@(private = "file")
emit_union_equal :: proc(e: ^Emitter, union_type: Type_Id, lhs, rhs: string) -> string {
	info := type_of(e.c, union_type)
	tag_llvm := union_tag_llvm(union_layout(e.c, union_type))

	left_tag := emit_union_tag(e, union_type, lhs)
	right_tag := emit_union_tag(e, union_type, rhs)
	same_tag := emit_value(e, "icmp eq %s %s, %s", tag_llvm, left_tag, right_tag)

	left_slot := value_address(e, union_type, lhs)
	right_slot := value_address(e, union_type, rhs)

	// The tag comparison is the answer unless an active payload overrides it.
	answer := alloca(e, "i1")
	store_scalar(e, "i1", same_tag, answer)

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
		left := load_temporary(e, variant, left_slot)
		right := load_temporary(e, variant, right_slot)
		// The comparison may open blocks, so the store goes wherever it ends.
		equal := emit_equal(e, variant, left, right)
		store_scalar(e, "i1", equal, answer)
		branch(e, done)
	}
	place_label(e, done)
	return load(e, "i1", answer)
}

// Field-wise equality, with each field read by `read`.
@(private = "file")
emit_fields_equal :: proc(
	e: ^Emitter, record: Type_Id, info: ^Type_Info, lhs, rhs: string,
	read: proc(e: ^Emitter, record: Type_Id, value: string, index: int) -> string,
) -> string {
	chain := Part_Chain{result = "true"}
	for field, index in info.fields {
		chain_part(e, &chain, symbol_of(e.c, field).type, read(e, record, lhs, index), read(e, record, rhs, index))
	}
	return chain_answer(e, chain)
}

// ------------------------------------------------------------ key hashing --

emit_hash_value :: proc(e: ^Emitter, type: Type_Id, value, seed: string) -> string {
	// design.md "Maps": a part with its own `==` hashes by its own `hash`, which
	// is the coherent partner of the `==` structural equality calls for it.
	if own := part_own_hash(e.c, type); own != INVALID_SYMBOL {
		return emit_hash_hook_call(e, own, type, value_address(e, type, value), seed)
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
		widened := emit_value(e, "zext %s %s to i64", union_tag_llvm(union_layout(e.c, under)), tag)
		tagged := emit_hash_mix(e, seed, widened)
		slot := value_address(e, under, value)
		state := alloca(e, "i64")
		store_scalar(e, "i64", tagged, state)
		done := new_label(e, "unionhash.done")
		hits := variant_labels(e, info, "unionhash.hit", .Payload)
		emit_union_switch(e, under, tag, hits, done)
		for variant, index in info.variants {
			if hits[index] == "" {
				continue
			}
			place_label(e, hits[index])
			payload := load_temporary(e, variant, slot)
			payload_hash := emit_hash_value(e, variant, payload, tagged)
			store_scalar(e, "i64", payload_hash, state)
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
			store_scalar(e, "i64", seed, state)
			loop := open_counted_loop(e, new_counter(e), "hash.array", fmt.aprintf("%d", info.count))
			element := load_temporary(e, info.element, gep_at(e, element_llvm, address, loop.index))
			next := emit_hash_value(e, info.element, element, load(e, "i64", state))
			store_scalar(e, "i64", next, state)
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
		return emit_value(e, "call i64 @loke_rt_v1_hash_bytes(ptr %s, i64 %s, i64 %s)", data, length, seed)
	}
	return emit_hash_scalar(e, under, value, seed)
}

// One hash step: `bits` folded into `seed`.
@(private = "file")
emit_hash_mix :: proc(e: ^Emitter, seed, bits: string) -> string {
	return emit_value(e, "mul i64 %s, %d", emit_value(e, "xor i64 %s, %s", seed, bits), HASH_MULTIPLIER)
}

// One scalar folded into `seed`, as `hash_const` does at compile time: its
// 64-bit integer image, or a wider integer's low word and then its high word.
@(private = "file")
emit_hash_scalar :: proc(e: ^Emitter, under: Type_Id, value, seed: string) -> string {
	#partial switch type_of(e.c, under).kind {
	case .Bool:
		return emit_hash_mix(e, seed, resize_int(e, value, 1, 64, signed = false))
	case .Raw_Pointer, .Pointer, .C_Pointer:
		return emit_hash_mix(e, seed, emit_value(e, "ptrtoint ptr %s to i64", value))
	}
	bits := type_bits(e.c, under)
	if bits <= 64 {
		return emit_hash_mix(e, seed, widen_to_i64(e, value, under))
	}
	low := resize_int(e, value, bits, 64, signed = false)
	high := resize_int(e, emit_value(e, "lshr i%d %s, 64", bits, value), bits, 64, signed = false)
	return emit_hash_mix(e, emit_hash_mix(e, seed, low), high)
}
