local utils = require 'nvim-treesitter.ts_utils'
local locals = require 'nvim-treesitter.locals'
local parsers = require 'nvim-treesitter.parsers'
local queries = require 'nvim-treesitter.query'

local M = {}

-- Highlight function arguments in function body
-- Used highlighting idea from nvim-treesitter-refactor/highlight_definitions
-- and node-capturing from nvim-treesitter-playground
function M.highlight_parameters()
  local semantic_ns = vim.api.nvim_create_namespace('params-highlight')
  local bufnr = vim.api.nvim_get_current_buf()
  local lang = parsers.get_buf_lang(bufnr)
  if not lang then return end
  local parser = parsers.get_parser(bufnr, lang)
  if not parser then return function() end end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  parser = parser:language_for_range({row, col, row, col})
  local query = queries.get_query(parser:lang(), 'highlights')
  for _, tree in ipairs(parser:trees()) do
    local root = tree:root()
    local start_row, _, end_row, _ = root:range()
    for _, match in query:iter_matches(root, bufnr, start_row, end_row) do
      for id, node in pairs(match) do
        local c = query.captures[id]
        if c == "parameter" then
          local def_node, scope = locals.find_definition(node, bufnr)
          local usages = locals.find_usages(def_node, scope, bufnr)
          for _, usage_node in ipairs(usages) do
            utils.highlight_node(usage_node, bufnr, semantic_ns, 'TSParameter')
          end
        end
      end
    end
  end
end

return M
