-- Splash animation player for the snacks dashboard.
-- Same idea as milli.nvim's runtime, with two fixes for responsiveness:
--   * only rows that changed between frames are repainted (milli repaints
--     everything every frame, which is what made it lag)
--   * playback runs while the dashboard is visible — including behind floats
--     like mini.files — and holds only when it's not on screen at all
-- Data format: { delays, frames, colors? } as emitted by `milli export -t lua`.

local M = {}

local ns = vim.api.nvim_create_namespace("dashboard_splash")
local hl_cache = {}
local token = 0 -- bumps on every (re)attach; orphaned loops see it and stop

local PAUSE_TICK = 150 -- ms between "are we on screen again?" checks while held

local function hl_group(fg, bg)
  local key = fg .. bg
  if not hl_cache[key] then
    local name = ("DashSplash_%s_%s"):format(fg:sub(2), bg == "NONE" and "NONE" or bg:sub(2))
    vim.api.nvim_set_hl(0, name, { fg = fg, bg = bg ~= "NONE" and bg or nil })
    hl_cache[key] = name
  end
  return hl_cache[key]
end

local function runs_equal(a, b)
  if a == b then return true end
  if not a or not b or #a ~= #b then return false end
  for i, ra in ipairs(a) do
    local rb = b[i]
    if ra[1] ~= rb[1] or ra[2] ~= rb[2] or ra[3] ~= rb[3] or ra[4] ~= rb[4] then
      return false
    end
  end
  return true
end

local function play(buf, data, my, opts)
  local frames, colors, delays = data.frames, data.colors, data.delays
  local speed = opts.speed or 1.0
  local loop = opts.loop ~= false

  -- Anchor: first non-blank line of frame 1 (seeded into the dashboard
  -- header), located in the buffer to find where the art starts and how far
  -- snacks indented it.
  local anchor_idx, anchor_text
  for i, line in ipairs(frames[1]) do
    if line:find("%S") then
      anchor_idx, anchor_text = i, (line:gsub("%s+$", ""))
      break
    end
  end
  if not anchor_idx then return end

  local start_row, pad
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local pos = l:find(anchor_text, 1, true)
    if pos then
      start_row, pad = i - anchor_idx, l:sub(1, pos - 1)
      break
    end
  end
  if not start_row then return end
  local pad_bytes = #pad

  local function paint_row(row, line, runs)
    local buf_row = start_row + row - 1
    pcall(vim.api.nvim_buf_set_lines, buf, buf_row, buf_row + 1, false, { pad .. line })
    vim.api.nvim_buf_clear_namespace(buf, ns, buf_row, buf_row + 1)
    for _, run in ipairs(runs or {}) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, buf_row, pad_bytes + run[1], {
        end_col = pad_bytes + run[2],
        hl_group = hl_group(run[3], run[4]),
        priority = 200,
      })
    end
  end

  local function paint(idx, prev)
    local frame, pframe = frames[idx], prev and frames[prev]
    local fcolors = colors and colors[idx]
    local pcolors = prev and colors and colors[prev]
    vim.bo[buf].modifiable = true
    for r, line in ipairs(frame) do
      -- frame lines are interned strings, so == is cheap
      local same = pframe and pframe[r] == line
        and runs_equal(fcolors and fcolors[r], pcolors and pcolors[r])
      if not same then
        paint_row(r, line, fcolors and fcolors[r])
      end
    end
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
  end

  -- Paint frame 1 right away: snacks just (re)rendered the header with its
  -- own highlight group, so without this the art sits uncolored until the
  -- next tick lands (the "blue blocks" glitch).
  paint(1, nil)
  if #frames == 1 then return end

  local function tick(idx)
    return math.max(15, (delays and delays[idx] or 100) / speed)
  end

  local idx, prev = 2, 1
  local function step()
    if my ~= token or not vim.api.nvim_buf_is_valid(buf) then return end
    if vim.fn.bufwinid(buf) == -1 then
      vim.defer_fn(step, PAUSE_TICK) -- dashboard not on screen: hold
      return
    end
    paint(idx, prev)
    prev = idx
    if idx == #frames and not loop then return end
    local delay = tick(idx)
    idx = idx % #frames + 1
    vim.defer_fn(step, delay)
  end
  vim.defer_fn(step, tick(1))
end

--- Animate `data` in the snacks dashboard whenever it (re)renders.
--- Re-render (open, resize) resets the buffer to the static header, so each
--- event restarts playback with a fresh anchor position.
--- `opts`: { speed?, loop? } — see lua/config/splash-settings.lua
function M.setup(data, opts)
  opts = opts or {}
  vim.api.nvim_create_autocmd("User", {
    pattern = { "SnacksDashboardOpened", "SnacksDashboardUpdatePost" },
    callback = function()
      vim.schedule(function()
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local buf = vim.api.nvim_win_get_buf(win)
          if vim.bo[buf].filetype == "snacks_dashboard" then
            token = token + 1
            play(buf, data, token, opts)
            return
          end
        end
      end)
    end,
  })
end

return M
