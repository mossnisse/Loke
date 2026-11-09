// The Windows subsystem an executable is linked for: design.md
// "@(subsystem=<string>)".
package lokec

Subsystem :: enum {
	Console,
	Windows,
}

// The root package's choice, read where the link needs it rather than kept on
// the compiler, so an incremental check has nothing to reset. Validation has
// already rejected a second or unknown value.
root_subsystem :: proc(c: ^Compiler) -> Subsystem {
	pkg := package_of(c, c.root_package)
	if pkg == nil {
		return .Console
	}
	for file in pkg.files {
		if text, written := attribute_string_value(c, file.attributes, "subsystem"); written {
			if subsystem, known := parse_subsystem(text); known {
				return subsystem
			}
		}
	}
	return .Console
}

@(private = "file")
parse_subsystem :: proc(text: string) -> (Subsystem, bool) {
	switch text {
	case "console": return .Console, true
	case "windows": return .Windows, true
	}
	return .Console, false
}

// design.md "@(subsystem=<string>)": once across the root package's files, and a
// known value. An imported package is `validate_root_only_attributes`' to
// reject, and a malformed value `validate_attribute_list`'s.
validate_subsystem_attributes :: proc(k: ^Checker, pkg: ^Package) {
	if pkg.id != k.c.root_package {
		return
	}
	first: Span
	seen := false
	for file in pkg.files {
		attribute, written := find_attribute(file.attributes, "subsystem")
		if !written {
			continue
		}
		if seen {
			errorf(k.c, attribute.span, "L0753", "`@(subsystem)` is written on more than one file of the root package")
			add_notef(k.c, first, "the first is here")
			continue
		}
		seen, first = true, attribute.span
		text, valid := attribute_string_text(k.c, attribute)
		if !valid {
			continue
		}
		if _, known := parse_subsystem(text); !known {
			errorf(k.c, attribute.span, "L0754", "`@(subsystem)` is `\"console\"` or `\"windows\"`, not `\"%s\"`", text)
		}
	}
}
