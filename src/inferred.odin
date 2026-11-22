// What the compiler inferred about a procedure and its signature does not say
// (future-plans.md "Package documentation"): what its result borrows and which
// allocator backs it, from its result contract (design.md "Procedure result
// contracts"), and whose package state a call writes, from its write effect
// (design.md "Global write effects"). An interface file and a hover show them.
package lokec

import "core:fmt"
import "core:strings"

// One phrase per fact, in a fixed order, and none when there is nothing to
// report. A template has no summary of its own, since each instance has one, so
// a generic procedure reports nothing.
//
// A parameter gets one phrase, its strongest: an allocator handle that backs the
// result is not also said to be borrowed, and a parameter the result borrows is
// not also said to lend its allocator, since the caller keeps the argument
// either way.
inferred_facts :: proc(c: ^Compiler, procedure: Symbol_Id, allocator := context.temp_allocator) -> []string {
	symbol := symbol_of(c, procedure)
	if symbol == nil || !c.program_analyzed {
		return nil
	}
	facts := make([dynamic]string, allocator)
	if summary, found := c.result_summaries[procedure]; found && summary != nil {
		for id, index in symbol.param_symbols {
			parameter := symbol_of(c, id)
			if parameter == nil {
				continue
			}
			name := identifier_text(c, parameter.name)
			handle := type_is_allocator(c, parameter.type)
			backs := index < REGION_PARAM_LIMIT && summary.region.params & (1 << uint(index)) != 0
			switch {
			case backs && handle:
				append(&facts, fmt.aprintf("result is backed by `%s`", name, allocator = allocator))
			case index < len(summary.params) && summary.params[index]:
				for path in borrowed_paths(c, parameter.type, summary.param_paths[index], allocator) {
					append(&facts, fmt.aprintf("result borrows `%s%s`", name, path, allocator = allocator))
				}
			case index < len(summary.param_loads) && summary.param_loads[index] != 0:
				append(&facts, fmt.aprintf("result borrows through `%s`", name, allocator = allocator))
			case backs:
				append(&facts, fmt.aprintf("result is backed by the allocator of `%s`", name, allocator = allocator))
			}
		}
		for owner in state_owners(c, symbol.pkg, summary.globals, allocator) {
			append(&facts, fmt.aprintf("result borrows %s", owner, allocator = allocator))
		}
	}
	// A procedure's own part: what a callback it is handed writes is its
	// caller's to know.
	program := &c.effect_program
	if index, found := program.index_of[procedure]; found && index < len(program.own) {
		for owner in state_owners(c, symbol.pkg, program.own[index].writes, allocator) {
			append(&facts, fmt.aprintf("writes %s", owner, allocator = allocator))
		}
	}
	return facts[:]
}

// The paths of a parameter the result may borrow, each as the selectors after
// its name: one empty text for the whole parameter, which no row or a row of
// another shape also means.
@(private = "file")
borrowed_paths :: proc(c: ^Compiler, type: Type_Id, row: []bool, allocator := context.temp_allocator) -> []string {
	shape := carrier_shape(c, type)
	out := make([dynamic]string, allocator)
	if len(row) == len(shape) && len(shape) > 1 {
		for borrowed, index in row {
			if !borrowed {
				continue
			}
			text := path_selectors(c, type, shape[index].steps, allocator)
			// Two paths the selectors do not tell apart are one fact.
			repeated := false
			for seen in out {
				repeated ||= seen == text
			}
			if !repeated {
				append(&out, text)
			}
		}
	}
	if len(out) == 0 {
		append(&out, "")
	}
	return out[:]
}

// A carrier path as the fields it selects, as `.items` or `.pair.left`. It ends
// at the first step that is not a record's field: an element, a variant, or a
// map's key or value has no selector a reader could write after the name.
@(private = "file")
path_selectors :: proc(c: ^Compiler, type: Type_Id, steps: []Proj_Step, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	current := type
	for step in steps {
		info := underlying_info(c, current)
		if info == nil || info.kind != .Struct || step.kind != .Field || step.lo < 0 || int(step.lo) >= len(info.fields) {
			break
		}
		field := symbol_of(c, info.fields[int(step.lo)])
		if field == nil {
			break
		}
		fmt.sbprintf(&b, ".%s", identifier_text(c, field.name))
		current = field.type
	}
	return strings.to_string(b)
}

// Whose state `globals` are: `package state` for the procedure's own package,
// then ``state of `core:log` `` for each package it imports, in the order first
// met. A global of any other package is reached only through an indirect call,
// whose bodies are the compilation's and not the procedure's, so it is left out
// and the phrases are the same whichever program the package is checked in.
@(private = "file")
state_owners :: proc(c: ^Compiler, own: Package_Id, globals: []Symbol_Id, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	packages := make([dynamic]Package_Id, context.temp_allocator)
	mine := false
	for id in globals {
		global := symbol_of(c, id)
		if global == nil {
			continue
		}
		if global.pkg == own {
			mine = true
			continue
		}
		known := false
		for seen in packages {
			known ||= seen == global.pkg
		}
		if !known && package_imports(c, own, global.pkg) {
			append(&packages, global.pkg)
		}
	}
	if mine {
		append(&out, "package state")
	}
	for id in packages {
		if pkg := package_of(c, id); pkg != nil {
			append(&out, fmt.aprintf("state of `%s`", pkg.key, allocator = allocator))
		}
	}
	return out[:]
}

// Whether `from` imports `target`, directly or through its imports.
@(private = "file")
package_imports :: proc(c: ^Compiler, from, target: Package_Id) -> bool {
	visited := make(map[Package_Id]bool, 16, context.temp_allocator)
	pending := make([dynamic]Package_Id, context.temp_allocator)
	append(&pending, from)
	for len(pending) > 0 {
		pkg := package_of(c, pop(&pending))
		if pkg == nil {
			continue
		}
		for imported in pkg.imports {
			if imported.target == target {
				return true
			}
			if !visited[imported.target] {
				visited[imported.target] = true
				append(&pending, imported.target)
			}
		}
	}
	return false
}
