from pathlib import Path
import re
root = Path(__file__).resolve().parent.parent
for path in (root / 'src').glob('emit_llvm*.odin'):
    if path.name.endswith('_test.odin'): continue
    text = path.read_text(encoding='utf-8')
    def localize(match):
        body = match[0]
        accesses = re.findall(r'v\.operation\.\((Call_\w+)\)\.', body)
        variants = set(accesses)
        if len(variants) != 1 or len(accesses) < 2: return body
        assert not re.search(r'\bchecked\b', body), match[1]
        variant = variants.pop()
        body = body.replace(f'v.operation.({variant}).', 'checked.')
        at = body.index('{\n') + 2
        print(path.name, match[1], variant)
        return body[:at] + f'\tchecked := v.operation.({variant})\n' + body[at:]
    new = re.sub(r'^(\w+) :: proc\b.*?^}', localize, text, flags=re.M | re.S)
    if text != new: path.write_text(new, encoding='utf-8', newline='\n')
