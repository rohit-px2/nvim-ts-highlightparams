local M = {}
local uv=vim.loop
-- Produces the difference between two values (values that are in one table but not the other)
-- and whether they are different
-- @param a table the first table
-- @param b table the second table
function M.difference(a, b)
    local aa = {}
    for _,v in pairs(a) do aa[v]=true end
    for _,v in pairs(b) do aa[v]=nil end
    local ret = {}
    local n = 0
    local is_different = false
    for _,v in pairs(a) do
        if aa[v] then n=n+1 ret[n]=v is_different=true end
    end
    return ret, is_different
end

-- Produces the length of tbl.
-- @param tbl table The table.
-- @return number len The length (non-negative integer).
function M.tbl_length(tbl)
  local count = 0
  for _, _ in ipairs(tbl) do
    count = count + 1
  end
  return count
end

-- print_delta prints the elapsed time between the current time
-- and start.
-- @param start number The start time.
-- @return number curtime The current time
function M.print_delta(start)
  local finish = uv.hrtime()
  print("Time Elapsed:", finish - start)
  return uv.hrtime()
end
return M
