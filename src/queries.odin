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

// `bundled` marks a file of the library shipped with the compiler, `base:` or
// `core:`, which no editor operation should rewrite.
Query_Source :: struct { path, text: string, line_starts: []u32, bundled: bool }
Query_Symbol :: struct {
	handle: Symbol_Handle,
	name: string,
	kind: Symbol_Kind,
	type: Type_Handle,
	definition: Query_Location,
	// The whole written declaration, from its first attribute through its end:
	// `name :: value`, a field, an enum member, or a parameter. It contains
	// `definition` and has no span exactly when `definition` has none.
	extent: Query_Location,
	// The innermost other written binding whose extent contains this one's:
	// the record or enum of a field or member, the procedure of a parameter,
	// local, or loop binding. Zero for a package-level declaration or a method.
	parent: Symbol_Handle,
	// The type an `impl` or `extend` member belongs to; zero otherwise.
	owner: Type_Handle,
	// Where a local, parameter, or loop binding can be named: the innermost
	// block, statement, or procedure holding its name. No span otherwise.
	scope: Query_Location,
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
// `type_value` is set when the node denotes `type` itself, as `Color` in
// `Color.Red`, rather than a value of it.
Query_Position :: struct { location: Query_Location, symbol: Symbol_Handle, type: Type_Handle, type_value: bool }
// One name that may follow `operand.`. A union variant has no symbol; its type
// is its payload's, or zero when it has none.
Query_Member :: struct { name: string, symbol: Symbol_Handle, type: Type_Handle, variant: bool }

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
	bundled := false
	if pkg := package_of(&s.compiler, s.queries.packages[file]); pkg != nil {
		bundled = strings.has_prefix(pkg.key, "base:") || strings.has_prefix(pkg.key, "core:")
	}
	return Query_Source{source.path, source.text, source.line_starts, bundled}, true
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

// The comments written directly above the binding's declaration, as `-doc`
// shows them. The caller owns the text. False when there are none.
query_documentation :: proc(s: ^Compilation_Session, handle: Symbol_Handle, allocator := context.allocator) -> (string, bool) {
	symbol, found := query_symbol(s, handle)
	if !found || symbol.extent.span.file == NO_FILE { return "", false }
	context.allocator = allocator
	text := doc_comment(&s.compiler, symbol.extent.span)
	return text, text != ""
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
			best.type_value ||= occurrence.type_value
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
	return Query_Position{
		Query_Location{s.snapshot, best.span}, Symbol_Handle{s.snapshot, best.symbol}, Type_Handle{s.snapshot, best.type},
		best.type_value && best.type != INVALID_TYPE,
	}, true
}

// The bindings an unqualified name can reach at a byte offset, innermost
// first: locals, parameters, and loop bindings written before it in an
// enclosing block or procedure, then the file's package with its imports, then
// the predeclared names. A shadowed binding is omitted. A local is reachable
// from the end of its name, so its own initializer counts. The caller owns the
// array.
query_visible :: proc(s: ^Compilation_Session, snapshot: Compilation_Snapshot, file, offset: u32, allocator := context.allocator) -> ([]Symbol_Handle, bool) {
	source, found := query_source(s, snapshot, file)
	if !found || int(offset) > len(source.text) { return nil, false }
	c, q := &s.compiler, &s.queries
	pkg := package_of(c, q.packages[file])
	if pkg == nil || pkg.scope == nil { return nil, false }
	Local :: struct { size, lo: u32, id: Symbol_Id }
	locals := make([dynamic]Local, allocator)
	defer delete(locals)
	for handle in q.documents[file] {
		scope, definition := q.symbols[handle.id].scope.span, q.symbols[handle.id].definition.span
		if scope.file != file || offset < definition.hi || offset < scope.lo || offset >= scope.hi { continue }
		append(&locals, Local{scope.hi - scope.lo, definition.lo, handle.id})
	}
	slice.sort_by(locals[:], proc(a, b: Local) -> bool {
		if a.size != b.size { return a.size < b.size }
		return a.lo > b.lo
	})
	out := make([dynamic]Symbol_Handle, allocator)
	seen := make(map[string]bool, allocator = allocator)
	defer delete(seen)
	for local in locals {
		name := q.symbols[local.id].name
		if seen[name] { continue }
		seen[name] = true
		append(&out, Symbol_Handle{s.snapshot, local.id})
	}
	for scope := pkg.scope; scope != nil; scope = scope.parent {
		start := len(out)
		for _, id in scope.names {
			if int(id) <= 0 || int(id) >= len(q.symbols) { continue }
			name := q.symbols[id].name
			if seen[name] || !identifier_spelling(name) { continue }
			seen[name] = true
			append(&out, Symbol_Handle{s.snapshot, id})
		}
		// A map has no order; declarations do.
		slice.sort_by(out[start:], proc(a, b: Symbol_Handle) -> bool { return a.id < b.id })
	}
	return out[:], true
}

// What may follow `operand.`, where `operand` is a `query_at` result in `file`.
// A package alias lists its package's public declarations. A type lists its
// enum members or union variants and its members. A value lists its fields, promoted
// fields after them, and methods, and through a pointer or box those of what
// it points at. Members are
// the ones the snapshot recorded and the file's package can see; one the
// checker contributes on demand appears once a lookup created it. Sorted by
// name; the caller owns the array.
query_members :: proc(s: ^Compilation_Session, operand: Query_Position, file: u32, allocator := context.allocator) -> ([]Query_Member, bool) {
	if !valid_snapshot(s, operand.location.snapshot) || int(file) >= len(s.queries.packages) { return nil, false }
	Members :: struct { s: ^Compilation_Session, observer: Package_Id, out: [dynamic]Query_Member, seen: map[string]bool }
	m := Members{s = s, observer = s.queries.packages[file], out = make([dynamic]Query_Member, allocator), seen = make(map[string]bool, allocator = allocator)}
	defer delete(m.seen)
	add :: proc(m: ^Members, id: Symbol_Id, methods: bool) {
		c := &m.s.compiler
		symbol := symbol_of(c, id)
		if symbol == nil || symbol.bound_excluded || symbol.superseded || (methods && !symbol.has_receiver) { return }
		if symbol.pkg != m.observer && !symbol.public { return }
		name := identifier_text(c, symbol.name)
		if m.seen[name] || !identifier_spelling(name) { return }
		m.seen[name] = true
		type := symbol.kind == .Proc ? symbol.proc_type : symbol.type
		append(&m.out, Query_Member{name, Symbol_Handle{m.s.snapshot, id}, Type_Handle{m.s.snapshot, type}, false})
	}
	// design.md "Promoted struct fields": an outer field wins over a promoted
	// one, so a `using` field's own fields come after the record's.
	add_fields :: proc(m: ^Members, type: Type_Id, depth: int) {
		c := &m.s.compiler
		info := underlying_info(c, type)
		if info == nil || info.kind != .Struct || depth > len(c.types) { return }
		for field in info.fields { add(m, field, false) }
		for field in info.fields {
			if symbol := symbol_of(c, field); symbol != nil && symbol.is_using { add_fields(m, symbol.type, depth + 1) }
		}
	}
	add_members :: proc(m: ^Members, type: Type_Id, methods: bool) {
		c := &m.s.compiler
		if info := type_of(c, type); info != nil {
			for member in info.members { add(m, member, methods) }
		}
		if pkg := package_of(c, m.observer); pkg != nil {
			for member in pkg.extensions[type] { add(m, member, methods) }
		}
	}
	c := &s.compiler
	alias := symbol_of(c, operand.symbol.id)
	switch {
	case operand.symbol.id != INVALID_SYMBOL && alias != nil && alias.kind == .Package_Alias:
		if target := package_of(c, alias.pkg); target != nil && target.scope != nil {
			for _, id in target.scope.names {
				if symbol := symbol_of(c, id); symbol != nil && symbol.public && symbol.kind != .Package_Alias { add(&m, id, false) }
			}
		}
	case operand.type.id == INVALID_TYPE:
		delete(m.out)
		return nil, false
	case operand.type_value:
		subject := operand.type.id
		info := underlying_info(c, subject)
		if info != nil && info.kind == .Enum {
			for member in info.fields { add(&m, member, false) }
		} else if info != nil && info.kind == .Union {
			for name, index in info.variant_names {
				text := identifier_text(c, name)
				if m.seen[text] || !identifier_spelling(text) { continue }
				m.seen[text] = true
				payload := index < len(info.variants) ? info.variants[index] : INVALID_TYPE
				if payload == TYPE_VOID { payload = INVALID_TYPE }
				append(&m.out, Query_Member{text, Symbol_Handle{s.snapshot, INVALID_SYMBOL}, Type_Handle{s.snapshot, payload}, true})
			}
		}
		add_members(&m, subject, false)
	case:
		subjects := [2]Type_Id{operand.type.id, INVALID_TYPE}
		if info := underlying_info(c, operand.type.id); info != nil && (info.kind == .Pointer || info.kind == .Box) {
			subjects[1] = info.element
		}
		for subject in subjects {
			if subject == INVALID_TYPE { continue }
			add_fields(&m, subject, 0)
			add_members(&m, subject, true)
		}
	}
	slice.sort_by(m.out[:], proc(a, b: Query_Member) -> bool { return a.name < b.name })
	return m.out[:], true
}

// design.md "Calling a value", "Iteration protocol", "Reverse iteration",
// "String format printing", "Maps", and "Indexing and slicing": member names
// the compiler looks up itself, where no use spells them.
@(private = "file")
IMPLICIT_MEMBER_NAMES := [?]string{"call", "iter", "iter_mut", "iter_reverse", "iter_mut_reverse", "next", "format", "hash", "len"}

// Member names a program can reach without writing them at a use: those the
// compiler looks up itself, and the requirements of every interface the
// checked program uses, as slot names and as the members their expressions
// select. A member so named may be used where no reference records it. The
// caller owns the array; its strings are borrowed.
query_implicit_names :: proc(s: ^Compilation_Session, snapshot: Compilation_Snapshot, allocator := context.allocator) -> ([]string, bool) {
	if !valid_snapshot(s, snapshot.id) { return nil, false }
	out := make([dynamic]string, allocator)
	append(&out, ..IMPLICIT_MEMBER_NAMES[:])
	selected :: proc(out: ^[dynamic]string, expr: Expr) {
		#partial switch v in expr {
		case ^Expr_Selector:
			if v.name.text != "" { append(out, v.name.text) }
			selected(out, v.operand)
		case ^Expr_Call:
			selected(out, v.callee)
			for argument in v.args { selected(out, argument.value) }
		case ^Expr_Unary: selected(out, v.operand)
		case ^Expr_Binary:
			selected(out, v.lhs)
			selected(out, v.rhs)
		case ^Expr_Index:
			selected(out, v.operand)
			for index in v.indices { selected(out, index) }
		}
	}
	for _, info in s.compiler.interfaces {
		if info == nil || info.node == nil { continue }
		for requirement in info.node.requirements {
			if requirement.kind == .Slot { append(&out, requirement.name.text) } else { selected(&out, requirement.expr) }
		}
	}
	return out[:], true
}

