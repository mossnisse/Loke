// Session-owned unsaved .loke files, consumed by ordinary source/package loading.
package lokec

import "core:os"
import "core:path/filepath"
import "core:strings"

// One unsaved file, under a case-insensitive key that the map owns.
Source_Overlay :: struct {
	path: string, // absolute, cleaned path
	text: string,
	dir:  string, // the key of the directory holding it, as `package_sources` compares
}

@(private)
delete_overlay :: proc(key: string, overlay: Source_Overlay) {
	delete(key)
	delete(overlay.path)
	delete(overlay.text)
	delete(overlay.dir)
}

// Empty text is an overlay, not an absent file. Paths have the same case-insensitive, cleaned identity as packages on Windows.
set_session_overlay :: proc(s: ^Compilation_Session, path, text: string) -> bool {
	if !s.initialized || !strings.equal_fold(filepath.ext(path), ".loke") { return false }
	context.allocator = s.allocator
	canonical := canonical_dir(path)
	key := dir_key(canonical)
	// Copy first: either argument may be borrowed from the old snapshot/overlay.
	overlay := Source_Overlay {
		path = strings.clone(canonical),
		text = strings.clone(text),
		dir  = dir_key(canonical_dir(path_dir(canonical, context.temp_allocator)), context.allocator),
	}
	if stored, found := &s.overlays[key]; found {
		delete(stored.path)
		delete(stored.text)
		delete(stored.dir)
		stored^ = overlay
	} else {
		s.overlays[strings.clone(key)] = overlay
	}
	invalidate_session_snapshot(s)
	return true
}

// Removing an overlay returns source loading to disk.
remove_session_overlay :: proc(s: ^Compilation_Session, path: string) -> bool {
	if !s.initialized { return false }
	context.allocator = s.allocator
	key, overlay := delete_key(&s.overlays, dir_key(canonical_dir(path)))
	if key == "" { return false }
	delete_overlay(key, overlay)
	invalidate_session_snapshot(s)
	return true
}

// Empty outside a session.
compiler_overlays :: proc(c: ^Compiler) -> map[string]Source_Overlay {
	return c.source_overlays^ if c.source_overlays != nil else nil
}

// A new unsaved file can establish a package directory without creating it on
// disk, including its parent directories. Package discovery still loads only
// direct children.
is_source_directory :: proc(c: ^Compiler, path: string) -> bool {
	if os.is_dir(path) { return true }
	prefix := strings.concatenate({strings.trim_right(dir_key(canonical_dir(path)), "/"), "/"}, context.temp_allocator)
	for key in compiler_overlays(c) {
		if strings.has_prefix(key, prefix) { return true }
	}
	return false
}
