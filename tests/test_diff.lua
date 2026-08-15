local plugin_root = vim.fn.getcwd()
local test_repo

vim.opt.runtimepath:prepend(plugin_root)

local function git(arguments)
  local command = { 'git', '-C', test_repo }
  vim.list_extend(command, arguments)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return result
end

local function write_file(path, lines) vim.fn.writefile(lines, test_repo .. '/' .. path) end

local function before()
  test_repo = vim.fn.tempname()
  vim.fn.mkdir(test_repo, 'p')
  test_repo = vim.fn.resolve(test_repo)
  git { 'init', '--quiet' }
  write_file('tracked.txt', { 'first', 'second' })
  write_file('.gitignore', { 'ignored.txt' })
  git { 'add', 'tracked.txt', '.gitignore' }
  git { '-c', 'user.name=Redpen Test', '-c', 'user.email=redpen@example.com', 'commit', '--quiet', '-m', 'Initial' }

  vim.cmd.cd(vim.fn.fnameescape(test_repo))
  vim.cmd.enew()
end

local function after()
  local diff = package.loaded['redpen.diff']
  if diff then diff.close() end
  vim.cmd.cd(vim.fn.fnameescape(plugin_root))

  if test_repo then
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      local buffer_path = vim.api.nvim_buf_get_name(buffer)
      if vim.startswith(buffer_path, test_repo .. '/') then
        pcall(vim.api.nvim_buf_delete, buffer, { force = true })
      end
    end
    vim.fn.delete(test_repo, 'rf')
    test_repo = nil
  end
end

local function wait_for_diff()
  assert(vim.wait(5000, function()
    return vim.bo.filetype == 'redpen-diff'
      and vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] ~= '  Loading…'
  end), 'Timed out waiting for the diff')
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function find_row(lines, expected_line)
  for row, line in ipairs(lines) do
    if line == expected_line then return row end
  end
  error('Missing diff line: ' .. expected_line)
end

local function test_untracked_files_appear_in_summary()
  write_file('new.txt', { 'untracked' })
  write_file('second.txt', { 'also untracked' })
  write_file('ignored.txt', { 'ignored' })

  require('redpen').open_diff()

  local lines = wait_for_diff()
  assert(vim.tbl_contains(lines, '  untracked new.txt'), 'Summary did not include the untracked file')
  assert(vim.tbl_contains(lines, '  untracked second.txt'), 'Summary did not include every untracked file')
  assert(not vim.tbl_contains(lines, '  untracked ignored.txt'), 'Summary included an ignored file')
  assert(vim.tbl_contains(lines, '  2 untracked files'), 'Summary did not count the untracked files')
end

local function test_working_tree_diff_shows_tracked_changes()
  write_file('tracked.txt', { 'first', 'second', 'third' })

  require('redpen').open_diff()

  local lines = wait_for_diff()
  assert(vim.tbl_contains(lines, '  +1 -0 tracked.txt'), 'Summary did not include the tracked change')
  assert(
    vim.tbl_contains(lines, '  1 file changed, 1 insertion(+), 0 deletions(-)'),
    'Summary did not include tracked totals'
  )
  assert(vim.tbl_contains(lines, 'Difftastic: HEAD → working tree'), 'Working-tree diff title was missing')
end

local function test_head_diff_shows_commit_changes_only()
  write_file('tracked.txt', { 'first', 'second', 'third' })
  git { 'add', 'tracked.txt' }
  git { '-c', 'user.name=Redpen Test', '-c', 'user.email=redpen@example.com', 'commit', '--quiet', '-m', 'Add third' }
  write_file('new.txt', { 'untracked' })
  local commit_hash = vim.trim(git { 'rev-parse', '--short', 'HEAD' }.stdout)

  require('redpen').open_diff_head()

  local lines = wait_for_diff()
  assert(vim.tbl_contains(lines, '  ' .. commit_hash .. ' Add third'), 'HEAD summary did not include the commit')
  assert(vim.tbl_contains(lines, '  +1 -0 tracked.txt'), 'HEAD summary did not include the committed change')
  assert(not vim.tbl_contains(lines, '  untracked new.txt'), 'HEAD summary included a working-tree file')
  assert(vim.tbl_contains(lines, 'Difftastic: HEAD'), 'HEAD diff title was missing')
