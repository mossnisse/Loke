// What the server checks for each open document, and how checked diagnostics
// reach the client. A root is one `lokec` input with its own session; every
// session carries every open document as an overlay.
package lsp

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import lokec "../src"

Root :: struct {
	path, key: string, // a package directory, or one file
	session:   lokec.Compilation_Session,
	// Checked as `lokec -doc` checks it, with no entry point: the root package
	// is not named `main`.
	library:   bool,
	dirty:     bool,
	// The configuration was rejected; `unplaced` holds why, for good.
	unconfigured: bool,
	// Results of the last check, allocated in `result_arena`.
	files:     map[string]File_Result, // by path key
	unplaced:  [dynamic]Lsp_Diagnostic, // shown on the root's open documents
	loaded:    map[string]bool, // path keys of every source the check read
	packages:  map[string]bool, // their directories' path keys
	result_arena: virtual.Arena,
}

File_Result :: struct { path: string, diagnostics: [dynamic]Lsp_Diagnostic }

Lsp_Diagnostic :: struct {
	range:    Range,
	severity: lokec.Severity,
	code, message: string,
	related:  []Related,
}

Related :: struct { path: string, range: Range, message: string }

// Work left for `run_pending_work`.
has_pending_work :: proc(s: ^Server) -> bool {
	if s.phase != .Running { return false }
	if s.layout_dirty || s.publish_due || len(s.pending) > 0 { return true }
	for _, root in s.roots { if root.dirty { return true } }
	return false
}

// One step: assign roots and answer the requests they can, then check one
// dirty root, a requested one first, or publish once none is dirty. Results are
// published only when every root was checked since the last edit, which marks
// them all dirty, so a result superseded by a later edit is never shown. True
// while more steps remain.
run_pending_work :: proc(s: ^Server) -> bool {
	if s.phase != .Running { return false }
	if s.layout_dirty { refresh_roots(s) }
	answer_requests(s)
	root := requested_root(s)
	if root == nil { root = next_dirty_root(s) }
	if root != nil {
		check_root(s, root)
		return true
	}
	if s.publish_due { publish(s) }
	return false
}

// Assigns each open document its root, creating roots it needs and destroying
// those no document needs any more. A document that the program of another
// open document's own root already loads joins that root, so an imported
// package keeps the collections its application's manifest supplies
// (compiler-guide.md "Projects"). Once no open document has that root as its
// own, the package goes back to its own root.
refresh_roots :: proc(s: ^Server) {
	s.layout_dirty = false
	Own :: struct { path, key: string }
	own := make(map[^Document]Own, context.temp_allocator)
	anchored := make(map[string]bool, context.temp_allocator)
	for _, doc in s.documents {
		path, key := root_of(s, doc)
		own[doc] = Own{path, key}
		anchored[key] = true
	}
	for _, doc in s.documents {
		path, key := own[doc].path, own[doc].key
		if importer := importing_root(s, doc, key, anchored); importer != nil {
			doc.root = importer
			continue
		}
		root := s.roots[key]
		if root == nil {
			root = create_root(s, path, key)
			s.roots[root.key] = root
		}
		doc.root = root
	}
	unused := make([dynamic]^Root, context.temp_allocator)
	for _, root in s.roots {
		used := false
		for _, doc in s.documents { used ||= doc.root == root }
		if !used { append(&unused, root) }
	}
	for root in unused {
		delete_key(&s.roots, root.key)
		destroy_root(root)
		s.publish_due = true
	}
}

// Of the other roots whose last check loaded the document and that are some
// open document's own root, the outermost: one whose own package no other
// candidate loads. Imports are acyclic, so there is one unless two
// applications import the document, and then the first by path.
@(private = "file")
importing_root :: proc(s: ^Server, doc: ^Document, own_key: string, anchored: map[string]bool) -> ^Root {
	best: ^Root
	for _, candidate in s.roots {
		if candidate.key == own_key || !anchored[candidate.key] || !candidate.loaded[doc.key] { continue }
		outermost := true
		for _, other in s.roots {
			if other != candidate && other.key != own_key && anchored[other.key] && other.loaded[doc.key] &&
			   (other.packages[candidate.key] || other.loaded[candidate.key]) {
				outermost = false
			}
		}
		if outermost && (best == nil || candidate.key < best.key) { best = candidate }
	}
	return best
}

