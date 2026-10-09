// `loke.project`: the dependencies a program imports, each registered as a
// collection so `require json ../json` lets source write `import "json:parse";`
// (readme.md "Projects").
package lokec

import "core:os"
import "core:strings"

PROJECT_FILE :: "loke.project"

// Registers what the nearest `loke.project` at or above `input` requires, then
// what each dependency's own `loke.project` requires, as collections. One name
// names one directory in the whole program. A `-collection` for the name wins,
// which is how a dependency is overridden or vendored.
register_project :: proc(c: ^Compiler, input: string) -> bool {
	dir := canonical_dir(is_source_directory(c, input) ? input : path_dir(input, context.temp_allocator))
	for !os.exists(join_path({dir, PROJECT_FILE}, context.temp_allocator)) {
		parent := path_dir(dir, context.temp_allocator)
		if parent == dir {
			return true
		}
		dir = parent
	}

	// The bundled and `-collection` names, which no manifest replaces.
	given := make(map[string]bool, context.temp_allocator)
	for name in c.collections {
		given[name] = true
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
			fields := strings.fields(line, context.temp_allocator)
			if len(fields) < 3 || fields[0] != "require" || strings.index_byte(fields[1], ':') >= 0 {
				errorf(c, span, "L0398", "a `%s` line is `require <name> <path>`, and a name has no `:`", PROJECT_FILE)
				continue
			}
			name := fields[1]
			// The path is the rest of the line, so it may contain spaces.
			rest := strings.trim_space(line[len("require"):])
			written := strings.trim_space(rest[len(name):])
			target := canonical_dir(join_path({project, written}, context.temp_allocator))
			switch {
			case name == "base" || name == "core":
				errorf(c, span, "L0399", "`%s` is the library bundled with the compiler; a project cannot require it", name)
			case given[name]:
				append(&pending, canonical_dir(c.collections[name]))
			case name in required_by:
				if dir_key(c.collections[name]) != dir_key(target) {
					errorf(c, span, "L0399", "`%s` is already required as another directory; one name names one directory", name)
					add_notef(c, required_by[name], "`%s` is first required here", name)
				}
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
