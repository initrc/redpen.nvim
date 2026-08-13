# redpen.nvim

`redpen.nvim` supports the two sides of code review:

- Write comments about specific lines, then copy the completed review.
- Read the current Git working-tree diff with Difftastic and jump from the
  rendered diff to the corresponding source line.

The plugin defines no keymaps. Every action is public, so your Neovim config
decides which keys to use.

## Requirements

- Neovim 0.10 or newer. The diff module depends on `vim.system()` and
  `vim.fs.root()`, which are available in Neovim 0.10.
- [Git](https://git-scm.com/)
- [Difftastic](https://difftastic.wilfred.me.uk/), with the `difft` executable
  available on `$PATH`
- A working Neovim clipboard provider for the `+` register

## Installation

### vim.pack

```lua
vim.pack.add { 'https://github.com/initrc/redpen.nvim' }

local redpen = require 'redpen'

-- `x` maps Visual mode only; unlike `v`, it does not include Select mode.
vim.keymap.set({ 'n', 'x' }, '<leader>ra', redpen.add_comment, { desc = '[R]edpen [A]dd comment' })
vim.keymap.set('n', '<leader>rd', redpen.open_diff, { desc = '[R]edpen [D]iff' })
vim.keymap.set('n', '<leader>rf', redpen.finish_review, { desc = '[R]edpen [F]inish review' })

-- These mappings exist only in a Redpen diff buffer.
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'redpen-diff',
  callback = function(event)
    vim.keymap.set('n', '<CR>', redpen.jump_to_source, {
      buffer = event.buf,
      desc = 'Open source file from Redpen diff',
    })
    vim.keymap.set('n', 'q', redpen.close_diff, {
      buffer = event.buf,
      desc = 'Close Redpen diff',
    })
  end,
})
```

### lazy.nvim

```lua
{
  'initrc/redpen.nvim',
  config = function()
    local redpen = require 'redpen'
    -- Same as the vim.pack example after `local redpen = require 'redpen'`.
  end,
}
```

No `setup()` call is required. The mappings in the `vim.pack` example work with
either installation method.

## Usage

### Add a comment

Call `add_comment()` on a line or visual line selection. Redpen opens an
editable prompt containing the generated location:

```text
lua/redpen/diff.lua:581
lua/redpen/diff.lua:581-617
```

Add your comment after the location and press Enter. Redpen stores the comment
in the current review so you can continue reading the diff and adding more.

Visual mode is inferred automatically from Neovim's current mode; no option is
required.

### Finish the review

Call `finish_review()` after adding all your comments. Redpen joins the comments
with line breaks, copies the completed review to the `+` register, and clears
the collected comments. You can then paste or send the entire review in one
step.

If no comments have been added, Redpen leaves the clipboard unchanged and
displays a notification.

### Read the diff

`open_diff()` finds the Git repository containing the current buffer and
replaces the current window with a scratch diff buffer. It displays:

1. Git porcelain status, including untracked files.
2. A colorized, side-by-side Difftastic comparison from `HEAD` to the working
   tree, including staged and unstaged tracked changes.

Move to a file header or diff row and call `jump_to_source()` to open the file
at the nearest corresponding new-file line. Use Neovim's normal jump history
(for example, `<C-o>`) to return to the diff. Call `close_diff()` to delete the
diff buffer and restore the buffer that was visible before it opened.

Calling `open_diff()` while a diff already exists focuses or redisplays that
diff instead of starting a second one.

## API

| Function | Description |
| --- | --- |
| `require('redpen').add_comment()` | Prompt for and collect a comment about the current line or active visual line range. |
| `require('redpen').finish_review()` | Copy all collected comments to the clipboard and clear the review. |
| `require('redpen').open_diff()` | Open or focus the repository diff. |
| `require('redpen').jump_to_source()` | Open the source location represented by the current diff row. |
| `require('redpen').close_diff()` | Close the active diff and restore its previous buffer. |

## License

[Apache License 2.0](LICENSE)
