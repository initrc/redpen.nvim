local comment = require 'redpen.comment'
local diff = require 'redpen.diff'

local M = {}

---Add a comment about the current line or active visual line range.
---@return string comment
function M.add_comment() return comment.add() end

---Copy all collected comments to the clipboard and clear them.
---@return string? review
function M.finish_review() return comment.finish() end

---Open the diff for the Git repository containing the current buffer.
function M.open_diff() return diff.open() end

---Open the HEAD commit diff for the Git repository containing the current buffer.
function M.open_diff_head() return diff.open_head() end

---Close the active diff and restore its previous buffer.
function M.close_diff() return diff.close() end

---Open the source location represented by the current diff row.
function M.jump_to_source() return diff.jump_to_source() end

return M
