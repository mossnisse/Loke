// Union storage, construction, widening, and tag and payload reads.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:slice"
import "core:strings"

// The widest head spelled as an integer. The target layout aligns no integer
// past this, and LLVM aligns a byte vector to its size.
UNION_INT_HEAD_BYTES :: 16

// The storage member that carries a union's alignment, one `align` bytes wide.
@(private)
union_head_type :: proc(align: u64) -> string {
	return align > UNION_INT_HEAD_BYTES ? fmt.aprintf("<%d x i8>", align) : fmt.aprintf("i%d", align * 8)
}

// The union storage type, built so LLVM's own layout matches the checker's
// cached facts: an alignment-carrying payload head, explicit payload padding,
// the tag, and tail padding. A bare `[N x i8]` payload would be byte-aligned,
// which is wrong when a union is allocated directly, nested in a struct, or
// used as an array element.
@(private)
union_storage_definition :: proc(e: ^Emitter, type: Type_Id) -> string {
	shape := union_layout(e.c, type)
	members := union_members(shape)
	parts := make([dynamic]string, 0, 4, context.temp_allocator)
	if members.head > 0 {
		append(&parts, union_head_type(members.head))
	}
	if members.padding > 0 {
		append(&parts, fmt.aprintf("[%d x i8]", members.padding))
	}
	if members.aligner {
		append(&parts, fmt.aprintf("[0 x %s]", union_head_type(shape.align)))
	}
	if members.tag {
		append(&parts, union_tag_llvm(shape))
	}
	if members.tail > 0 {
		append(&parts, fmt.aprintf("[%d x i8]", members.tail))
	}
	return strings.concatenate({"{ ", strings.join(parts[:], ", ", context.temp_allocator), " }"})
}

// The members of a union's storage, in order, each a byte count, or 0 when it
// is absent: the payload's alignment-carrying head and the payload's padding
// after it; without a payload, an empty member that carries the alignment; the
// tag, which a niche union has none of; and tail padding. The storage type, a
// union constant and the tag's member index are all read from it.
@(private)
Union_Members :: struct {
	head, padding: u64,
	aligner, tag:  bool,
	tail:          u64,
}

@(private)
union_members :: proc(shape: Union_Layout) -> Union_Members {
	members: Union_Members
	if shape.payload_size > 0 {
		members.head, members.padding = shape.align, shape.payload_size - shape.align
		if shape.niche {
			return members
		}
	} else {
		members.aligner = shape.align > shape.tag_bytes
	}
	members.tag = true
	members.tail = shape.size - shape.payload_size - shape.tag_bytes
	return members
}

// The storage member of `union_storage_definition` that holds the tag.
@(private = "file")
union_tag_member :: proc(e: ^Emitter, type: Type_Id) -> int {
	members := union_members(union_layout(e.c, type))
	return int(members.head > 0) + int(members.padding > 0) + int(members.aligner)
}

// Constructing a variant: zero the storage, write the payload through a typed
// pointer, then write the tag. `value` is empty for a payloadless variant,
// which is nothing but its tag.
@(private)
emit_union_value :: proc(e: ^Emitter, union_type: Type_Id, index: int, value: string) -> string {
	slot := temporary_slot(e, union_type)
	store(e, union_type, "zeroinitializer", slot)
	emit_union_write_variant(e, union_type, slot, index, value)
	return load_temporary(e, union_type, slot)
}

@(private)
emit_option_some :: proc(e: ^Emitter, option_type: Type_Id, payload: string) -> string {
	return emit_union_value(e, option_type, union_index_of(e.c, option_type, "some"), payload)
}

// `Option(T)` from a runtime presence flag.
@(private)
emit_option_value :: proc(e: ^Emitter, option_type: Type_Id, present, payload: string) -> string {
	return emit_union_either(
		e, option_type, present,
		union_index_of(e.c, option_type, "some"), payload,
		union_index_of(e.c, option_type, "none"), "",
	)
}

