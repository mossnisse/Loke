// References and rename across every program the server checks. A binding is
// its written definition: each root whose program loads that file contributes
// the uses its own check recorded, and nothing is matched by spelling alone.
// Rename refuses rather than guess: every program involved must check without
// errors, and every written use of the old name must be one the compiler
// resolved.
package lsp

import "core:fmt"
import "core:slice"
import "core:strings"

import lokec "../src"

// A request that was valid but could not be carried out; the message says why.
REQUEST_FAILED :: -32803

// The binding a request names, by where it is written.
@(private = "file")
Target :: struct {
	symbol:  lokec.Query_Symbol,
	path:    string,
	lo, hi:  u32,
	defined: bool,
}

// The binding at the position in the document's own root.
@(private = "file")
find_target :: proc(s: ^Server, session: ^lokec.Compilation_Session, snapshot: lokec.Compilation_Snapshot, file: u32, text: string, position: Position) -> (target: Target, found: bool) {
	at := symbol_at(s, session, snapshot, file, text, position) or_return
	target.symbol = lokec.query_symbol(session, at.symbol) or_return
	definition, defined := lokec.query_definition(session, at.symbol)
	if !defined { return target, true }
	source := lokec.query_source(session, snapshot, definition.span.file) or_return
	target.path, target.lo, target.hi, target.defined = source.path, definition.span.lo, definition.span.hi, true
	return target, true
}

// The target as a root's snapshot knows it: the binding written at the same
// place. `loaded` is false when the root's program does not read that file.
@(private = "file")
binding_in :: proc(root: ^Root, target: Target) -> (snapshot: lokec.Compilation_Snapshot, handle: lokec.Symbol_Handle, loaded, found: bool) {
	if root.unconfigured { return }
	captured: bool
	snapshot, captured = lokec.session_snapshot(&root.session)
	if !captured { return }
	file, in_program := lokec.query_file(&root.session, snapshot, target.path)
	if !in_program { return }
	loaded = true
	at, recorded := lokec.query_at(&root.session, snapshot, file, target.lo)
	if !recorded { return }
	return snapshot, at.symbol, true, same_binding(&root.session, at.symbol, target)
}

@(private = "file")
same_binding :: proc(session: ^lokec.Compilation_Session, handle: lokec.Symbol_Handle, target: Target) -> bool {
	definition, defined := lokec.query_definition(session, handle)
	if !defined { return false }
	source, found := lokec.query_source(session, lokec.Compilation_Snapshot{definition.snapshot}, definition.span.file)
	return found && definition.span.lo == target.lo && definition.span.hi == target.hi && path_key(source.path, context.temp_allocator) == path_key(target.path, context.temp_allocator)
}

@(private = "file")
Found_Location :: struct { key, path: string, lo: u32, range: Range }

