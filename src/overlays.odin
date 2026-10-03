// Session-owned unsaved .loke files, consumed by ordinary source/package loading.
package lokec

import "core:path/filepath"
import "core:strings"

// Copy the path and text. Empty text is an overlay, not an absent file. Paths
// have the same case-insensitive, cleaned identity as packages on Windows.
set_session_overlay :: proc(s: ^Compilation_Session, path, text: string) -> bool {
	if !s.initialized || path == "" || !strings.equal_fold(filepath.ext(path), ".loke") { return false }
	context.allocator = s.allocator
	key := dir_key(canonical_dir(path))
	// Copy first: either argument may be borrowed from the old snapshot/overlay.
	overlay := Source_Overlay{path = strings.clone(canonical_dir(path)), text = strings.clone(text)}
	if previous, found := s.overlays[key]; found {
		overlay.key = previous.key
		delete(previous.path)
		delete(previous.text)
		s.overlays[key] = overlay
	} else {
		overlay.key = strings.clone(key)
		s.overlays[overlay.key] = overlay
	}
	invalidate_session_snapshot(s)
	return true
}

// Removing an overlay returns source loading to disk. A missing overlay is a
// no-op and does not invalidate a checked result.
remove_session_overlay :: proc(s: ^Compilation_Session, path: string) -> bool {
	if !s.initialized { return false }
	context.allocator = s.allocator
	key := dir_key(canonical_dir(path))
	if previous, found := s.overlays[key]; found {
		delete_key(&s.overlays, key)
		delete(previous.key)
		delete(previous.path)
		delete(previous.text)
		invalidate_session_snapshot(s)
		return true
	}
	return false
}

// Empty outside a session. A pointer, not a copy of the map, so an overlay edit
// can never leave the compiler holding a stale map header.
compiler_overlays :: proc(c: ^Compiler) -> map[string]Source_Overlay {
	return c.source_overlays^ if c.source_overlays != nil else nil
}

// A new unsaved file can establish a package directory without creating it on
// disk, including its parent directories. Package discovery still loads only
// direct children.
is_source_directory :: proc(c: ^Compiler, path: string) -> bool {
	if is_directory(path) { return true }
	key := strings.concatenate({strings.trim_right(dir_key(canonical_dir(path)), "/"), "/"}, context.temp_allocator)
	for _, overlay in compiler_overlays(c) {
		if strings.has_prefix(overlay.key, key) { return true }
	}
	return false
}
