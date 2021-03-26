local ts_utils = require 'nvim-treesitter.ts_utils'
local locals = require 'nvim-treesitter.locals'
local parsers = require 'nvim-treesitter.parsers'
local queries = require 'nvim-treesitter.query'
local semantic_ns = vim.api.nvim_create_namespace('params-highlight')
local scope_ns = vim.api.nvim_create_namespace('scope-highlight')
local uv = vim.loop
local M = {}
M.langs = {}
M.parsers = {}
-- Converts an object to a string.
-- Particularly, used for tables
-- @param o any The object to be turned into a string
local function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
    else
      return tostring(o)
    end
end

-- benchmarks a function, returning the amount of time it took
-- to run in nanoseconds (using uv.hrtime)
-- @param f function the function to benchmark
local function benchmark(f, ...)
  local start = uv.hrtime()
  f(...)
  local delta = uv.hrtime() - start
  return delta
end

-- Highlights every node in nodes with the given buffer, highlighting namespace,
-- and highlight group
function M.highlight_nodes(nodes, bufnr, namespace, hlgroup, start_row, end_row)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, start_row, end_row)
  for _, node in ipairs(nodes) do
    vim.schedule(function()
      ts_utils.highlight_node(node, bufnr, namespace, hlgroup)
    end)
  end
end