// Every recorded use of the binding, in every root, once each and in order.
references :: proc(s: ^Server, session: ^lokec.Compilation_Session, snapshot: lokec.Compilation_Snapshot, file: u32, text: string, position: Position, include_declaration: bool) -> string {
	target, found := find_target(s, session, snapshot, file, text, position)
	if !found || !target.defined { return "null" }
	locations := make([dynamic]Found_Location, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for _, root in s.roots {
		root_snapshot, handle, _, same := binding_in(root, target)
		if !same { continue }
		uses, listed := lokec.query_references(&root.session, handle, include_declaration)
		if !listed { continue }
		defer delete(uses)
		for use in uses {
			path, range, placed := place(s, &root.session, root_snapshot, use, context.temp_allocator)
			if !placed { continue }
			key := path_key(path, context.temp_allocator)
			identity := fmt.tprintf("%s\x00%d", key, use.span.lo)
			if seen[identity] { continue }
			seen[identity] = true
			append(&locations, Found_Location{key, path, use.span.lo, range})
		}
	}
	sort_locations(locations[:])
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for location, index in locations {
		if index > 0 { strings.write_byte(&b, ',') }
		write_location(s, &b, location.path, location.range)
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

@(private = "file")
sort_locations :: proc(locations: []Found_Location) {
	slice.sort_by(locations, proc(a, b: Found_Location) -> bool {
		if a.key != b.key { return a.key < b.key }
		return a.lo < b.lo
	})
}

// The name's range and spelling, when a rename could start here.
prepare_rename :: proc(s: ^Server, session: ^lokec.Compilation_Session, snapshot: lokec.Compilation_Snapshot, file: u32, text: string, position: Position) -> (result, failure: string) {
	target, found := find_target(s, session, snapshot, file, text, position)
	if !found { return "null", "" }
	if failure = renameable(s, target); failure != "" { return }
	at, _ := symbol_at(s, session, snapshot, file, text, position)
	_, range, _ := place(s, session, snapshot, at.location, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"range":`)
	write_range(&b, range)
	strings.write_string(&b, `,"placeholder":`)
	write_json_string(&b, target.symbol.name)
	strings.write_byte(&b, '}')
	return strings.to_string(b), ""
}

// Why the binding cannot be renamed at all, or "".
@(private = "file")
renameable :: proc(s: ^Server, target: Target) -> string {
	name := target.symbol.name
	if !target.defined || target.symbol.kind == .Builtin {
		return fmt.tprintf("`%s` has no written declaration to rename.", name)
	}
	for _, root in s.roots {
		if root.unconfigured { continue }
		snapshot, captured := lokec.session_snapshot(&root.session)
		if !captured { continue }
		file, loaded := lokec.query_file(&root.session, snapshot, target.path)
		if !loaded { continue }
		if source, found := lokec.query_source(&root.session, snapshot, file); found && source.bundled {
			return fmt.tprintf("`%s` belongs to the library bundled with the compiler.", name)
		}
	}
	return ""
}

@(private = "file")
Edit :: struct { key, path: string, lo: u32, range: Range }

// A workspace edit that renames every use of the binding in every program the
// server checks, or why it would be unsafe.
rename :: proc(s: ^Server, session: ^lokec.Compilation_Session, snapshot: lokec.Compilation_Snapshot, file: u32, text: string, position: Position, new_name: string) -> (result, failure: string) {
	target, found := find_target(s, session, snapshot, file, text, position)
	if !found { return "", "There is no binding at this position to rename." }
	if failure = renameable(s, target); failure != "" { return }
	old := target.symbol.name
	// Fields, enum members, and `impl` or `extend` members are reached through
	// a value or type, so scope cannot capture them; their type's other
	// members can.
	member := target.symbol.kind == .Field || target.symbol.kind == .Enum_Member || target.symbol.owner.id != lokec.INVALID_TYPE
	// grammar.md "Keywords": a reserved word is a member name too.
	kind, single := single_token(new_name)
	if !single || (kind != .Ident && !(member && lokec.reserved_keyword(kind))) {
		return "", fmt.tprintf("`%s` is not a name.", new_name)
	}
	if new_name == old { return `{"changes":{}}`, "" }
	// design.md "Receiver forms": a first parameter named `self` is what
	// makes a procedure a method.
	if target.symbol.kind == .Parameter && (old == "self" || new_name == "self") {
		return "", "`self` marks a method's receiver, so a parameter cannot be renamed to or from it."
	}
	edits := make([dynamic]Edit, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for _, root in s.roots {
		root_snapshot, handle, loaded, same := binding_in(root, target)
		if !loaded { continue }
		rs := &root.session
		diagnostics, _ := lokec.query_diagnostics(rs, root_snapshot)
		for diagnostic in diagnostics {
			if diagnostic.severity != .Error { continue }
			at := ""
			if source, placed := lokec.query_source(rs, root_snapshot, diagnostic.location.span.file); placed {
				at = fmt.tprintf(" (%s:%d)", source.path, offset_to_position(source.text, source.line_starts, diagnostic.location.span.lo, true).line + 1)
			}
			return "", fmt.tprintf("Rename needs every program that loads the binding to check without errors first: %s%s", first_line(diagnostic.message), at)
		}
		if same {
			// The bundled library reaches a program's names only through a
			// generic it instantiates, which records the use.
			uses, _ := lokec.query_references(rs, handle)
			defer delete(uses)
			for use in uses {
				source, _ := lokec.query_source(rs, root_snapshot, use.span.file)
				if source.bundled {
					line := offset_to_position(source.text, source.line_starts, use.span.lo, true).line + 1
					return "", fmt.tprintf("`%s` is used by the library bundled with the compiler, at %s:%d.", old, source.path, line)
				}
			}
			if member {
				if conflict := member_conflict(rs, root_snapshot, handle, new_name); conflict != "" { return "", conflict }
				// A method the compiler or an interface reaches by name has
				// uses no reference records, such as `value()` for `call`.
				implicit: []string
				if target.symbol.kind == .Proc || target.symbol.kind == .Proc_Group {
					implicit, _ = lokec.query_implicit_names(rs, root_snapshot, context.temp_allocator)
				}
				for name in implicit {
					if name == old || name == new_name {
						return "", fmt.tprintf("`%s` is a member name the compiler or an interface looks up by name, so renaming `%s` could change uses no reference records.", name, old)
					}
				}
			}
		}
		for source_file := u32(0); ; source_file += 1 {
			source := lokec.query_source(rs, root_snapshot, source_file) or_break
			if source.bundled || !strings.has_suffix(source.path, ".loke") { continue }
			// Parsed, so a reserved word written as a member name is an
			// identifier here and one written as syntax stays a keyword.
			tokens := parsed_tokens(source.text)
			defer delete(tokens)
			open := make([dynamic]lokec.Token_Kind, context.temp_allocator)
			edited := make([dynamic]u32, context.temp_allocator)
			for token, index in tokens {
				#partial switch token.kind {
				case .Lparen, .Lbracket, .Lbrace: append(&open, token.kind)
				case .Rparen, .Rbracket, .Rbrace: if len(open) > 0 { pop(&open) }
				}
				if token.kind != .Ident { continue }
				word := source.text[token.lo:token.hi]
				qualified := index > 0 && tokens[index - 1].kind == .Period
				// A member's new name matters where a selector could reach it.
				if word != old && (word != new_name || (member && !qualified)) { continue }
				// A package clause and an import alias name packages, never
				// a binding the snapshot records.
				if index > 0 && (tokens[index - 1].kind == .Package || tokens[index - 1].kind == .Import) { continue }
				at, recorded := lokec.query_at(rs, root_snapshot, source_file, token.lo)
				resolved := recorded && at.symbol.id != lokec.INVALID_SYMBOL
				where_written := fmt.tprintf("%s:%d", source.path, offset_to_position(source.text, source.line_starts, token.lo, true).line + 1)
				if word == old {
					if !resolved {
						return "", fmt.tprintf("`%s` at %s has no binding the compiler recorded, as in an inactive `when` branch, a generic that is never instantiated, or an interface slot, so rename cannot tell what it names.", old, where_written)
					}
					if !same_binding(rs, at.symbol, target) { continue }
					// `f(old = value)` names the callee's parameter, which the
					// caller's scope cannot capture.
					label := target.symbol.kind == .Parameter && index > 0 && index + 1 < len(tokens) && tokens[index + 1].kind == .Assign &&
						(tokens[index - 1].kind == .Lparen || tokens[index - 1].kind == .Comma) && len(open) > 0 && open[len(open) - 1] == .Lparen
					// Through a package, a selector reads that package's
					// declarations, not this scope. A public extension is also
					// one of its package's names.
					if (!member && !qualified && !label) || (member && !qualified && reaches(rs, root_snapshot, source_file, token.lo, target, package_only = true)) {
						if other, visible := visible_named(rs, root_snapshot, source_file, token.lo, new_name); visible {
							return "", fmt.tprintf("`%s` already names %s where `%s` appears, at %s.", new_name, describe(rs, other), old, where_written)
						}
					}
					// design.md "Promoted struct fields": the operand's own
					// fields, promoted fields, and methods share one lookup.
					// The operand is the selector's own, not whatever ends at the
					// token before the `.`: in `(outer).old` that is a `)`. A
					// `.Member` with no operand takes its type from context.
					if member && qualified && index >= 2 && ends_operand(tokens[index - 2].kind) {
						operand, typed := lokec.query_selector_operand(rs, root_snapshot, source_file, token.lo)
						if !typed {
							return "", fmt.tprintf("At %s, rename cannot tell what `.%s` is selected from, so it cannot check what `.%s` would select.", where_written, old, new_name)
						}
						members, listed := lokec.query_members(rs, operand, source_file, context.temp_allocator)
						if !listed {
							return "", fmt.tprintf("At %s, rename cannot list the members `.%s` is selected from, so it cannot check what `.%s` would select.", where_written, old, new_name)
						}
						for candidate in members {
							if candidate.name == new_name {
								return "", fmt.tprintf("At %s, `.%s` would select the existing member `%s` instead.", where_written, new_name, new_name)
							}
						}
					}
					identity := fmt.tprintf("%s\x00%d", path_key(source.path, context.temp_allocator), token.lo)
					if seen[identity] { continue }
					seen[identity] = true
					path, range, _ := place(s, rs, root_snapshot, at.location, context.temp_allocator)
					append(&edits, Edit{path_key(path, context.temp_allocator), path, token.lo, range})
					append(&edited, token.lo)
				} else if member {
					if same && index >= 2 && ends_operand(tokens[index - 2].kind) && promotes_target(rs, root_snapshot, source_file, token.lo, target, new_name) {
						return "", fmt.tprintf("At %s, `.%s` could select the renamed `%s`, which its operand reaches through a `using` field.", where_written, new_name, old)
					}
				} else if resolved && same {
					if conflict := local_conflict(rs, root_snapshot, source_file, at, handle, target); conflict != "" {
						return "", fmt.tprintf("`%s` is declared at %s, %s.", new_name, where_written, conflict)
					}
				}
			}
			if at, keyword := reads_as_keyword(source.text, edited[:], old, new_name); keyword {
				line := offset_to_position(source.text, source.line_starts, at, true).line + 1
				return "", fmt.tprintf("At %s:%d, `%s` would be read as a keyword there, not as the renamed name.", source.path, line, new_name)
			}
		}
	}
	slice.sort_by(edits[:], proc(a, b: Edit) -> bool {
		if a.key != b.key { return a.key < b.key }
		return a.lo < b.lo
	})
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"changes":{`)
	for edit, index in edits {
		if index == 0 || edits[index - 1].key != edit.key {
			if index > 0 { strings.write_string(&b, "],") }
			write_json_string(&b, uri_for(s, edit.key, edit.path))
			strings.write_string(&b, ":[")
		} else {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, `{"range":`)
		write_range(&b, edit.range)
		strings.write_string(&b, `,"newText":`)
		write_json_string(&b, new_name)
		strings.write_byte(&b, '}')
	}
	if len(edits) > 0 { strings.write_byte(&b, ']') }
	strings.write_string(&b, "}}")
	return strings.to_string(b), ""
}

// grammar.md "Keywords": a contextual keyword is a name except in its own
// position. The first edited offset at which the renamed text parses the new
// name as the keyword, if any; `edited` is ascending, as the scan finds them.
@(private = "file")
reads_as_keyword :: proc(text: string, edited: []u32, old, new_name: string) -> (u32, bool) {
	if len(edited) == 0 { return 0, false }
	b := strings.builder_make(context.temp_allocator)
	written := u32(0)
	for lo in edited {
		strings.write_string(&b, text[written:lo])
		strings.write_string(&b, new_name)
		written = lo + u32(len(old))
	}
	strings.write_string(&b, text[written:])
	tokens := parsed_tokens(strings.to_string(b))
	defer delete(tokens)
	next := 0
	for lo, k in edited {
		shifted := u32(int(lo) + k * (len(new_name) - len(old)))
		for next < len(tokens) && tokens[next].lo < shifted { next += 1 }
		if next < len(tokens) && tokens[next].lo == shifted && tokens[next].kind != .Ident { return lo, true }
	}
	return 0, false
}

// The kind of the one token `name` lexes to, when it is exactly one token and
// not the blank `_`.
@(private = "file")
single_token :: proc(name: string) -> (lokec.Token_Kind, bool) {
	if name == "" || name == "_" { return .EOF, false }
	tokens := lex_text(name)
	defer delete(tokens)
	count := 0
	for token in tokens { if token.kind != .EOF { count += 1 } }
	return tokens[0].kind, count == 1 && tokens[0].lo == 0 && int(tokens[0].hi) == len(name)
}

@(private = "file")
first_line :: proc(text: string) -> string {
	if newline := strings.index_byte(text, '\n'); newline >= 0 { return text[:newline] }
	return text
}

// The binding an unqualified `name` reaches at the offset, if any.
@(private = "file")
visible_named :: proc(session: ^lokec.Compilation_Session, snapshot: lokec.Compilation_Snapshot, file, offset: u32, name: string) -> (lokec.Query_Symbol, bool) {
	visible, found := lokec.query_visible(session, snapshot, file, offset, context.temp_allocator)
	if !found { return {}, false }
	for handle in visible {
		if symbol, known := lokec.query_symbol(session, handle); known && symbol.name == name { return symbol, true }
	}
	return {}, false
}

// Why a local declared with the new name at `at` would conflict once the
// renamed local takes that name, or "". Where the renamed one is visible, the
// declaration either shares its scope, a redeclaration, or is nested in it,
// and design.md "Variable declarations" forbids a local shadowing an outer
// variable or parameter. One declared before the renamed binding is instead
// visible at its declaration, which the use check refuses. Between them, the
// two checks cover capture: a binding the renamed one would shadow at some use
// is declared before it in an enclosing scope or later in its own.
@(private = "file")
local_conflict :: proc(session: ^lokec.Compilation_Session, snapshot: lokec.Compilation_Snapshot, file: u32, at: lokec.Query_Position, renamed: lokec.Symbol_Handle, target: Target) -> string {
	symbol, known := lokec.query_symbol(session, at.symbol)
	outer, found := lokec.query_symbol(session, renamed)
	if !known || !found || symbol.definition.span != at.location.span { return "" }
	if outer.scope.span.file == lokec.NO_FILE || symbol.scope.span.file == lokec.NO_FILE { return "" }
	if !reaches(session, snapshot, file, at.location.span.lo, target) { return "" }
	if symbol.scope.span == outer.scope.span { return "in the same scope" }
	if outer.kind == .Var || outer.kind == .Parameter { return fmt.tprintf("where the local `%s` is visible, and a local cannot shadow another", target.symbol.name) }
	return ""
}

// Whether the renamed binding is what its own name reaches at the offset,
// with `package_only` as one of its package's names rather than a local.
@(private = "file")
reaches :: proc(session: ^lokec.Compilation_Session, snapshot: lokec.Compilation_Snapshot, file, offset: u32, target: Target, package_only := false) -> bool {
	visible, found := lokec.query_visible(session, snapshot, file, offset, context.temp_allocator)
	if !found { return false }
	for handle in visible {
		symbol, known := lokec.query_symbol(session, handle)
		if !known || symbol.name != target.symbol.name { continue }
		return same_binding(session, handle, target) && (!package_only || symbol.scope.span.file == lokec.NO_FILE)
	}
	return false
}

// Whether the member's type already has a member spelled `new_name`, as its
// declaration writes them or as the type is seen from where it is declared.
@(private = "file")
member_conflict :: proc(session: ^lokec.Compilation_Session, snapshot: lokec.Compilation_Snapshot, handle: lokec.Symbol_Handle, new_name: string) -> string {
	symbol, _ := lokec.query_symbol(session, handle)
	owner := symbol.owner
	file := symbol.definition.span.file
	if symbol.parent.id != lokec.INVALID_SYMBOL && (symbol.kind == .Field || symbol.kind == .Enum_Member) {
		parent, _ := lokec.query_symbol(session, symbol.parent)
		owner = parent.type
		siblings, _ := lokec.query_symbols(session, snapshot, file)
		for sibling in siblings {
			other, known := lokec.query_symbol(session, sibling)
			if known && other.parent == symbol.parent && other.name == new_name {
				return fmt.tprintf("`%s` already has a member `%s`.", parent.name, new_name)
			}
		}
	}
	if owner.id == lokec.INVALID_TYPE { return "" }
	type, _ := lokec.query_type(session, owner)
	for type_value in ([]bool{false, true}) {
		operand := lokec.Query_Position{location = lokec.Query_Location{snapshot = snapshot.id}, type = owner, type_value = type_value}
		members, listed := lokec.query_members(session, operand, file, context.temp_allocator)
		if !listed { continue }
		for candidate in members {
			if candidate.name == new_name { return fmt.tprintf("`%s` already has a member `%s`.", type.name, new_name) }
		}
	}
	return ""
}

// Whether the `.new_name` selector at the offset would, once the renamed field
// is spelled `new_name`, select it or become ambiguous. design.md "Promoted
// struct fields": a field a struct declares hides those promoted into it, and
// two `using` fields that each lead to the name are ambiguous whatever their
// depths, so each branch is followed on its own, as the checker's
// `promoted_field_path` does.
@(private = "file")
promotes_target :: proc(session: ^lokec.Compilation_Session, snapshot: lokec.Compilation_Snapshot, file, offset: u32, target: Target, new_name: string) -> bool {
	if target.symbol.kind != .Field { return false }
	operand, typed := lokec.query_selector_operand(session, snapshot, file, offset)
	if !typed || operand.type_value { return false }
	// A selector reaches through one pointer or box, after distinct layers on
	// either side of it.
	type := operand.type
	if outer, found := underlying(session, type); found && (outer.kind == .Pointer || outer.kind == .Box) { type = outer.element }
	Lookup :: enum { None, Target, Other, Ambiguous }
	lookup :: proc(session: ^lokec.Compilation_Session, type: lokec.Type_Handle, target: Target, new_name: string, depth: int) -> Lookup {
		info, found := underlying(session, type)
		if !found || info.kind != .Struct || depth > 64 { return .None }
		direct := Lookup.None
		for field in info.fields {
			symbol, known := lokec.query_symbol(session, field)
			if !known { continue }
			if same_binding(session, field, target) { return .Target }
			if symbol.name == new_name { direct = .Other }
		}
		if direct != .None { return direct }
		result := Lookup.None
		for field in info.fields {
			symbol, known := lokec.query_symbol(session, field)
			if !known || !symbol.promotes { continue }
			reached := lookup(session, symbol.type, target, new_name, depth + 1)
			if reached == .Ambiguous || (reached != .None && result != .None) { return .Ambiguous }
			if reached != .None { result = reached }
		}
		return result
	}
	reached := lookup(session, type, target, new_name, 0)
	return reached == .Target || reached == .Ambiguous
}

// The type under any distinct layers.
@(private = "file")
underlying :: proc(session: ^lokec.Compilation_Session, type: lokec.Type_Handle) -> (lokec.Query_Type, bool) {
	info, found := lokec.query_type(session, type)
	for steps := 0; found && info.kind == .Distinct && steps < 64; steps += 1 { info, found = lokec.query_type(session, info.element) }
	return info, found
}

// "the local `count` declared at line 4", for a refusal.
@(private = "file")
describe :: proc(session: ^lokec.Compilation_Session, symbol: lokec.Query_Symbol) -> string {
	definition := symbol.definition.span
	if definition.file == lokec.NO_FILE { return fmt.tprintf("the predeclared `%s`", symbol.name) }
	source, found := lokec.query_source(session, lokec.Compilation_Snapshot{symbol.definition.snapshot}, definition.file)
	if !found { return fmt.tprintf("`%s`", symbol.name) }
	line := offset_to_position(source.text, source.line_starts, definition.lo, true).line + 1
	return fmt.tprintf("`%s` declared at %s:%d", symbol.name, source.path, line)
}
