// Read-only views of the current compilation. All handles carry a snapshot ID;
// no query resolves a name, checks syntax, or exposes a mutable semantic node.
package lokec

import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"

Snapshot_Id :: distinct u64
Compilation_Snapshot :: struct { id: Snapshot_Id }
Symbol_Handle :: struct { snapshot: Snapshot_Id, id: Symbol_Id }
Type_Handle :: struct { snapshot: Snapshot_Id, id: Type_Id }
Query_Location :: struct { snapshot: Snapshot_Id, span: Span }

Query_Source :: struct { path, text: string, line_starts: []u32 }
Query_Symbol :: struct {
	handle: Symbol_Handle,
	name: string,
	kind: Symbol_Kind,
	type: Type_Handle,
	definition: Query_Location,
	public, generic: bool,
}
Query_Type :: struct {
	handle: Type_Handle,
	name: string,
	kind: Type_Kind,
	element, key, result: Type_Handle,
	count: u64,
	bits: u16,
	signed, mutable, result_inout: bool,
	fields, members: []Symbol_Handle,
	parameters: []Type_Handle,
	param_modes: []Param_Mode,
}
Query_Parameter :: struct { name: string, type: Type_Handle, mode: Param_Mode, has_default: bool }
Query_Signature :: struct {
	symbol: Symbol_Handle,
	text: string,
	parameters: []Query_Parameter,
	result: Type_Handle,
	complete, result_inout, diverges: bool,
}
Query_Note :: struct { location: Query_Location, message: string }
Query_Diagnostic :: struct {
	severity: Severity,
	code, message, label: string,
	location: Query_Location,
	notes: []Query_Note,
}
Query_Position :: struct { location: Query_Location, symbol: Symbol_Handle, type: Type_Handle }

@(private = "file")
snapshot_counter: u64
next_snapshot_id :: proc() -> Snapshot_Id {
	// Process-wide identity also rejects handles from other sessions or from a
	// session destroyed and recreated at the same address.
	return Snapshot_Id(sync.atomic_add(&snapshot_counter, 1) + 1)
}

invalidate_session_snapshot :: proc(s: ^Compilation_Session) {
	s.snapshot, s.ready, s.queries_ready = 0, false, false
	virtual.arena_destroy(&s.query_arena)
	s.queries = {}
}

// Capture views once, on demand, including after failed initialization/checking.
// Later calls and every query only read, so several threads may share them;
// keep it that way (compiler-architecture.md "Snapshots and queries").
// Returned strings/slices are borrowed and must not be modified. They expire at
// invalidation, an overlay edit, the next check, or destruction. Capture
// diagnostics before emission to obtain checking diagnostics; later emission
// cannot change them.
session_snapshot :: proc(s: ^Compilation_Session) -> (Compilation_Snapshot, bool) {
	if !s.initialized || s.snapshot == 0 { return {}, false }
	if !s.queries_ready {
		build_snapshot_queries(s)
		s.queries_ready = true
	}
	return Compilation_Snapshot{s.snapshot}, true
}

@(private = "file")
valid_snapshot :: proc(s: ^Compilation_Session, id: Snapshot_Id) -> bool {
	return s.initialized && s.queries_ready && id != 0 && id == s.snapshot
}

query_source :: proc(s: ^Compilation_Session, snapshot: Compilation_Snapshot, file: u32) -> (Query_Source, bool) {
	if !valid_snapshot(s, snapshot.id) || int(file) >= len(s.compiler.sources) { return {}, false }
	source := s.compiler.sources[file]
	return Query_Source{source.path, source.text, source.line_starts}, true
}

query_file :: proc(s: ^Compilation_Session, snapshot: Compilation_Snapshot, path: string) -> (u32, bool) {
	if !valid_snapshot(s, snapshot.id) { return 0, false }
	key := dir_key(canonical_dir(path))
	for source, index in s.compiler.sources {
		if strings.equal_fold(canonical_dir(source.path), key) { return u32(index), true }
	}
	return 0, false
}