// design.md "Widening by label": each alternative keeps its payload under the
// wider union's tag for its label. The layouts differ, so the payload is moved
// into the wider storage, one arm per alternative.
@(private)
emit_union_widen :: proc(e: ^Emitter, value: string, from, to: Type_Id) -> string {
	source := type_of(e.c, from)
	slot := temporary_slot(e, to)
	store(e, to, "zeroinitializer", slot)
	spilled := emit_union_spill(e, from, value)
	tag := emit_union_tag(e, from, value)
	done := new_label(e, "widen.done")
	hits := variant_labels(e, source, "widen.hit")
	emit_union_switch(e, from, tag, hits, "")
	for payload, index in source.variants {
		place_label(e, hits[index])
		operand := ""
		if payload != TYPE_VOID {
			operand = emit_union_payload(e, from, payload, spilled)
		}
		emit_union_write_variant(e, to, slot, widened_variant(e.c, from, to, index), operand)
		branch(e, done)
	}
	place_label(e, done)
	return load_temporary(e, to, slot)
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
	slot := temporary_slot(e, union_type)
	store(e, union_type, "zeroinitializer", slot)
	yes, no, done := new_label(e, "variant.yes"), new_label(e, "variant.no"), new_label(e, "variant.done")
	branch_if(e, condition, yes, no)

	place_label(e, yes)
	emit_union_write_variant(e, union_type, slot, true_index, true_payload)
	branch(e, done)

	place_label(e, no)
	emit_union_write_variant(e, union_type, slot, false_index, false_payload)
	branch(e, done)

	place_label(e, done)
	return load_temporary(e, union_type, slot)
}

// Writes a variant into zeroed storage. An empty `payload` means the caller has
// nothing to write: the variant is payloadless, or its payload is zero-sized
// and the zeroed slot is already the whole value.
@(private = "file")
emit_union_write_variant :: proc(e: ^Emitter, union_type: Type_Id, slot: string, index: int, payload: string) {
	if payload_type := union_variant_payload(e.c, union_type, index);
	   payload != "" && payload_type != TYPE_VOID {
		store(e, payload_type, payload, gep_field(e, llvm_type(e, union_type), slot, 0))
	}
	emit_union_store_tag(e, union_type, slot, index)
}

// A niche union's tag is its payload: the zeroed slot is already the
// payloadless variant, and a written reference is never null.
@(private = "file")
emit_union_store_tag :: proc(e: ^Emitter, union_type: Type_Id, slot: string, tag: int) {
	llvm := llvm_type(e, union_type)
	shape := union_layout(e.c, union_type)
	if shape.niche {
		return
	}
	address := gep_field(e, llvm, slot, union_tag_member(e, union_type))
	fmt.sbprintfln(&e.b, "  store %s %d, ptr %s", union_tag_llvm(shape), tag, address)
}

// The tag of a union *value*, which is what every extraction and type switch
// tests.
@(private)
emit_union_tag :: proc(e: ^Emitter, union_type: Type_Id, value: string) -> string {
	// One member of the value, which a large one holds in memory.
	read_member :: proc(e: ^Emitter, union_type: Type_Id, value: string, member: int, type: string) -> string {
		llvm := llvm_type(e, union_type)
		return is_large_value(e, union_type) ? load(e, type, gep_field(e, llvm, value, member)) : extract(e, llvm, value, member)
	}

	shape := union_layout(e.c, union_type)
	if shape.niche {
		head := union_head_type(shape.align)
		word := read_member(e, union_type, value, 0, head)
		some := union_niche_variant(e.c, union_type)
		present := icmp_zero(e, head, word, equal = false)
		out := emit_value(e, "select i1 %s, i8 %d, i8 %d", present, some, 1 - some)
		return out
	}
	return read_member(e, union_type, value, union_tag_member(e, union_type), union_tag_llvm(shape))
}

// Whether a union value's tag is `index`.
@(private)
emit_union_tag_is :: proc(e: ^Emitter, union_type: Type_Id, value: string, index: int) -> string {
	tag := emit_union_tag(e, union_type, value)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %d", out, union_tag_llvm(union_layout(e.c, union_type)), tag, index)
	return out
}

