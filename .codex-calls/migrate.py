from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
files = {p.name: p.read_text(encoding='utf-8') for p in (root / 'src').glob('*.odin')}
for name, text in files.items():
    (root / '.codex-calls' / (name + '.txt')).write_text(text, encoding='utf-8')

def replace(name, old, new):
    assert old in files[name], (name, old)
    files[name] = files[name].replace(old, new)

ast = files['ast.odin']
a = ast.index('// The compiler-defined operation available on every union value.')
b = ast.index('// design.md "string type conversions": named UTF-8', a)
ast = ast[:a] + ast[b:]
a = ast.index('// A call, a conversion, or a generic application')
types = '''// The checker selects one operation. Nil is the explicit unchecked state;
// syntax clones retain no operation. Symbol identity stays in base.resolution,
// and argument binding/evaluation order are shared by every operation.
Call_Operation :: union {
	Call_Procedure,
	Call_Compile_Time,
	Call_Builtin,
	Call_Conversion,
	Call_Reflect,
	Call_Text,
	Call_Enum_From_Int,
	Call_Union_Construct,
	Call_Extract,
	Call_Text_Conversion,
	Call_Atomic,
	Call_Sort_By,
	Call_Simd_Reduce,
	Call_Dyn_Conversion,
	Call_Dyn_Slot,
	Call_Allocation,
}

Call_Procedure :: struct {}
Call_Compile_Time :: struct {} // type/interface applications, never runtime calls
Call_Builtin :: struct {} // intrinsic without additional checked metadata
Call_Conversion :: struct {} // representation/numeric conversion, no user hook
Call_Reflect :: struct { op: Reflect_Op, field: Symbol_Id }
Call_Text :: struct { op: Text_Op }
Call_Enum_From_Int :: struct { type: Type_Id }
Call_Union_Construct :: struct { index: int, clone: bool }
// The same checked extraction node used by the postfix spelling.
Call_Extract :: struct { node: ^Expr_Checked_Extract }
Call_Text_Conversion :: struct { op: Text_Conversion }
// Orderings and the element type are settled during checking, not runtime args.
Call_Atomic :: struct { type: Type_Id, order: int, failure_order: int }
Call_Sort_By :: struct { comparator: Symbol_Id }
Call_Simd_Reduce :: struct { fold: Simd_Fold }
// A nil witness represents conversion of a nil pointer to a nil dyn view.
Call_Dyn_Conversion :: struct { witness: ^Witness }
Call_Dyn_Slot :: struct { index: int }
// The element of new/new_clone, or the container type of make.
Call_Allocation :: struct { type: Type_Id }

'''
ast = ast[:a] + types + ast[a:]
a = ast.index('\t// `field.get(value)`', ast.index('Expr_Call :: struct'))
b = ast.index('\t// design.md "Variadic parameters"', a)
ast = ast[:a] + '\toperation: Call_Operation,\n' + ast[b:]
a = ast.index('\t// The witness a `(dyn I)', ast.index('Expr_Call :: struct'))
b = ast.index('\n}', a)
ast = ast[:a] + ast[b:]
files['ast.odin'] = ast
replace('semantic.odin', '\n\tConversion,', '')

# Checker producers: build one payload instead of independently setting flags.
for name in ('check_calls.odin', 'check_builtin.odin', 'hooks.odin', 'emit_llvm_test.odin'):
    text = files[name]
    text = re.sub(r'(\t(v|call)\.resolution = Resolution\{kind = \.Call[^\n]*\}\n)',
                  lambda m: m[1] + '\t' + m[2] + '.operation = ' + ('Call_Builtin{}' if name in ('check_builtin.odin', 'hooks.odin') else 'Call_Procedure{}') + '\n', text)
    files[name] = text
replace('check_calls.odin', '\tv.resolution = Resolution{kind = .Conversion}', '\tv.operation = Call_Conversion{}\n\tv.resolution = {}')
replace('check_calls.odin', '\t\tcheck_interface_application(k, v, info)', '\t\tv.operation = Call_Compile_Time{}\n\t\tcheck_interface_application(k, v, info)')
replace('check_calls.odin', '\t\tv.type = TYPE_TYPE', '\t\tv.operation = Call_Compile_Time{}\n\t\tv.type = TYPE_TYPE')
replace('reflect.odin', '\tv.reflect = op\n\tv.reflect_field = field', '\tv.operation = Call_Reflect{op = op, field = field}')
replace('text.odin', '\tv.text = op', '\tv.operation = Call_Text{op = op}')
replace('text.odin', '\tv.text = .From_Runes', '\tv.operation = Call_Text{op = .From_Runes}')
replace('text.odin', '\tv.text_conversion = op', '\tv.operation = Call_Text_Conversion{op = op}')
replace('enums.odin', '\tv.enum_from_int = subject', '\tv.operation = Call_Enum_From_Int{type = subject}')
replace('union.odin', '\tv.union_op = .Construct\n\tv.variant_index = index', '\tv.operation = Call_Union_Construct{index = index}')
replace('union.odin', '\tv.variant_clone = classify_copy(k, v.args[0].value, payload, "variant construction")', '\tv.operation = Call_Union_Construct{\n\t\tindex = index,\n\t\tclone = classify_copy(k, v.args[0].value, payload, "variant construction"),\n\t}')
replace('erased.odin', '\tv.resolution = Resolution{kind = .Conversion}', '\tv.operation = Call_Dyn_Conversion{}\n\tv.resolution = {}')
replace('erased.odin', '\tv.dyn_witness = witness', '\tv.operation = Call_Dyn_Conversion{witness = witness}')
replace('erased.odin', '\tv.union_op = .Extract\n', '')
replace('erased.odin', '\tv.extract = extract', '\tv.operation = Call_Extract{node = extract}')
replace('erased.odin', '\tv.is_dyn_call = true\n\tv.dyn_slot = index', '\tv.operation = Call_Dyn_Slot{index = index}')
replace('check_builtin.odin', '\tv.sort_comparator = match', '\tv.operation = Call_Sort_By{comparator = match}')
for value in ('element', 'value', 'container'):
    replace('check_builtin.odin', 'v.alloc_type = ' + value, 'v.operation = Call_Allocation{type = ' + value + '}')
