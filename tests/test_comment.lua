local plugin_root = vim.fn.getcwd()
local original_input = vim.fn.input
local original_notify = vim.notify
local original_setreg = vim.fn.setreg
local test_directory
local input_calls
local input_suffixes
local notifications
local written_register
local written_review
local CANCELLED_INPUT = {}

vim.opt.runtimepath:prepend(plugin_root)

local function before()
  test_directory = vim.fn.tempname()
  vim.fn.mkdir(test_directory, 'p')
  test_directory = vim.fn.resolve(test_directory)
  vim.fn.writefile({ 'first', 'second', 'third' }, test_directory .. '/review.txt')
  vim.cmd.cd(vim.fn.fnameescape(test_directory))
  vim.cmd.edit(vim.fn.fnameescape(test_directory .. '/review.txt'))

  package.loaded.redpen = nil
  package.loaded['redpen.comment'] = nil
  input_calls = {}
  input_suffixes = {}
  notifications = {}
  written_register = nil
  written_review = nil

  rawset(vim.fn, 'input', function(prompt, default)
    table.insert(input_calls, { prompt = prompt, default = default })
    local suffix = table.remove(input_suffixes, 1)
    assert(suffix, 'Test did not provide an input response')
    if suffix == CANCELLED_INPUT then return '' end
    return default .. suffix
  end)
  rawset(vim.fn, 'setreg', function(register, value)
    written_register = register
    written_review = value
  end)
  rawset(vim, 'notify', function(message) table.insert(notifications, message) end)
end

local function after()
  if vim.api.nvim_get_mode().mode ~= 'n' then vim.cmd.normal { vim.keycode '<Esc>', bang = true } end
  rawset(vim.fn, 'input', original_input)
  rawset(vim.fn, 'setreg', original_setreg)
  rawset(vim, 'notify', original_notify)
  package.loaded.redpen = nil
  package.loaded['redpen.comment'] = nil
  vim.cmd.cd(vim.fn.fnameescape(plugin_root))

  if test_directory then
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      local buffer_path = vim.api.nvim_buf_get_name(buffer)
      if vim.startswith(buffer_path, test_directory .. '/') then
        pcall(vim.api.nvim_buf_delete, buffer, { force = true })
      end
    end
    vim.fn.delete(test_directory, 'rf')
    test_directory = nil
  end
end

local function wait_for_notifications(count)
  assert(vim.wait(1000, function() return #notifications >= count end), 'Timed out waiting for a notification')
end

local function test_add_comment_uses_current_file_and_line()
  input_suffixes = { 'Needs work' }
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  local comment = require('redpen').add_comment()

  assert(comment == 'review.txt:2 Needs work', 'Comment used the wrong source location: ' .. vim.inspect(comment))
  assert(input_calls[1].prompt == 'Comment: ', 'Comment used the wrong input prompt')
  assert(input_calls[1].default == 'review.txt:2 ', 'Comment used the wrong input default')
  wait_for_notifications(1)
  assert(notifications[1] == 'Review updated (1 comment)', 'Comment notification used the wrong count')
end

local function test_add_comment_uses_visual_line_range()
  input_suffixes = { 'Review this range' }
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd.normal { 'V2j', bang = true }
  assert(vim.api.nvim_get_mode().mode == 'V', 'Test did not enter Visual Line mode')

  local comment = require('redpen').add_comment()

  assert(comment == 'review.txt:1-3 Review this range', 'Comment used the wrong visual range')
  assert(vim.api.nvim_get_mode().mode == 'n', 'Adding a visual comment did not leave Visual mode')
  wait_for_notifications(1)
end

local function test_cancelled_comment_is_not_added()
  input_suffixes = { CANCELLED_INPUT }

  local comment = require('redpen').add_comment()
  local review = require('redpen').finish_review()

  assert(comment == nil, 'Cancelling input returned a comment')
  assert(review == nil, 'Cancelling input added a comment to the review')
  assert(#notifications == 1, 'Cancelling input reported a review update')
  assert(notifications[1] == 'No review comments to copy', 'Cancelled review used the wrong notification')
end

local function test_finish_review_copies_and_clears_comments()
  input_suffixes = { 'First comment', 'Second comment' }
  local redpen = require 'redpen'
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local first_comment = redpen.add_comment()
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  local second_comment = redpen.add_comment()

  local review = redpen.finish_review()

  local expected_review = first_comment .. '\n' .. second_comment
  assert(review == expected_review, 'Finished review did not join the comments')
  assert(written_register == '+', 'Finished review used the wrong register')
  assert(written_review == expected_review, 'Finished review copied the wrong text')
  wait_for_notifications(3)
  assert(vim.tbl_contains(notifications, 'Review updated (2 comments)'), 'Review did not report two comments')
  assert(vim.tbl_contains(notifications, 'Review copied to clipboard (2 comments)'), 'Review did not report copying')

  local empty_review = redpen.finish_review()
  assert(empty_review == nil, 'Finishing an empty review returned text')
  assert(written_review == expected_review, 'Finishing an empty review changed the clipboard')
  assert(vim.tbl_contains(notifications, 'No review comments to copy'), 'Empty review did not notify the user')
end

local function run()
  local tests = {
    { 'single-line comment', test_add_comment_uses_current_file_and_line },
    { 'visual comment', test_add_comment_uses_visual_line_range },
    { 'cancelled comment', test_cancelled_comment_is_not_added },
    { 'finish review', test_finish_review_copies_and_clears_comments },
  }

  for _, test in ipairs(tests) do
    local ok, error_message = xpcall(function()
      before()
      test[2]()
    end, debug.traceback)
    after()
    if not ok then error(test[1] .. ':\n' .. error_message) end
  end

  return #tests
end

vim.api.nvim_echo({ { ('REDPEN_TEST_COUNT=%d'):format(run()) } }, false, {})
