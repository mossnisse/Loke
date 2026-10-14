// Completion and signature help, answered while code is being written. Both
// read the snapshot of the document's current text, which is often unfinished:
// the compiler still checks a statement it could not parse to the end, so the
// operand of `value.` or the callee of `call(first, ` keeps its recorded
// meaning (compiler-architecture.md "Language server").
package lsp

import "core:fmt"
import "core:strings"

import lokec "../src"

// LSP `CompletionItemKind` values.
Completion_Kind :: enum {
	Method = 2, Function = 3, Field = 5, Variable = 6, Class = 7, Interface = 8,
	Module = 9, Value = 12, Enum = 13, Keyword = 14, Enum_Member = 20,
	Constant = 21, Struct = 22,
}

// The kind as the client can show it: the kinds after `Reference` have an
// older equivalent for clients that do not list them.
@(private = "file")
completion_client_kind :: proc(s: ^Server, kind: Completion_Kind) -> int {
	if int(kind) in s.completion_kinds { return int(kind) }
	#partial switch kind {
	case .Enum_Member, .Constant: return int(Completion_Kind.Value)
	case .Struct:                 return int(Completion_Kind.Class)
	}
	return int(kind)
}

@(private = "file")
Completion_Item :: struct {
	label:  string,
	kind:   Completion_Kind,
	detail: string,
	symbol: lokec.Symbol_Handle, // for documentation; zero for a keyword or variant
}

EMPTY_COMPLETION :: `{"isIncomplete":false,"items":[]}`

