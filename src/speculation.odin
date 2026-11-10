// Speculative checking: probes whose diagnostics roll back, the one sanctioned
// commit from inside a probe, settling a declaration for the whole program, and
// holding diagnostics aside meanwhile (compiler-architecture.md "Checking and
// overload resolution").
package lokec

// A hypothetical check (compiler-architecture.md "Checking and overload
// resolution"). `end_probe` fails if a probe grew the emission registries without
// a `begin_commit`.
Probe :: struct {
	diagnostics, depth, commits: int,
	registries:                  Emission_Registries,
}

// The sizes of the registries emission reads.
Emission_Registries :: struct {
	typeids, typeid_order, witnesses, witness_order: int,
	materialized, materialized_order:                int,
	instances, checked_bodies, static_locals:        int,
	synth_procs, spawn_tasks:                        int,
	format_requested, type_info_requested:           bool,
}

emission_registries :: proc(c: ^Compiler) -> Emission_Registries {
	r := Emission_Registries {
		typeids             = len(c.typeid_requested),
		typeid_order        = len(c.typeid_order),
		witnesses           = len(c.witnesses),
		witness_order       = len(c.witness_order),
		materialized        = len(c.materialized),
		materialized_order  = len(c.materialized_order),
		checked_bodies      = len(c.checked_bodies),
		static_locals       = len(c.static_locals),
		synth_procs         = len(c.synth_procs),
		spawn_tasks         = len(c.spawn_tasks),
		format_requested    = c.format_requested,
		type_info_requested = c.type_info_requested,
	}
	for pkg in c.packages { r.instances += len(pkg.instances) }
	return r
}

begin_probe :: proc(c: ^Compiler) -> Probe {
	c.speculation_depth += 1
	return Probe {
		diagnostics = len(c.diagnostics),
		depth       = c.speculation_depth,
		commits     = c.commits,
		registries  = emission_registries(c),
	}
}

end_probe :: proc(c: ^Compiler, probe: Probe, keep := false) {
	assert(c.speculation_depth == probe.depth, "a probe ended out of order")
	assert(c.commits != probe.commits || emission_registries(c) == probe.registries,
	       "a probe enrolled emission state without asking committing(c)")
	if !keep {
		truncate_diagnostics(c, probe.diagnostics)
	}
	c.speculation_depth -= 1
	// Nothing is left to roll back what was held from this probe. A body under a
	// commit may still sit inside a probe the commit set aside.
	if c.speculation_depth == 0 && c.open_commits == 0 {
		release_held_diagnostics(c)
	}
}

// Whether what the checker finds now belongs to the program, as it does outside
// every probe. Every such write asks this; nothing else reads `speculation_depth`.
committing :: proc(c: ^Compiler) -> bool {
	return c.speculation_depth == 0
}

// The one sanctioned commit from inside a probe: `ensure_proc_typed_for_eval`
// checks a body compile-time evaluation will execute, which is a real use.
begin_commit :: proc(c: ^Compiler) -> (saved: int) {
	saved = c.speculation_depth
	c.speculation_depth = 0
	c.commits += 1
	c.open_commits += 1
	return
}

end_commit :: proc(c: ^Compiler, saved: int) {
	c.speculation_depth = saved
	c.open_commits -= 1
}

// A declaration is settled once, and the check that settles it is never run again,
// so whichever check asks first, it is settled for the program: a probe that led to
// it rolls back what the probe found, not what the declaration did.
Settling :: struct {
	speculation, mark: int,
	in_probe:          bool,
}

begin_settling :: proc(c: ^Compiler, d: ^Decl) -> Settling {
	return begin_settling_file_scope(c) if d.top_level else {}
}

// For what is declared at file scope but is not a `top_level` declaration, such as a
// member of a block.
begin_settling_file_scope :: proc(c: ^Compiler) -> Settling {
	if committing(c) {
		return {}
	}
	return {speculation = begin_commit(c), mark = len(c.diagnostics), in_probe = true}
}

end_settling :: proc(c: ^Compiler, settling: Settling) {
	if settling.in_probe {
		hold_diagnostics(c, settling.mark)
		end_commit(c, settling.speculation)
	}
}

// Whether an error was reported since `mark`, a length of `c.diagnostics`.
// Diagnostics a nested check held aside belong to that check.
errors_since :: proc(c: ^Compiler, mark: int) -> bool {
	for d in c.diagnostics[clamp(mark, 0, len(c.diagnostics)):] {
		if d.severity == .Error { return true }
	}
	return false
}

// Moves every diagnostic past `length`, with its share of `error_count`, out of
// `truncate_diagnostics`' reach until `release_held_diagnostics`.
hold_diagnostics :: proc(c: ^Compiler, length: int) {
	wanted := clamp(length, 0, len(c.diagnostics))
	context.allocator = diagnostic_allocator(c)
	for index in wanted ..< len(c.diagnostics) {
		if c.diagnostics[index].severity == .Error {
			c.error_count -= 1
		}
		append(&c.held_diagnostics, c.diagnostics[index])
	}
	shrink_diagnostics(c, wanted)
}

release_held_diagnostics :: proc(c: ^Compiler) {
	context.allocator = diagnostic_allocator(c)
	for d in c.held_diagnostics {
		append(&c.diagnostics, d)
		if d.severity == .Error {
			c.error_count += 1
		}
	}
	clear(&c.held_diagnostics)
}
