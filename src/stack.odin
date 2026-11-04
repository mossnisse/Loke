package lokec

// Every phase walks the tree recursively and the evaluator recurses on the host
// stack, so this reservation bounds how deeply a program may nest (`MAX_NEST`)
// and how deeply compile-time evaluation may recurse (`eval_step`). Reserved,
// not committed: pages nobody touches cost nothing. Threads created without a
// size, the test runner's included, get the same.
COMPILER_STACK :: 64 * 1024 * 1024

// The flag rides on this import, which is linked only because `stack_remaining`
// calls into it. An attribute's string cannot be computed, hence the assert.
#assert(COMPILER_STACK == 67108864)
@(extra_linker_flags = "/STACK:67108864")
foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32 {
	GetCurrentThreadStackLimits :: proc(low, high: ^uintptr) ---
}

// Bytes of stack left below the caller's frame on this thread.
stack_remaining :: proc() -> uintptr {
	probe: u8
	low, high: uintptr
	GetCurrentThreadStackLimits(&low, &high)
	return uintptr(&probe) - low
}
