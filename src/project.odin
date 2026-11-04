// `loke.project`: the dependencies a program imports, each registered as a
// collection so `require json ../json` lets source write `import "json:parse";`
// (compiler-guide.md "Projects").
package lokec

import "core:os"
import "core:strings"

PROJECT_FILE :: "loke.project"

// Registers what the nearest `loke.project` at or above `input` requires, then
// what each dependency's own `loke.project` requires, as collections.
register_project :: proc(c: ^Compiler, input: string) -> bool {
	dir, found := nearest_project_dir(c, input)
	if !found {
		return true
	}
	// The line that required each name, for the conflict diagnostic.
	required_by := make(map[string]Span, context.temp_allocator)
	visited := make(map[string]bool, context.temp_allocator)
	pending := make([dynamic]string, context.temp_allocator)
	append(&pending, dir)
	for len(pending) > 0 {
		project := pop_front(&pending)
		if visited[dir_key(project)] {
			continue
		}
		visited[dir_key(project)] = true
		path := join_path({project, PROJECT_FILE}, c.semantic_allocator)
		if !os.exists(path) {
			continue
		}
		file, loaded := load_source(c, path)
		if !loaded {
			continue
		}
		text := c.sources[file].text
		for offset := 0; offset < len(text); {
			end := strings.index_byte(text[offset:], '\n')
			end = end < 0 ? len(text) : offset + end
			line := strings.trim_space(text[offset:end])
			span := Span{file = file, lo = u32(offset), hi = u32(end)}
			offset = end + 1
			if line == "" || line[0] == '#' {
				continue
			}
			name, written, well_formed := parse_require_line(line)
			if !well_formed {
				errorf(c, span, "L0398", "a `%s` line is `require <name> <path>`, and a name has no `:`", PROJECT_FILE)
				continue
			}
			target := canonical_dir(join_path({project, written}, context.temp_allocator))
			switch {
			case name == "base" || name == "core":
				errorf(c, span, "L0399", "`%s` is the library bundled with the compiler; a project cannot require it", name)
			case name in required_by:
				if dir_key(c.collections[name]) != dir_key(target) {
					errorf(c, span, "L0399", "`%s` is already required as another directory; one name names one directory, and `-collection %s=<path>` chooses it for the whole program", name, name)
					add_notef(c, required_by[name], "`%s` is first required here", name)
				}
			case name in c.collections:
				// A `-collection`, which no manifest replaces.
				append(&pending, canonical_dir(c.collections[name]))
			case !is_source_directory(c, target):
				errorf(c, span, "L0399", "dependency `%s` names `%s`, which is not a directory", name, written)
			case:
				c.collections[name] = strings.clone(target, c.semantic_allocator)
				required_by[name] = span
				append(&pending, target)
			}
		}
	}
	return c.error_count == 0
}

// The directory of the nearest `loke.project` at or above `input`.
@(private = "file")
nearest_project_dir :: proc(c: ^Compiler, input: string) -> (dir: string, found: bool) {
	dir = canonical_dir(is_source_directory(c, input) ? input : path_dir(input, context.temp_allocator))
	for !os.exists(join_path({dir, PROJECT_FILE}, context.temp_allocator)) {
		parent := canonical_dir(path_dir(dir, context.temp_allocator))
		if parent == dir {
			return "", false
		}
		dir = parent
	}
	return dir, true
}

// The path is the rest of the line, so it may contain spaces.
@(private = "file")
parse_require_line :: proc(line: string) -> (name, written: string, ok: bool) {
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) < 3 || fields[0] != "require" || strings.index_byte(fields[1], ':') >= 0 {
		return
	}
	name = fields[1]
	rest := strings.trim_space(line[len("require"):])
	return name, strings.trim_space(rest[len(name):]), true
}

// Explicit entries replace bundled `base:` and `core:` roots.
@(private)
register_collections :: proc(c: ^Compiler, entries: []string) {
	for name in ([]string{"base", "core"}) {
		if bundled := install_component(name); bundled != "" {
			c.collections[name] = strings.clone(bundled, c.semantic_allocator)
		}
	}

	explicit := make(map[string]bool, len(entries), context.temp_allocator)
	for entry in entries {
		split := strings.index_byte(entry, '=')
		if split <= 0 {
			errorf(c, NO_SPAN, "L0333", "`-collection %s` needs the form name=path", entry)
			continue
		}
		name := entry[:split]
		root := entry[split + 1:]
		if strings.index_byte(name, ':') >= 0 {
			errorf(c, NO_SPAN, "L0333", "collection name `%s` cannot contain `:`", name)
			continue
		}
		if root == "" {
			errorf(c, NO_SPAN, "L0333", "collection `%s` needs a path", name)
			continue
		}
		if explicit[name] {
			errorf(c, NO_SPAN, "L0333", "collection `%s` is registered more than once", name)
			continue
		}
		explicit[name] = true
		c.collections[name] = strings.clone(root, c.semantic_allocator)
	}
}
