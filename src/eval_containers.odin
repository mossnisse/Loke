// Compile-time containers and their operations. A compile-time container is only
// its contents: a `[dynamic]T`'s elements, or a map's key/value pairs in
// insertion order. Capacity and map iteration order have no compile-time answer
// and are rejected, never approximated.
package lokec

// The key and value halves of a map entry live at `2i` and `2i+1`.
@(private = "file")
MAP_ENTRY_KEY :: 0
@(private = "file")
MAP_ENTRY_VALUE :: 1

@(private)
eval_container_literal :: proc(ev: ^Evaluator, v: ^Expr_Composite) -> (out: Eval_Value, success: bool) {
	is_map := type_is_map(ev.k.c, v.type)
	elements := eval_elements(ev, len(v.elements) * (is_map ? 2 : 1)) or_return
	// A map entry's key is evaluated before its value (design.md "Evaluation
	// order"), and each is copied before later elements can change its source.
	for element, index in v.elements {
		if !is_map {
			elements[index] = eval_copied(ev, element.value) or_return
			continue
		}
		elements[2 * index + MAP_ENTRY_KEY] = eval_copied(ev, element.key) or_return
		elements[2 * index + MAP_ENTRY_VALUE] = eval_copied(ev, element.value) or_return
	}
	literal := Eval_Value{kind = .Aggregate, type = v.type, elements = elements}
	if is_map {
		return map_deduplicate(ev, literal)
	}
	return literal, true
}

// A repeated key keeps the last value, as at run time. Entries move down within
// the literal's own block.
@(private = "file")
map_deduplicate :: proc(ev: ^Evaluator, m: Eval_Value) -> (out: Eval_Value, success: bool) {
	out = m
	out.elements = m.elements[:0]
	for index := 0; index < len(m.elements); index += 2 {
		at := map_find(ev, &out, m.elements[index]) or_return
		if at >= 0 {
			out.elements[at + MAP_ENTRY_VALUE] = m.elements[index + MAP_ENTRY_VALUE]
			continue
		}
		kept := len(out.elements)
		m.elements[kept + MAP_ENTRY_KEY] = m.elements[index + MAP_ENTRY_KEY]
		m.elements[kept + MAP_ENTRY_VALUE] = m.elements[index + MAP_ENTRY_VALUE]
		out.elements = m.elements[:kept + 2]
	}
	return out, true
}

// The entry index of `key`, or -1. A linear scan: each comparison costs a step, so
// the step limit stops a map at about 1400 keys, too few to want a hash index.
@(private = "file")
map_find :: proc(ev: ^Evaluator, m: ^Eval_Value, key: Eval_Value) -> (out: int, success: bool) {
	for index := 0; index < len(m.elements); index += 2 {
		same := eval_map_key_equal(ev, m.type, m.elements[index], key) or_return
		if same {
			return index, true
		}
	}
	return -1, true
}

// The runtime's key policy; structural equality only for the built-in one.
@(private = "file")
eval_map_key_equal :: proc(ev: ^Evaluator, map_type: Type_Id, a, b: Eval_Value) -> (out: bool, success: bool) {
	eval_step(ev, ev.origin) or_return
	policy := ev.k.c.map_key_policies[container_key(ev.k.c, map_type)]
	if !key_policy_settled(policy) {
		return false, eval_fail(ev, ev.origin, "L0405", "a map key operation was not resolved during checking")
	}
	if policy.kind == .Builtin {
		return eval_compare(ev, .Eq_Eq, a, b)
	}
	if policy.equal == INVALID_SYMBOL || !ensure_proc_typed_for_eval(ev.k, policy.equal) {
		return false, eval_fail(ev, ev.origin, "L0341", "the map key's equality cannot be evaluated")
	}
	result := eval_invoke(ev, policy.equal, nil, ev.origin, []Eval_Value{a, b}) or_return
	if result.kind != .Boolean {
		return false, eval_fail(ev, ev.origin, "L0341", "the map key's equality must return a boolean")
	}
	return result.boolean, true
}

