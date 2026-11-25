// Places: loads and stores, temporaries, and the addresses of expressions.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

// A load from a written place, which may be under-aligned through a packed
// field. `load` stays right for compiler-owned slots.
@(private)
load_place :: proc(e: ^Emitter, type: Type_Id, address: string) -> string {
	if is_large_value(e, type) {
		snapshot := temporary_slot(e, type)
		copy_bytes(e, snapshot, address, type_size(e.c, type))
		return snapshot
	}
	return load(e, llvm_type(e, type), address, align_suffix(e, address, type))
}

// clang crashes in instruction selection on a first-class value with 65536 or
// more scalars in it, so a value larger than this never becomes one. It is the
// address of storage nothing else writes, and crosses calls by pointer.
LARGE_VALUE_BYTES :: 4096

@(private)
is_large_value :: proc(e: ^Emitter, type: Type_Id) -> bool {
	return type != INVALID_TYPE && type_size(e.c, type) > LARGE_VALUE_BYTES
}

// Storage for one value of `type` within the current full expression, aligned
// to at least `align` when that is given. A large one is shared with other full
// expressions, since each would otherwise keep its whole size in the frame for
// the entire function.
@(private)
temporary_slot :: proc(e: ^Emitter, type: Type_Id, align: u64 = 0) -> string {
	return temporary_storage(e, llvm_type(e, type), type_size(e.c, type), align)
}

// As `temporary_slot`, for storage of the LLVM type `llvm`, `size` bytes, that
// has no Loke type of its own.
@(private)
temporary_storage :: proc(e: ^Emitter, llvm: string, size: u64, align: u64 = 0) -> string {
	spelled := align == 0 ? llvm : fmt.aprintf("%s, align %d", llvm, align)
	if size <= LARGE_VALUE_BYTES {
		return alloca(e, spelled)
	}
	slot := Large_Slot{type = spelled}
	for free, index in e.large_free {
		if free.type == spelled {
			slot = free
			unordered_remove(&e.large_free, index)
			break
		}
	}
	if slot.name == "" {
		slot.name = alloca(e, spelled)
	}
	append(&e.large_taken, slot)
	return slot.name
}

