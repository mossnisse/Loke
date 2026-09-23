package lokec

// Every phase walks the tree recursively and the evaluator recurses on the host
// stack, so this reservation bounds how deeply a program may nest (`MAX_NEST`)
// and how deeply compile-time evaluation may recurse (`eval_step`). Reserved,
// not committed: pages nobody touches cost nothing. Threads created without a
// size, the test runner's included, get the same.
COMPILER_STACK :: 64 * 1024 * 1024

when ODIN_OS == .Windows {
	// The flag rides on this import, which is linked only because
	// `stack_remaining` calls into it; its value must equal `COMPILER_STACK`.
	@(extra_linker_flags = "/STACK:67108864")
	foreign import kernel32 "system:Kernel32.lib"
	@(default_calling_convention = "system")
	foreign kernel32 {
		GetCurrentThreadStackLimits :: proc(low, high: ^uintptr) ---
	}
}

// Bytes of stack left below the caller's frame on this thread.
stack_remaining :: proc() -> uintptr {
	probe: u8
	when ODIN_OS == .Windows {
		low, high: uintptr
		GetCurrentThreadStackLimits(&low, &high)
		return uintptr(&probe) - low
	} else {
		// ponytail: lokec runs on Windows; another host needs its own query.
		return max(uintptr)
	}
}