replace('simd.odin', '\tv.simd_fold = fold', '\tv.operation = Call_Simd_Reduce{fold = fold}')
replace('atomics.odin', '\t\tv.atomic_order = int(order)', '\t\tv.operation = Call_Atomic{order = int(order)}')
replace('atomics.odin', '\tv.atomic_order = int(order)', '\toperation := Call_Atomic{type = element, order = int(order)}')
replace('atomics.odin', '\t\tv.atomic_failure_order = int(failure)', '\t\toperation.failure_order = int(failure)')
replace('atomics.odin', '\tv.atomic_type = element', '\tv.operation = operation')

# Payload access within operation-specific consumers. Dispatch guards are
# rewritten separately below; no compatibility getters or duplicate flags.
access = {'reflect_field': ('Call_Reflect', 'field'), 'reflect': ('Call_Reflect', 'op'),
          'enum_from_int': ('Call_Enum_From_Int', 'type'), 'variant_index': ('Call_Union_Construct', 'index'),
          'variant_clone': ('Call_Union_Construct', 'clone'), 'extract': ('Call_Extract', 'node'),
          'text_conversion': ('Call_Text_Conversion', 'op'),
          'atomic_type': ('Call_Atomic', 'type'), 'atomic_order': ('Call_Atomic', 'order'),
          'atomic_failure_order': ('Call_Atomic', 'failure_order'), 'sort_comparator': ('Call_Sort_By', 'comparator'),
          'simd_fold': ('Call_Simd_Reduce', 'fold'), 'dyn_witness': ('Call_Dyn_Conversion', 'witness'),
          'dyn_slot': ('Call_Dyn_Slot', 'index'), 'alloc_type': ('Call_Allocation', 'type')}
consumers = ['emit_llvm_calls.odin','emit_llvm_expr.odin','emit_llvm_runtime.odin','emit_llvm_atomics.odin',
             'emit_llvm_simd.odin','emit_llvm_containers.odin','eval.odin','cfg.odin','cfg_provenance.odin','emit_llvm_test.odin']
for name in consumers:
    text = files[name]
    # Form guards before replacing payload reads, so unrelated variants are
    # never asserted merely to inspect their old default-valued fields.
    guards = {'v.enum_from_int != INVALID_TYPE': 'v.operation != nil && (v.operation in Call_Enum_From_Int)',
              'v.union_op == .Extract && v.extract != nil': 'v.operation in Call_Extract',
              'v.union_op == .Extract': 'v.operation in Call_Extract',
              'v.union_op == .Construct': 'v.operation in Call_Union_Construct',
              'v.union_op != .Construct': '!(v.operation in Call_Union_Construct)',
              'v.union_op != .None': 'v.operation in Call_Union_Construct',
              'v.is_dyn_call': 'v.operation in Call_Dyn_Slot',
              'v.resolution.kind == .Conversion && type_is_dyn(e.c, as_type)': 'v.operation in Call_Dyn_Conversion',
              'v.resolution.kind == .Conversion': 'v.operation in Call_Conversion',
              'v.text_conversion != .None': 'v.operation in Call_Text_Conversion',
              'v.reflect != .None': 'v.operation in Call_Reflect',
              'v.text != .None': 'v.operation in Call_Text'}
    for old, new in guards.items(): text = text.replace(old, new)
    for field, (variant, member) in access.items():
        text = re.sub(r'\bv\.' + field + r'\b', f'v.operation.({variant}).{member}', text)
    # v.text also occurs on evaluator values; only these call-specific sites.
    text = text.replace('switch v.text {', 'switch v.operation.(Call_Text).op {')
    files[name] = text
replace('emit_llvm_test.odin', 'extraction := call.extract', 'extraction := call.operation.(Call_Extract).node')

for name, text in files.items():
    path = root / 'src' / name
    if text != path.read_text(encoding='utf-8'):
        path.write_text(text, encoding='utf-8', newline='\n')
