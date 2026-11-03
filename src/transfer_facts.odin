// What a value takes to another thread, and what its storage holds.
package lokec

import "core:fmt"
import "core:slice"

// design.md "@(thread_affine)": what a value would take to another thread that
// may not go. Like `@(move_only)`, affinity propagates structurally, but transfer
// also follows pointees, owned and shared payloads, container elements, and a
// generic record's type arguments. An unchecked address, a `rawptr` or a C
// pointer, is not followed: design.md "Concurrency and the memory model" lets one
// cross without proving anything about what it reaches.
Transfer_Facts :: struct {
	// A thread-affine type it holds or reaches.
	affine:     Type_Id,
	// A `dyn` it reaches, behind which affinity cannot be seen.
	erased:     Type_Id,
	// A mutable carrier it holds or reaches, through which a task sharing it could
	// write (design.md "Sharing with tasks").
	mutable:    Type_Id,
	// An `@(wakes_on_drop)` type it is, holds, or reaches, so keeping the value may
	// keep a waiter asleep (design.md "Releasing before the join").
	waker:      Type_Id,
	// With `through_views`, a mutable carrier reached through a read-only view: moving
	// the view gives a task nothing of its own.
	viewed:     Type_Id,
	// The outermost read-only view and witness each fact came through, if one did.
	affine_via: Transfer_Via,
	erased_via: Transfer_Via,
	viewed_via: Transfer_Via,
}

Transfer_Via :: struct {
	view, witness: Type_Id,
}

// A type is walked once outside any read-only view and once inside one.
@(private = "file")
Transfer_Visit :: struct {
	type:   Type_Id,
	viewed: bool,
}

// What to do about a value whose erasure hides what a task needs to see.
@(private = "file")
CONCRETE_VALUE_NOTE :: "pass the concrete value instead, or convert it to the view at this call"

// design.md "@(thread_affine)": a value crossing to another thread holds or
// reaches nothing thread-affine, and no erased value whose eligibility the
// compiler cannot see. A `dyn` view shows it through each type converted to it.
@(private)
report_transfer_facts :: proc(c: ^Compiler, base_type: Type_Id, facts: Transfer_Facts, span: Span) {
	switch {
	case facts.affine != INVALID_TYPE:
		if facts.affine_via.view != INVALID_TYPE {
			errorf(
				c, span, "L0724", "%s, which is `@(thread_affine)`, so it cannot cross to another thread",
				viewed_subject(c, base_type, facts.affine, facts.affine_via),
			)
		} else if facts.affine == base_type {
			errorf(c, span, "L0724", "`%s` is `@(thread_affine)`, so it cannot cross to another thread", type_name(c, base_type))
		} else {
			errorf(
				c, span, "L0724",
				"`%s` holds or reaches `%s`, which is `@(thread_affine)`, so it cannot cross to another thread",
				type_name(c, base_type), type_name(c, facts.affine),
			)
		}
		if declared := symbol_of(c, type_of(c, facts.affine).symbol); declared != nil {
			add_notef(c, declared.span, "`%s` is declared here", type_name(c, facts.affine))
		}
	case facts.erased != INVALID_TYPE && facts.erased_via.view != INVALID_TYPE:
		errorf(
			c, span, "L0725", "%s, which hides the type it erased, so nothing shows that it may cross to another thread",
			viewed_subject(c, base_type, facts.erased, facts.erased_via),
		)
	case facts.erased == base_type:
		errorf(
			c, span, "L0725",
			"`%s` hides the type it erased, so nothing shows that it may cross to another thread",
			type_name(c, base_type),
		)
	case facts.erased != INVALID_TYPE:
		errorf(
			c, span, "L0725",
			"`%s` reaches `%s`, which hides the type it erased, so nothing shows that it may cross to another thread",
			type_name(c, base_type), type_name(c, facts.erased),
		)
	case:
		return
	}
	if facts.affine == INVALID_TYPE {
		add_notef(c, span, CONCRETE_VALUE_NOTE)
	}
}