// The value slot of `key`, which must be there.
@(private)
eval_map_entry :: proc(ev: ^Evaluator, m: ^Eval_Value, key: Eval_Value, span: Span) -> (out: ^Eval_Value, success: bool) {
	at := map_find(ev, m, key) or_return
	if at < 0 {
		// What panics at run time is a compile-time error.
		return nil, eval_fail(ev, span, "L0343", "this key is not in the map")
	}
	return &m.elements[at + MAP_ENTRY_VALUE], true
}

// The value slot for `key`, adding a placeholder entry when it is missing. A new
// entry keeps `key` as it is, so the caller has copied it.
@(private)
map_entry_place :: proc(ev: ^Evaluator, m: ^Eval_Value, key: Eval_Value) -> (out: ^Eval_Value, success: bool) {
	at := map_find(ev, m, key) or_return
	if at >= 0 {
		return &m.elements[at + MAP_ENTRY_VALUE], true
	}
	zero := zero_value(ev, container_element(ev.k.c, m.type)) or_return
	eval_splice(ev, m, len(m.elements), 0, key, zero) or_return
	return &m.elements[len(m.elements) - 1], true
}

// Replaces `removed` elements at `at` with `inserted`, in the block `self` has when
// they fit. A new block has room to spare, so a container that grows one element
// at a time costs memory in proportion to its size.
@(private = "file")
eval_splice :: proc(ev: ^Evaluator, self: ^Eval_Value, at, removed: int, inserted: ..Eval_Value) -> bool {
	count := len(self.elements) - removed + len(inserted)
	room := max(self.capacity, len(self.elements))
	block := raw_data(self.elements)[:room]
	if count > room {
		block = eval_elements(ev, max(count, 2 * room, 8)) or_return
		self.capacity = len(block)
		copy(block, self.elements[:at])
	}
	copy(block[at + len(inserted):], self.elements[at + removed:])
	copy(block[at:], inserted)
	self.elements = block[:count]
	return true
}

// The element's ordering: its own `<` when it has one (standard-library.md "Sorting
// slices"), otherwise the built-in comparison.
@(private = "file")
eval_less :: proc(ev: ^Evaluator, span: Span, less: Symbol_Id, a, b: Eval_Value) -> (bool, bool) {
	if less == INVALID_SYMBOL {
		return eval_compare(ev, .Lt, a, b)
	}
	result, ok := eval_operator_call(ev, less, nil, span, []Eval_Value{a, b})
	return result.boolean, ok
}

// A stable merge sort; each comparison costs a step.
@(private = "file")
eval_sort :: proc(ev: ^Evaluator, span: Span, elements: []Eval_Value, descending: bool, less: Symbol_Id) -> bool {
	if len(elements) < 2 {
		return true
	}
	scratch, err := make([]Eval_Value, len(elements), ev.alloc)
	if err != nil {
		return false
	}
	// The sorted run ends up in `elements`, so the scratch holds nothing after.
	defer delete(scratch, ev.alloc)
	from, to := elements, scratch
	for width := 1; width < len(elements); width *= 2 {
		for lo := 0; lo < len(elements); lo += 2 * width {
			middle := min(lo + width, len(elements))
			hi := min(lo + 2 * width, len(elements))
			left, right, out := lo, middle, lo
			for left < middle && right < hi {
				if !eval_step(ev, span) {
					return false
				}
				a, b := from[right], from[left]
				// The right run's element goes first only when strictly before.
				before, ok := eval_less(ev, span, less, descending ? b : a, descending ? a : b)
				if !ok {
					return false
				}
				if before {
					to[out] = from[right]
					right += 1
				} else {
					to[out] = from[left]
					left += 1
				}
				out += 1
			}
			copy(to[out:], from[left:middle])
			copy(to[out + middle - left:], from[right:hi])
		}
		from, to = to, from
	}
	if raw_data(from) != raw_data(elements) {
		copy(elements, from)
	}
	return true
}

