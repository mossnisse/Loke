// The C runtime a foreign COFF input asks the linker for.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:mem/virtual"
import "core:path/filepath"
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

// The library a `/DEFAULTLIB` directive names for each runtime, without `.lib`.
@(private = "file")
CRT_LIBRARIES := [Crt_Kind]string {
	.Static        = "libcmt",
	.Static_Debug  = "libcmtd",
	.Dynamic       = "msvcrt",
	.Dynamic_Debug = "msvcrtd",
}

// Each runtime as a diagnostic names it, with the option that selects it.
@(private)
CRT_DESCRIPTIONS := [Crt_Kind]string {
	.Static        = "the static C runtime (`/MT`)",
	.Static_Debug  = "the debug static C runtime (`/MTd`)",
	.Dynamic       = "the dynamic C runtime (`/MD`)",
	.Dynamic_Debug = "the debug dynamic C runtime (`/MDd`)",
}

// `coff_requested_crts` of the file at `path`, or none when it cannot be read.
// The file is mapped rather than read, so a large archive costs the pages of
// its headers and directives, not a copy of all of it.
@(private)
file_requested_crts :: proc(path: string) -> Crt_Kinds {
	data, err := virtual.map_file_from_path(path, {.Read})
	if err != nil {
		return {}
	}
	defer virtual.unmap_file(data)
	return coff_requested_crts(data)
}

// The C runtimes named by the `.drectve` sections of an object file or of each
// object in an archive (`.lib`). An import library's members name none, and so
// do an object compiled with `/Zl` and anything that is not plain COFF: neither
// clang's `-flto` bitcode nor MSVC's `/GL` objects are read.
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
@(private)
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
	SEPARATORS :: " \t\r\n\x00"
	text := strings.trim_prefix(directives, "\xef\xbb\xbf")
	kinds: Crt_Kinds
	for len(text) > 0 {
		text = strings.trim_left(text, SEPARATORS)
		end, quoted := 0, false
		for end < len(text) && (quoted || strings.index_byte(SEPARATORS, text[end]) < 0) {
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
		if extension := filepath.ext(library); strings.equal_fold(extension, ".lib") {
			library = strings.trim_suffix(library, extension)
		}
		for runtime_library, kind in CRT_LIBRARIES {
			if strings.equal_fold(library, runtime_library) {
				kinds += {kind}
			}
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