// One value crossing to a task, which it shares with the parent unless it is
// the task's alone.
@(private)
prov_transfer_argument :: proc(c: ^Compiler, argument: Expr, shared: bool) {
	base := expr_base(argument)
	if base == nil || base.type == INVALID_TYPE {
		return
	}
	span := expr_span(argument)
	transferred := prov_transferred_type(c, argument)
	facts := transfer_facts(c, transferred, through_views = true)
	// A task may share an erased value only as its own, and moving one would
	// still not show that it may cross (design.md "Sharing with tasks").
	if shared && base.erased_from == INVALID_TYPE && (base.type == facts.erased && !carrier_is_mutable(c, base.type)) {
		errorf(c, span, "L0729", "`%s` hides what it captures, so a task cannot share it", type_name(c, base.type))
		add_notef(c, span, CONCRETE_VALUE_NOTE)
		return
	}
	report_transfer_facts(c, base.type, facts, span)
	// What a read-only view may view is shared however the view is passed:
	// moving the view gives the task nothing of its own.
	if facts.viewed != INVALID_TYPE {
		errorf(
			c, span, "L0729", "%s, so a task sharing it could write what the parent reaches too",
			viewed_subject(c, base.type, facts.viewed, facts.viewed_via),
		)
		add_notef(c, span, CONCRETE_VALUE_NOTE)
	}
	if shared && facts.mutable != INVALID_TYPE && !carrier_is_mutable(c, transferred) {
		// A view made at this call only borrows what it converts, so moving the
		// view gives the task nothing of its own.
		advice := ": move it into the task, or pass the mutable borrow itself"
		if transferred != base.type {
			advice = "; the view only borrows what it converts: pass the mutable borrow itself instead"
			if dyn_proc_signature(c, base.type) != INVALID_TYPE {
				advice = "; the view only borrows the callable: move the callable into the task through a generic `Callable` parameter instead"
			}
		}
		errorf(
			c, span, "L0729", "`%s` reaches `%s`, so a task sharing it could write what the parent reaches too%s",
			type_name(c, base.type), type_name(c, facts.mutable), advice,
		)
	}
}

// A fact reached through a read-only view, said of the value that holds it:
// "`dyn I`, which may view ..." or "`Holder` reaches `dyn I`, which may view ...".
@(private = "file")
viewed_subject :: proc(c: ^Compiler, base, reached: Type_Id, via: Transfer_Via) -> string {
	chain := view_chain_text(c, reached, via)
	if via.view == base {
		return chain
	}
	return fmt.tprintf("`%s` reaches %s", type_name(c, base), chain)
}

// What an argument takes across: a `dyn` made at the call is checked through
// what it erased, which is known there. An explicit conversion to one is the
// implicit one written out, so its operand is what was erased.
@(private)
prov_transferred_type :: proc(c: ^Compiler, argument: Expr) -> Type_Id {
	base := expr_base(argument)
	if base.erased_from != INVALID_TYPE {
		return base.erased_from
	}
	if call, is_call := argument.(^Expr_Call); is_call && len(call.bound) == 1 && call.bound[0] != nil {
		kind := underlying_kind(c, call.type)
		#partial switch _ in call.operation {
		case Call_Dyn_Conversion, Call_Conversion:
			if kind == .Dyn {
				return prov_transferred_type(c, call.bound[0])
			}
		}
	}
	return base.type
}

// How a transfer fact is reached: "`dyn I`, which may view a `W`, which
// reaches `T`" through the read-only view `via` names, or "`T`" without one.
view_chain_text :: proc(c: ^Compiler, reached: Type_Id, via: Transfer_Via) -> string {
	if via.view == INVALID_TYPE {
		return fmt.tprintf("`%s`", type_name(c, reached))
	}
	if via.witness == reached {
		return fmt.tprintf("`%s`, which may view a `%s`", type_name(c, via.view), type_name(c, reached))
	}
	return fmt.tprintf(
		"`%s`, which may view a `%s`, which reaches `%s`",
		type_name(c, via.view), type_name(c, via.witness), type_name(c, reached),
	)
}

// With `through_views`, a `dyn` view is followed into every type the program
// converts to its interface application instead of counting as erased (design.md
// "Globals while tasks run", "Sharing with tasks").
transfer_facts :: proc(c: ^Compiler, type: Type_Id, through_views := false) -> Transfer_Facts {
	none := Transfer_Via{INVALID_TYPE, INVALID_TYPE}
	facts := Transfer_Facts {
		affine = INVALID_TYPE, erased = INVALID_TYPE, mutable = INVALID_TYPE, waker = INVALID_TYPE, viewed = INVALID_TYPE,
		affine_via = none, erased_via = none, viewed_via = none,
	}
	visited := make(map[Transfer_Visit]bool, 8, context.temp_allocator)
	transfer_facts_walk(c, type, &facts, &visited, through_views, none)
	return facts
}