// A document is checked through its package directory, as `lokec <dir>`
// checks it. A directory where two or more files declare `main` holds separate
// programs, such as `examples/`, so each of its files is its own root.
@(private = "file")
root_of :: proc(s: ^Server, doc: ^Document) -> (path, key: string) {
	dir := lokec.canonical_dir(lokec.path_dir(doc.path, context.temp_allocator))
	dir_key := lokec.dir_key(dir)
	entries := 0
	for file_key, declares in directory_entries(s, dir) {
		if declares && s.documents[file_key] == nil { entries += 1 }
	}
	for _, other in s.documents {
		if declares_entry(other.text) && path_key(lokec.path_dir(other.path, context.temp_allocator), context.temp_allocator) == dir_key {
			entries += 1
		}
	}
	if entries >= 2 { return doc.path, doc.key }
	return dir, dir_key
}

// Whether each `.loke` file in `dir` on disk declares `main`, by path key.
// Cached until a document opens, closes, or saves, or the client reports a
// changed file; open documents' own text overrides it.
@(private = "file")
directory_entries :: proc(s: ^Server, dir: string) -> map[string]bool {
	allocator := virtual.arena_allocator(&s.scan_arena)
	if s.scans == nil { s.scans = make(map[string]map[string]bool, allocator) }
	dir_key := lokec.dir_key(dir)
	if cached, found := s.scans[dir_key]; found { return cached }
	entries := make(map[string]bool, allocator)
	infos, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	for info in infos {
		if info.type != .Regular || !strings.equal_fold(filepath.ext(info.name), ".loke") { continue }
		path := lokec.join_path({dir, info.name}, context.temp_allocator)
		data, err := os.read_entire_file(path, context.temp_allocator)
		entries[path_key(path, allocator)] = err == nil && declares_entry(string(data))
	}
	s.scans[strings.clone(dir_key, allocator)] = entries
	return entries
}

clear_directory_scans :: proc(s: ^Server) {
	virtual.arena_destroy(&s.scan_arena)
	s.scans = nil
}

// Whether the file declares `main` outside any bracket: the name followed by the
// `:` of a declaration, as the compiler's lexer reads it, so comments and
// literals do not count. Only for grouping files into roots; a `main` inside a
// file-scope `when` is not seen, and the compiler decides what the file means.
declares_entry :: proc(text: string) -> bool {
	scratch: lokec.Compiler
	defer lokec.destroy_compilation(&scratch)
	append(&scratch.sources, lokec.Source{text = text})
	tokens := lokec.lex(&scratch, 0)
	defer delete(tokens)
	depth := 0
	for token, index in tokens {
		#partial switch token.kind {
		case .Lparen, .Lbracket, .Lbrace:
			depth += 1
		case .Rparen, .Rbracket, .Rbrace:
			depth = max(depth - 1, 0)
		case .Ident:
			if depth == 0 && text[token.lo:token.hi] == "main" && index + 1 < len(tokens) && tokens[index + 1].kind == .Colon {
				return true
			}
		}
	}
	return false
}

@(private = "file")
create_root :: proc(s: ^Server, path, key: string) -> ^Root {
	root := new(Root)
	root.path, root.key = strings.clone(path), strings.clone(key)
	root.dirty = true
	if !lokec.init_session(&root.session, s.config) {
		// Every later overlay edit would hide the reason, so keep it now.
		root.unconfigured = true
		collect_results(s, root)
	}
	for _, doc in s.documents {
		lokec.set_session_overlay(&root.session, doc.path, doc.text)
	}
	return root
}

destroy_root :: proc(root: ^Root) {
	lokec.destroy_session(&root.session)
	virtual.arena_destroy(&root.result_arena)
	delete(root.path)
	delete(root.key)
	free(root)
}

@(private = "file")
next_dirty_root :: proc(s: ^Server) -> ^Root {
	best: ^Root
	for _, root in s.roots {
		if root.dirty && (best == nil || root.key < best.key) { best = root }
	}
	return best
}

// Checks as `lokec <root>` or, for a package not named `main`, `lokec -doc
// <root>` would, reusing the packages that come before the first changed one
// (compiler-architecture.md "Incremental checking"). The first check of a
// library finds out its name and checks again in the right mode.
@(private = "file")
check_root :: proc(s: ^Server, root: ^Root) {
	root.dirty = false
	s.publish_due = true
	// What the program loads decides which documents join this root.
	s.layout_dirty = true
	if root.unconfigured { return }
	lokec.check_session_incremental(&root.session, root.path, documentation = root.library)
	if name, known := root_package_name(root); known && (name == "main") == root.library {
		root.library = !root.library
		lokec.check_session_incremental(&root.session, root.path, documentation = root.library)
	}
	collect_results(s, root)
}

