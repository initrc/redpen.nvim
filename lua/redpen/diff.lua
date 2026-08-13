local M = {}

-- Keep this module's highlights separate from Treesitter, LSP, and plugins.
local HIGHLIGHT_NAMESPACE = vim.api.nvim_create_namespace 'redpen-diff'
local HIGHLIGHT_GROUPS = {
  title = 'RedpenDiffTitle',
  muted = 'RedpenDiffMuted',
  red = 'RedpenDiffRed',
  green = 'RedpenDiffGreen',
  yellow = 'RedpenDiffYellow',
  blue = 'RedpenDiffBlue',
  mauve = 'RedpenDiffMauve',
  teal = 'RedpenDiffTeal',
  text = 'RedpenDiffText',
}

---@enum DiffMode
local DIFF_MODE = {
  WORKING_TREE = 'working_tree',
  HEAD_COMMIT = 'head_commit',
}

---@param diff_mode DiffMode
local function difft_title(diff_mode)
  if diff_mode == DIFF_MODE.HEAD_COMMIT then return 'Difftastic: HEAD' end
  return 'Difftastic: HEAD → working tree'
end

local state = {
  -- Incrementing this makes callbacks from a closed diff harmless.
  run_id = 0,
  diff_buf = nil,
  diff_win = nil,
  buffer_before_diff = nil,
  source_window_options = nil,
  repo_root = nil,
  diff_mode = nil,
  -- Maps a diff row to its source. Headers omit `line`; `kind` keeps the
  -- Summary and Difftastic sections from matching each other.
  row_targets = {},
  running_jobs = {},
}

local ANSI_CODE_TO_HIGHLIGHT_GROUP = {
  ['30'] = HIGHLIGHT_GROUPS.muted,
  ['31'] = HIGHLIGHT_GROUPS.red,
  ['32'] = HIGHLIGHT_GROUPS.green,
  ['33'] = HIGHLIGHT_GROUPS.yellow,
  ['34'] = HIGHLIGHT_GROUPS.blue,
  ['35'] = HIGHLIGHT_GROUPS.mauve,
  ['36'] = HIGHLIGHT_GROUPS.teal,
  ['37'] = HIGHLIGHT_GROUPS.text,
  ['90'] = HIGHLIGHT_GROUPS.muted,
  ['91'] = HIGHLIGHT_GROUPS.red,
  ['92'] = HIGHLIGHT_GROUPS.green,
  ['93'] = HIGHLIGHT_GROUPS.yellow,
  ['94'] = HIGHLIGHT_GROUPS.blue,
  ['95'] = HIGHLIGHT_GROUPS.mauve,
  ['96'] = HIGHLIGHT_GROUPS.teal,
  ['97'] = HIGHLIGHT_GROUPS.text,
}

local function link_highlights_to_colorscheme()
  for diff_group, colorscheme_group in pairs {
    [HIGHLIGHT_GROUPS.title] = 'Title',
    [HIGHLIGHT_GROUPS.muted] = 'Comment',
    [HIGHLIGHT_GROUPS.red] = 'DiagnosticError',
    [HIGHLIGHT_GROUPS.green] = 'DiagnosticOk',
    [HIGHLIGHT_GROUPS.yellow] = 'DiagnosticWarn',
    [HIGHLIGHT_GROUPS.blue] = 'DiagnosticInfo',
    [HIGHLIGHT_GROUPS.mauve] = 'Special',
    [HIGHLIGHT_GROUPS.teal] = 'DiagnosticHint',
    [HIGHLIGHT_GROUPS.text] = 'Normal',
  } do
    -- Namespace 0 means global. `link` inherits the current colorscheme's color.
    vim.api.nvim_set_hl(0, diff_group, { link = colorscheme_group })
  end
end

-- Colorschemes recreate highlight groups when loaded. Re-link ours afterward;
-- `clear = true` replaces an older copy of this named autocmd group on reload.
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('redpen-diff-highlights', { clear = true }),
  callback = link_highlights_to_colorscheme,
})