@(private = "file")
transfer_facts_walk :: proc(
	c: ^Compiler, type: Type_Id, facts: ^Transfer_Facts, visited: ^map[Transfer_Visit]bool, through_views: bool,
	via: Transfer_Via,
) {
	visit := Transfer_Visit{type, via.view != INVALID_TYPE}
	if type == INVALID_TYPE || visited[visit] {
		return
	}
	visited[visit] = true
	info := type_of(c, type)
	if info == nil {
		return
	}
	if info.thread_affine && facts.affine == INVALID_TYPE {
		facts.affine, facts.affine_via = type, via
	}
	if info.wakes_on_drop && facts.waker == INVALID_TYPE {
		facts.waker = type
	}
	#partial switch info.kind {
	case .Pointer, .Slice, .Dyn:
		if !info.mutable {
			break
		}
		if visit.viewed && facts.viewed == INVALID_TYPE {
			facts.viewed, facts.viewed_via = type, via
		} else if !visit.viewed && facts.mutable == INVALID_TYPE {
			facts.mutable = type
		}
	}
	#partial switch info.kind {
	case .Dyn:
		if through_views && !view_is_printing(c, info) {
			for witness in view_witness_types(c, info) {
				inner := via
				if inner.view == INVALID_TYPE && !info.mutable {
					inner = {type, witness}
				}
				transfer_facts_walk(c, witness, facts, visited, through_views, inner)
			}
		} else if facts.erased == INVALID_TYPE {
			facts.erased, facts.erased_via = type, via
		}
	case .Distinct, .Pointer, .Slice, .Dynamic_Array, .Box, .Array, .Simd:
		transfer_facts_walk(c, info.element, facts, visited, through_views, via)
	case .Map:
		transfer_facts_walk(c, info.key, facts, visited, through_views, via)
		transfer_facts_walk(c, info.element, facts, visited, through_views, via)
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil {
				transfer_facts_walk(c, sym.type, facts, visited, through_views, via)
			}
		}
		// A `Shared(T)` holds its payload behind a `rawptr`, as a view may.
		for arg in info.instance_args {
			if arg.is_type {
				transfer_facts_walk(c, arg.type, facts, visited, through_views, via)
			}
		}
	case .Union:
		for variant in info.variants {
			transfer_facts_walk(c, variant, facts, visited, through_views, via)
		}
	}
}

// standard-library.md "Printed forms": a printed argument is viewed where it is
// written, but a nested field or a generic instance reaches its formatter in a
// pass after the effects, so these witnesses are not all known while checked.
@(private = "file")
view_is_printing :: proc(c: ^Compiler, view: ^Type_Info) -> bool {
	format, found := c.runtime_types["Format_View"]
	return found && underlying_info(c, format).dyn_interface == view.dyn_interface
}

// design.md "@(wakes_on_drop)": the `waker` of `transfer_facts`.
type_reaches_waker :: proc(c: ^Compiler, type: Type_Id) -> Type_Id {
	return transfer_facts(c, type).waker
}

// The `@(wakes_on_drop)` type the carrier at `path` in a `type` value belongs
// to: a marked type the path passes through, or one the carrier, or a
// truncated path's subtree, reaches. INVALID_TYPE for a carrier outside every
// marked subvalue. A generic record whose type argument reaches a marked type
// may hold one where no field shows it, behind a `rawptr`, so each of its
// carriers belongs to that type.
@(private)
path_waker :: proc(c: ^Compiler, type: Type_Id, path: []Proj_Step) -> Type_Id {
	info := type_of(c, type)
	if info == nil {
		return INVALID_TYPE
	}
	if info.wakes_on_drop {
		return type
	}
	if len(path) == 0 || type_is_carrier(c, type) {
		return type_reaches_waker(c, type)
	}
	step, rest := path[0], path[1:]
	if payload := shared_payload_type(c, type); payload != INVALID_TYPE {
		return path_waker(c, payload, rest)
	}
	#partial switch info.kind {
	case .Distinct:
		return path_waker(c, info.element, path)
	case .Struct:
		for arg in info.instance_args {
			if arg.is_type {
				if found := type_reaches_waker(c, arg.type); found != INVALID_TYPE {
					return found
				}
			}
		}
		if step.kind == .Field {
			for field in info.fields {
				if sym := symbol_of(c, field); sym != nil && i64(sym.index) == step.lo {
					return path_waker(c, sym.type, rest)
				}
			}
		}
	case .Union:
		for variant in info.variants {
			if found := path_waker(c, variant, rest); found != INVALID_TYPE {
				return found
			}
		}
		return INVALID_TYPE
	case .Array, .Dynamic_Array, .Box:
		return path_waker(c, info.element, rest)
	case .Map:
		if len(rest) > 0 && rest[0].kind == .Field {
			return path_waker(c, rest[0].lo == PROJ_MAP_KEY ? info.key : info.element, rest[1:])
		}
	}
	return type_reaches_waker(c, type)
}

