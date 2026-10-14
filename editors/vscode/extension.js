// Starts loke-lsp for `.loke` documents, and shows the page its
// `loke.documentation` command returns. Everything else comes from the server
// (compiler-guide.md "Language server").
const vscode = require('vscode');
const { LanguageClient } = require('vscode-languageclient/node');

let client;

async function activate(context) {
  const config = vscode.workspace.getConfiguration('loke');
  client = new LanguageClient('loke', 'Loke',
    { command: config.get('serverPath') },
    {
      documentSelector: [{ scheme: 'file', language: 'loke' }],
      initializationOptions: { collections: config.get('collections'), defines: config.get('defines') },
    });

  // The client registers the server's `loke.documentation` itself and drops its
  // result, so the command that shows the page has a name of its own.
  context.subscriptions.push(vscode.commands.registerCommand('loke.showDocumentation', async () => {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== 'loke') return;
    try {
      const page = await client.sendRequest('workspace/executeCommand', {
        command: 'loke.documentation',
        arguments: [editor.document.uri.toString()],
      });
      if (page == null) {
        vscode.window.showInformationMessage('No documentation for this file.');
        return;
      }
      const doc = await vscode.workspace.openTextDocument({ language: 'markdown', content: page });
      await vscode.window.showTextDocument(doc, vscode.ViewColumn.Beside);
      await vscode.commands.executeCommand('markdown.showPreview');
    } catch (error) {
      vscode.window.showErrorMessage(error.message);
    }
  }));

  await client.start();
}

function deactivate() {
  return client?.stop();
}

module.exports = { activate, deactivate };
