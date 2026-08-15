local plugin_root = vim.fn.getcwd()
local test_repo

vim.opt.runtimepath:prepend(plugin_root)

local function git(arguments)
  local command = { 'git', '-C', test_repo }
  vim.list_extend(command, arguments)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end

local function before()
  test_repo = vim.fn.tempname()
  vim.fn.mkdir(test_repo, 'p')
  git { 'init', '--quiet' }
  vim.fn.writefile({ 'tracked' }, test_repo .. '/tracked.txt')
  vim.fn.writefile({ 'ignored.txt' }, test_repo .. '/.gitignore')
  git { 'add', 'tracked.txt', '.gitignore' }
  git { '-c', 'user.name=Redpen Test', '-c', 'user.email=redpen@example.com', 'commit', '--quiet', '-m', 'Initial' }

  vim.cmd.cd(vim.fn.fnameescape(test_repo))
end

local function after()
  local diff = package.loaded['redpen.diff']
  if diff then diff.close() end
  vim.cmd.cd(vim.fn.fnameescape(plugin_root))
  if test_repo then vim.fn.delete(test_repo, 'rf') end
end

local function test_untracked_files_appear_in_summary()
  vim.fn.writefile({ 'untracked' }, test_repo .. '/new.txt')
  vim.fn.writefile({ 'also untracked' }, test_repo .. '/second.txt')
  vim.fn.writefile({ 'ignored' }, test_repo .. '/ignored.txt')

  require('redpen.diff').open()

  assert(vim.wait(5000, function()
    return vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] ~= '  Loading…'
  end), 'Timed out waiting for the diff summary')

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert(vim.tbl_contains(lines, '  untracked new.txt'), 'Summary did not include the untracked file')
  assert(vim.tbl_contains(lines, '  untracked second.txt'), 'Summary did not include every untracked file')
  assert(not vim.tbl_contains(lines, '  untracked ignored.txt'), 'Summary included an ignored file')
  assert(vim.tbl_contains(lines, '  2 untracked files'), 'Summary did not count the untracked files')
end

local function run()
  local ok, error_message = xpcall(function()
    before()
    test_untracked_files_appear_in_summary()
  end, debug.traceback)
  after()
  if not ok then error(error_message) end
end

run()
