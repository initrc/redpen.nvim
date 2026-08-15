local M = {}
local comments = {}

local function format_comment_count(count)
  return ('%d %s'):format(count, count == 1 and 'comment' or 'comments')
end

local function is_visual_mode()
  local mode = vim.api.nvim_get_mode().mode
  return mode == 'v' or mode == 'V' or mode == vim.keycode '<C-v>'
end

local function comment_location(visual)
  local start_line
  local end_line

  if visual then
    -- Read the live visual selection because '< and '> are only updated after
    -- leaving Visual mode.
    start_line = vim.fn.line 'v'
    end_line = vim.fn.line '.'

    if start_line > end_line then
      start_line, end_line = end_line, start_line
    end
  else
    start_line = vim.fn.line '.'
    end_line = start_line
  end

  local path
  if vim.bo.filetype == 'redpen-diff' then
    local source_range, error_message = require('redpen.diff').source_range(start_line, end_line)
    if not source_range then return nil, error_message end
    path = source_range.path
    start_line = source_range.start_line
    end_line = source_range.end_line
  else
    -- "%" is the current buffer's file name; ":." makes it relative to the cwd.
    path = vim.fn.expand '%:.'
  end

  if start_line == end_line then return ('%s:%d'):format(path, start_line) end
  return ('%s:%d-%d'):format(path, start_line, end_line)
end

-- Add a comment about the current line or active visual line range.
function M.add()
  -- Neovim reports characterwise, linewise, and blockwise Visual mode as
  -- "v", "V", and CTRL-V respectively.
  local visual = is_visual_mode()
  local comment, error_message = comment_location(visual)
  if not comment then
    vim.notify(error_message, vim.log.levels.INFO)
    return
  end

  -- Prefill the complete value so it can be checked or edited before adding.
  comment = vim.fn.input('Comment: ', comment .. ' '):gsub('%s+$', '')
  if visual then vim.cmd.normal { vim.keycode '<Esc>', bang = true } end
  if comment == '' then return end

  table.insert(comments, comment)

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
