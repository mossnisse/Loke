// Places, expressions, branching expressions, and unsafe operations.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

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

// The inverse: a value in memory. A large value is already an address, and a
// small one is spilled to a slot of its own.
@(private)
value_address :: proc(e: ^Emitter, type: Type_Id, value: string) -> string {
	if is_large_value(e, type) {
		return value
	}
	return spill(e, type, value)
}

// A copy of `value` in a stack slot of its own, large or not.
@(private)
spill :: proc(e: ^Emitter, type: Type_Id, value: string) -> string {
	slot := alloca(e, llvm_type(e, type))
	store(e, type, value, slot)
	return slot
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
			from = private_constant(e, "@.aggregate.", fmt.aprintf("%s %s", llvm_type(e, type), value))
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
@(private)
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
@(private = "file")
emit_index_below :: proc(e: ^Emitter, v: ^Expr_Index, length: string) -> string {
	index := checked_index_to_i64(e, emit_expr(e, v.indices[0]), expr_base(v.indices[0]).type)
	emit_bounds_check(e, index, length, "index out of range")
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
// `0 <= lo <= hi <= length` in one trap seam before any address is formed. With
// no `length`, as over a C pointer, `hi` is required and only must not be
// negative.
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
	reversed := emit_value(e, "icmp ugt i64 %s, %s", low, high)
	past_end := length == "" \
		? emit_value(e, "icmp slt i64 %s, 0", high) \
		: emit_value(e, "icmp ugt i64 %s, %s", high, length)
	panic_if(e, combine_or(e, reversed, past_end), "slice.bounds", message)
	return
}

// `data[low:high]`, of `element`s, as a pointer and length of LLVM `storage`.
@(private = "file")
emit_subrange :: proc(e: ^Emitter, storage, element, data, low, high: string) -> string {
	start := gep_at(e, element, data, low)
	return emit_ptr_len(e, storage, start, emit_value(e, "sub i64 %s, %s", high, low))
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
	return emit_subrange(e, llvm_type(e, as_type), llvm_type(e, info.element), data, low, high)
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
	return emit_subrange(e, STRING_VIEW_TYPE, "i8", data, low, high)
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
	place_label(e, checked_label)
}

// design.md "C pointers": `x[:]`/`x[i:]` stay unbounded C pointers; `x[:n]` and
// `x[i:n]` make a checked `[]T`, and a negative length panics (design.md "string
// type conversions").
@(private = "file")
emit_c_pointer_slice :: proc(e: ^Emitter, v: ^Expr_Slice, as_type: Type_Id) -> string {
	element := llvm_type(e, underlying_info(e.c, expr_base(v.operand).type).element)
	data := emit_expr(e, v.operand)
	if v.hi == nil {
		low := "0"
		if v.lo != nil {
			low = checked_index_to_i64(e, emit_expr(e, v.lo), expr_base(v.lo).type)
		}
		return gep_at(e, element, data, low)
	}
	low, high := emit_slice_bounds(e, v, "", "slice bounds out of range")
	return emit_subrange(e, llvm_type(e, as_type), element, data, low, high)
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
	return resize_int(e, value, type_bits(e.c, type), 64, type_signed(e.c, type))
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
	slot := spill(e, as_type, value)
	if !base_is_const(base) {
		hold_addressed_temporary(e, expr, as_type, slot)
	}
	return slot
}

// The address an erased view of `expr` holds: the place itself, or a temporary
// holding the value. A view reads its target at the type's alignment, so it
// views an aligned copy of a packed place.
@(private)
emit_viewed_address :: proc(e: ^Emitter, expr: Expr, from: Type_Id) -> string {
	return aligned_copy_if_needed(e, from, spill_viewed_at(e, expr, from))
}

// `address`, or where it is less aligned than `type` asks, as a packed field
// may be (design.md "@(packed)"), an aligned copy of what it holds, for a
// reader that reads at the type's alignment.
@(private)
aligned_copy_if_needed :: proc(e: ^Emitter, type: Type_Id, address: string) -> string {
	if align, known := e.place_align[address]; !known || align >= type_align(e.c, type) {
		return address
	}
	aligned := temporary_slot(e, type)
	copy_bytes(e, aligned, address, type_size(e.c, type))
	return aligned
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
			return string_as_view(e, STRING_TYPE, load_place(e, from, emit_lent_address(e, expr, from))), true
		case .Pointer:
			// A `Box(T)` lent as the `^T` of its payload.
			if underlying_kind(e.c, from) == .Box {
				return emit_box_payload_address(e, from, load_place(e, from, emit_lent_address(e, expr, from))), true
			}
			// design.md "Variadic parameters": a `T` a `..^T` pack lends, where it is
			// or in a temporary that lives through the call.
			if pointee, lends := variadic_lent_pointee(e.c, as_type); lends && pointee == from {
				return emit_lent_address(e, expr, from), true
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
	// Start from all-zero bits so an omitted field holds its zero value
	// (design.md "Struct literals", "Zero values"). The literal's own type may
	// have no zero, as with a `Box` field: every part without one is supplied.
	store(e, as_type, "zeroinitializer", address)
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
		return not_i1(e, result)
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
	left_data, left_len := string_parts(e, storage, lhs)
	right_data, right_len := string_parts(e, storage, rhs)
	return emit_text_concat_parts(e, left_data, left_len, right_data, right_len)
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
	declare_intrinsic(e, key, pair_type, strings.concatenate({llvm, ", ", llvm}))
	pair := emit_value(e, "call %s @%s(%s %s, %s %s)", pair_type, key, llvm, lhs, llvm, rhs)
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

@(private)
scalar_int_form :: proc(e: ^Emitter, type: Type_Id) -> Int_Form {
	return Int_Form {
		llvm = llvm_type(e, type),
		mask = "i1",
		bits = type_bits(e.c, type),
		signed = type_signed(e.c, type),
	}
}

@(private)
form_const :: proc(e: ^Emitter, form: Int_Form, value: string) -> string {
	return form.lanes == nil ? value : simd_repeated(e, form.lanes, value)
}

@(private = "file")
form_zero :: proc(form: Int_Form) -> string {
	return form.lanes == nil ? "0" : "zeroinitializer"
}

// The `i1` a `panic_if` tests: whether any lane of `mask` is set.
@(private)
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

// ---------------------------------------------------- branching expressions --

@(private = "file")
emit_short_circuit :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	lhs := emit_expr(e, v.lhs)
	// The left operand may have opened blocks of its own; the phi names the last.
	entry_label := current_block(e, "sc.entry")
	rhs_label := new_label(e, "sc.rhs")
	done_label := new_label(e, "sc.done")
	if v.op == .And_And {
		branch_if(e, lhs, rhs_label, done_label)
	} else {
		branch_if(e, lhs, done_label, rhs_label)
	}

	place_label(e, rhs_label)
	begin_conditional(e)
	rhs := emit_expr(e, v.rhs)
	end_conditional(e)
	rhs_exit := current_block(e, "sc.rhs.exit")
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

// One arm of a conditional, and, when the arms meet in a phi, the block it ends
// in, for the phi to name.
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
	} else {
		exit = current_block(e, exit_prefix)
	}
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
		return string_as_view(e, STRING_TYPE, value)
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
		emit_unreachable(e)
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
