// The editor grammar in editors/vscode lists Loke's keywords and predeclared
// names for highlighting; this keeps those lists in step with the
// specification, so a new keyword or built-in is not left unhighlighted.
package tests

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

EDITOR_GRAMMAR :: "editors/vscode/syntaxes/loke.tmLanguage.json"

// Every keyword of grammar.md "Keywords" is highlighted as one, and nothing
// else is but its contextual keywords; every name of design.md "Predeclared
// names" is highlighted as a predeclared name, and nothing else is.
@(test)
editor_grammar_follows_the_specification :: proc(t: ^testing.T) {
	data, err := os.read_entire_file(EDITOR_GRAMMAR, context.temp_allocator)
	if !testing.expectf(t, err == nil, "cannot read %s", EDITOR_GRAMMAR) { return }
	grammar, parse_err := json.parse(data, allocator = context.temp_allocator)
	if !testing.expectf(t, parse_err == nil, "%s is not valid JSON: %v", EDITOR_GRAMMAR, parse_err) { return }
	repository := object_member(grammar, "repository")
	keyword_words := make(map[string]bool, context.temp_allocator)
	for entry in ([]string{"keywords", "package", "import"}) { pattern_words(object_member(repository, entry), &keyword_words) }
	name_words := make(map[string]bool, context.temp_allocator)
	for entry in ([]string{"types", "builtins", "constants"}) { pattern_words(object_member(repository, entry), &name_words) }

	grammar_md, _ := os.read_entire_file("grammar.md", context.temp_allocator)
	keywords := section(string(grammar_md), "Keywords")
	reserved := make(map[string]bool, context.temp_allocator)
	contextual := make(map[string]bool, context.temp_allocator)
	fence := strings.index(keywords, "```")
	if testing.expect(t, fence >= 0, "grammar.md \"Keywords\" has no keyword block") {
		block := keywords[fence + 3:]
		block = block[:max(strings.index(block, "```"), 0)]
		for word in strings.fields(block, context.temp_allocator) { reserved[word] = true }
	}
	for line in strings.split_lines(keywords, context.temp_allocator) {
		if !strings.has_prefix(line, "| `") { continue }
		cell := line[1:]
		cell = cell[:max(strings.index_byte(cell, '|'), 0)]
		for word in backticked(cell) { contextual[word] = true }
	}
	testing.expect(t, len(reserved) > 30 && len(contextual) > 5, "grammar.md \"Keywords\" did not list the keywords")

	design_md, _ := os.read_entire_file("design.md", context.temp_allocator)
	predeclared := make(map[string]bool, context.temp_allocator)
	for name in ([]string{"true", "false", "nil"}) { predeclared[name] = true }
	for line in strings.split_lines(section(string(design_md), "Predeclared names"), context.temp_allocator) {
		if !strings.has_prefix(line, "- ") { continue }
		for name in backticked(line) { predeclared[name] = true }
	}
	testing.expect(t, len(predeclared) > 50, "design.md \"Predeclared names\" did not list the names")

	for word in reserved {
		testing.expectf(t, keyword_words[word], "the keyword `%s` is not highlighted by %s", word, EDITOR_GRAMMAR)
	}
	// concurrency-proposal.md "Milestone 4: `parallel` and `spawn`, gated":
	// grammar.md lists the two statements' words once milestone 5 enables them.
	for word in ([]string{"parallel", "spawn"}) { contextual[word] = true }
	for word in keyword_words {
		testing.expectf(t, reserved[word] || contextual[word], "%s highlights `%s` as a keyword, but grammar.md does not list it", EDITOR_GRAMMAR, word)
	}
	for name in predeclared {
		testing.expectf(t, name_words[name], "the predeclared name `%s` is not highlighted by %s", name, EDITOR_GRAMMAR)
	}
	for word in name_words {
		testing.expectf(t, predeclared[word], "%s highlights `%s` as predeclared, but design.md does not list it", EDITOR_GRAMMAR, word)
	}
}

@(private = "file")
object_member :: proc(value: json.Value, name: string) -> json.Value {
	if object, is_object := value.(json.Object); is_object { return object[name] }
	return nil
}

// The names an entry's `match` patterns list, with its nested patterns: every
// run of name characters outside escapes and character classes.
@(private = "file")
pattern_words :: proc(entry: json.Value, words: ^map[string]bool) {
	if pattern, has_match := object_member(entry, "match").(json.String); has_match {
		is_word :: proc(ch: u8) -> bool { return ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') }
		for i := 0; i < len(pattern); {
			switch {
			case pattern[i] == '\\':
				i += 2
			case pattern[i] == '[':
				for i += 1; i < len(pattern) && pattern[i] != ']'; { i += pattern[i] == '\\' ? 2 : 1 }
				i += 1
			case is_word(pattern[i]):
				start := i
				for i < len(pattern) && is_word(pattern[i]) { i += 1 }
				words[string(pattern[start:i])] = true
			case:
				i += 1
			}
		}
	}
	if patterns, is_array := object_member(entry, "patterns").(json.Array); is_array {
		for nested in patterns { pattern_words(nested, words) }
	}
}

// The text under `## heading`, up to the next heading of that level.
@(private = "file")
section :: proc(text, heading: string) -> string {
	start := strings.index(text, strings.concatenate({"\n## ", heading, "\n"}, context.temp_allocator))
	if start < 0 { return "" }
	rest := text[start + len(heading) + 5:]
	if end := strings.index(rest, "\n## "); end >= 0 { return rest[:end] }
	return rest
}

@(private = "file")
backticked :: proc(text: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	rest := text
	for {
		open := strings.index_byte(rest, '`')
		if open < 0 { break }
		close := strings.index_byte(rest[open + 1:], '`')
		if close < 0 { break }
		append(&out, rest[open + 1:open + 1 + close])
		rest = rest[open + close + 2:]
	}
	return out[:]
}