// After `operand.`, what the operand's recorded type or package offers.
// Elsewhere, every binding an unqualified name could reach there, innermost
// first, then the keywords. Nothing inside a comment or literal, and nothing
// after a `.` whose operand is unknown.
completion :: proc(s: ^Server, session: ^lokec.Compilation_Session, snapshot: lokec.Compilation_Snapshot, file: u32, text: string, position: Position) -> string {
	offset := u32(position_to_offset(text, position, s.utf8_positions))
	comments := make([dynamic]lokec.Span, context.temp_allocator)
	tokens := lex_text(text, &comments)
	defer delete(tokens)
	if inside_comment_or_literal(text, tokens, comments[:], offset) { return EMPTY_COMPLETION }
	start := offset
	for start > 0 && is_name_byte(text[start - 1]) { start -= 1 }
	before := -1
	for token, index in tokens {
		if token.hi > start { break }
		before = index
	}
	items := make([dynamic]Completion_Item, context.temp_allocator)
	if before >= 0 && tokens[before].kind == .Period {
		// `.Member` with no operand takes its type from context, which no
		// query records.
		if before == 0 || !ends_operand(tokens[before - 1].kind) { return EMPTY_COMPLETION }
		operand, found := lokec.query_at(session, snapshot, file, tokens[before - 1].hi - 1)
		if !found { return EMPTY_COMPLETION }
		members, listed := lokec.query_members(session, operand, file, context.temp_allocator)
		if !listed { return EMPTY_COMPLETION }
		for member in members {
			item := Completion_Item{label = member.name, kind = .Enum_Member}
			if member.variant {
				if type, typed := lokec.query_type(session, member.type); typed { item.detail = type.name }
			} else if symbol, known := lokec.query_symbol(session, member.symbol); known {
				item.kind, item.detail, item.symbol = completion_kind(session, symbol, member = true), symbol_detail(session, symbol), member.symbol
			}
			append(&items, item)
		}
	} else {
		visible, found := lokec.query_visible(session, snapshot, file, start, context.temp_allocator)
		if !found { return EMPTY_COMPLETION }
		for handle in visible {
			symbol, known := lokec.query_symbol(session, handle)
			if !known { continue }
			append(&items, Completion_Item{symbol.name, completion_kind(session, symbol, member = false), symbol_detail(session, symbol), handle})
		}
		for kind in lokec.Token_Kind.Break ..= lokec.Token_Kind.Where {
			append(&items, Completion_Item{label = strings.to_lower(fmt.tprint(kind), context.temp_allocator), kind = .Keyword})
		}
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"isIncomplete":false,"items":[`)
	for item, index in items {
		if index > 0 { strings.write_byte(&b, ',') }
		strings.write_string(&b, `{"label":`)
		write_json_string(&b, item.label)
		fmt.sbprintf(&b, `,"kind":%d,"sortText":"%05d"`, completion_client_kind(s, item.kind), index)
		if item.detail != "" {
			strings.write_string(&b, `,"detail":`)
			write_json_string(&b, item.detail)
		}
		if documentation, documented := lokec.query_documentation(session, item.symbol, context.temp_allocator); documented {
			if s.markdown_completion {
				strings.write_string(&b, `,"documentation":{"kind":"markdown","value":`)
				write_json_string(&b, documentation)
				strings.write_byte(&b, '}')
			} else {
				strings.write_string(&b, `,"documentation":`)
				write_json_string(&b, documentation)
			}
		}
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// A token that can end the operand of a selector.
@(private = "file")
ends_operand :: proc(kind: lokec.Token_Kind) -> bool {
	#partial switch kind {
	case .Ident, .Rparen, .Rbracket, .Rbrace, .Caret, .String, .Raw_String: return true
	}
	return false
}

@(private = "file")
completion_kind :: proc(session: ^lokec.Compilation_Session, symbol: lokec.Query_Symbol, member: bool) -> Completion_Kind {
	#partial switch symbol.kind {
	case .Proc, .Proc_Group: return member ? .Method : .Function
	case .Builtin:           return .Function
	case .Var, .Parameter:   return .Variable
	case .Const:             return .Constant
	case .Field:             return .Field
	case .Enum_Member:       return .Enum_Member
	case .Package_Alias:     return .Module
	case .Type:
		type, _ := lokec.query_type(session, symbol.type)
		#partial switch type.kind {
		case .Struct:    return .Struct
		case .Enum:      return .Enum
		case .Interface: return .Interface
		}
	}
	return .Class
}

// A procedure's signature on one line, or the recorded type of anything with
// a value.
symbol_detail :: proc(session: ^lokec.Compilation_Session, symbol: lokec.Query_Symbol) -> string {
	#partial switch symbol.kind {
	case .Proc, .Proc_Group:
		if signatures, found := lokec.query_signatures(session, symbol.handle); found {
			text := strings.join(strings.fields(signatures[0].text, context.temp_allocator), " ", context.temp_allocator)
			text, _ = strings.replace_all(text, "( ", "(", context.temp_allocator)
			text, _ = strings.replace_all(text, ", )", ")", context.temp_allocator)
			return text
		}
	case .Var, .Const, .Field, .Parameter, .Enum_Member:
		if type, found := lokec.query_type(session, symbol.type); found { return type.name }
	case .Package_Alias:
		return "package"
	}
	return ""
}

// The signatures of the call whose argument list holds the cursor: the
// innermost bracket still open before it must be that call's `(`, and the name
// before it must be a procedure or group the snapshot recorded. The active
// parameter counts the commas written so far, or follows a named argument; a
// method call's receiver is not one of them.
signature_help :: proc(s: ^Server, session: ^lokec.Compilation_Session, snapshot: lokec.Compilation_Snapshot, file: u32, text: string, position: Position) -> string {
	offset := u32(position_to_offset(text, position, s.utf8_positions))
	comments := make([dynamic]lokec.Span, context.temp_allocator)
	tokens := lex_text(text, &comments)
	defer delete(tokens)
	if inside_comment_or_literal(text, tokens, comments[:], offset) { return "null" }
	open := make([dynamic]int, context.temp_allocator)
	for token, index in tokens {
		if token.lo >= offset { break }
		#partial switch token.kind {
		case .Lparen, .Lbracket, .Lbrace: append(&open, index)
		case .Rparen, .Rbracket, .Rbrace: if len(open) > 0 { pop(&open) }
		}
	}
	if len(open) == 0 || tokens[open[len(open) - 1]].kind != .Lparen { return "null" }
	paren := open[len(open) - 1]
	if paren == 0 || tokens[paren - 1].kind != .Ident { return "null" }
	callee, found := lokec.query_at(session, snapshot, file, tokens[paren - 1].lo)
	if !found { return "null" }
	symbol, known := lokec.query_symbol(session, callee.symbol)
	if !known || (symbol.kind != .Proc && symbol.kind != .Proc_Group) { return "null" }
	signatures, signed := lokec.query_signatures(session, callee.symbol)
	if !signed { return "null" }

	active, argument, depth := 0, paren + 1, 0
	for index in paren + 1 ..< len(tokens) {
		token := tokens[index]
		if token.lo >= offset { break }
		#partial switch token.kind {
		case .Lparen, .Lbracket, .Lbrace: depth += 1
		case .Rparen, .Rbracket, .Rbrace: depth -= 1
		case .Comma:
			if depth == 0 { active, argument = active + 1, index + 1 }
		}
	}
	named := ""
	if argument + 1 < len(tokens) && tokens[argument].kind == .Ident && tokens[argument + 1].kind == .Assign && tokens[argument + 1].lo < offset {
		named = text[tokens[argument].lo:tokens[argument].hi]
	}
	// `value.method(` supplies `self` before the parentheses.
	receiver := false
	if paren >= 3 && tokens[paren - 2].kind == .Period && ends_operand(tokens[paren - 3].kind) {
		if operand, typed := lokec.query_at(session, snapshot, file, tokens[paren - 3].hi - 1); typed && !operand.type_value {
			alias, _ := lokec.query_symbol(session, operand.symbol)
			receiver = alias.kind != .Package_Alias
		}
	}

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"signatures":[`)
	chosen, chosen_parameter := -1, 0
	for signature, index in signatures {
		name := symbol.name
		if member, member_found := lokec.query_symbol(session, signature.symbol); member_found { name = member.name }
		label := fmt.tprintf("%s :: %s", name, signature.text)
		parameter := active
		if receiver && len(signature.parameters) > 0 && signature.parameters[0].name == "self" { parameter += 1 }
		if named != "" {
			parameter = -1
			for candidate, slot in signature.parameters { if candidate.name == named { parameter = slot } }
		}
		if chosen < 0 && parameter >= 0 && parameter < len(signature.parameters) { chosen, chosen_parameter = index, parameter }
		if index > 0 { strings.write_byte(&b, ',') }
		strings.write_string(&b, `{"label":`)
		write_json_string(&b, label)
		if documentation, documented := lokec.query_documentation(session, signature.symbol, context.temp_allocator); documented {
			strings.write_string(&b, `,"documentation":`)
			write_json_string(&b, documentation)
		}
		strings.write_string(&b, `,"parameters":[`)
		write_parameter_labels(s, &b, label, signature.parameters)
		fmt.sbprintf(&b, `],"activeParameter":%d}}`, max(parameter, 0))
	}
	fmt.sbprintf(&b, `],"activeSignature":%d,"activeParameter":%d}}`, max(chosen, 0), chosen_parameter)
	return strings.to_string(b)
}

// Each parameter as its name's place in the label, found in order among the
// names inside the label's outer parentheses; a client without offsets gets
// the name itself.
@(private = "file")
write_parameter_labels :: proc(s: ^Server, b: ^strings.Builder, label: string, parameters: []lokec.Query_Parameter) {
	tokens := lex_text(label)
	defer delete(tokens)
	next, depth := 0, 0
	for parameter, index in parameters {
		if index > 0 { strings.write_byte(b, ',') }
		lo, hi := -1, -1
		for next < len(tokens) && lo < 0 {
			token := tokens[next]
			next += 1
			#partial switch token.kind {
			case .Lparen, .Lbracket, .Lbrace: depth += 1
			case .Rparen, .Rbracket, .Rbrace: depth -= 1
			case .Ident:
				if depth == 1 && label[token.lo:token.hi] == parameter.name { lo, hi = int(token.lo), int(token.hi) }
			}
		}
		if s.label_offsets && lo >= 0 {
			if s.utf8_positions {
				fmt.sbprintf(b, `{{"label":[%d,%d]}}`, lo, hi)
			} else {
				fmt.sbprintf(b, `{{"label":[%d,%d]}}`, utf16_length(label[:lo]), utf16_length(label[:hi]))
			}
		} else {
			strings.write_string(b, `{"label":`)
			write_json_string(b, parameter.name)
			strings.write_byte(b, '}')
		}
	}
}

// The compiler's own tokens for a text: literals are whole, and comments are
// left out, their spans appended to `comments` when it is given.
lex_text :: proc(text: string, comments: ^[dynamic]lokec.Span = nil) -> []lokec.Token {
	scratch: lokec.Compiler
	defer lokec.destroy_compilation(&scratch)
	append(&scratch.sources, lokec.Source{text = text})
	tokens := lokec.lex(&scratch, 0)
	if comments != nil { append(comments, ..scratch.sources[0].comments[:]) }
	return tokens
}

// Whether the offset falls inside a string or rune literal, or a comment as
// the lexer found it, nesting included. The end of a `//` comment, and of a
// block comment the text never closes, is still inside it.
@(private = "file")
inside_comment_or_literal :: proc(text: string, tokens: []lokec.Token, comments: []lokec.Span, offset: u32) -> bool {
	for token in tokens {
		if token.lo >= offset || token.kind == .EOF { break }
		if offset < token.hi {
			#partial switch token.kind {
			case .String, .Raw_String, .Rune: return true
			}
			return false
		}
	}
	for comment in comments {
		if comment.lo >= offset { break }
		written := text[comment.lo:comment.hi]
		open_ended := strings.has_prefix(written, "//") || !strings.has_suffix(written, "*/")
		if offset < comment.hi || (offset == comment.hi && open_ended) { return true }
	}
	return false
}