// A mutating operation needs a place; a read can take any value.
@(private)
eval_container_op :: proc(ev: ^Evaluator, v: ^Expr_Call, symbol: ^Symbol) -> (out: Eval_Value, success: bool) {
	defer { if !eval_memory_ok(ev) { success = false } }
	if len(v.bound) == 0 || v.bound[0] == nil {
		return Eval_Value{}, false
	}
	receiver: Eval_Value
	self := &receiver
	if symbol.receiver == .Inout {
		self = eval_place(ev, v.bound[0]) or_return
	} else {
		receiver = eval_expr(ev, v.bound[0]) or_return
	}
	element := sequence_element(ev.k.c, self.type)

	switch symbol.container_op {
	case .None:
		return {}, eval_fail(ev, v.span, "L0405", "a container call has no operation")

	case .Append:
		added := eval_appended(ev, v) or_return
		defer delete(added, ev.alloc)
		eval_splice(ev, self, len(self.elements), 0, ..added) or_return
		return eval_alloc_ok(ev, symbol)

	case .Sort, .Reverse_Sort:
		// A dynamic array is sorted as its place. A slice's receiver is a copy of
		// its header, but the header's elements are the viewed storage itself
		// (`eval_slice`), so sorting them sorts what the slice views (standard-library.md
		// "Sorting slices").
		if symbol.receiver != .Inout && underlying_kind(ev.k.c, self.type) != .Slice {
			return {}, eval_fail(ev, v.span, "L0341", "this value cannot be sorted at compile time")
		}
		less := INVALID_SYMBOL
		if policy := resolved_element_order_policy(ev.k.c, element); policy.kind == .Inherent {
			less = policy.less
		}
		eval_sort(ev, v.span, self.elements, symbol.container_op == .Reverse_Sort, less) or_return
		return eval_void(), true

	case .Swap:
		// As for `sort`: a slice swaps the elements it views (standard-library.md
		// "Swapping elements").
		if symbol.receiver != .Inout && underlying_kind(ev.k.c, self.type) != .Slice {
			return {}, eval_fail(ev, v.span, "L0341", "this value cannot be rearranged at compile time")
		}
		left := eval_count_argument(ev, v, 1) or_return
		right := eval_count_argument(ev, v, 2) or_return
		for at in ([2]int{left, right}) {
			if at >= len(self.elements) {
				return {}, eval_fail(ev, v.span, "L0361", "index %d is out of range", at)
			}
		}
		self.elements[left], self.elements[right] = self.elements[right], self.elements[left]
		return eval_void(), true

	case .Chunks_Mut:
		// Its chunks are handed out by a protocol iterator, which compile-time
		// evaluation does not run.
		return {}, eval_fail(ev, v.span, "L0341", "`chunks_mut` has no compile-time meaning yet")

	case .Split_At_Mut:
		// Both halves view the receiver's elements (standard-library.md "Splitting a
		// mutable slice").
		mid := eval_count_argument(ev, v, 1) or_return
		if mid > len(self.elements) {
			return {}, eval_fail(ev, v.span, "L0361", "split index %d is out of range for length %d", mid, len(self.elements))
		}
		halves := eval_elements(ev, 2) or_return
		halves[0] = Eval_Value{kind = .Aggregate, type = self.type, elements = self.elements[:mid]}
		halves[1] = Eval_Value{kind = .Aggregate, type = self.type, elements = self.elements[mid:]}
		return Eval_Value{kind = .Aggregate, type = symbol.result, elements = halves}, true

	case .Insert:
		at := eval_count_argument(ev, v, 1) or_return
		value := eval_copied(ev, v.bound[2]) or_return
		if at > len(self.elements) {
			return {}, eval_fail(ev, v.span, "L0361", "index %d is out of range", at)
		}
		eval_splice(ev, self, at, 0, value) or_return
		return eval_alloc_ok(ev, symbol)

	case .Pop:
		if len(self.elements) == 0 {
			return eval_option(ev, symbol.result, Eval_Value{}, false)
		}
		last := self.elements[len(self.elements) - 1]
		self.elements = self.elements[:len(self.elements) - 1]
		return eval_option(ev, symbol.result, last, true)

	case .Remove, .Remove_Unordered:
		at := eval_count_argument(ev, v, 1) or_return
		if at >= len(self.elements) {
			return {}, eval_fail(ev, v.span, "L0361", "index %d is out of range", at)
		}
		taken := self.elements[at]
		if symbol.container_op == .Remove {
			eval_splice(ev, self, at, 1) or_return
		} else {
			// The last element moves into the hole.
			self.elements[at] = self.elements[len(self.elements) - 1]
			self.elements = self.elements[:len(self.elements) - 1]
		}
		return taken, true

	case .Clear, .Map_Clear:
		self.elements = self.elements[:0]
		return eval_void(), true

	case .Resize:
		size := eval_count_argument(ev, v, 1) or_return
		if size <= len(self.elements) {
			self.elements = self.elements[:size]
			return eval_alloc_ok(ev, symbol)
		}
		eval_hooks_supported(ev, element, v.span) or_return
		for len(self.elements) < size {
			zero := zero_value(ev, element) or_return
			eval_splice(ev, self, len(self.elements), 0, zero) or_return
		}
		return eval_alloc_ok(ev, symbol)

	case .Reserve, .Shrink, .Map_Reserve,
	     .Map_Shrink:
		// No allocation here, so these do nothing observable.
		eval_count_argument(ev, v, 1) or_return
		return eval_alloc_ok(ev, symbol)

	case .Map_Entries, .Map_Keys, .Map_Values,
	     .Map_Lookup_Value, .Map_Find, .Map_Remove,
	     .Map_Find_Or_Insert, .Map_Try_Insert:
		return eval_map_op(ev, v, symbol, self)
	}
	return Eval_Value{}, false
}

