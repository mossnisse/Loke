from pathlib import Path
import subprocess
root = Path(__file__).resolve().parent.parent
cases = sorted((root / 'tests' / 'll').glob('*.loke'))
for path in cases:
    output = root / '.codex-calls' / path.with_suffix('.exe').name
    args = [str(path.relative_to(root)), '-emit-ll', '-o', str(output)]
    results = []
    for version in ('before', 'after'):
        result = subprocess.run([str(root / f'.codex-calls-{version}.exe'), *args], cwd=root, capture_output=True)
        assert result.returncode == 0, (path.name, version, result.stderr.decode(errors='replace'))
        results.append((output.with_suffix('.ll').read_bytes(), result.stdout, result.stderr))
    assert results[0] == results[1], path.name
print(f'All {len(cases)} LLVM corpus modules and diagnostics are byte-identical.', flush=True)