query_diagnostics :: proc(s: ^Compilation_Session, snapshot: Compilation_Snapshot) -> ([]Query_Diagnostic, bool) {
	if !valid_snapshot(s, snapshot.id) { return nil, false }
	return s.queries.diagnostics, true
}

// All source-backed bindings in a file, including locals/fields/parameters,
// once per written definition. Missing or uncollected declarations are omitted.
query_symbols :: proc(s: ^Compilation_Session, snapshot: Compilation_Snapshot, file: u32) -> ([]Symbol_Handle, bool) {
	if !valid_snapshot(s, snapshot.id) || int(file) >= len(s.queries.documents) { return nil, false }
	return s.queries.documents[file][:], true
}

query_symbol :: proc(s: ^Compilation_Session, handle: Symbol_Handle) -> (Query_Symbol, bool) {
	if !valid_snapshot(s, handle.snapshot) || handle.id == INVALID_SYMBOL || int(handle.id) >= len(s.queries.symbols) { return {}, false }
	return s.queries.symbols[handle.id], true
}

query_type :: proc(s: ^Compilation_Session, handle: Type_Handle) -> (Query_Type, bool) {
	if !valid_snapshot(s, handle.snapshot) || handle.id == INVALID_TYPE || int(handle.id) >= len(s.queries.types) { return {}, false }
	return s.queries.types[handle.id], true
}

query_definition :: proc(s: ^Compilation_Session, handle: Symbol_Handle) -> (Query_Location, bool) {
	if _, found := query_symbol(s, handle); !found { return {}, false }
	id := s.queries.canonical[handle.id]
	location := s.queries.symbols[id].definition
	return location, location.span.file != NO_FILE
}

// Exact binding identity, not matching spelling. The caller owns the returned
// array and deletes it. Definitions are optional; locations are deduplicated.
query_references :: proc(s: ^Compilation_Session, handle: Symbol_Handle, include_definition := false) -> ([]Query_Location, bool) {
	if _, found := query_symbol(s, handle); !found { return nil, false }
	id := s.queries.canonical[handle.id]
	out := make([dynamic]Query_Location)
	seen := make(map[Span]bool)
	defer delete(seen)
	if include_definition {
		if location, found := query_definition(s, handle); found {
			append(&out, location)
			seen[location.span] = true
		}
	}
	for occurrence in s.queries.occurrences {
		if occurrence.reference && occurrence.symbol != INVALID_SYMBOL &&
		   s.queries.canonical[occurrence.symbol] == id && !seen[occurrence.span] {
			append(&out, Query_Location{s.snapshot, occurrence.span})
			seen[occurrence.span] = true
		}
	}
	return out[:], true
}

// A procedure group returns its available members. A generic template supplies
// written syntax with complete=false; erroneous/unresolved signatures are absent.
query_signatures :: proc(s: ^Compilation_Session, handle: Symbol_Handle) -> ([]Query_Signature, bool) {
	if _, found := query_symbol(s, handle); !found { return nil, false }
	signatures := s.queries.signatures[handle.id]
	return signatures[:], len(signatures) > 0
}