// Appends to `objects` the type of each object a value of `type` points to,
// owns out of line, or views; false when it holds a raw or foreign pointer or
// an erased view, whose target may be storage of any type. An allocator's
// state is its own, and a procedure value holds no state. `inside` holds the
// types the walk is within, so a record already diagnosed as holding itself
// by value counts as unknown storage rather than recursing forever. A
// body-local type skips the package's finite-size phase, so `size_state`
// alone would miss its cycle, and a path rather than a visited set keeps two
// sibling fields of one type from looking like a cycle.
@(private)
collect_pointees :: proc(c: ^Compiler, type: Type_Id, objects: ^[dynamic]Type_Id, inside: ^[dynamic]Type_Id) -> bool {
	add :: proc(objects: ^[dynamic]Type_Id, type: Type_Id) {
		if !slice.contains(objects[:], type) {
			append(objects, type)
		}
	}
	info := type_of(c, type)
	if info == nil || slice.contains(inside[:], type) {
		return false
	}
	append(inside, type)
	defer pop(inside)
	#partial switch info.kind {
	case .Raw_Pointer, .C_Pointer, .Dyn, .Interface, .Type, .Invalid:
		return false
	case .Distinct, .Array, .Simd:
		return collect_pointees(c, info.element, objects, inside)
	case .Pointer, .Slice, .Dynamic_Array, .Box:
		add(objects, info.element)
	case .Map:
		add(objects, info.key)
		add(objects, info.element)
	case .String, .String_View, .CString_View:
		add(objects, TYPE_U8)
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil && !collect_pointees(c, sym.type, objects, inside) {
				return false
			}
		}
	case .Union:
		for variant in info.variants {
			if !collect_pointees(c, variant, objects, inside) {
				return false
			}
		}
	}
	return true
}

// Whether storage of type `outer` holds storage of type `inner` within its own
// bytes: itself, or a field, element, or variant, at any depth. A distinct type
// shares its storage with what it wraps, and a view's mutability is not part
// of its storage. `outer` must be one `collect_pointees` walked without finding
// unknown storage, which rules out a record holding itself by value along the
// same edges this follows.
@(private)
type_holds_inline :: proc(c: ^Compiler, outer, inner: Type_Id) -> bool {
	if same_storage_type(c, outer, inner) {
		return true
	}
	info := type_of(c, outer)
	if info == nil {
		return true
	}
	#partial switch info.kind {
	case .Distinct, .Array, .Simd:
		return type_holds_inline(c, info.element, inner)
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil && type_holds_inline(c, sym.type, inner) {
				return true
			}
		}
	case .Union:
		for variant in info.variants {
			if type_holds_inline(c, variant, inner) {
				return true
			}
		}
	}
	return false
}

// Two types share one storage layout: the same underlying type, or pointers or
// views of such. A distinct pointer to itself bounds the walk as
// `type_underlying` bounds its own.
@(private = "file")
same_storage_type :: proc(c: ^Compiler, a, b: Type_Id) -> bool {
	first, second := a, b
	for _ in 0 ..< len(c.types) + 1 {
		first, second = type_underlying(c, first), type_underlying(c, second)
		if first == second {
			return true
		}
		x, y := type_of(c, first), type_of(c, second)
		if x == nil || y == nil || x.kind != y.kind || x.kind != .Pointer && x.kind != .Slice {
			return false
		}
		first, second = x.element, y.element
	}
	return true
}