@(private = "file")
root_package_name :: proc(root: ^Root) -> (string, bool) {
	c := &root.session.compiler
	if c.root_package == lokec.INVALID_PACKAGE { return "", false }
	pkg := lokec.package_of(c, c.root_package)
	if pkg == nil { return "", false }
	name := lokec.identifier_text(c, pkg.name)
	return name, name != ""
}

// Copies the checked diagnostics out of the snapshot, positioned for the
// client. A diagnostic `lokec` would print once is kept once.
@(private = "file")
collect_results :: proc(s: ^Server, root: ^Root) {
	virtual.arena_destroy(&root.result_arena)
	allocator := virtual.arena_allocator(&root.result_arena)
	root.files = make(map[string]File_Result, allocator)
	root.unplaced = make([dynamic]Lsp_Diagnostic, allocator)
	root.loaded = make(map[string]bool, allocator)
	root.packages = make(map[string]bool, allocator)
	snapshot, ok := lokec.session_snapshot(&root.session)
	if !ok { return }
	for file := u32(0); ; file += 1 {
		source := lokec.query_source(&root.session, snapshot, file) or_break
		root.loaded[path_key(source.path, allocator)] = true
		root.packages[path_key(lokec.path_dir(source.path, context.temp_allocator), allocator)] = true
	}
	diagnostics, _ := lokec.query_diagnostics(&root.session, snapshot)
	seen := make(map[string]bool, context.temp_allocator)
	for d in diagnostics {
		span := d.location.span
		identity := fmt.tprintf("%v|%d:%d:%d|%s|%s|%s", d.severity, span.file, span.lo, span.hi, d.code, d.message, d.label)
		if seen[identity] { continue }
		seen[identity] = true
		// Text `lokec` prints beside the source line goes into the message;
		// a client without related information gets the notes there too.
		message := d.message if d.label == "" else fmt.tprintf("%s\n%s", d.message, d.label)
		related := make([dynamic]Related, allocator)
		for note in d.notes {
			path, range, placed := place(s, &root.session, snapshot, note.location, allocator)
			switch {
			case placed && s.related_information:
				append(&related, Related{path, range, strings.clone(note.message, allocator)})
			case placed:
				message = fmt.tprintf("%s\nnote: %s:%d:%d: %s", message, path, range.start.line + 1, range.start.character + 1, note.message)
			case:
				message = fmt.tprintf("%s\nnote: %s", message, note.message)
			}
		}
		out := Lsp_Diagnostic{
			severity = d.severity, code = strings.clone(d.code, allocator),
			message = strings.clone(message, allocator), related = related[:],
		}
		path, range, placed := place(s, &root.session, snapshot, d.location, allocator)
		out.range = range
		if !placed {
			append(&root.unplaced, out)
			continue
		}
		key := path_key(path, allocator)
		file, found := &root.files[key]
		if !found {
			root.files[key] = File_Result{path = path, diagnostics = make([dynamic]Lsp_Diagnostic, allocator)}
			file = &root.files[key]
		}
		append(&file.diagnostics, out)
	}
}

// A snapshot location as a canonical path and a client range.
place :: proc(s: ^Server, session: ^lokec.Compilation_Session, snapshot: lokec.Compilation_Snapshot, location: lokec.Query_Location, allocator := context.allocator) -> (path: string, range: Range, ok: bool) {
	if location.span.file == lokec.NO_FILE { return }
	source := lokec.query_source(session, snapshot, location.span.file) or_return
	range.start = offset_to_position(source.text, source.line_starts, location.span.lo, s.utf8_positions)
	range.end = offset_to_position(source.text, source.line_starts, max(location.span.hi, location.span.lo), s.utf8_positions)
	return strings.clone(lokec.canonical_dir(source.path), allocator), range, true
}