// New storage for one value of `type` within the current full expression,
// holding zero.
@(private)
zeroed_slot :: proc(e: ^Emitter, type: Type_Id) -> string {
	// A large slot is shared, so the newest `load` may have read from it.
	held := loaded_is_newest(e) && !is_large_value(e, type)
	slot := temporary_slot(e, type)
	store(e, type, "zeroinitializer", slot)
	keep_loaded(e, held)
	return slot
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

// Whether a value of `record` is held in storage to read or build its fields:
// it is large, or its LLVM members are byte arrays rather than its fields'
// types (`record_uses_byte_members`).
@(private = "file")
record_parts_in_memory :: proc(e: ^Emitter, record: Type_Id) -> bool {
	return is_large_value(e, record) || record_uses_byte_members(e, record, underlying_info(e.c, record))
}

// One field of a record value. A large record is an address, read in place, and
// a large field stays one; a small byte-member record is read from a copy.
@(private)
record_part :: proc(e: ^Emitter, record: Type_Id, value: string, index: int) -> string {
	if !record_parts_in_memory(e, record) {
		return extract(e, llvm_type(e, record), value, index)
	}
	return record_field_at(e, record, value_address(e, record, value), index)
}

// One field of the record in storage at `address`, at its own type and the
// alignment its place guarantees; a large field stays the address.
@(private)
record_field_at :: proc(e: ^Emitter, record: Type_Id, address: string, index: int) -> string {
	field := symbol_of(e.c, underlying_info(e.c, record).fields[index]).type
	return load_temporary(e, field, element_address(e, record, address, index))
}

// A record of `parts`, in field order. A large one, or a byte-member one, is
// built in storage, and a large part is the address of its value.
@(private)
build_record :: proc(e: ^Emitter, record: Type_Id, parts: ..string) -> string {
	fields := underlying_info(e.c, record).fields
	if record_parts_in_memory(e, record) {
		slot := temporary_slot(e, record)
		for part, index in parts {
			store(e, symbol_of(e.c, fields[index]).type, part, element_address(e, record, slot, index))
		}
		return load_temporary(e, record, slot)
	}
	llvm := llvm_type(e, record)
	built := "undef"
	for part, index in parts {
		built = insert(e, llvm, built, llvm_type(e, symbol_of(e.c, fields[index]).type), part, index)
	}
	return built
}

// Copies `size` bytes between two places, which are one place or do not
// overlap: design.md "What is not checked" leaves any other to `unsafe` code.
@(private)
copy_bytes :: proc(e: ^Emitter, to, from: string, size: u64) {
	if size > 0 {
		fmt.sbprintfln(&e.b, "  call void @llvm.memcpy.p0.p0.i64(ptr %s, ptr %s, i64 %d, i1 false)", to, from, size)
	}
}

@(private)
zero_bytes :: proc(e: ^Emitter, address: string, size: u64) {
	if size > 0 {
		fmt.sbprintfln(&e.b, "  call void @llvm.memset.p0.i64(ptr %s, i8 0, i64 %d, i1 false)", address, size)
	}
}

// Whether LLVM holds a value of the type spelled `llvm` as an aggregate, a
// struct or an array, and not as a scalar or a vector.
@(private)
is_llvm_aggregate :: proc(llvm: string) -> bool {
	return llvm[0] == '%' || llvm[0] == '{' || llvm[0] == '['
}

// Writes `value` to the place at `address`. A zero aggregate is written with
// `llvm.memset`, and one that a place still holds, having just been read from
// it, is copied from there with `llvm.memcpy`: clang's fast instruction
// selector cannot lower a first-class aggregate `load` or `store`, and the
// slow one splits each into an instruction per scalar inside.
@(private)
store :: proc(e: ^Emitter, type: Type_Id, value, address: string) {
	if address == "" || value == "" {
		return
	}
	llvm, size := llvm_type(e, type), type_size(e.c, type)
	large := is_large_value(e, type)
	switch {
	case large && strings.has_prefix(value, LARGE_ZERO_PREFIX), value == "zeroinitializer" && is_llvm_aggregate(llvm):
		zero_bytes(e, address, size)
	case large:
		// The value is the address of its storage, which a constant has none of.
		from := value
		if value[0] != '%' && value[0] != '@' {
			from = private_constant(e, "@.aggregate.", fmt.aprintf("%s %s", llvm, value))
		}
		copy_bytes(e, address, from, size)
	case value == e.loaded.value && loaded_is_newest(e) && is_llvm_aggregate(llvm):
		// The load stays for whatever else names the value (`write_function`).
		copy_bytes(e, address, e.loaded.from, size)
		append(&e.copied, value)
	case:
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s%s", llvm, value, address, align_suffix(e, address, type))
	}
}

// `body`, a function's text from its entry block on, without the `load` of
// each value among `copied` that nothing uses: `store` copied the place such a
// value was read from, which leaves the load without a use unless the value
// was also wanted for something else.
@(private)
write_without_unused_loads :: proc(out: ^strings.Builder, body: string, copied: []string) {
	if len(copied) == 0 {
		strings.write_string(out, body)
		return
	}
	// Where each load's line is, and whether anything but that line names its value.
	Load :: struct {
		lo, hi: int,
		used:   bool,
	}
	loads := make(map[string]Load, len(copied), context.temp_allocator)
	for value in copied {
		loads[value] = {}
	}
	for at := 0; at < len(body); {
		lo := strings.index_byte(body[at:], '%')
		if lo < 0 {
			break
		}
		lo += at
		at = lo + 1
		for at < len(body) && unquoted_name_byte(body[at]) {
			at += 1
		}
		load, copied_one := &loads[body[lo:at]]
		if !copied_one {
			continue
		}
		if strings.has_prefix(body[at:], " = ") {
			load.lo = lo - len("  ")
			load.hi = at + strings.index_byte(body[at:], '\n') + 1
		} else {
			load.used = true
		}
	}
	// A value is named after the ones before it, so the lines are in order.
	kept := 0
	for value in copied {
		if load := loads[value]; !load.used && load.hi > kept {
			strings.write_string(out, body[kept:load.lo])
			kept = load.hi
		}
	}
	strings.write_string(out, body[kept:])
}

@(private = "file")
place_align_of :: proc(e: ^Emitter, address: string, type: Type_Id) -> u64 {
	if a, ok := e.place_align[address]; ok {
		return a
	}
	return type_align(e.c, type)
}

// `, align N` for a place known to be less aligned than its pointee.
@(private)
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
@(private)
projects_managed_literal :: proc(e: ^Emitter, expr: Expr) -> bool {
	literal, is_literal := whole_of(expr).(^Expr_Composite)
	return is_literal && Expr(literal) != expr && emit_lifecycle(e, literal.type).managed
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

// `value` in storage of its own, as the temporary `expr` makes. A call's large
// result is already in a slot of this full expression that nothing else names,
// so that slot is the temporary, with no copy into a second one. One a local's
// value extends still gets storage of its own (`temporary_slot_for`).
@(private = "file")
hold_in_temporary :: proc(e: ^Emitter, expr: Expr, type: Type_Id, value: string) -> string {
	slot := value
	if value != e.call_slot || expr_base(expr).extended {
		slot = temporary_slot_for(e, expr, type)
		store(e, type, value, slot)
	}
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
		out := emit_gep(
			e, "getelementptr inbounds %s, ptr %s, i64 0, i64 %s",
			llvm_type(e, base_type), base_address, index,
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
	return check_index_below(e, emit_index_operands(e, v), length)
}

// The index of an `Expr_Index`, evaluated and not yet checked. A signed
// built-in `a + b` or `a - b` evaluated at run time, `sum`, is its two
// operands, which `check_index_below` adds and checks together with the bounds.
@(private = "file")
Index_Operands :: struct {
	type:     Type_Id,
	sum:      ^Expr_Binary,
	lhs, rhs: string,
}

@(private = "file")
emit_index_operands :: proc(e: ^Emitter, v: ^Expr_Index) -> Index_Operands {
	written := v.indices[0]
	if sum, summed := written.(^Expr_Binary); summed && index_sum_is_deferred(e, sum) {
		return {sum.type, sum, emit_expr(e, sum.lhs), emit_expr(e, sum.rhs)}
	}
	return {type = expr_base(written).type, lhs = emit_expr(e, written)}
}

@(private = "file")
index_sum_is_deferred :: proc(e: ^Emitter, v: ^Expr_Binary) -> bool {
	return (v.op == .Plus || v.op == .Minus) && v.resolution.kind == .Builtin_Operator &&
		!base_is_const(&v.base) && conversion_source(&v.base) == INVALID_TYPE &&
		type_is_integer(e.c, v.type) && type_signed(e.c, v.type)
}

// `index` as a checked i64 below `length`. A sum `a + b` or `a - b` has the
// overflow check of design.md "Integer overflow" and the bounds check behind
// one branch, which leaves a loop over it no branch of the addition's own for
// the optimizer to vectorize past. An exact result above the type's range wraps
// to a negative index, which is out of bounds. One below it comes only from a
// negative `a` with, for `+`, a negative `b`, and for `-`, a `b` that is not
// negative; every such result is negative, so it panics one way or the other.
// Both reach the failure block, where the checked operation says which panic
// it is.
@(private = "file")
check_index_below :: proc(e: ^Emitter, index: Index_Operands, length: string) -> string {
	if index.sum == nil {
		checked := checked_index_to_i64(e, index.lhs, index.type)
		emit_bounds_check(e, checked, length, "index out of range")
		return checked
	}
	op, llvm, lhs, rhs := index.sum.op, llvm_type(e, index.type), index.lhs, index.rhs
	wrapped := emit_value(e, "%s %s %s, %s", op == .Plus ? "add" : "sub", llvm, lhs, rhs)
	added := op == .Plus ? rhs : emit_value(e, "xor %s %s, -1", llvm, rhs)
	signs := emit_value(e, "and %s %s, %s", llvm, lhs, added)
	both_negative := emit_value(e, "icmp slt %s %s, 0", llvm, signs)
	checked := checked_index_to_i64(e, wrapped, index.type)
	outside := emit_value(e, "icmp uge i64 %s, %s", checked, length)

	fail, ok := new_label(e, "bounds"), new_label(e, "ok")
	branch_if_unlikely(e, combine_or(e, both_negative, outside), fail, ok)
	place_label(e, fail)
	emit_checked_integer(e, op, true, llvm, lhs, rhs)
	emit_panic(e, "index out of range")
	place_label(e, ok)
	return checked
}

// The current allocation and length of the dynamic array at `header`.
@(private = "file")
load_dynamic_parts :: proc(e: ^Emitter, header: string) -> (data, length: string) {
	data = load(e, "ptr", gep_field(e, CONTAINER_TYPE, header, CONTAINER_STORAGE))
	length = load(e, "i64", gep_field(e, CONTAINER_TYPE, header, CONTAINER_LEN))
	return
}

// `xs[i]`: an address in the current allocation, valid only as long as it is.
// design.md "Evaluation order": the array is indexed once its index is
// evaluated, so its storage and length are read after an index that grows it.
@(private = "file")
emit_dynamic_element_address :: proc(e: ^Emitter, v: ^Expr_Index) -> string {
	operand_type := expr_base(v.operand).type
	header := emit_address(e, v.operand, lending = true)
	operands := emit_index_operands(e, v)
	data, length := load_dynamic_parts(e, header)
	index := check_index_below(e, operands, length)
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

// `lo` and `hi`, evaluated (`emit_slice_bound_values`) and checked against
// `length` (`check_slice_bounds`).
@(private = "file")
emit_slice_bounds :: proc(e: ^Emitter, v: ^Expr_Slice, length, message: string) -> (low, high: string) {
	low, high = emit_slice_bound_values(e, v)
	return check_slice_bounds(e, low, high, length, message)
}

// `lo` and `hi`, each evaluated once in order: "0" without a `lo`, and ""
// without a `hi`.
@(private = "file")
emit_slice_bound_values :: proc(e: ^Emitter, v: ^Expr_Slice) -> (low, high: string) {
	low = "0"
	if v.lo != nil {
		low = checked_index_to_i64(e, emit_expr(e, v.lo), expr_base(v.lo).type)
	}
	if v.hi != nil {
		high = checked_index_to_i64(e, emit_expr(e, v.hi), expr_base(v.hi).type)
	}
	return
}

// The bounds checked as `0 <= low <= high <= length` in one trap seam before
// any address is formed, where a `high` not written is `length`. With no
// `length`, as over a C pointer, `high` is required and only must not be
// negative.
@(private = "file")
check_slice_bounds :: proc(e: ^Emitter, low, high, length, message: string) -> (string, string) {
	high := high == "" ? length : high
	reversed := emit_value(e, "icmp ugt i64 %s, %s", low, high)
	past_end := length == "" \
		? emit_value(e, "icmp slt i64 %s, 0", high) \
		: emit_value(e, "icmp ugt i64 %s, %s", high, length)
	panic_if(e, combine_or(e, reversed, past_end), "slice.bounds", message)
	return low, high
}

// `data[low:high]`, of `element`s, as a pointer and length of LLVM `storage`.
@(private = "file")
emit_subrange :: proc(e: ^Emitter, storage, element, data, low, high: string) -> string {
	start := gep_at(e, element, data, low)
	return emit_ptr_len(e, storage, start, emit_value(e, "sub i64 %s, %s", high, low))
}

// `base[lo:hi]` over a fixed array, a slice, or a dynamic array's current
// allocation up to `len`.
@(private)
emit_builtin_slice :: proc(e: ^Emitter, v: ^Expr_Slice, as_type: Type_Id) -> string {
	operand_type := expr_base(v.operand).type
	info := underlying_info(e.c, operand_type)

	data, length, low, high: string
	#partial switch info.kind {
	case .String, .String_View:
		return emit_text_subrange(e, v)
	case .C_Pointer:
		return emit_c_pointer_slice(e, v, as_type)
	case .Slice:
		data, length = emit_slice_parts(e, v.operand)
		low, high = emit_slice_bound_values(e, v)
	case .Dynamic_Array:
		// design.md "Evaluation order": as an index does, the bounds come before
		// the array's storage and length are read.
		header := emit_address(e, v.operand, lending = true)
		low, high = emit_slice_bound_values(e, v)
		data, length = load_dynamic_parts(e, header)
	case:
		data = emit_lent_address(e, v.operand, operand_type)
		length = fmt.aprintf("%d", info.count)
		low, high = emit_slice_bound_values(e, v)
	}

	low, high = check_slice_bounds(e, low, high, length, "slice bounds out of range")
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
	inside := emit_value(e, "icmp ult i64 %s, %s", bound, length)
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
@(private)
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