// Byte offsets are half-open, as Span is. Choose the narrowest written node;
// do not fall back to a parent when that node is unresolved. Instantiations
// disagreeing at the same source position yield no symbol/type for that part.
query_at :: proc(s: ^Compilation_Session, snapshot: Compilation_Snapshot, file, offset: u32) -> (Query_Position, bool) {
	if source, found := query_source(s, snapshot, file); !found || int(offset) >= len(source.text) { return {}, false }
	best := Query_Occurrence{span = no_span()}
	symbol_conflict, type_conflict := false, false
	for occurrence in s.queries.occurrences {
		span := occurrence.span
		if span.file != file || offset < span.lo || offset >= span.hi { continue }
		if best.span.file == NO_FILE || span.hi - span.lo < best.span.hi - best.span.lo {
			best = occurrence
			symbol_conflict, type_conflict = false, false
		} else if span == best.span {
			// A structural wrapper may have no binding/type of its own. Merge
			// known annotations, but never restore a conflicting specialization.
			if occurrence.type != INVALID_TYPE && !type_conflict {
				if best.type == INVALID_TYPE { best.type = occurrence.type }
				else if occurrence.type != best.type { best.type, type_conflict = INVALID_TYPE, true }
			}
			if occurrence.symbol != INVALID_SYMBOL && !symbol_conflict {
				if best.symbol == INVALID_SYMBOL { best.symbol = occurrence.symbol }
				else if s.queries.canonical[occurrence.symbol] != s.queries.canonical[best.symbol] {
					best.symbol, symbol_conflict = INVALID_SYMBOL, true
				}
			}
		}
	}
	if best.span.file == NO_FILE || (best.symbol == INVALID_SYMBOL && best.type == INVALID_TYPE) { return {}, false }
	return Query_Position{Query_Location{s.snapshot, best.span}, Symbol_Handle{s.snapshot, best.symbol}, Type_Handle{s.snapshot, best.type}}, true
}

@(private)
Query_Occurrence :: struct { span: Span, symbol: Symbol_Id, type: Type_Id, reference: bool }
@(private)
Snapshot_Queries :: struct {
	symbols: []Query_Symbol,
	types: []Query_Type,
	canonical: []Symbol_Id,
	documents: [][dynamic]Symbol_Handle,
	signatures: [][dynamic]Query_Signature,
	diagnostics: []Query_Diagnostic,
	occurrences: [dynamic]Query_Occurrence,
}