@(private)
Query_Occurrence :: struct { span: Span, symbol: Symbol_Id, type: Type_Id, reference, type_value: bool }
@(private)
Snapshot_Queries :: struct {
	symbols: []Query_Symbol,
	types: []Query_Type,
	canonical: []Symbol_Id,
	documents: [][dynamic]Symbol_Handle,
	signatures: [][dynamic]Query_Signature,
	diagnostics: []Query_Diagnostic,
	occurrences: [dynamic]Query_Occurrence,
	// Each source file's package, or none for a manifest.
	packages: []Package_Id,
	// Syntax that opens a lexical scope, from the index.
	regions: [dynamic]Span,
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
	q.packages = make([]Package_Id, len(c.sources))
	for &pkg in c.packages {
		for file in pkg.files {
			if file != nil && int(file.file) < len(q.packages) { q.packages[file.file] = pkg.id }
		}
	}
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
			handle = Symbol_Handle{s.snapshot, Symbol_Id(index)}, name = identifier_text(c, symbol.name), kind = symbol.kind,
			type = Type_Handle{s.snapshot, type}, definition = Query_Location{s.snapshot, symbol.span},
			extent = Query_Location{s.snapshot, no_span()}, parent = Symbol_Handle{s.snapshot, INVALID_SYMBOL},
			owner = Type_Handle{s.snapshot, symbol.owner_type}, scope = Query_Location{s.snapshot, no_span()},
			public = symbol.public, generic = symbol.generic,
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
	// A written binding the walk gave no declaration, such as a loop binding,
	// is described by its name alone.
	for handles in q.documents {
		for handle in handles {
			symbol := &q.symbols[handle.id]
			if symbol.extent.span.file == NO_FILE { symbol.extent = symbol.definition }
		}
	}
	for handles in q.documents { nest_query_bindings(q, handles[:]) }
	slice.sort_by(q.regions[:], proc(a, b: Span) -> bool {
		if a.file != b.file { return a.file < b.file }
		if a.lo != b.lo { return a.lo < b.lo }
		return a.hi > b.hi
	})
	for handles in q.documents { scope_query_locals(q, handles[:]) }
	// Clones share their written binding's declaration, parent, and scope.
	for &symbol, slot in q.symbols {
		if slot == 0 || symbol.definition.span.file == NO_FILE { continue }
		canonical := q.symbols[q.canonical[slot]]
		symbol.extent, symbol.parent, symbol.scope = canonical.extent, canonical.parent, canonical.scope
	}
}

