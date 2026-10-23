# Loke for VS Code and VSCodium

Syntax highlighting for `.loke` files, and the `loke-lsp` language server:
diagnostics as you type, hover, go to definition, document symbols,
completion, signature help, find references, rename, formatting, and the
interface file of the current package. What each operation does is described in
[Language server](../../compiler-guide.md#language-server).

## Install

Build `loke-lsp.exe` first, as [readme.md](../../readme.md) describes, and
keep it beside `base/` and `core/`. Then, with Node.js installed, run these
in this directory:

```powershell
npm install
npx @vscode/vsce package --skip-license
codium --install-extension loke-0.1.0.vsix --force
```

Use `code` instead of `codium` for VS Code. Reload the window afterwards.
Repeat all three after the extension changes: the version stays `0.1.0`, so
`--force` is what replaces the installed copy.

## Settings

| Setting | Meaning |
| --- | --- |
| `loke.serverPath` | The `loke-lsp` executable: an absolute path, or a name found on `PATH`. The default is `loke-lsp`. |
| `loke.collections` | Collections, each as `lokec -collection` takes it, such as `"shapes=../shapes"`. |
| `loke.defines` | Defines, each as `lokec -define` takes it, such as `"VERBOSE=true"`. |

The server reads its settings when it starts, so reload the window after
changing them. To format on save:

```json
"[loke]": { "editor.formatOnSave": true }
```

## Commands

**Loke: Show Interface** opens, beside the current file, the interface file
`lokec -api` writes for its package: every public declaration and its doc
comment, without bodies, from the unsaved text. A checked-in `api.loki` opens
as Loke too, and the server leaves it unchecked.

The server's messages appear in the **Output** panel under **Loke**.

A fenced code block in a Markdown file whose info string starts with `loke`,
as ` ```loke ` and the repository's ` ```loke file=hello.loke `, is highlighted
as Loke in the file's source. The rendered preview does not highlight it.

Highlighting comes from the text alone, so it goes by the shape of a name:
`Type_Name` is shown as a type and `ALL_CAPS` as a constant. The contextual
keywords `parallel` and `spawn` are shown as keywords only at the start of a
statement, and the start of a line counts as one: a type named `parallel`
whose literal begins a continued line, as in `value :=` followed by
`parallel{1};`, is shown as a keyword. The grammar's
keyword and predeclared-name lists are checked against the specification by
`tests/editor_test.odin`.