@(private = "file")
eval_map_op :: proc(ev: ^Evaluator, v: ^Expr_Call, symbol: ^Symbol, self: ^Eval_Value) -> (out: Eval_Value, success: bool) {
	#partial switch symbol.container_op {
	case .Map_Entries, .Map_Keys, .Map_Values:
		return {}, eval_fail(ev, v.span, "L0341", "a map view has no compile-time meaning; iterate the map itself")

	case .Map_Lookup_Value, .Map_Find, .Map_Remove:
		key := eval_expr(ev, v.bound[1]) or_return
		at := map_find(ev, self, key) or_return
		if at < 0 {
			return eval_option(ev, symbol.result, Eval_Value{}, false)
		}
		entry := &self.elements[at + MAP_ENTRY_VALUE]
		#partial switch symbol.container_op {
		case .Map_Find:
			pointer := Eval_Value {
				kind   = .Nil,
				type   = union_variant_payload(ev.k.c, symbol.result, union_index_of(ev.k.c, symbol.result, "some")),
				target = entry,
			}
			return eval_option(ev, symbol.result, pointer, true)
		case .Map_Remove:
			taken := entry^
			eval_splice(ev, self, at, 2) or_return
			return eval_option(ev, symbol.result, taken, true)
		}
		copied := copy_value(ev, entry^) or_return
		return eval_option(ev, symbol.result, copied, true)

	case .Map_Find_Or_Insert, .Map_Try_Insert:
		key := eval_copied(ev, v.bound[1]) or_return
		value := eval_copied(ev, v.bound[2]) or_return
		before := len(self.elements)
		slot := map_entry_place(ev, self, key) or_return
		if symbol.container_op == .Map_Try_Insert {
			slot^ = value
			return eval_alloc_ok(ev, symbol)
		}
		// design.md "Map container operations": `elem` is stored only for a new key.
		if len(self.elements) > before {
			slot^ = value
		}
		return eval_map_slot(ev, symbol, slot)
	}
	return Eval_Value{}, false
}

