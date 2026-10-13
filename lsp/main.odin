// loke-lsp: the Loke language server, over stdin and stdout. Checking uses the
// compiler's sessions (compiler-architecture.md "Reusable batch sessions"), so
// diagnostics are the ones `lokec` reports for the same inputs.
//
// A reader thread frames incoming messages into an inbox. The main thread, the
// one with the compiler's stack reservation, applies them and checks between
// batches.
package lsp

import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

import lokec "../src"

USAGE :: `loke-lsp - the Loke language server

Speaks the Language Server Protocol on stdin and stdout; an editor starts it.
Keep it beside lokec.exe, base/, and core/, which it finds the same way.

usage:
    loke-lsp [options]

options:
    -h, --help    print this message and stop
    -version      print the server version and stop
`

// Edits closer together than this are checked once.
DEBOUNCE :: 150 * time.Millisecond

Inbox :: struct {
	mutex:  sync.Mutex,
	cond:   sync.Cond,
	bodies: [dynamic]string,
	closed: bool, // the input ended
}

main :: proc() {
	for arg in os.args[1:] {
		switch arg {
		case "-h", "-help", "--help":
			fmt.print(USAGE)
			os.exit(0)
		case "-version", "--version":
			fmt.printfln("%s %s", SERVER_NAME, lokec.LOKE_VERSION_STRING)
			os.exit(0)
		case:
			fmt.eprintfln("error: unknown option `%s`", arg)
			fmt.eprint(USAGE)
			os.exit(2)
		}
	}

	inbox: Inbox
	// Not joined: at exit it is blocked reading, and the process ends anyway.
	thread.create_and_start_with_data(&inbox, read_input, context)

	s: Server
	init_server(&s, write_output, nil)
	for {
		timeout := time.Duration(-1)
		if has_pending_work(&s) { timeout = max(DEBOUNCE - time.tick_since(s.last_edit), 0) }
		bodies, closed := take(&inbox, timeout)
		handle_messages(&s, bodies[:])
		for body in bodies { delete(body) }
		delete(bodies)
		if s.exited { break }
		// The client went away without `exit`.
		if closed {
			s.exit_code = s.phase == .Shutdown ? 0 : 1
			break
		}
		if has_pending_work(&s) && time.tick_since(s.last_edit) >= DEBOUNCE {
			run_pending_work(&s)
		}
		free_all(context.temp_allocator)
	}
	os.exit(s.exit_code)
}

// Waits for messages up to `timeout`, forever when it is negative, and takes
// every message that has arrived.
@(private = "file")
take :: proc(inbox: ^Inbox, timeout: time.Duration) -> (bodies: [dynamic]string, closed: bool) {
	sync.mutex_lock(&inbox.mutex)
	defer sync.mutex_unlock(&inbox.mutex)
	for len(inbox.bodies) == 0 && !inbox.closed && timeout != 0 {
		if timeout < 0 {
			sync.cond_wait(&inbox.cond, &inbox.mutex)
		} else if !sync.cond_wait_with_timeout(&inbox.cond, &inbox.mutex, timeout) {
			break
		}
	}
	bodies, inbox.bodies = inbox.bodies, {}
	return bodies, inbox.closed
}

@(private = "file")
read_input :: proc(data: rawptr) {
	inbox := (^Inbox)(data)
	reader := Message_Reader{read = proc(_: rawptr, buffer: []byte) -> int {
		n, err := os.read(os.stdin, buffer)
		return err == nil ? n : 0
	}}
	defer destroy_reader(&reader)
	for {
		body, ok := read_message(&reader)
		sync.mutex_lock(&inbox.mutex)
		if ok { append(&inbox.bodies, body) } else { inbox.closed = true }
		sync.cond_signal(&inbox.cond)
		sync.mutex_unlock(&inbox.mutex)
		if !ok { return }
	}
}

@(private = "file")
write_output :: proc(_: rawptr, message: string) {
	data := transmute([]byte)message
	for len(data) > 0 {
		n, err := os.write(os.stdout, data)
		if err != nil || n <= 0 { return }
		data = data[n:]
	}
}
