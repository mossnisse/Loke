; A placeholder assembly input. An `obj` build never assembles it: one
; relocatable object cannot carry a second, so the compiler diagnoses the import
; and tells the final consumer to assemble and link it separately (L0603).
section .text
global helper_value
helper_value:
	mov eax, 11
	ret
