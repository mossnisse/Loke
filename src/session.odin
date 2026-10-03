// Reusable batch compilations. The driver owns presentation and artifact
// choices; a session owns configuration and all state of its current program.
package lokec

import "core:mem"
import "core:mem/virtual"
import "core:strings"

Compilation_Config :: struct {
	defines:           []string,
	collections:       []string,
	copy_cost:         u64,
	copy_cost_enabled: bool,
	panic_unwind:      bool,
	opt_mode:          Opt_Mode,
	build_mode:        Build_Mode,
	debug_info:        bool,
	debug:             bool,
	log_level:         Log_Level,
}

DEFAULT_COMPILATION_CONFIG :: Compilation_Config{
	copy_cost = 512,
	copy_cost_enabled = true,
	panic_unwind = true,
}

// Fill in place and never copy a live session: its allocators point into it.
// Compiler data, IDs, diagnostics and emitted text are borrowed until the next
// overlay edit, check or destruction. Configuration is copied and fixed for
// the session.
Compilation_Session :: struct {
	compiler: Compiler,
	config: Compilation_Config,
	allocator: mem.Allocator,
	configuration_arena: virtual.Arena,
	scratch_arena: virtual.Arena,
	overlays: map[string]Source_Overlay,
	query_arena: virtual.Arena,
	snapshot: Snapshot_Id,
	queries: Snapshot_Queries,
	queries_ready: bool,
	initialized, configured, started, ready: bool,
}

init_session :: proc(s: ^Compilation_Session, config := DEFAULT_COMPILATION_CONFIG) -> bool {
	if s.initialized { return false }
	s.initialized = true
	s.allocator = context.allocator
	s.overlays = make(map[string]Source_Overlay, s.allocator)
	s.snapshot = next_snapshot_id()
	s.config = config
	allocator := virtual.arena_allocator(&s.configuration_arena)
	s.config.defines = make([]string, len(config.defines), allocator)
	for entry, index in config.defines {
		s.config.defines[index] = strings.clone(entry, allocator)
	}
	s.config.collections = make([]string, len(config.collections), allocator)
	for entry, index in config.collections {
		s.config.collections[index] = strings.clone(entry, allocator)
	}
	s.configured = configure_session(s)
	return s.configured
}

@(private = "file")
configure_session :: proc(s: ^Compilation_Session) -> bool {
	context.allocator = s.allocator
	context.temp_allocator = virtual.arena_allocator(&s.scratch_arena)
	c, config := &s.compiler, s.config
	c.copy_cost_threshold, c.copy_cost_enabled = config.copy_cost, config.copy_cost_enabled
	c.panic_unwind = config.panic_unwind
	c.opt_mode, c.build_mode = config.opt_mode, config.build_mode
	c.debug_info, c.debug = config.debug_info, config.debug
	c.log_level = config.log_level
	configured := seed_defines(c, config.defines) && register_collections(c, config.collections)
	c.source_overlays = s.overlays
	return configured
}

// Every check reloads sources, manifests and imports and runs the whole-program
// pipeline. Even a failed check replaces the preceding compilation. Documentation
// checks omit entry validation and finalization, as the CLI's -doc path does.
check_session :: proc(s: ^Compilation_Session, input: string, documentation := false) -> bool {
	if !s.initialized || !s.configured { return false }
	context.allocator = s.allocator
	// Input may itself be borrowed from the preceding snapshot.
	input_copy := strings.clone(input)
	defer delete(input_copy)
	invalidate_session_snapshot(s)
	s.snapshot = next_snapshot_id()
	if s.started {
		destroy_compilation(&s.compiler)
		virtual.arena_destroy(&s.scratch_arena)
		if !configure_session(s) { return false }
	}
	s.started, s.ready = true, false
	context.temp_allocator = virtual.arena_allocator(&s.scratch_arena)
	c := &s.compiler
	// The caller may release its path as soon as this call returns.
	path := strings.clone(input_copy, c.semantic_allocator)
	if !register_project(c, path) { return false }
	root, compiled := compile_program(c, path)
	if compiled {
		if c.build_mode == .Exe && !documentation { validate_executable(c, root) }
		check_exports(c)
	}
	if c.error_count > 0 { return false }
	if !documentation {
		finalize_semantics(c)
		s.ready = c.error_count == 0
	}
	return c.error_count == 0
}

