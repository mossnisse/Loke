/* Panic stack traces for `-g` executables.
 *
 * The generated `wmain` of a `-g` build enables them. DbgHelp reads names and
 * lines from the PDB the linker wrote beside the executable, and is loaded only
 * when a trace is printed, so no program gains a link dependency on it.
 *
 * Like the rest of the runtime this file includes no platform header, so the
 * few kernel32 entry points and DbgHelp records it uses are declared here, as
 * the Windows x64 ABI lays them out.
 */
#include "loke_rt.h"

#include <stdio.h>
#include <string.h>

__declspec(dllimport) void *LoadLibraryA(const char *name);
__declspec(dllimport) void *GetProcAddress(void *module, const char *name);
__declspec(dllimport) void *GetCurrentProcess(void);
__declspec(dllimport) unsigned short RtlCaptureStackBackTrace(
	unsigned long skip, unsigned long count, void **frames, unsigned long *hash);

/* dbghelp.h's SYMBOL_INFO, with room for the name after it. */
typedef struct {
	unsigned long size_of_struct;
	unsigned long type_index;
	uint64_t reserved[2];
	unsigned long index;
	unsigned long size;
	uint64_t mod_base;
	unsigned long flags;
	uint64_t value;
	uint64_t address;
	unsigned long register_;
	unsigned long scope;
	unsigned long tag;
	unsigned long name_len;
	unsigned long max_name_len;
	char name[1];
} symbol_info;

LOKE_RT_STATIC_ASSERT(sizeof(symbol_info) == 88, symbol_info_size);

/* dbghelp.h's IMAGEHLP_LINE64. */
typedef struct {
	unsigned long size_of_struct;
	void *key;
	unsigned long line_number;
	char *file_name;
	uint64_t address;
} line_info;

LOKE_RT_STATIC_ASSERT(sizeof(line_info) == 40, line_info_size);

#define SYMOPT_DEFERRED_LOADS 0x00000004
#define SYMOPT_LOAD_LINES 0x00000010

typedef int (*initialize_fn)(void *process, const char *search_path, int invade);
typedef unsigned long (*set_options_fn)(unsigned long options);
typedef int (*from_addr_fn)(void *process, uint64_t address, uint64_t *displacement, symbol_info *symbol);
typedef int (*line_fn)(void *process, uint64_t address, unsigned long *displacement, line_info *line);
/* The inline-frame queries, which DbgHelp has had since Windows 8. */
typedef unsigned long (*inline_count_fn)(void *process, uint64_t address);
typedef int (*inline_query_fn)(
	void *process, uint64_t start, unsigned long start_context, uint64_t start_return, uint64_t current,
	unsigned long *context, unsigned long *frame_index);
typedef int (*inline_symbol_fn)(
	void *process, uint64_t address, unsigned long context, uint64_t *displacement, symbol_info *symbol);
typedef int (*inline_line_fn)(
	void *process, uint64_t address, unsigned long context, uint64_t module_base, unsigned long *displacement,
	line_info *line);

typedef struct {
	void *process;
	from_addr_fn from_addr;
	line_fn line_from_addr;
	inline_count_fn inline_count;
	inline_query_fn inline_query;
	inline_symbol_fn inline_symbol;
	inline_line_fn inline_line;
	int printed;
} dbghelp_api;

static volatile int32_t enabled;
/* DbgHelp is single-threaded; the first thread to panic prints the trace. */
static volatile int32_t taken;

void loke_rt_v1_enable_panic_trace(void) {
	enabled = 1;
}

static int is_loke_source(const char *path) {
	size_t length = strlen(path);
	return length > 5 && _stricmp(path + length - 5, ".loke") == 0;
}

/* One frame, if it has a `.loke` line: an inlined one when `inlined`, looked up
 * by its inline context, and otherwise the physical frame at `address`. */
