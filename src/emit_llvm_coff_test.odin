package lokec

import "core:fmt"
import "core:testing"

// A COFF object with one `.drectve` section holding `directives`, in the
// ordinary layout or the one `/bigobj` writes.
@(private = "file")
coff_object :: proc(directives: string, bigobj := false) -> []u8 {
	BIGOBJ_CLASS_BYTES :: "\xc7\xa1\xba\xd1\xee\xba\xa9\x4b\xaf\x20\xfa\xf6\x6a\xa4\xdc\xb8"
	header := bigobj ? 56 : 20
	out := make([dynamic]u8, header + 40, context.temp_allocator)
	put_u16 :: proc(out: []u8, at: int, value: u16) {
		out[at], out[at + 1] = u8(value), u8(value >> 8)
	}
	put_u32 :: proc(out: []u8, at: int, value: u32) {
		put_u16(out, at, u16(value))
		put_u16(out, at + 2, u16(value >> 16))
	}
	if bigobj {
		put_u16(out[:], 2, 0xFFFF)
		put_u16(out[:], 4, 2)
		put_u16(out[:], 6, 0x8664)
		copy(out[12:28], BIGOBJ_CLASS_BYTES)
		put_u32(out[:], 44, 1)
	} else {
		put_u16(out[:], 0, 0x8664)
		put_u16(out[:], 2, 1)
	}
	copy(out[header:], ".drectve")
	put_u32(out[:], header + 16, u32(len(directives)))
	put_u32(out[:], header + 20, u32(header + 40))
	append(&out, directives)
	return out[:]
}

// An archive of `members`, each named by its key, as `lib.exe` lays one out.
@(private = "file")
coff_archive :: proc(members: [][2]string) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, "!<arch>\n")
	for member in members {
		name, body := member[0], member[1]
		append(&out, fmt.tprintf("%-16s%-12s%-6s%-6s%-8s%-10d`\n", name, "0", "", "", "0", len(body)))
		append(&out, body)
		if len(body) % 2 == 1 {
			append(&out, '\n')
		}
	}
	return out[:]
}

@(test)
crt_requests_are_read_from_each_directive_spelling :: proc(t: ^testing.T) {
	// clang's spelling.
	testing.expect_value(t, coff_requested_crts(coff_object("-defaultlib:msvcrt.lib -defaultlib:oldnames.lib")), Crt_Kinds{.Dynamic})
	// MSVC's: upper case, quoted, after a byte-order mark.
	testing.expect_value(t, coff_requested_crts(coff_object("\xef\xbb\xbf   /DEFAULTLIB:\"LIBCMTD\" /DEFAULTLIB:\"OLDNAMES\" ")), Crt_Kinds{.Static_Debug})
	testing.expect_value(t, coff_requested_crts(coff_object("/DEFAULTLIB:\"msvcrtd.lib\" /FAILIFMISMATCH:\"RuntimeLibrary=MDd_DynamicDebug\"")), Crt_Kinds{.Dynamic_Debug})
	testing.expect_value(t, coff_requested_crts(coff_object("/DEFAULTLIB:libcmt.lib")), Crt_Kinds{.Static})
	// A library that is no C runtime, and an option that only looks like one.
	testing.expect_value(t, coff_requested_crts(coff_object("/DEFAULTLIB:user32.lib /NODEFAULTLIB:msvcrt.lib /EXPORT:msvcrt")), Crt_Kinds{})
	testing.expect_value(t, coff_requested_crts(coff_object("/defaultlib:MSVCRT", bigobj = true)), Crt_Kinds{.Dynamic})
}

@(test)
crt_requests_are_gathered_from_an_archives_objects :: proc(t: ^testing.T) {
	// Every member before the objects looks like no object: the symbol index,
	// the long names, and an import member, which shares `/bigobj`'s signature.
	import_member :: "\x00\x00\xff\xff\x00\x00\x64\x86" + "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" + "foo\x00foo.dll\x00"
	archive := coff_archive({
		{"/", "\x00\x00\x00\x00"},
		{"//", "a-long-member-name.obj/\n"},
		{"foo.dll/", import_member},
		// Odd-sized, so the next member starts after a padding byte.
		{"a.obj/", string(coff_object("-defaultlib:libcmt.lib "))},
		{"/0", string(coff_object("/DEFAULTLIB:\"MSVCRT\""))},
	})
	testing.expect_value(t, coff_requested_crts(archive), Crt_Kinds{.Static, .Dynamic})

	// An import library alone asks for nothing, whatever its DLL was built with.
	testing.expect_value(t, coff_requested_crts(coff_archive({{"/", "\x00\x00\x00\x00"}, {"foo.dll/", import_member}})), Crt_Kinds{})
}

// A damaged input reads as asking for nothing, never out of bounds: the
// linker is the one to reject it.
@(test)
damaged_coff_inputs_ask_for_no_crt :: proc(t: ^testing.T) {
	object := coff_object("/DEFAULTLIB:MSVCRT")
	testing.expect_value(t, coff_requested_crts(object[:30]), Crt_Kinds{})
	testing.expect_value(t, coff_requested_crts(object[:10]), Crt_Kinds{})
	testing.expect_value(t, coff_requested_crts(nil), Crt_Kinds{})

	// A section whose data would run past the end.
	pointer := make([]u8, len(object), context.temp_allocator)
	copy(pointer, object)
	pointer[20 + 20] = 0xFF
	testing.expect_value(t, coff_requested_crts(pointer), Crt_Kinds{})

	// A member whose size runs past the end of the archive.
	archive := coff_archive({{"a.obj/", string(object)}})
	testing.expect_value(t, coff_requested_crts(archive[:len(archive) - 4]), Crt_Kinds{})
	testing.expect_value(t, coff_requested_crts(transmute([]u8)string("!<arch>\n")), Crt_Kinds{})
}
