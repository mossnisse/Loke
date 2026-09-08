# The GNU-syntax companion to helper.asm. An `obj` build never assembles it
# either; an `exe` build passes it to clang, which knows this syntax.
	.text
	.globl helper_value
helper_value:
	movl $11, %eax
	ret