local function set_window_options(win, options)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  for option, value in pairs(options) do
    vim.wo[win][option] = value
  end
end

local function apply_diff_window_options()
  set_window_options(state.diff_win, {
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    -- Keep each side-by-side diff row on one screen row; scroll horizontally
    -- instead of soft-wrapping long output.
    wrap = false,
  })
end

local function restore_source_window_options()
  set_window_options(state.diff_win, state.source_window_options or {})
end

-- Reset the diff buffer to exactly these lines.
local function reset_diff_buffer_lines(diff_lines)
  local diff_buffer = state.diff_buf
  if not diff_buffer or not vim.api.nvim_buf_is_valid(diff_buffer) then return end
  vim.bo[diff_buffer].modifiable = true
  -- `0, -1` replaces the whole buffer. `false` allows index clamping, though
  -- both indices used here are already valid.
  vim.api.nvim_buf_set_lines(diff_buffer, 0, -1, false, diff_lines)
  vim.bo[diff_buffer].modifiable = false
end

-- Remove ANSI terminal styling from one raw Difftastic output line and return
-- both its clean printable text and the equivalent Neovim highlight ranges.
local function parse_ansi_line(raw_line)
  local clean_parts = {}
  local highlight_ranges = {}
  local active_highlight_group
  local raw_index = 0
  local clean_index = 0

  while raw_index < #raw_line do
    -- Find the next color code, such as ESC[31m. `\27` is ESC. Lua searches
    -- are one-based, so start at the byte after zero-based `raw_index`.
    local ansi_start, ansi_end, ansi_codes = raw_line:find('\27%[([%d;]*)m', raw_index + 1)
    -- Example for raw_line = `"\27[31mdeleted\27[0m"`:
    --   1. raw_index=0  -> ansi_start=1,  ansi_end=5,  ansi_codes="31", text_between_codes=""
    --   2. raw_index=5  -> ansi_start=13, ansi_end=16, ansi_codes="0",  text_between_codes="deleted"
    -- The seven letters get `{ col = 0, end_col = 7 }` in `highlight_ranges`.
    local text_between_codes = ansi_start and raw_line:sub(raw_index + 1, ansi_start - 1) or raw_line:sub(raw_index + 1)
    if text_between_codes ~= '' then
      -- `table.insert` appends this text to the list of clean output parts.
      table.insert(clean_parts, text_between_codes)
      if active_highlight_group then
        table.insert(highlight_ranges, {
          col = clean_index,
          end_col = clean_index + #text_between_codes,
          group = active_highlight_group,
        })
      end
      clean_index = clean_index + #text_between_codes
    end
    if not ansi_start then break end

    for ansi_code in ansi_codes:gmatch '%d+' do
      -- ANSI 0 resets all styles; 39 restores the default foreground color.
      -- In either case, following text should have no custom highlight group.
      if ansi_code == '0' or ansi_code == '39' then
        active_highlight_group = nil
      elseif ANSI_CODE_TO_HIGHLIGHT_GROUP[ansi_code] then
        active_highlight_group = ANSI_CODE_TO_HIGHLIGHT_GROUP[ansi_code]
      end
    end
    -- `ansi_end` is one-based and inclusive, which is numerically equal to the
    -- zero-based offset immediately after the sequence.
    raw_index = ansi_end
  end

  -- `{ "de", "leted\r" }` becomes `"deleted"`; the final `\r` came from CRLF.
  local clean_line = table.concat(clean_parts):gsub('\r$', '')
  -- `"\27[2Kdeleted"` becomes `"deleted"` by removing an untranslated ANSI command.
  return clean_line:gsub('\27%[[%d;?]*[ -/]*[@-~]', ''), highlight_ranges
end

-- Convert Difftastic's compact rename syntax into the path Neovim can open.
local function parse_difft_path(display_path)
  -- `src/{old => new}/file.lua` becomes `src/new/file.lua`.
  local prefix, renamed, suffix = display_path:match '^(.-){.- => (.-)}(.*)$'
  if prefix then return prefix .. renamed .. suffix end
  -- `old.lua => new.lua` becomes `new.lua`; ordinary paths stay unchanged.
  return display_path:match '^.- => (.+)$' or display_path
end

-- Difftastic separates its two sides with a string position containing spaces.
-- Positions here are Lua's one-based byte positions, not Neovim columns.
local function is_difft_gutter(clean_lines, first_row, last_row, gutter_position)
  if gutter_position < 1 then return false end
  local position_exists = false
  for difft_row = first_row, last_row do
    local clean_line = clean_lines[difft_row]
    if clean_line and #clean_line >= gutter_position then
      position_exists = true
      -- In `"ab cd"`, `sub(3, 3)` returns the single character `" "`.
      local gutter_character = clean_line:sub(gutter_position, gutter_position)
      if gutter_character ~= ' ' then return false end
    end
  end
  return position_exists
end

-- Find the whitespace column separating Difftastic's old and new sides.
-- In `1 old     1 new`, the gutter is between `old` and the second `1`.
local function find_difft_gutter(clean_lines, first_row, last_row, output_width)
  -- Full-width output uses the requested midpoint as its gutter.
  local gutter_position = math.floor(output_width / 2)
  if is_difft_gutter(clean_lines, first_row, last_row, gutter_position) then return gutter_position end

  local widest_line = 0
  for difft_row = first_row, last_row do
    widest_line = math.max(widest_line, #(clean_lines[difft_row] or ''))
  end
  -- Difftastic makes short output narrower, so its actual midpoint may differ.
  gutter_position = math.floor(widest_line / 2)
  if is_difft_gutter(clean_lines, first_row, last_row, gutter_position) then return gutter_position end
end

-- Parse Difftastic text into diff lines, colors, and source locations.
local function parse_difft_output(raw_output, output_width)
  -- `"first\nsecond\n"` becomes `{ "first", "second" }`.
  local raw_lines = vim.split(raw_output, '\n', { plain = true, trimempty = true })
  local clean_lines, highlight_ranges, row_targets, section_header_rows = {}, {}, {}, {}
  local current_source_path

  for difft_row, raw_line in ipairs(raw_lines) do
    local clean_line, line_highlight_ranges = parse_ansi_line(raw_line)
    clean_lines[difft_row], highlight_ranges[difft_row] = clean_line, line_highlight_ranges

    -- `lua/user.lua --- 2/3 --- Lua` gives `difft_path = "lua/user.lua"`.
    local difft_path = clean_line:match '^(.-)%s+%-%-%-%s+.+$'
    -- `" 14 ---"` and `" . ---"` are diff rows, not file headers.
    if difft_path and not clean_line:match '^%s*[%d%.]+%s' then
      current_source_path = parse_difft_path(vim.trim(difft_path))
      table.insert(section_header_rows, difft_row)
    end
    if current_source_path then row_targets[difft_row] = { path = current_source_path, kind = 'diff' } end
  end

  for header_index, header_row in ipairs(section_header_rows) do
    local next_header_row = section_header_rows[header_index + 1]
    local section_last_row = next_header_row and next_header_row - 1 or #clean_lines
    local gutter_position = find_difft_gutter(clean_lines, header_row + 1, section_last_row, output_width)
    local previous_source_line
    if gutter_position then
      for difft_row = header_row + 1, section_last_row do
        -- Skip the one-based gutter position to isolate the new-file side.
        local new_side = clean_lines[difft_row]:sub(gutter_position + 1)
        -- `"  56 local x = 1"` gives `new_line_marker = "56"`.
        local new_line_marker = new_side:match '^%s*(%S+)'
        local source_line = new_line_marker and tonumber(new_line_marker)
        if source_line then
          previous_source_line = source_line
          row_targets[difft_row].line = source_line
        elseif new_line_marker and new_line_marker:match '^%.+$' then
          -- After `" 56 long line"`, a wrapped row starts with `" . continued"`;
          -- reuse line 56 because the wrapped text still belongs to that line.
          row_targets[difft_row].line = previous_source_line
        end
      end
    end
  end

  return clean_lines, highlight_ranges, row_targets, section_header_rows
end

---@param raw_output string
---@param diff_mode DiffMode
local function parse_diff_summary(raw_output, diff_mode)
  -- `--numstat -z` keeps paths unquoted and NUL-separated so even unusual
  -- filenames can be mapped back to their source files without ambiguity.
  local entries = vim.split(raw_output, '\0', { plain = true, trimempty = false })
  local summary_lines, row_targets, highlight_ranges = { 'Summary' }, {}, {}
  local entry_index = 1
  if diff_mode == DIFF_MODE.HEAD_COMMIT then
    local commit_hash, commit_subject = entries[1] or '', entries[2] or ''
    if commit_hash ~= '' then table.insert(summary_lines, '  ' .. commit_hash .. ' ' .. commit_subject) end
    entry_index = 3
  end

  local file_count, insertion_count, deletion_count = 0, 0, 0
  while entry_index <= #entries do
    -- `git show` puts a newline between its formatted header and numstat data.
    local entry = entries[entry_index]:gsub('^\n', '')
    local added, deleted, current_path = entry:match '^([^\t]+)\t([^\t]+)\t(.*)$'
    if added then
      local displayed_path = current_path
      if current_path == '' then
        local original_path = entries[entry_index + 1] or '?'
        current_path = entries[entry_index + 2] or '?'
        displayed_path = original_path .. ' → ' .. current_path
        entry_index = entry_index + 2
      end

      displayed_path = displayed_path:gsub('\n', '\\n')
      local summary_row = #summary_lines + 1
      if added == '-' or deleted == '-' then
        summary_lines[summary_row] = '  binary ' .. displayed_path
      else
        summary_lines[summary_row] = string.format('  +%s -%s %s', added, deleted, displayed_path)
        local deletion_col = 5 + #added
        highlight_ranges[summary_row] = {
          { col = 2, end_col = 3 + #added, group = HIGHLIGHT_GROUPS.green },
          { col = deletion_col, end_col = deletion_col + 1 + #deleted, group = HIGHLIGHT_GROUPS.red },
        }
        insertion_count = insertion_count + tonumber(added)
        deletion_count = deletion_count + tonumber(deleted)
      end
      row_targets[summary_row] = { path = current_path, line = 1, kind = 'summary' }
      file_count = file_count + 1
    end
    entry_index = entry_index + 1
  end

  if file_count == 0 then
    table.insert(summary_lines, '  No tracked changes')
  else
    local file_label = file_count == 1 and 'file' or 'files'
    local insertion_label = insertion_count == 1 and 'insertion' or 'insertions'
    local deletion_label = deletion_count == 1 and 'deletion' or 'deletions'
    table.insert(
      summary_lines,
      string.format(
        '  %d %s changed, %d %s(+), %d %s(-)',
        file_count,
        file_label,
        insertion_count,
        insertion_label,
        deletion_count,
        deletion_label
      )
    )
  end
  return summary_lines, row_targets, highlight_ranges
end

local function add_diff_highlight(diff_row, highlight_range)
  local diff_buf = assert(state.diff_buf)
  -- Extmarks attach metadata to buffer text. API rows/columns are zero-based,
  -- so convert our one-based parsed row; `end_col` is the exclusive endpoint.
  -- Buffer, namespace, row, and column identify the extmark. The final table
  -- holds optional properties such as its ending column and highlight group.
  vim.api.nvim_buf_set_extmark(diff_buf, HIGHLIGHT_NAMESPACE, diff_row - 1, highlight_range.col, {
    end_col = highlight_range.end_col,
    hl_group = highlight_range.group,
    priority = 100,
  })
end

---@param diff_mode DiffMode
local function render_diff(summary_result, difft_result, run_id, output_width, diff_mode)
  local diff_buffer, diff_window = state.diff_buf, state.diff_win
  if
    run_id ~= state.run_id
    or not diff_buffer
    or not vim.api.nvim_buf_is_valid(diff_buffer)
    or not diff_window
    or not vim.api.nvim_win_is_valid(diff_window)
  then
    return
  end
  state.running_jobs = {}

  local summary_lines, summary_row_targets, summary_highlight_ranges
  if summary_result.code == 0 then
    summary_lines, summary_row_targets, summary_highlight_ranges =
      parse_diff_summary(summary_result.stdout or '', diff_mode)
  else
    summary_lines = { 'Summary', '  ' .. vim.trim(summary_result.stderr or 'Failed to load summary') }
    summary_row_targets, summary_highlight_ranges = {}, {}
  end

  local diff_lines = vim.list_extend({}, summary_lines)
  table.insert(diff_lines, '')
  local difft_title_row = #diff_lines + 1
  table.insert(diff_lines, difft_title(diff_mode))
  -- Difftastic row 1 appears at `1 + difft_row_offset` in the diff buffer.
  local difft_row_offset = #diff_lines

  local difft_lines, difft_highlight_ranges, difft_row_targets, difft_header_rows = {}, {}, {}, {}
  if difft_result.code == 0 and difft_result.stdout ~= '' then
    difft_lines, difft_highlight_ranges, difft_row_targets, difft_header_rows =
      parse_difft_output(difft_result.stdout, output_width)
    vim.list_extend(diff_lines, difft_lines)
  elseif difft_result.code == 0 then
    table.insert(diff_lines, '  No tracked changes')
  else
    table.insert(diff_lines, '  ' .. vim.trim(difft_result.stderr or 'Failed to run Difftastic'))
  end

  state.row_targets = {}
  for summary_row, row_target in pairs(summary_row_targets) do
    state.row_targets[summary_row] = row_target
  end
  for difft_row, row_target in pairs(difft_row_targets) do
    state.row_targets[difft_row + difft_row_offset] = row_target
  end

  reset_diff_buffer_lines(diff_lines)
  -- Remove this namespace's old extmarks—and therefore their highlights—from
  -- every row (`0, -1`). This does not remove text or other plugins' extmarks.
  vim.api.nvim_buf_clear_namespace(diff_buffer, HIGHLIGHT_NAMESPACE, 0, -1)
  add_diff_highlight(1, { col = 0, end_col = #diff_lines[1], group = HIGHLIGHT_GROUPS.title })
  add_diff_highlight(difft_title_row, {
    col = 0,
    end_col = #diff_lines[difft_title_row],
    group = HIGHLIGHT_GROUPS.title,
  })
  -- Summary highlights are keyed by diff row and start at row 2, so the table
  -- is sparse and needs `pairs`. The remaining tables are dense lists, so they
  -- use `ipairs` to visit numeric entries in order.
  for summary_row, row_highlights in pairs(summary_highlight_ranges) do
    for _, highlight_range in ipairs(row_highlights) do
      add_diff_highlight(summary_row, highlight_range)
    end
  end
  for difft_row, row_highlights in ipairs(difft_highlight_ranges) do
    for _, highlight_range in ipairs(row_highlights) do
      add_diff_highlight(difft_row + difft_row_offset, highlight_range)
    end
  end
  for _, difft_row in ipairs(difft_header_rows) do
    add_diff_highlight(difft_row + difft_row_offset, {
      col = 0,
      end_col = #difft_lines[difft_row],
      group = HIGHLIGHT_GROUPS.title,
    })
  end
  -- Cursor positions use a one-based row but a zero-based byte column.
  vim.api.nvim_win_set_cursor(diff_window, { 1, 0 })
end

-- Resolve a header or wrapped row to the nearest real line in the same file.
-- Example: a `foo.lua` header resolves to the closest numbered `foo.lua` row.
local function resolve_row_target(diff_row)
  local selected_target = state.row_targets[diff_row]
  if not selected_target or selected_target.line then return selected_target end

  local diff_buffer = assert(state.diff_buf)
  -- A valid Neovim buffer always has at least one line, so this is also its
  -- last valid one-based row number. The API returns an integer, never nil.
  local last_diff_row = vim.api.nvim_buf_line_count(diff_buffer)
  local distance = 1
  while true do
    local row_below = diff_row + distance
    local row_above = diff_row - distance
    if row_below > last_diff_row and row_above < 1 then break end

    -- At distance 1 from row 10, check rows 11 and 9; then increment to 2.
    for _, candidate_row in ipairs { row_below, row_above } do
      if candidate_row >= 1 and candidate_row <= last_diff_row then
        local candidate_target = state.row_targets[candidate_row]
        if
          candidate_target
          and candidate_target.path == selected_target.path
          and candidate_target.kind == selected_target.kind
          and candidate_target.line
        then
          return candidate_target
        end
      end
    end
    distance = distance + 1
  end
  return selected_target
end

-- Resolve one diff row or a visual range to its source path and lines.
function M.source_range(start_row, end_row)
  local start_target = resolve_row_target(start_row)
  if not start_target then return nil, 'No changed file at the selection' end

  local start_line = start_target.line or 1
  end_row = end_row or start_row
  if end_row == start_row then
    return { path = start_target.path, start_line = start_line, end_line = start_line }
  end

  local end_target = resolve_row_target(end_row)
  if not end_target then return nil, 'No changed file at the selection' end
  if end_target.path ~= start_target.path then return nil, 'The selection spans multiple changed files' end

  local end_line = end_target.line or 1
  if start_line > end_line then start_line, end_line = end_line, start_line end
  return { path = start_target.path, start_line = start_line, end_line = end_line }
end

function M.jump_to_source()
  -- Window ID 0 means the current window. The result is a Lua list such as
  -- `{ 12, 4 }`: `[1]` reads row 12 and `[2]` reads byte column 4. `[0]` is nil.
  local cursor_position = vim.api.nvim_win_get_cursor(0)
  local diff_row = cursor_position[1]
  local source_target = resolve_row_target(diff_row)
  if not source_target then
    vim.notify('No changed file at the cursor', vim.log.levels.INFO)
    return
  end

  local repo_root = state.repo_root
  if not repo_root then return end
  local source_path = vim.fs.joinpath(repo_root, source_target.path)
  if vim.fn.filereadable(source_path) ~= 1 then
    vim.notify('Source file not found: ' .. source_target.path, vim.log.levels.WARN)
    return
  end

  -- `+N` places the cursor on source line N. `fnameescape` protects spaces and
  -- other characters that would otherwise be parsed as Ex command syntax.
  vim.cmd('edit +' .. (source_target.line or 1) .. ' ' .. vim.fn.fnameescape(source_path))
  restore_source_window_options()
  -- Execute normal-mode `zz` immediately; `bang` bypasses user mappings.
  vim.cmd.normal { 'zz', bang = true }
end

local function stop_running_jobs()
  for _, job in ipairs(state.running_jobs) do
    -- Signal 15 requests a graceful stop; `pcall` ignores an already-exited job.
    pcall(job.kill, job, 15)
  end
end

local function reset_diff_state()
  state.diff_buf = nil
  state.diff_win = nil
  state.buffer_before_diff = nil
  state.source_window_options = nil
  state.repo_root = nil
  state.diff_mode = nil
  state.row_targets = {}
  state.running_jobs = {}
end

function M.close()
  local diff_buf = state.diff_buf
  local diff_win = state.diff_win
  local buffer_before_diff = state.buffer_before_diff
  local source_window_options = state.source_window_options
  state.run_id = state.run_id + 1
  stop_running_jobs()
  reset_diff_state()

  if
    diff_win
    and diff_buf
    and vim.api.nvim_win_is_valid(diff_win)
    and vim.api.nvim_win_get_buf(diff_win) == diff_buf
  then
    local restored_buffer
    if buffer_before_diff and vim.api.nvim_buf_is_valid(buffer_before_diff) then
      restored_buffer = buffer_before_diff
    else
      -- Arguments are `{ listed, scratch }`: create a normal listed empty buffer
      -- when the original empty buffer was deleted on diff startup.
      restored_buffer = vim.api.nvim_create_buf(true, false)
    end
    vim.api.nvim_win_set_buf(diff_win, restored_buffer)
    set_window_options(diff_win, source_window_options or {})
  end
  if diff_buf and vim.api.nvim_buf_is_valid(diff_buf) then vim.api.nvim_buf_delete(diff_buf, { force = true }) end
end

local function run_async(command, command_options, run_id, on_exit)
  -- `text = true` returns stdout/stderr strings. Command options override defaults.
  local process_options = vim.tbl_extend('force', { cwd = state.repo_root, text = true }, command_options or {})
  -- The callback makes `vim.system` asynchronous; the run ID rejects stale output.
  local job = vim.system(command, process_options, function(result)
    if run_id == state.run_id then on_exit(result) end
  end)
  table.insert(state.running_jobs, job)
end

---@param diff_mode DiffMode
local function load_diff(run_id, output_width, diff_mode)
  local summary_result, difft_result
  local function render_when_ready()
    if not summary_result or not difft_result then return end
    -- The process exit handler is a libuv callback; schedule buffer changes
    -- onto Neovim's main loop after both commands have completed.
    vim.schedule(function() render_diff(summary_result, difft_result, run_id, output_width, diff_mode) end)
  end

  local summary_command = { 'git', 'diff', '--numstat', '-z', 'HEAD', '--' }
  if diff_mode == DIFF_MODE.HEAD_COMMIT then
    summary_command = { 'git', 'show', '--numstat', '-z', '--format=%h%x00%s%x00', 'HEAD', '--' }
  end
  run_async(summary_command, nil, run_id, function(result)
    summary_result = result
    render_when_ready()
  end)

  -- A repository without HEAD has no commit to compare or show.
  run_async({ 'git', 'rev-parse', '--verify', '--quiet', 'HEAD' }, nil, run_id, function(commit_result)
    if commit_result.code ~= 0 then
      difft_result = { code = 0, stdout = '', stderr = '' }
      render_when_ready()
      return
    end

    local command = { 'git', '-c', 'diff.external=difft', 'diff', 'HEAD', '--' }
    if diff_mode == DIFF_MODE.HEAD_COMMIT then
      command = { 'git', '-c', 'diff.external=difft', 'show', '--ext-diff', '--format=', 'HEAD', '--' }
    end
    run_async(
      command,
      {
        -- Always emit colors for translation into Neovim highlights. A fixed
        -- side-by-side layout lets the parser locate the new-file line numbers.
        env = {
          DFT_COLOR = 'always',
          DFT_DISPLAY = 'side-by-side-show-both',
          DFT_WIDTH = tostring(output_width),
        },
      },
      run_id,
      function(result)
        difft_result = result
        render_when_ready()
      end
    )
  end)
end

-- Only replace a startup `[No Name]` buffer, never a buffer containing user work.
local function is_disposable_empty_buffer(buffer)
  return vim.api.nvim_buf_get_name(buffer) == ''
    and not vim.bo[buffer].modified
    and vim.bo[buffer].buftype == ''
    and vim.api.nvim_buf_line_count(buffer) == 1
    and vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1] == ''
end

local function find_repo_root()
  local current_path = vim.api.nvim_buf_get_name(0)
  return vim.fs.root(current_path ~= '' and current_path or vim.fn.getcwd(), '.git')
end

-- Remember what the current window should show again when the diff closes.
local function remember_window_before_diff()
  local diff_window = vim.api.nvim_get_current_win()
  local buffer_before_diff = vim.api.nvim_get_current_buf()
  state.diff_win = diff_window
  state.buffer_before_diff = buffer_before_diff
  state.source_window_options = {
    number = vim.wo.number,
    relativenumber = vim.wo.relativenumber,
    signcolumn = vim.wo.signcolumn,
    wrap = vim.wo.wrap,
  }
  return diff_window, buffer_before_diff
end

---@param diff_mode DiffMode
local function show_loading_diff(diff_mode)
  state.diff_mode = diff_mode
  apply_diff_window_options()
  reset_diff_buffer_lines { 'Summary', '  Loading…', '', difft_title(diff_mode), '  Loading…' }
  -- Keep enough width for two readable sides even when the current window is narrow.
  local output_width = math.max(80, vim.api.nvim_win_get_width(state.diff_win))
  load_diff(state.run_id, output_width, diff_mode)
end

---@param diff_mode DiffMode
local function open(diff_mode)
  local existing_diff_buffer = state.diff_buf
  if existing_diff_buffer and vim.api.nvim_buf_is_valid(existing_diff_buffer) then
    -- The diff may already be visible in another split or tab. Focus that
    -- window instead of displaying the same diff buffer in two windows.
    local visible_diff_windows = vim.fn.win_findbuf(existing_diff_buffer)
    if #visible_diff_windows > 0 then
      state.diff_win = visible_diff_windows[1]
      vim.api.nvim_set_current_win(state.diff_win)
    else
      -- If source navigation hid the diff, reopen it here and remember the
      -- current buffer so `close()` restores that buffer in this window.
      local diff_window = remember_window_before_diff()
      vim.api.nvim_win_set_buf(diff_window, existing_diff_buffer)
    end

    if state.diff_mode ~= diff_mode then
      state.run_id = state.run_id + 1
      stop_running_jobs()
      state.running_jobs = {}
      show_loading_diff(diff_mode)
    else
      apply_diff_window_options()
    end
    return
  end

  local repo_root = find_repo_root()
  if not repo_root then
    vim.notify('Not a Git repository', vim.log.levels.ERROR)
    return
  end

  link_highlights_to_colorscheme()
  state.run_id = state.run_id + 1
  state.repo_root = repo_root
  local diff_window, buffer_before_diff = remember_window_before_diff()

  -- Arguments are `{ listed, scratch }`: the diff should not appear as a
  -- normal file buffer and should never be written to disk.
  local diff_buffer = vim.api.nvim_create_buf(false, true)
  state.diff_buf = diff_buffer
  -- `vim.bo[buffer]` accesses that buffer's local options. `bufhidden` accepts
  -- `''`, `hide`, `unload`, `delete`, or `wipe`; `hide` keeps this diff loaded
  -- when a source file replaces it, so `<C-o>` can return to the diff.
  vim.bo[diff_buffer].bufhidden = 'hide'
  vim.bo[diff_buffer].modifiable = false
  -- A URI-like synthetic name identifies the buffer without implying a disk path.
  vim.api.nvim_buf_set_name(diff_buffer, 'redpen-diff://' .. state.run_id)
  vim.api.nvim_win_set_buf(diff_window, diff_buffer)
  if is_disposable_empty_buffer(buffer_before_diff) then
    -- The deleted startup buffer cannot be reached with `<C-o>`. It contained
    -- nothing; `<C-o>` is used later to return from a source file to the diff.
    vim.api.nvim_buf_delete(buffer_before_diff, { force = true })
    state.buffer_before_diff = nil
  end

  -- The filetype lets users add their own buffer-local diff mappings.
  vim.bo[diff_buffer].filetype = 'redpen-diff'
  -- `<C-o>` can return from a source file; restore the diff-only window options.
  vim.api.nvim_create_autocmd('BufEnter', {
    -- This is a field in the autocmd options table, not an assignment statement.
    -- It filters `BufEnter`, so the callback runs only for this diff buffer.
    buffer = diff_buffer,
    callback = function()
      state.diff_win = vim.api.nvim_get_current_win()
      apply_diff_window_options()
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = diff_buffer,
    -- Run once for this specific buffer; wiping it invalidates all diff state.
    once = true,
    callback = function(args)
      if args.buf ~= state.diff_buf then return end
      state.run_id = state.run_id + 1
      stop_running_jobs()
      reset_diff_state()
    end,
  })

  show_loading_diff(diff_mode)
end

function M.open() return open(DIFF_MODE.WORKING_TREE) end

function M.open_head() return open(DIFF_MODE.HEAD_COMMIT) end

return M
