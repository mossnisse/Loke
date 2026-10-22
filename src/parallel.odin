// `parallel` blocks and `spawn` statements (concurrency-proposal.md "Syntax"),
// which are not available yet: milestone 4 of the proposal's implementation
// plan checks and lowers them behind a hidden option.
package lokec

// What checking a spawn records for later phases.
Spawn_Task :: struct {}

check_parallel :: proc(k: ^Checker, s: ^Stmt_Parallel) -> Flow_Info {
	errorf(k.c, s.keyword, "L0727", "`parallel` blocks are not available yet")
	if s.executor != nil {
		check_expr(k, s.executor)
	}
	outer := k.parallel_block
	k.parallel_block = s
	defer k.parallel_block = outer
	return check_scoped_block(k, s.body)
}

check_spawn :: proc(k: ^Checker, s: ^Stmt_Spawn) -> Flow_Info {
	if k.parallel_block == nil {
		errorf(k.c, s.keyword, "L0727", "`spawn` belongs inside a `parallel` block of the same procedure")
	}
	if s.result != nil {
		check_expr(k, s.result)
	}
	check_expr(k, s.call)
	return FLOWS
}