static void print_frame(dbghelp_api *api, uint64_t address, int inlined, unsigned long context) {
	line_info line;
	memset(&line, 0, sizeof line);
	line.size_of_struct = sizeof line;
	unsigned long displacement = 0;
	int found = inlined
		? api->inline_line(api->process, address, context, 0, &displacement, &line)
		: api->line_from_addr(api->process, address, &displacement, &line);
	if (!found || !is_loke_source(line.file_name)) {
		return;
	}
	uint64_t storage[(sizeof(symbol_info) + 256) / sizeof(uint64_t)];
	symbol_info *symbol = (symbol_info *)storage;
	memset(storage, 0, sizeof storage);
	symbol->size_of_struct = sizeof(symbol_info);
	symbol->max_name_len = 256;
	int named = inlined
		? api->inline_symbol(api->process, address, context, 0, symbol)
		: api->from_addr(api->process, address, 0, symbol);

	/* The file's own name keeps the report the same wherever the program was
	 * built; the procedure's package already tells two same-named files apart. */
	const char *file = line.file_name;
	for (const char *at = line.file_name; *at != 0; at++) {
		if (*at == '\\' || *at == '/') {
			file = at + 1;
		}
	}
	if (!api->printed) {
		fputs("loke: stack trace, newest call first:\n", stderr);
		api->printed = 1;
	}
	fprintf(stderr, "    %s at %s:%lu\n", named ? symbol->name : "?", file, line.line_number);
}

/* Only frames with a `.loke` line are printed, which leaves out the runtime,
 * the C library, and the startup code. A procedure LLVM inlined is printed
 * as its own frame, innermost first. */
void loke_rt_v1_panic_trace(void) {
	if (!enabled || __sync_lock_test_and_set(&taken, 1) != 0) {
		return;
	}
	void *frames[64];
	unsigned short count = RtlCaptureStackBackTrace(0, 64, frames, 0);

	void *dbghelp = LoadLibraryA("dbghelp.dll");
	if (dbghelp == 0) {
		return;
	}
	initialize_fn initialize = (initialize_fn)GetProcAddress(dbghelp, "SymInitialize");
	set_options_fn set_options = (set_options_fn)GetProcAddress(dbghelp, "SymSetOptions");
	dbghelp_api api = {
		.process = GetCurrentProcess(),
		.from_addr = (from_addr_fn)GetProcAddress(dbghelp, "SymFromAddr"),
		.line_from_addr = (line_fn)GetProcAddress(dbghelp, "SymGetLineFromAddr64"),
		.inline_count = (inline_count_fn)GetProcAddress(dbghelp, "SymAddrIncludeInlineTrace"),
		.inline_query = (inline_query_fn)GetProcAddress(dbghelp, "SymQueryInlineTrace"),
		.inline_symbol = (inline_symbol_fn)GetProcAddress(dbghelp, "SymFromInlineContext"),
		.inline_line = (inline_line_fn)GetProcAddress(dbghelp, "SymGetLineFromInlineContext"),
	};
	if (initialize == 0 || set_options == 0 || api.from_addr == 0 || api.line_from_addr == 0) {
		return;
	}
	int inlining = api.inline_count != 0 && api.inline_query != 0 && api.inline_symbol != 0 && api.inline_line != 0;
	set_options(SYMOPT_DEFERRED_LOADS | SYMOPT_LOAD_LINES);
	if (!initialize(api.process, 0, 1)) {
		return;
	}

	for (unsigned short i = 0; i < count; i++) {
		/* A return address is the instruction after the call; one byte back is
		 * the call's own line. */
		uint64_t address = (uint64_t)(uintptr_t)frames[i] - 1;
		unsigned long inlined = inlining ? api.inline_count(api.process, address) : 0;
		unsigned long context = 0, frame_index = 0;
		if (inlined > 0 && api.inline_query(api.process, address, 0, address, address, &context, &frame_index)) {
			for (unsigned long k = 0; k < inlined; k++) {
				print_frame(&api, address, 1, context + k);
			}
		}
		print_frame(&api, address, 0, 0);
	}
	fflush(stderr);
}
