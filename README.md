# redpen.nvim

`redpen.nvim` is built to make reviewing AI-generated code less painful. After
trying IDEs, terminal applications, and shell-based workflows, I kept running
into the same problems:

- Line-based diff algorithms make structural changes harder to understand.
- Moving between a diff and the source files is slow and disruptive.
- Adding filenames and line ranges to review comments takes manual effort.

Redpen addresses each of these problems inside Neovim:

- It uses [Difftastic](https://difftastic.wilfred.me.uk/) for syntax-aware diffs.
- It applies your NeoVim colorscheme to the diff for a consistent interface.
- It makes navigating between diff rows and source files fast.
- It creates comments for a line or line range, then copies the complete,
  formatted review to the clipboard when you finish.

## Screenshots

Diff against HEAD
![Diff against HEAD](https://github.com/initrc/redpen.nvim/blob/main/assets/redpen-diff.png)

HEAD commit
![HEAD commit](https://github.com/initrc/redpen.nvim/blob/main/assets/redpen-head-commit.png)

## Requirements

- Neovim 0.10 or newer.
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
vim.keymap.set('n', '<leader>rD', redpen.open_diff_head, { desc = '[R]edpen HEAD [D]iff' })
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

Keyboard shortcuts mentioned in this section are from the configuration above. If
you chose different mappings, use those instead.

### Read the diff

Press `<leader>rd` to compare `HEAD` to the working tree, or `<leader>rD` to see
the changes introduced by `HEAD`. Both find the Git repository containing the
current buffer and replace the current window with a scratch diff buffer. They
display a summary with per-file change counts followed by a colorized,
side-by-side Difftastic comparison. The HEAD summary also includes the commit's
abbreviated hash and subject. The working-tree summary also lists untracked
files.

Move to a summary file, file header, or diff row and press `<CR>` to open the
file. To return to the diff, press `<leader>rd`/`<leader>rD` again or use
Neovim's normal jump history (for example, `<C-o>`). Press `q` to delete the
diff buffer and restore the buffer that was visible before it opened.

Pressing `<leader>rd` or `<leader>rD` while a diff already exists focuses or
redisplays that diff instead of starting a second one.

### Add a comment

Press `<leader>ra` from either a source file or a Redpen diff buffer. It works on
the current line or an active visual line selection. Redpen opens an editable
prompt containing the generated source location:

```text
lua/redpen/diff.lua:581
lua/redpen/diff.lua:581-617
```

Add your comment after the location and submit the prompt. Redpen stores the
comment in the current review so you can continue reading the diff and adding
more.

Visual mode is inferred automatically from Neovim's current mode; no option is
required. In a Redpen diff buffer, the location comes from the same source-row
mapping used by `<CR>`.

### Finish the review

Press `<leader>rf` after adding all your comments. Redpen joins the comments with
line breaks, copies the completed review to the `+` register, and clears the
collected comments. You can then paste or send the entire review in one step.

If no comments have been added, Redpen leaves the clipboard unchanged and
displays a notification.

## API

| Function | Description |
| --- | --- |
| `require('redpen').add_comment()` | Prompt for and collect a comment about the current line or active visual line range. |
| `require('redpen').finish_review()` | Copy all collected comments to the clipboard and clear the review. |
| `require('redpen').open_diff()` | Open or focus the repository diff. |
| `require('redpen').open_diff_head()` | Open or focus the HEAD commit diff. |
| `require('redpen').jump_to_source()` | Open the source location represented by the current diff row. |
| `require('redpen').close_diff()` | Close the active diff and restore its previous buffer. |

## License

[Apache License 2.0](LICENSE)