// An `int` argument, with the negative-count fault the runtime raises.
@(private = "file")
eval_count_argument :: proc(ev: ^Evaluator, v: ^Expr_Call, index: int) -> (out: int, success: bool) {
	value := eval_expr(ev, v.bound[index]) or_return
	number, fits := bi_to_i64(ev.alloc, value.integer)
	if !fits || number < 0 {
		return 0, eval_fail(ev, expr_span(v.bound[index]), "L0343", "a container count cannot be negative")
	}
	return int(number), true
}

// What `append` adds, in written order; a spread adds a copy of each element it
// views (design.md "Variadic parameters").
@(private = "file")
eval_appended :: proc(ev: ^Evaluator, v: ^Expr_Call) -> (out: []Eval_Value, success: bool) {
	added := make([dynamic]Eval_Value, 0, len(v.variadic_elements), ev.alloc)
	if v.variadic_forwards {
		eval_append_spread(ev, &added, v.bound[v.variadic_slot]) or_return
		return added[:], true
	}
	cursor: Call_Pack_Cursor
	for operand, is_spread in call_pack_next(v, &cursor) {
		if is_spread {
			eval_append_spread(ev, &added, operand) or_return
			continue
		}
		copied := eval_copied(ev, operand) or_return
		append(&added, copied)
	}
	return added[:], true
}

@(private = "file")
eval_append_spread :: proc(ev: ^Evaluator, added: ^[dynamic]Eval_Value, spread: Expr) -> bool {
	viewed := eval_expr(ev, spread) or_return
	for element in viewed.elements {
		copied := copy_value(ev, element) or_return
		append(added, copied)
	}
	return true
}

// What an operation that might allocate answers when it had nothing to allocate:
// nothing, or `.ok` carrying `Unit` for the `try_` spelling.
@(private = "file")
eval_alloc_ok :: proc(ev: ^Evaluator, symbol: ^Symbol) -> (out: Eval_Value, success: bool) {
	if !container_member_is_fallible(ev.k.c, symbol) {
		return eval_void(), true
	}
	unit := zero_value(ev, ev.k.c.unit_type) or_return
	return eval_named_union(ev, symbol.result, "ok", unit)
}

// `find_or_insert`'s `^mut V`, wrapped in `.ok` for the `try_` spelling.
@(private = "file")
eval_map_slot :: proc(ev: ^Evaluator, symbol: ^Symbol, slot: ^Eval_Value) -> (Eval_Value, bool) {
	if container_member_is_fallible(ev.k.c, symbol) {
		payload := union_variant_payload(ev.k.c, symbol.result, union_index_of(ev.k.c, symbol.result, "ok"))
		return eval_named_union(ev, symbol.result, "ok", Eval_Value{kind = .Nil, type = payload, target = slot})
	}
	return Eval_Value{kind = .Nil, type = symbol.result, target = slot}, true
}

// `key in m`, or `x in r` (design.md "Ranges").
@(private)
eval_in :: proc(ev: ^Evaluator, v: ^Expr_Binary) -> (out: Eval_Value, success: bool) {
	// A failing `or_return` in the key leaves before the subject is evaluated.
	key := eval_expr(ev, v.lhs) or_return
	subject := eval_expr(ev, v.rhs) or_return
	present: bool
	if info := type_of(ev.k.c, subject.type); info != nil && info.is_range &&
	   subject.kind == .Aggregate && len(subject.elements) == 3 {
		present = eval_range_contains(ev, subject, key) or_return
	} else {
		at := map_find(ev, &subject, key) or_return
		present = at >= 0
	}
	return Eval_Value{kind = .Boolean, type = TYPE_BOOL, boolean = present}, true
}

@(private = "file")
eval_range_contains :: proc(ev: ^Evaluator, range, key: Eval_Value) -> (out: bool, success: bool) {
	above := eval_compare(ev, .Lt_Eq, range.elements[RANGE_LOW], key) or_return
	below := eval_compare(ev, .Lt, key, range.elements[RANGE_HIGH]) or_return
	at := eval_compare(ev, .Eq_Eq, key, range.elements[RANGE_HIGH]) or_return
	return above && (below || (range.elements[RANGE_CLOSED].boolean && at)), true
}