-- Like ts_utils.get_node_text but without the nvim api call (use buffer parameter)
function M.get_node_text(node, buffer)
  local start_row, start_col, end_row, end_col = node:range()
  --print("Start row:", start_row)
  --print("Start col:", start_col)
  if start_row ~= end_row then
    local lines = {}
    for i = start_row, end_row + 1 do
      lines[i-start_row + 1] = buffer[i]
    end
    lines[1] = string.sub(lines[1], start_col+1)
    lines[#lines] = string.sub(lines[#lines], 1, end_col)
    print(lines[1])
    return lines
  else
    local line = buffer[start_row+1]
    local x = line and { string.sub(line, start_col + 1, end_col) } or {}
    return x
  end
end

-- Gets usages of node within the given scope.
-- Here, a "usage" means an identifier within the scope whose text matches
-- the text of node.
function M.get_usages(node, scope, bufnr, usage_nodes, buffer, tbl, text, sr, sc, er, ec)
  if not sr then
    sr, sc, er, ec = node:range()
  end
  text = text or M.get_node_text(node, buffer)[1]
  usage_nodes = usage_nodes or {}
  for pnode, _ in scope:iter_children() do
    if tbl[pnode] == text then
      usage_nodes[#usage_nodes+1] = pnode
      goto cont
    end
    -- pnode will either be a new scope or a node.
    -- First we check if it is a scope
    if pnode:named_child_count() ~= 0 then
      -- Iterate over children recursively
     M.get_usages(node, pnode, bufnr, usage_nodes, buffer, tbl, text, sr, sc, er, ec)
    elseif pnode:type() == 'identifier' and M.get_node_text(pnode, buffer)[1] == text then
      -- A function with the same name as the parameter should not be highlighted
      -- In general, identifiers with the same name as a parameter, but that come before
      -- the parameter, are not usages of the parameter.
      local nr, nc, _, _= pnode:range()
      if nr < sr or (nr == sr and nc < sc) then goto cont end
      -- Check the s-expr of the parent and see if we are in a declaration
      usage_nodes[#usage_nodes+1] = pnode
      tbl[pnode] = text
    end
    ::cont::
  end
  return usage_nodes
end

function M.schedule_run(f, ...)
  local args = {...}
  vim.schedule(function()
    return f(unpack(args))
  end)
end

M.types = {
  ["function"] = true,
  ["function_definition"] = true,
  ["arrow_function"] = true,
  ["method_definition"] = true,
  ["function_declaration"] = true,
  ["function_item"] = true,
  ["method_declaration"] = true,
  ["local_function"] = true,
  -- go anonymous function
  ["func_literal"] = true,
}

local function is_func_node(type)
  -- Why are there so many different ways of writing "function"
  return M.types[type] ~= nil
end

-- Highlights all usages of parameters in root from start_row to end_row.
function M.highlight_parameters_in(root, bufnr, start_row, end_row, query, buffer, namespace)
  local usage_buffer = {}
  local iter = query:iter_captures(root, bufnr, start_row, end_row)
  --for id, node in query:iter_captures(root, bufnr, start_row, end_row) do
  while true do
    local status, id, node = pcall(function() return iter() end)
    if status == false then
      print("Ran into an error")
      M.clear_cache()
      return
    end
    if not id or not node then return end
    -- If node is a parameter, highlight its usages
    if query.captures[id] == 'parameter' then
      local scope = node:parent()
      -- Get function scope
      while true do
        if scope == root then goto cont end
        if is_func_node(scope:type()) then
          break
        end
        scope = scope:parent()
      end
      local usage_nodes = M.get_usages(node, scope, bufnr, {}, buffer, usage_buffer, nil)
      M.highlight_nodes(usage_nodes, bufnr, namespace, 'TSParameter', start_row, end_row)
    end
    ::cont::
  end
end


-- Around 5x faster than v1
function M.highlight_parameters_v2()
  local bufnr = vim.api.nvim_get_current_buf()
  if not bufnr then return end
  local lang = parsers.get_buf_lang(bufnr)
  if not lang then return end
  local parser = parsers.get_parser(bufnr, lang)
  local lines = tonumber(vim.api.nvim_exec([[echo line('$')]], true))
  if lines and lines > 10000 then return end
  if not parser then return end
  M.current_buffer = bufnr
  local tstree = parser:parse()
  local tree = tstree[1]
  local query = queries.get_query(lang, 'highlights')
  local root = tree:root()
  local start_row, _, end_row, _ = root:range()
  M.buffer_contents = vim.api.nvim_buf_get_lines(bufnr, 0, end_row, true)
  --M.buffers[bufnr] = M.buffer_contents
  M.highlight_parameters_in(root, bufnr, start_row, end_row, query, M.buffer_contents, semantic_ns)
end

-- Gets the starting and ending line that is viewable in the current buffer
-- Note: 0-indexed
function M.get_view_range()
  local top_line = tonumber(vim.api.nvim_exec([[echo line('w0')]], true))
  local bot_line = tonumber(vim.api.nvim_exec([[echo line('w$')]], true))
  return top_line-1, bot_line-1
end

M.prev_time = uv.hrtime()
M.tick = {}

-- Clears cache contents
function M.clear_cache()
  M.buffer_contents = {}
  M.tick = {}
  M.parsers = {}
  vim.api.nvim_buf_clear_namespace(0, semantic_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(0, scope_ns, 0, -1)
end

-- Only highlight parameters that the user can see
-- Should work well with highlight_parameters_v2
-- (run highlight_parameters_v2 on BufEnter, and run this continuously
-- (CursorHold, CursorMoved, TextChanged))
function M.highlight_parameters_in_view()
  local handle
  handle = uv.new_async(vim.schedule_wrap(function()
    local bufnr = vim.api.nvim_get_current_buf()
    if not bufnr then return end
    local cur_time = uv.hrtime()
    -- Allow call every 0.2 secs minimum
    if (M.prev_time and cur_time - M.prev_time < 200000000) then
      --print("Not doing any work now")
      return
    end
    local new_tick = vim.b.changedtick
    if new_tick == M.tick[bufnr] then
      --print("Not doing any work")
      return
    end
    M.tick[bufnr] = new_tick
    M.prev_time = cur_time

    local lines = tonumber(vim.api.nvim_exec([[echo line('$')]], true))
    if lines and lines > 10000 then return
    elseif not lines then return end

    local lang = M.langs[bufnr] or parsers.get_buf_lang(bufnr)
    if not lang then return end
    M.langs[bufnr] = M.langs[bufnr] or lang
    local parser = M.parsers[bufnr] or parsers.get_parser(bufnr, lang)
    if not parser then return end

    M.parsers[bufnr] = M.parsers[bufnr] or parser
    M.current_buffer = bufnr
    local query = queries.get_query(lang, 'highlights')
    --local query = vim.treesitter.get_query(lang, 'highlights')
    local root = parser:parse()[1]:root()
    local view_start, view_end = M.get_view_range()
    local cur_node = ts_utils.get_node_at_cursor(0)
    if not cur_node then return end
    if cur_node == root then return end
    while true do
      if not cur_node:parent() or cur_node:parent() == root then break
      else
        cur_node = cur_node:parent()
      end
    end
    local root_start, _, root_end, _ = cur_node:range()
    view_start = root_start and math.min(view_start, root_start) or view_start
    view_end = root_end and math.max(view_end, root_end) or view_end
    if view_start < 0 then view_start = 0 end
    if view_end > lines-1 then view_end = lines-1 end
    --print(view_start)
    --print(view_end)
    M.buffer_contents = vim.api.nvim_buf_get_lines(bufnr, 0, view_end+1, true)
    -- Highlight in current function if user cannot see parameters
    --local cur_node = ts_utils.get_node_at_cursor()
    --while not cur_node:type():find("function") do
      --if cur_node == root then break end
      --cur_node = cur_node:parent()
    --end
    M.highlight_parameters_in(root, bufnr, view_start, view_end, query, M.buffer_contents, semantic_ns)
    handle:close()
  end))
  handle:send()
end

function M.test()
  print("Time Elasped:", benchmark(M.highlight_parameters_in_view))
end

function M.highlight_parameters_v2_test()
  print("Time Elapsed:", benchmark(M.highlight_parameters_v2))
end

function M.highlight_parameters_v1_test()
  print("Time Elapsed:", benchmark(M.highlight_parameters))
end

-- Highlights usages of parameters in the current buffer.
-- Note: Right now this is too slow to be run on each keystroke/cursorhold
-- as there will be a huge delay
-- From my estimates a ~1500 line file will take roughly 0.4 seconds
function M.highlight_parameters()
  local bufnr = vim.api.nvim_get_current_buf()
  local lang = parsers.get_buf_lang(bufnr)
  if not lang then return end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local parser = parsers.get_parser(bufnr, lang)
  if not parser then return function() end end
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
            ts_utils.highlight_node(usage_node, bufnr, semantic_ns, 'TSParameter')
          end
        end
      end
    end
  end
end

return M
