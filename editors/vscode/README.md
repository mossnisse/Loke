# Loke for VS Code and VSCodium

Syntax highlighting for `.loke` files, and the `loke-lsp` language server:
diagnostics as you type, hover, go to definition, document symbols,
completion, signature help, find references, rename, formatting, and the
`-doc` page of the current program. What each operation does is described in
[Language server](../../compiler-guide.md#language-server).

## Install

Build `loke-lsp.exe` first, as [readme.md](../../readme.md) describes, and
keep it beside `base/` and `core/`. Then, with Node.js installed, run these
in this directory:

```powershell
npm install
npx @vscode/vsce package --skip-license
codium --install-extension loke-0.1.0.vsix
```

Use `code` instead of `codium` for VS Code. Reload the window afterwards.

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

**Loke: Show Documentation** opens the Markdown page `lokec -doc` prints for
the current file's program in a preview beside it.

The server's messages appear in the **Output** panel under **Loke**.

A fenced code block in a Markdown file whose info string starts with `loke`,
as ` ```loke ` and the repository's ` ```loke file=hello.loke `, is highlighted
as Loke in the file's source. The rendered preview does not highlight it.

Highlighting comes from the text alone, so it goes by the shape of a name:
`Type_Name` is shown as a type and `ALL_CAPS` as a constant. The grammar's
keyword and predeclared-name lists are checked against the specification by
`tests/editor_test.odin`.
