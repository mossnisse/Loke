// Projection paths: the steps from a root's storage down to a place in it, and how
// two paths compare. They need no solver state, so the walk, the carrier shapes and
// the solver in `borrow.odin` share them.
package lokec

import "core:mem"

Proj_Kind :: enum u8 {
	Field,
	Range, // half-open constant element range; an index `i` is [i, i+1)
	Wild,  // anything not statically distinct; overlaps every sibling
}

Proj_Step :: struct {
	precision: Precision_Loss,
	kind:      Proj_Kind,
	// design.md "@(synchronized)": the step selects a synchronized field from
	// outside its package, so reaching the place is exclusive access.
	synchronized: bool,
	// An element of a dynamic array, which an operation may move to another
	// index. Carrier slots see that happen (`rearrange_carriers`); region facts,
	// being flow-insensitive, do not (`prov_region_path`).
	shifts:    bool,
	lo:        i64,
	hi:        i64,
}

path_is_synchronized :: proc(path: []Proj_Step) -> bool {
	for step in path {
		if step.synchronized {
			return true
		}
	}
	return false
}

proj_field :: proc(index: int) -> Proj_Step {
	return Proj_Step{kind = .Field, lo = i64(index)}
}

proj_range :: proc(lo, hi: i64) -> Proj_Step {
	return Proj_Step{kind = .Range, lo = lo, hi = hi}
}

proj_wild :: proc() -> Proj_Step {
	return Proj_Step{kind = .Wild}
}

// Element `index` of a dynamic array, one by itself up to the budget.
proj_dynamic_element :: proc(index: i64) -> Proj_Step {
	return Proj_Step{kind = .Range, lo = index, hi = index + 1, shifts = true}
}

// A new path, one step below `path`.
path_extend :: proc(path: []Proj_Step, step: Proj_Step, allocator: mem.Allocator) -> []Proj_Step {
	out := make([]Proj_Step, len(path) + 1, allocator)
	copy(out, path)
	out[len(path)] = step
	return out
}

// `path` below `prefix`, which is one of the two when the other is empty.
path_concat :: proc(prefix, path: []Proj_Step, allocator: mem.Allocator) -> []Proj_Step {
	if len(prefix) == 0 {
		return path
	}
	if len(path) == 0 {
		return prefix
	}
	out := make([]Proj_Step, len(prefix) + len(path), allocator)
	copy(out, prefix)
	copy(out[len(prefix):], path)
	return out
}

// Whether two steps name one place, whatever else each records of how it was
// reached.
same_step :: proc(a, b: Proj_Step) -> bool {
	return a.kind == b.kind && a.lo == b.lo && a.hi == b.hi
}

// Two paths into one root overlap unless some step proves them disjoint, so a
// prefix overlaps everything below it.
paths_overlap :: proc(a, b: []Proj_Step) -> bool {
	shared := min(len(a), len(b))
	for index in 0 ..< shared {
		if !steps_overlap(a[index], b[index]) {
			return false
		}
	}
	return true
}

@(private)
steps_overlap :: proc(a, b: Proj_Step) -> bool {
	if a.kind != b.kind {
		return true // nothing was proven distinct
	}
	#partial switch a.kind {
	case .Field:
		return a.lo == b.lo
	case .Range:
		return a.lo < b.hi && b.lo < a.hi
	}
	return true
}

@(private)
path_is_indistinct :: proc(path: []Proj_Step) -> bool {
	for step in path {
		if step.kind == .Wild || step.kind == .Range && step.hi - step.lo > 1 {
			return true
		}
	}
	return false
}

// Whether `path` names one place: fields and single constant elements, none
// merged.
@(private)
path_is_exact :: proc(path: []Proj_Step) -> bool {
	for step in path {
		if step.kind == .Wild || step.kind == .Range && step.hi != step.lo + 1 || step.precision != {} {
			return false
		}
	}
	return true
}

@(private)
path_has_exact_prefix :: proc(path, prefix: []Proj_Step) -> bool {
	if len(prefix) > len(path) {
		return false
	}
	for step, index in prefix {
		if !same_step(step, path[index]) {
			return false
		}
	}
	return true
}

// Whether the place `path` names may be the one `tail` names inside a value
// stored at some place: whether its last steps may overlap `tail`.
@(private)
prov_path_may_end_in :: proc(path, tail: []Proj_Step) -> bool {
	return len(path) >= len(tail) && paths_overlap(path[len(path) - len(tail):], tail)
}

@(private)
prov_same_path :: proc(a, b: []Proj_Step) -> bool {
	return len(a) == len(b) && path_has_exact_prefix(a, b)
}