// Sends each file whose diagnostics differ from what the client last received,
// and an empty list for each file that no longer has any. A file's list is the
// union over all roots, since an imported package is checked by every root
// that imports it.
@(private = "file")
publish :: proc(s: ^Server) {
	s.publish_due = false
	wanted := make(map[string]Wanted_File, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for _, root in s.roots {
		for key, &file in root.files {
			for &d in file.diagnostics { want_diagnostic(&wanted, &seen, key, file.path, &d) }
		}
		for &d in root.unplaced {
			for _, doc in s.documents {
				if doc.root == root { want_diagnostic(&wanted, &seen, doc.key, doc.path, &d) }
			}
		}
	}

	keys := make([dynamic]string, context.temp_allocator)
	for key in wanted { append(&keys, key) }
	for key in s.published { if key not_in wanted { append(&keys, key) } }
	slice.sort(keys[:])
	for key in keys {
		entry, want := wanted[key]
		previous, had := s.published[key]
		doc := s.documents[key]
		if !want {
			send_diagnostics(s, previous.uri, doc if doc != nil && doc.uri == previous.uri else nil, nil)
			forget_published(s, key)
			continue
		}
		uri := uri_for(s, key, entry.path)
		slice.stable_sort_by(entry.diagnostics[:], proc(a, b: ^Lsp_Diagnostic) -> bool {
			if a.range.start.line != b.range.start.line { return a.range.start.line < b.range.start.line }
			return a.range.start.character < b.range.start.character
		})
		params := diagnostics_params(s, uri, doc, entry.diagnostics[:])
		if had && previous.uri == uri && previous.params == params { continue }
		// The client opened the file under its own spelling of the URI after
		// diagnostics went out under ours.
		if had && previous.uri != uri { send_diagnostics(s, previous.uri, nil, nil) }
		send_notification(s, "textDocument/publishDiagnostics", params)
		forget_published(s, key)
		s.published[strings.clone(key)] = Published{strings.clone(uri), strings.clone(params)}
	}
}

@(private = "file")
Wanted_File :: struct { path: string, diagnostics: [dynamic]^Lsp_Diagnostic }

// Two roots that import one package both report its diagnostics; the client
// gets each once.
@(private = "file")
want_diagnostic :: proc(wanted: ^map[string]Wanted_File, seen: ^map[string]bool, key, path: string, d: ^Lsp_Diagnostic) {
	identity := fmt.tprintf(
		"%s|%d:%d-%d:%d|%v|%s|%s", key, d.range.start.line, d.range.start.character,
		d.range.end.line, d.range.end.character, d.severity, d.code, d.message,
	)
	if seen[identity] { return }
	seen[identity] = true
	entry, found := &wanted[key]
	if !found {
		wanted[key] = Wanted_File{path, make([dynamic]^Lsp_Diagnostic, context.temp_allocator)}
		entry = &wanted[key]
	}
	append(&entry.diagnostics, d)
}

@(private = "file")
forget_published :: proc(s: ^Server, key: string) {
	if key in s.published {
		stored_key, previous := delete_key(&s.published, key)
		delete(stored_key)
		delete(previous.uri)
		delete(previous.params)
	}
}

// The client's own spelling for a document it opened; otherwise one built
// from the path.
uri_for :: proc(s: ^Server, key, path: string) -> string {
	if doc := s.documents[key]; doc != nil { return doc.uri }
	return path_to_uri(path, context.temp_allocator)
}

@(private = "file")
send_diagnostics :: proc(s: ^Server, uri: string, doc: ^Document, diagnostics: []^Lsp_Diagnostic) {
	send_notification(s, "textDocument/publishDiagnostics", diagnostics_params(s, uri, doc, diagnostics))
}

// `PublishDiagnosticsParams`, with the version of the open document the
// diagnostics were computed from.
@(private = "file")
diagnostics_params :: proc(s: ^Server, uri: string, doc: ^Document, diagnostics: []^Lsp_Diagnostic) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"uri":`)
	write_json_string(&b, uri)
	if doc != nil { fmt.sbprintf(&b, `,"version":%d`, doc.version) }
	strings.write_string(&b, `,"diagnostics":[`)
	for d, index in diagnostics {
		if index > 0 { strings.write_byte(&b, ',') }
		strings.write_string(&b, `{"range":`)
		write_range(&b, d.range)
		fmt.sbprintf(&b, `,"severity":%d,"code":`, d.severity == .Error ? 1 : 2)
		write_json_string(&b, d.code)
		strings.write_string(&b, `,"source":"lokec","message":`)
		write_json_string(&b, d.message)
		if len(d.related) > 0 {
			strings.write_string(&b, `,"relatedInformation":[`)
			for note, slot in d.related {
				if slot > 0 { strings.write_byte(&b, ',') }
				strings.write_string(&b, `{"location":{"uri":`)
				write_json_string(&b, uri_for(s, path_key(note.path, context.temp_allocator), note.path))
				strings.write_string(&b, `,"range":`)
				write_range(&b, note.range)
				strings.write_string(&b, `},"message":`)
				write_json_string(&b, note.message)
				strings.write_byte(&b, '}')
			}
			strings.write_byte(&b, ']')
		}
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

write_range :: proc(b: ^strings.Builder, range: Range) {
	fmt.sbprintf(
		b, `{{"start":{{"line":%d,"character":%d}},"end":{{"line":%d,"character":%d}}}}`,
		range.start.line, range.start.character, range.end.line, range.end.character,
	)
}