// The LLVM integer type of a union's tag, as stored and as `emit_union_tag`
// computes it.
@(private)
union_tag_llvm :: proc(shape: Union_Layout) -> string {
	switch shape.tag_bytes {
	case 1:
		return "i8"
	case 2:
		return "i16"
	}
	return "i32"
}

// Which variants of a union `variant_labels` gives a label.
@(private)
Labeled_Variants :: enum {
	All,
	// Those with a payload.
	Payload,
	// Those whose payload a drop or clone must visit.
	Managed,
}

// A label for each variant of a union that `which` selects, by variant index,
// and "" for the rest.
@(private)
variant_labels :: proc(e: ^Emitter, info: ^Type_Info, prefix: string, which := Labeled_Variants.All) -> []string {
	labels := make([]string, len(info.variants))
	for variant, index in info.variants {
		selected: bool
		switch which {
		case .All:
			selected = true
		case .Payload:
			selected = variant != TYPE_VOID
		case .Managed:
			selected = variant != TYPE_VOID && emit_lifecycle(e, variant).managed
		}
		if selected {
			labels[index] = new_label(e, prefix)
		}
	}
	return labels
}

// Dispatches on a union's `tag` with one LLVM `switch`: variant `index` goes to
// `targets[index]`, and a variant whose target is "" goes to `rest`. With `rest`
// "" as well, such a tag is unreachable. The caller places each target.
@(private)
emit_union_switch :: proc(e: ^Emitter, union_type: Type_Id, tag: string, targets: []string, rest: string) {
	if e.terminated {
		return
	}
	if rest != "" && slice.all_of(targets, "") {
		branch(e, rest)
		return
	}
	width := union_tag_llvm(union_layout(e.c, union_type))
	otherwise := rest != "" ? rest : new_label(e, "union.none")
	fmt.sbprintf(&e.b, "  switch %s %s, label %%%s [", width, tag, otherwise)
	for target, index in targets {
		if target != "" {
			fmt.sbprintf(&e.b, " %s %d, label %%%s", width, index, target)
		}
	}
	strings.write_string(&e.b, " ]\n")
	e.terminated = true
	if rest == "" {
		place_label(e, otherwise)
		emit_unreachable(e)
	}
}

@(private)
emit_union_spill :: proc(e: ^Emitter, union_type: Type_Id, value: string) -> string {
	slot := temporary_slot(e, union_type)
	store(e, union_type, value, slot)
	return slot
}

@(private)
emit_union_payload :: proc(e: ^Emitter, union_type, payload_type: Type_Id, slot: string) -> string {
	return load_place(e, payload_type, gep_field(e, llvm_type(e, union_type), slot, 0))
}

// `Result(T, Allocator_Error)` from a runtime failure flag. The error is the
// refused size (design.md "Allocation failure"): `error` when the failure is
// already an `Allocator_Error`, else taken from the runtime's note. `value` is
// the success payload, empty when success carries `Unit`.
@(private)
emit_alloc_result :: proc(e: ^Emitter, result: Type_Id, failed: string, value := "", error := "") -> string {
	refused := error
	if refused == "" && failed != "false" {
		refused = emit_take_refusal(e)
	}
	return emit_union_either(
		e, result, failed,
		union_index_of(e.c, result, "err"), refused,
		union_index_of(e.c, result, "ok"), value,
	)
}

// The size the runtime's note holds for the last refused allocation, which it
// gives up. A drop that may allocate between a refusal and its report takes it
// first and restores it after.
@(private)
emit_take_refusal :: proc(e: ^Emitter) -> string {
	return emit_value(e, "call i64 @loke_rt_v1_take_refusal()")
}

// An `Allocator_Error` turning back into a status or a policy call: its size
// returns to the runtime's note, charged to `allocator`.
@(private)
emit_restore_refusal :: proc(e: ^Emitter, allocator, error: string) {
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_restore_refusal(ptr %s, i64 %s)", allocator, error)
}