// A local is reachable inside the innermost block, statement, or procedure
// holding its name: syntax nests, so a sweep in source order finds it. A
// field, member, or a record's generic parameter is not a local, nor is a
// package-level declaration, which no region holds.
@(private = "file")
scope_query_locals :: proc(q: ^Snapshot_Queries, handles: []Symbol_Handle) {
	if len(handles) == 0 { return }
	file := q.symbols[handles[0].id].definition.span.file
	Binding :: struct { lo: u32, id: Symbol_Id }
	bindings := make([dynamic]Binding)
	for handle in handles {
		symbol := q.symbols[handle.id]
		#partial switch symbol.kind {
		case .Field, .Enum_Member, .Package_Alias, .Builtin, .Invalid: continue
		}
		if parent := symbol.parent.id; parent != INVALID_SYMBOL && q.symbols[parent].kind == .Type { continue }
		append(&bindings, Binding{symbol.definition.span.lo, handle.id})
	}
	slice.sort_by(bindings[:], proc(a, b: Binding) -> bool { return a.lo < b.lo })
	first, _ := slice.binary_search_by(q.regions[:], file, proc(region: Span, file: u32) -> slice.Ordering {
		return region.file < file ? .Less : .Greater
	})
	open := make([dynamic]Span)
	next := first
	for binding in bindings {
		for next < len(q.regions) && q.regions[next].file == file && q.regions[next].lo <= binding.lo {
			region := q.regions[next]
			for len(open) > 0 && open[len(open) - 1].hi <= region.lo { pop(&open) }
			append(&open, region)
			next += 1
		}
		for len(open) > 0 && open[len(open) - 1].hi <= binding.lo { pop(&open) }
		if len(open) > 0 { q.symbols[binding.id].scope.span = open[len(open) - 1] }
	}
}

