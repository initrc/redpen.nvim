local M = {}
local comments = {}

local function format_comment_count(count)
  return ('%d %s'):format(count, count == 1 and 'comment' or 'comments')
end

local function is_visual_mode()
  local mode = vim.api.nvim_get_mode().mode
  return mode == 'v' or mode == 'V' or mode == vim.keycode '<C-v>'
end

-- Add a comment about the current line or active visual line range.
function M.add()
  -- Neovim reports characterwise, linewise, and blockwise Visual mode as
  -- "v", "V", and CTRL-V respectively.
  local visual = is_visual_mode()

  -- "%" is the current buffer's file name; ":." makes it relative to the cwd.
  local path = vim.fn.expand '%:.'
  local comment = path

  if visual then
    -- Read the live visual selection because '< and '> are only updated after
    -- leaving Visual mode.
    local start_line = vim.fn.line 'v'
    local end_line = vim.fn.line '.'

    if start_line > end_line then
      start_line, end_line = end_line, start_line
    end

    if start_line == end_line then
      comment = ('%s:%d'):format(path, start_line)
    else
      comment = ('%s:%d-%d'):format(path, start_line, end_line)
    end
  else
    comment = ('%s:%d'):format(path, vim.fn.line '.')
  end

  -- Prefill the complete value so it can be checked or edited before adding.
  comment = vim.fn.input('Comment: ', comment .. ' '):gsub('%s+$', '')
  table.insert(comments, comment)

  if visual then
    vim.cmd.normal { vim.keycode '<Esc>', bang = true }
  end

  -- Wait until input() has released the command area before displaying the
  -- confirmation there. With cmdheight=0, it temporarily covers the last line.
  local comment_count = #comments
  vim.schedule(function() vim.notify(('Review updated (%s)'):format(format_comment_count(comment_count))) end)
  return comment
end

-- Copy all collected comments and start a new review.
function M.finish()
  local comment_count = #comments
  if comment_count == 0 then
    vim.notify('No review comments to copy', vim.log.levels.INFO)
    return
  end

  local review = table.concat(comments, '\n')
  vim.fn.setreg('+', review)
  comments = {}
  vim.notify(('Review copied to clipboard (%s)'):format(format_comment_count(comment_count)))
  return review
end

return M