end

local function test_open_reuses_diff_and_close_restores_source()
  local source_path = test_repo .. '/tracked.txt'
  vim.cmd.edit(vim.fn.fnameescape(source_path))
  local source_buffer = vim.api.nvim_get_current_buf()
  vim.wo.number = true
  vim.wo.relativenumber = true
  vim.wo.signcolumn = 'yes'
  vim.wo.wrap = true

  local redpen = require 'redpen'
  redpen.open_diff()
  wait_for_diff()
  local diff_buffer = vim.api.nvim_get_current_buf()

  assert(diff_buffer ~= source_buffer, 'Diff did not replace the source buffer')
  assert(not vim.wo.number, 'Diff window kept line numbers')
  assert(not vim.wo.relativenumber, 'Diff window kept relative line numbers')
  assert(vim.wo.signcolumn == 'no', 'Diff window kept the sign column')
  assert(not vim.wo.wrap, 'Diff window kept line wrapping')

  redpen.open_diff()
  assert(vim.api.nvim_get_current_buf() == diff_buffer, 'Opening the same diff created another buffer')

  redpen.close_diff()
  assert(vim.api.nvim_get_current_buf() == source_buffer, 'Closing the diff did not restore the source buffer')
  assert(not vim.api.nvim_buf_is_valid(diff_buffer), 'Closing the diff did not delete its buffer')
  assert(vim.wo.number, 'Closing the diff did not restore line numbers')
  assert(vim.wo.relativenumber, 'Closing the diff did not restore relative line numbers')
  assert(vim.wo.signcolumn == 'yes', 'Closing the diff did not restore the sign column')
  assert(vim.wo.wrap, 'Closing the diff did not restore line wrapping')
end

local function test_source_range_and_jump_use_summary_targets()
  write_file('new.txt', { 'first', 'second' })
  write_file('second.txt', { 'another' })

  local redpen = require 'redpen'
  local diff = require 'redpen.diff'
  redpen.open_diff()

  local lines = wait_for_diff()
  local new_file_row = find_row(lines, '  untracked new.txt')
  local second_file_row = find_row(lines, '  untracked second.txt')
  local source_range = assert(diff.source_range(new_file_row))
  assert(source_range.path == 'new.txt', 'Source range used the wrong path')
  assert(source_range.start_line == 1 and source_range.end_line == 1, 'Source range used the wrong line')

  local missing_range, missing_error = diff.source_range(1)
  assert(not missing_range and missing_error == 'No changed file at the selection', 'Title row resolved to a source')
  local spanning_range, spanning_error = diff.source_range(new_file_row, second_file_row)
  assert(
    not spanning_range and spanning_error == 'The selection spans multiple changed files',
    'A range spanning files resolved to one source'
  )

  vim.api.nvim_win_set_cursor(0, { new_file_row, 0 })
  redpen.jump_to_source()
  assert(vim.api.nvim_buf_get_name(0) == test_repo .. '/new.txt', 'Jump opened the wrong source file')
  assert(vim.api.nvim_win_get_cursor(0)[1] == 1, 'Jump opened the wrong source line')
end

local function run()
  local tests = {
    { 'untracked summary', test_untracked_files_appear_in_summary },
    { 'working-tree diff', test_working_tree_diff_shows_tracked_changes },
    { 'HEAD diff', test_head_diff_shows_commit_changes_only },
    { 'diff reuse and close', test_open_reuses_diff_and_close_restores_source },
    { 'source range and jump', test_source_range_and_jump_use_summary_targets },
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
