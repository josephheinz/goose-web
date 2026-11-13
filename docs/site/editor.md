# Editor support

`gweb lsp` is a language server for gweb projects. It reports diagnostics
only: no hover, completion or go to definition.

It needs `node` on `PATH`, and `goose` v2026.4 or later (or `$GOOSE`).

## What it reports

- gweb errors and warnings, on the whole line.
- Goose errors, at the line and column of your source. gweb generates Goose
  from your files, and the server maps each error back.

Files it checks: `components/*.gshtml`, `app/**/*.html`, `app/**/*.goose`.
Files in `lib/` and in packages are not checked; use your usual Goose setup
for them. Components map to the right line, not the exact column.

Start the editor at the project root (the folder with `app/`). The server
writes `.gweb.lsp/` there. Keep it out of git.

## How it works

It generates the project into `.gweb.lsp/`, starts `goose lsp` with
`.gweb.lsp/main.goose` as its entry file, sends it the generated files
(unsaved text included), and maps the diagnostics back. Only diagnostics for
your files are shown. It reruns 250 ms after you stop
typing.

If `goose lsp` is missing, exits, or does not answer within 10 s, the server
runs `gweb lsp-gen --check` instead, on open and save. You see the same
errors, only later. It says so once in the editor log.

## Setup

The command is `gweb lsp`. The `.gshtml` and template files need a filetype
first; `.gshtml` and `.html` are not Goose.

### Neovim

```lua
vim.filetype.add({ extension = { gshtml = 'gshtml' } })

vim.lsp.config('gweb', {
  cmd = { 'gweb', 'lsp' },
  filetypes = { 'gshtml', 'html', 'goose' },
  root_markers = { 'gweb.packages', 'app' },
})
vim.lsp.enable('gweb')
```

With `nvim-lspconfig` on an older Neovim:

```lua
local configs = require('lspconfig.configs')
configs.gweb = {
  default_config = {
    cmd = { 'gweb', 'lsp' },
    filetypes = { 'gshtml', 'html', 'goose' },
    root_dir = require('lspconfig.util').root_pattern('app'),
  },
}
require('lspconfig').gweb.setup({})
```

### Helix

`~/.config/helix/languages.toml`:

```toml
[language-server.gweb]
command = "gweb"
args = ["lsp"]

[[language]]
name = "gshtml"
scope = "source.gshtml"
file-types = ["gshtml"]
roots = ["app"]
language-servers = ["gweb"]

[[language]]
name = "html"
language-servers = ["vscode-html-language-server", "gweb"]
```

`html` gets the server in every project; it ignores files outside `app/`.

### Zed

Zed starts servers from extensions, so a custom command needs a small
extension that launches `gweb lsp` for HTML files.

### VS Code

There is no gweb extension. Install a generic LSP client extension, and
configure it to run `gweb lsp` for HTML and Goose files. To open `.gshtml` as
HTML, add to `settings.json`:

```json
{ "files.associations": { "*.gshtml": "html" } }
```

These snippets are not tested. Check the names against your editor's docs.