@(private = "file")
build_snapshot_queries :: proc(s: ^Compilation_Session) {
	context.allocator = virtual.arena_allocator(&s.query_arena)
	context.temp_allocator = context.allocator
	c, q := &s.compiler, &s.queries
	q.symbols = make([]Query_Symbol, len(c.symbols))
	q.types = make([]Query_Type, len(c.types))
	q.canonical = make([]Symbol_Id, len(c.symbols))
	q.documents = make([][dynamic]Symbol_Handle, len(c.sources))
	q.signatures = make([][dynamic]Query_Signature, len(c.symbols))
	q.diagnostics = make([]Query_Diagnostic, len(c.diagnostics))
	// Cloned syntax represents the same written binding, even when its types
	// differ by specialization. Instance procedures point back to the template.
	Binding_Key :: struct { span: Span, kind: Symbol_Kind, name: Identifier_Id }
	bindings := make(map[Binding_Key]Symbol_Id)
	for symbol, index in c.symbols {
		if index == 0 { continue }
		id := Symbol_Id(index)
		for source := symbol; source.instance_of != INVALID_SYMBOL; source = symbol_of(c, id) { id = source.instance_of }
		source := symbol_of(c, id)
		written := written_query_binding(c, source)
		if written {
			key := Binding_Key{source.span, source.kind, source.name}
			if existing, found := bindings[key]; found { id = existing } else { bindings[key] = id }
		}
		q.canonical[index] = id
		type := symbol.kind == .Proc ? symbol.proc_type : symbol.type
		q.symbols[index] = Query_Symbol{
			Symbol_Handle{s.snapshot, Symbol_Id(index)}, identifier_text(c, symbol.name), symbol.kind,
			Type_Handle{s.snapshot, type}, Query_Location{s.snapshot, symbol.span}, symbol.public, symbol.generic,
		}
		if id == Symbol_Id(index) && written {
			append(&q.documents[source.span.file], Symbol_Handle{s.snapshot, id})
		}
		if written {
			append(&q.occurrences, Query_Occurrence{span = symbol.span, symbol = Symbol_Id(index), type = type})
		} else { q.symbols[index].definition.span = no_span() }
	}
	for id, index in q.canonical {
		if index > 0 && int(id) != index && q.symbols[id].type.id != q.symbols[index].type.id { q.symbols[id].type.id = INVALID_TYPE }
	}
	for info, index in c.types {
		if index == 0 { continue }
		type := Query_Type{
			handle = Type_Handle{s.snapshot, Type_Id(index)}, name = type_name_alloc(c, Type_Id(index), context.allocator), kind = info.kind,
			element = Type_Handle{s.snapshot, info.element}, key = Type_Handle{s.snapshot, info.key}, result = Type_Handle{s.snapshot, info.result},
			count = info.count, bits = info.bits, signed = info.signed, mutable = info.mutable, result_inout = info.result_inout,
			fields = make([]Symbol_Handle, len(info.fields)), members = make([]Symbol_Handle, len(info.members)),
			parameters = make([]Type_Handle, len(info.parameters)), param_modes = slice.clone(info.param_modes),
		}
		for field, slot in info.fields { type.fields[slot] = Symbol_Handle{s.snapshot, field} }
		for member, slot in info.members { type.members[slot] = Symbol_Handle{s.snapshot, member} }
		for parameter, slot in info.parameters { type.parameters[slot] = Type_Handle{s.snapshot, parameter} }
		q.types[index] = type
	}
	for symbol, index in c.symbols {
		if index == 0 || symbol.kind != .Proc || symbol.signature_error { continue }
		if symbol.proc_type == INVALID_TYPE && !symbol.generic { continue }
		text := ""
		literal := symbol.proc_literal
		if literal == nil && symbol.decl != nil { literal = decl_proc_literal(symbol.decl) }
		if literal != nil && literal.signature != nil {
			span := literal.signature.span
			if span.file != NO_FILE && int(span.file) < len(c.sources) && int(span.hi) <= len(c.sources[span.file].text) {
				text = c.sources[span.file].text[span.lo:span.hi]
			}
		}
		if text == "" && symbol.proc_type != INVALID_TYPE { text = q.types[symbol.proc_type].name }
		signature := Query_Signature{
			symbol = Symbol_Handle{s.snapshot, Symbol_Id(index)}, text = text, result = Type_Handle{s.snapshot, symbol.result},
			complete = !symbol.generic, result_inout = symbol.result_inout, diverges = symbol.diverges,
			parameters = make([]Query_Parameter, len(symbol.params)),
		}
		for parameter, slot in symbol.params {
			value := Query_Parameter{type = Type_Handle{s.snapshot, parameter}}
			if slot < len(symbol.param_symbols) {
				if parameter_symbol := symbol_of(c, symbol.param_symbols[slot]); parameter_symbol != nil {
					value.name, value.mode = identifier_text(c, parameter_symbol.name), parameter_symbol.mode
				}
			}
			value.has_default = slot < len(symbol.param_defaults) && symbol.param_defaults[slot] != nil
			signature.parameters[slot] = value
		}
		append(&q.signatures[index], signature)
	}
	for symbol, index in c.symbols {
		if index == 0 { continue }
		if symbol.kind == .Proc_Group {
			for member in symbol.members { append(&q.signatures[index], ..q.signatures[member][:]) }
		}
	}
	for diagnostic, index in c.diagnostics {
		view := Query_Diagnostic{
			diagnostic.severity, diagnostic.code, diagnostic.message, diagnostic.label,
			Query_Location{s.snapshot, diagnostic.span}, make([]Query_Note, len(diagnostic.notes)),
		}
		for note, slot in diagnostic.notes { view.notes[slot] = Query_Note{Query_Location{s.snapshot, note.span}, note.message} }
		q.diagnostics[index] = view
	}
	index := Query_Index{c = c, q = q, visited = make(map[rawptr]bool)}
	for file in c.parsed_files { for item in file.items { index_query_item(&index, item) } }
	for symbol in c.symbols {
		if symbol == nil { continue }
		if symbol.decl != nil { index_query_decl(&index, symbol.decl) }
		if symbol.proc_literal != nil { index_query_expr(&index, symbol.proc_literal) }
	}
}