// Parents by position: written syntax nests, so the innermost extent strictly
// containing a binding's own is the declaration it is written in. Bindings
// declared together, as `a, b: int`, share an extent and a parent.
@(private = "file")
nest_query_bindings :: proc(q: ^Snapshot_Queries, handles: []Symbol_Handle) {
	Nest :: struct { lo, hi: u32, id: Symbol_Id }
	nests := make([]Nest, len(handles))
	for handle, index in handles {
		span := q.symbols[handle.id].extent.span
		nests[index] = Nest{span.lo, span.hi, handle.id}
	}
	slice.sort_by(nests, proc(a, b: Nest) -> bool {
		if a.lo != b.lo { return a.lo < b.lo }
		if a.hi != b.hi { return a.hi > b.hi }
		return a.id < b.id
	})
	open := make([dynamic]Nest)
	for nest in nests {
		for len(open) > 0 && open[len(open) - 1].hi < nest.hi { pop(&open) }
		parent := INVALID_SYMBOL
		if len(open) > 0 {
			enclosing := open[len(open) - 1]
			if enclosing.lo == nest.lo && enclosing.hi == nest.hi {
				parent = q.symbols[enclosing.id].parent.id
			} else {
				parent = enclosing.id
				append(&open, nest)
			}
		} else {
			append(&open, nest)
		}
		q.symbols[nest.id].parent.id = parent
	}
}
