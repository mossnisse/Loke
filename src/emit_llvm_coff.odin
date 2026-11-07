// The C runtime a foreign COFF input asks the linker for.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:strconv"
import "core:strings"

// What `/MT`, `/MTd`, `/MD`, and `/MDd` tell a compiler to request: each object
// it writes names its C runtime in a `/DEFAULTLIB` linker directive.
Crt_Kind :: enum u8 {
	Static,
	Static_Debug,
	Dynamic,
	Dynamic_Debug,
}

Crt_Kinds :: bit_set[Crt_Kind; u8]

// The C runtimes named by the `.drectve` sections of an object file or of each
// object in an archive (`.lib`). An import library's members, an LTO bitcode
// member, and anything that is not COFF name none; so does an object compiled
// with `/Zl`.
@(private)
coff_requested_crts :: proc(data: []u8) -> Crt_Kinds {
	ARCHIVE_SIGNATURE :: "!<arch>\n"
	MEMBER_HEADER :: 60
	if len(data) < len(ARCHIVE_SIGNATURE) || string(data[:len(ARCHIVE_SIGNATURE)]) != ARCHIVE_SIGNATURE {
		return coff_object_crts(data)
	}
	kinds: Crt_Kinds
	at := len(ARCHIVE_SIGNATURE)
	for at + MEMBER_HEADER <= len(data) {
		header := data[at:at + MEMBER_HEADER]
		size, parsed := strconv.parse_int(strings.trim_space(string(header[48:58])), 10)
		if !parsed || size < 0 || size > len(data) - at - MEMBER_HEADER {
			break
		}
		body := data[at + MEMBER_HEADER:][:size]
		// `/` (the symbol indexes), `//` (the long names), and `/<ECSYMBOLS>/`
		// hold no code; an object's name is `name/` or `/<offset>`.
		if !(header[0] == '/' && (header[1] == ' ' || header[1] == '/' || header[1] == '<')) {
			kinds += coff_object_crts(body)
		}
		// Members start on even offsets.
		at += MEMBER_HEADER + size + (size & 1)
	}
	return kinds
}

// `ANON_OBJECT_HEADER_BIGOBJ`'s class identifier, which tells a `/bigobj`
// object from an import member sharing its first four bytes.
@(private = "file")
BIGOBJ_CLASS :: "\xc7\xa1\xba\xd1\xee\xba\xa9\x4b\xaf\x20\xfa\xf6\x6a\xa4\xdc\xb8"

@(private = "file")
coff_object_crts :: proc(object: []u8) -> Crt_Kinds {
	HEADER :: 20
	BIGOBJ_HEADER :: 56
	SECTION_HEADER :: 40
	if len(object) < HEADER {
		return {}
	}
	sections_at, count: int
	if read_u16_le(object, 0) == 0 && read_u16_le(object, 2) == 0xFFFF {
		if len(object) < BIGOBJ_HEADER || read_u16_le(object, 4) < 2 || string(object[12:28]) != BIGOBJ_CLASS {
			return {}
		}
		sections_at, count = BIGOBJ_HEADER, int(read_u32_le(object, 44))
	} else {
		// An object has no optional header; an image or other data that
		// happens to get here would.
		if read_u16_le(object, 16) != 0 {
			return {}
		}
		sections_at, count = HEADER, int(read_u16_le(object, 2))
	}
	kinds: Crt_Kinds
	for i in 0 ..< count {
		at := sections_at + i * SECTION_HEADER
		if at + SECTION_HEADER > len(object) {
			break
		}
		if string(object[at:at + 8]) != ".drectve" {
			continue
		}
		size := int(read_u32_le(object, at + 16))
		start := int(read_u32_le(object, at + 20))
		if start > len(object) || size > len(object) - start {
			continue
		}
		kinds += directive_crts(string(object[start:][:size]))
	}
	return kinds
}

// A `.drectve` section is linker options separated by spaces, each starting
// with `/` or `-` in any case, a value possibly quoted: `/DEFAULTLIB:"MSVCRT"`
// from MSVC, `-defaultlib:msvcrt.lib` from clang.
@(private = "file")
directive_crts :: proc(directives: string) -> Crt_Kinds {
	text := strings.trim_prefix(directives, "\xef\xbb\xbf")
	kinds: Crt_Kinds
	for len(text) > 0 {
		text = strings.trim_left(text, " \t\r\n\x00")
		end, quoted := 0, false
		for end < len(text) && (quoted || !strings.contains_rune(" \t\r\n\x00", rune(text[end]))) {
			if text[end] == '"' {
				quoted = !quoted
			}
			end += 1
		}
		option := text[:end]
		text = text[end:]
		if len(option) < 2 || (option[0] != '/' && option[0] != '-') {
			continue
		}
		name, _, value := strings.partition(option[1:], ":")
		if !strings.equal_fold(name, "defaultlib") {
			continue
		}
		library := strings.trim(value, "\"")
		if len(library) >= 4 && strings.equal_fold(library[len(library) - 4:], ".lib") {
			library = library[:len(library) - 4]
		}
		switch {
		case strings.equal_fold(library, "libcmt"):
			kinds += {.Static}
		case strings.equal_fold(library, "libcmtd"):
			kinds += {.Static_Debug}
		case strings.equal_fold(library, "msvcrt"):
			kinds += {.Dynamic}
		case strings.equal_fold(library, "msvcrtd"):
			kinds += {.Dynamic_Debug}
		}
	}
	return kinds
}

@(private = "file")
read_u16_le :: proc(data: []u8, at: int) -> u16 {
	return u16(data[at]) | u16(data[at + 1]) << 8
}

@(private = "file")
read_u32_le :: proc(data: []u8, at: int) -> u32 {
	return u32(data[at]) | u32(data[at + 1]) << 8 | u32(data[at + 2]) << 16 | u32(data[at + 3]) << 24
}