// In-memory emission creates no artifacts and performs no toolchain invocation.
// It consumes only the finalized state; an unchecked/failed/documentation
// session is rejected without entering the backend.
emit_session_ir :: proc(s: ^Compilation_Session) -> (string, bool) {
	if !s.ready || s.compiler.error_count > 0 { return "", false }
	context.temp_allocator = virtual.arena_allocator(&s.scratch_arena)
	return emit_llvm_module(&s.compiler)
}

// Artifact/toolchain policy is supplied separately from checking configuration.
emit_session :: proc(s: ^Compilation_Session, opts: Emission_Options) -> int {
	if !s.ready || s.compiler.error_count > 0 { return 2 }
	context.allocator = s.allocator
	context.temp_allocator = virtual.arena_allocator(&s.scratch_arena)
	if opts.output == "" {
		errorf(&s.compiler, no_span(), "L0401", "an output path is required")
		return 2
	}
	return emit_package(&s.compiler, opts)
}

// Safe after a failed initialization/check and on an already destroyed session.
destroy_session :: proc(s: ^Compilation_Session) {
	if s.initialized { context.allocator = s.allocator }
	invalidate_session_snapshot(s)
	destroy_compilation(&s.compiler)
	virtual.arena_destroy(&s.scratch_arena)
	virtual.arena_destroy(&s.configuration_arena)
	for _, overlay in s.overlays {
		delete(overlay.key)
		delete(overlay.path)
		delete(overlay.text)
	}
	delete(s.overlays)
	s^ = {}
}

@(private = "file")
seed_defines :: proc(c: ^Compiler, defines: []string) -> bool {
	init_semantic_stores(c)
	c.defines = make(map[string]Const_Value, len(defines), c.semantic_allocator)
	for entry in defines {
		split := strings.index_byte(entry, '=')
		if split <= 0 {
			errorf(c, no_span(), "L0388", "`-define:%s` needs the form NAME=VALUE", entry)
			continue
		}
		name := entry[:split]
		text := entry[split + 1:]
		if !is_config_name(name) {
			errorf(c, no_span(), "L0388", "`%s` is not a valid configuration name", name)
			continue
		}
		if _, duplicate := c.defines[name]; duplicate {
			errorf(c, no_span(), "L0388", "`%s` is defined more than once", name)
			continue
		}
		switch text {
		case "true":
			c.defines[name] = bool_const(true)
		case "false":
			c.defines[name] = bool_const(false)
		case:
			if value, ok := bi_parse_int_literal(c, text); ok {
				c.defines[name] = integer_const(value)
			} else {
				c.defines[name] = Const_Value{kind = .String, text = text}
			}
		}
	}
	return c.error_count == 0
}

@(private = "file")
is_config_name :: proc(name: string) -> bool {
	for i in 0 ..< len(name) {
		ch := name[i]
		letter := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_'
		if !letter && !(i > 0 && ch >= '0' && ch <= '9') {
			return false
		}
	}
	return len(name) > 0
}

// Explicit entries replace bundled `base:` and `core:` roots.
@(private = "file")
register_collections :: proc(c: ^Compiler, entries: []string) -> bool {
	init_semantic_stores(c)
	for name in ([]string{"base", "core"}) {
		if bundled := install_component(name); bundled != "" {
			// Cloned like an explicit entry, so the whole map has one owner and
			// the heap path `install_component` returns is not left behind.
			c.collections[name] = strings.clone(bundled, c.semantic_allocator)
			delete(bundled)
		}
	}

	explicit := make(map[string]bool, len(entries), context.temp_allocator)
	for entry in entries {
		split := strings.index_byte(entry, '=')
		if split <= 0 {
			errorf(c, no_span(), "L0333", "`-collection %s` needs the form name=path", entry)
			continue
		}
		name := entry[:split]
		root := entry[split + 1:]
		if strings.index_byte(name, ':') >= 0 {
			errorf(c, no_span(), "L0333", "collection name `%s` cannot contain `:`", name)
			continue
		}
		if root == "" {
			errorf(c, no_span(), "L0333", "collection `%s` needs a path", name)
			continue
		}
		if explicit[name] {
			errorf(c, no_span(), "L0333", "collection `%s` is registered more than once", name)
			continue
		}
		explicit[name] = true
		c.collections[name] = strings.clone(root, c.semantic_allocator)
	}
	return c.error_count == 0
}
